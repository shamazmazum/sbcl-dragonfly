(in-package :sb-bsd-sockets)

;;; Our class and constructor

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defclass inet-socket (socket)
    ((family :initform sockint::AF-INET))
    (:documentation "Class representing TCP and UDP sockets.

Examples:

 (make-instance 'inet-socket :type :stream :protocol :tcp)

 (make-instance 'inet-socket :type :datagram :protocol :udp)
")))

;;; XXX should we *...* this?
(defparameter inet-address-any (vector 0 0 0 0))

(defmethod socket-namestring ((socket inet-socket))
  (ignore-errors
    (multiple-value-bind (addr port) (socket-name socket)
      (format nil "~{~A~^.~}:~A" (coerce addr 'list) port))))

(defmethod socket-peerstring ((socket inet-socket))
  (ignore-errors
    (multiple-value-bind (addr port) (socket-peername socket)
      (format nil "~{~A~^.~}:~A" (coerce addr 'list) port))))

;;; binding a socket to an address and port.  Doubt that anyone's
;;; actually using this much, to be honest.

(defun make-inet-address (dotted-quads)
  "Return a vector of octets given a string DOTTED-QUADS in the format
\"127.0.0.1\". Signals an error if the string is malformed."
  (declare (type string dotted-quads))
  (labels ((oops ()
             (error "~S is not a string designating an IP address."
                    dotted-quads))
           (check (x)
             (if (typep x '(unsigned-byte 8))
                 x
                 (oops))))
    (let* ((s1 (position #\. dotted-quads))
           (s2 (if s1 (position #\. dotted-quads :start (1+ s1)) (oops)))
           (s3 (if s2 (position #\. dotted-quads :start (1+ s2)) (oops)))
           (u0 (parse-integer dotted-quads :end s1))
           (u1 (parse-integer dotted-quads :start (1+ s1) :end s2))
           (u2 (parse-integer dotted-quads :start (1+ s2) :end s3)))
      (multiple-value-bind (u3 end) (parse-integer dotted-quads :start (1+ s3) :junk-allowed t)
        (unless (= end (length dotted-quads))
          (oops))
        (let ((vector (make-array 4 :element-type '(unsigned-byte 8))))
          (setf (aref vector 0) (check u0)
                (aref vector 1) (check u1)
                (aref vector 2) (check u2)
                (aref vector 3) (check u3))
          vector)))))

(define-condition unknown-protocol ()
  ((name :initarg :name
         :reader unknown-protocol-name))
  (:report (lambda (c s)
             (format s "Protocol not found: ~a" (prin1-to-string
                                                 (unknown-protocol-name c))))))
(defvar *protocols*
  `((:tcp ,sockint::ipproto_tcp "tcp" "TCP")
    (:udp ,sockint::ipproto_udp "udp" "UDP")
    (:ip ,sockint::ipproto_ip "ip" "IP")
    (:ipv6 ,sockint::ipproto_ipv6 "ipv6" "IPV6")
    (:icmp ,sockint::ipproto_icmp "icmp" "ICMP")
    (:igmp ,sockint::ipproto_igmp "igmp" "IGMP")
    (:raw ,sockint::ipproto_raw "raw" "RAW")))

;;; Try to get to a protocol quickly, falling back to calling
;;; getprotobyname if it's available.
(defun get-protocol-by-name (name)
  "Given a protocol name, return the protocol number, the protocol name, and
a list of protocol aliases"
  (let ((result (cdr (if (keywordp name)
                         (assoc name *protocols*)
                         (assoc name *protocols* :test #'string-equal)))))
    (if result
        (values (first result) (second result) (third result))
        #-android
        (getprotobyname (string-downcase name))
        #+android (error 'unknown-protocol :name name))))

#+(and sb-thread (not os-provides-getprotoby-r) (not android) (not netbsd))
;; Since getprotobyname is not thread-safe, we need a lock.
(sb-ext:defglobal **getprotoby-lock** (sb-thread:make-mutex :name "getprotoby lock"))

;;; getprotobyname only works in the internet domain, which is why this
;;; is here
#-android
(defun getprotobyname (name)
  ;; Brownie Points.  Hopefully there's one person out there using
  ;; RSPF sockets and SBCL who will appreciate the extra info
  (labels ((protoent-to-values (protoent)
             (values
              (sockint::protoent-proto protoent)
              (sockint::protoent-name protoent)
              (let ((index 0))
                (loop
                  for alias = (sb-alien:deref
                               (sockint::protoent-aliases protoent) index)
                  while (not (sb-alien:null-alien alias))
                  do (incf index)
                  collect (sb-alien::c-string-to-string
                           (sb-alien:alien-sap alias)
                           (sb-impl::default-external-format)
                           'character))))))
    #+(and sb-thread os-provides-getprotoby-r (not netbsd))
    (let ((buffer-length 1024)
          (max-buffer 10000)
          (result-buf nil)
          (buffer nil)
          #-solaris
          (result nil))
      (declare (type fixnum buffer-length)
               (type fixnum max-buffer))
      (loop
        (unwind-protect
             (progn
               (setf result-buf (sb-alien:make-alien sockint::protoent)
                     buffer (sb-alien:make-alien sb-alien:char buffer-length))
               #-solaris
               (setf result (sb-alien:make-alien (* sockint::protoent)))
               (when (or (sb-alien:null-alien result-buf)
                         (sb-alien:null-alien buffer)
                         (sb-alien:null-alien result))
                 (error "Could not allocate foreign memory."))
               (let ((res (sockint::getprotobyname-r
                           name result-buf buffer buffer-length #-solaris result)))
                 (cond ((eql res 0)
                        #-solaris
                        (when (sb-alien::null-alien (sb-alien:deref result 0))
                          (error 'unknown-protocol :name name))
                        (return-from getprotobyname
                          (protoent-to-values result-buf)))
                       (t
                        (let ((errno (sb-unix::get-errno)))
                          (cond ((eql errno sockint::erange)
                                 (incf buffer-length 1024)
                                 (when (> buffer-length max-buffer)
                                   (error "Exceeded max-buffer of ~d" max-buffer)))
                                (t
                                 (error "Unexpected errno ~d" errno))))))))
          (when result-buf
            (sb-alien:free-alien result-buf))
          (when buffer
            (sb-alien:free-alien buffer))
          #-solaris
          (when result
            (sb-alien:free-alien result)))))
    #+(or (not sb-thread) (not os-provides-getprotoby-r) netbsd)
    (tagbody
       (flet ((get-it ()
                (let ((ent (sockint::getprotobyname name)))
                  (if (sb-alien::null-alien ent)
                      (go :error)
                      (return-from getprotobyname (protoent-to-values ent))))))
         #+(and sb-thread (not netbsd))
         (sb-thread::with-system-mutex (**getprotoby-lock**)
           (get-it))
         #+(or (not sb-thread) netbsd)
         (get-it))
     :error
       (error 'unknown-protocol :name name))))

;;; our protocol provides make-sockaddr-for, size-of-sockaddr,
;;; bits-of-sockaddr

(defmethod make-sockaddr-for ((socket inet-socket) &optional sockaddr &rest address)
  (let ((host (first address))
        (port (second address))
        (sockaddr (or sockaddr (sockint::allocate-sockaddr-in))))
    (when (and host port)
      (let ((in-port (sockint::sockaddr-in-port sockaddr))
            (in-addr (sockint::sockaddr-in-addr sockaddr)))
        (declare (fixnum port))
        ;; port and host are represented in C as "network-endian" unsigned
        ;; integers of various lengths.  This is stupid.  The value of the
        ;; integer doesn't matter (and will change depending on your
        ;; machine's endianness); what the bind(2) call is interested in
        ;; is the pattern of bytes within that integer.

        ;; We have no truck with such dreadful type punning.  Octets to
        ;; octets, dust to dust.
        (setf (sockint::sockaddr-in-family sockaddr) sockint::af-inet)
        (setf (sb-alien:deref in-port 0) (ldb (byte 8 8) port))
        (setf (sb-alien:deref in-port 1) (ldb (byte 8 0) port))

        (setf (sb-alien:deref in-addr 0) (elt host 0))
        (setf (sb-alien:deref in-addr 1) (elt host 1))
        (setf (sb-alien:deref in-addr 2) (elt host 2))
        (setf (sb-alien:deref in-addr 3) (elt host 3))))
  sockaddr))

(defmethod free-sockaddr-for ((socket inet-socket) sockaddr)
  (sockint::free-sockaddr-in sockaddr))

(defmethod size-of-sockaddr ((socket inet-socket))
  sockint::size-of-sockaddr-in)

(defmethod bits-of-sockaddr ((socket inet-socket) sockaddr)
  "Returns address and port of SOCKADDR as multiple values"
  (declare (type (sb-alien:alien
                  (* (sb-alien:struct sb-bsd-sockets-internal::sockaddr-in)))
                 sockaddr))
  (let ((vector (make-array 4 :element-type '(unsigned-byte 8))))
    (loop for i below 4
          do (setf (aref vector i)
                   (sb-alien:deref (sockint::sockaddr-in-addr sockaddr) i)))
    (values
     vector
     (+ (* 256 (sb-alien:deref (sockint::sockaddr-in-port sockaddr) 0))
        (sb-alien:deref (sockint::sockaddr-in-port sockaddr) 1)))))

(defun make-inet-socket (type protocol)
  "Make an INET socket.  Deprecated in favour of make-instance"
  (make-instance 'inet-socket :type type :protocol protocol))
