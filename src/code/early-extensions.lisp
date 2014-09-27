;;;; various extensions (including SB-INT "internal extensions")
;;;; available both in the cross-compilation host Lisp and in the
;;;; target SBCL

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!IMPL")

(defvar *core-pathname* nil
  #!+sb-doc
  "The absolute pathname of the running SBCL core.")

(defvar *runtime-pathname* nil
  #!+sb-doc
  "The absolute pathname of the running SBCL runtime.")

;;; something not EQ to anything we might legitimately READ
(defglobal *eof-object* (make-symbol "EOF-OBJECT"))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant max-hash sb!xc:most-positive-fixnum))

(def!type hash ()
  `(integer 0 ,max-hash))

;;; a type used for indexing into sequences, and for related
;;; quantities like lengths of lists and other sequences.
;;;
;;; A more correct value for the exclusive upper bound for indexing
;;; would be (1- ARRAY-DIMENSION-LIMIT) since ARRAY-DIMENSION-LIMIT is
;;; the exclusive maximum *size* of one array dimension (As specified
;;; in CLHS entries for MAKE-ARRAY and "valid array dimensions"). The
;;; current value is maintained to avoid breaking existing code that
;;; also uses that type for upper bounds on indices (e.g. sequence
;;; length).
;;;
;;; In SBCL, ARRAY-DIMENSION-LIMIT is arranged to be a little smaller
;;; than MOST-POSITIVE-FIXNUM, for implementation (see comment above
;;; ARRAY-DIMENSION-LIMIT) and efficiency reasons: staying below
;;; MOST-POSITIVE-FIXNUM lets the system know it can increment a value
;;; of type INDEX without having to worry about using a bignum to
;;; represent the result.
(def!type index () `(integer 0 (,sb!xc:array-dimension-limit)))

;;; like INDEX, but only up to half the maximum. Used by hash-table
;;; code that does plenty to (aref v (* 2 i)) and (aref v (1+ (* 2 i))).
(def!type index/2 () `(integer 0 (,(floor sb!xc:array-dimension-limit 2))))

;;; like INDEX, but augmented with -1 (useful when using the index
;;; to count downwards to 0, e.g. LOOP FOR I FROM N DOWNTO 0, with
;;; an implementation which terminates the loop by testing for the
;;; index leaving the loop range)
(def!type index-or-minus-1 () `(integer -1 (,sb!xc:array-dimension-limit)))

;;; A couple of VM-related types that are currently used only on the
;;; alpha platform. -- CSR, 2002-06-24
(def!type unsigned-byte-with-a-bite-out (s bite)
  (cond ((eq s '*) 'integer)
        ((and (integerp s) (> s 0))
         (let ((bound (ash 1 s)))
           `(integer 0 ,(- bound bite 1))))
        (t
         (error "Bad size specified for UNSIGNED-BYTE type specifier: ~S." s))))

;;; Motivated by the mips port. -- CSR, 2002-08-22
(def!type signed-byte-with-a-bite-out (s bite)
  (cond ((eq s '*) 'integer)
        ((and (integerp s) (> s 1))
         (let ((bound (ash 1 (1- s))))
           `(integer ,(- bound) ,(- bound bite 1))))
        (t
         (error "Bad size specified for SIGNED-BYTE type specifier: ~S." s))))

(def!type load/store-index (scale lowtag min-offset
                                 &optional (max-offset min-offset))
  `(integer ,(- (truncate (+ (ash 1 16)
                             (* min-offset sb!vm:n-word-bytes)
                             (- lowtag))
                          scale))
            ,(truncate (- (+ (1- (ash 1 16)) lowtag)
                          (* max-offset sb!vm:n-word-bytes))
                       scale)))

#!+(or x86 x86-64)
(defun displacement-bounds (lowtag element-size data-offset)
  (let* ((adjustment (- (* data-offset sb!vm:n-word-bytes) lowtag))
         (bytes-per-element (ceiling element-size sb!vm:n-byte-bits))
         (min (truncate (+ sb!vm::minimum-immediate-offset adjustment)
                        bytes-per-element))
         (max (truncate (+ sb!vm::maximum-immediate-offset adjustment)
                        bytes-per-element)))
    (values min max)))

#!+(or x86 x86-64)
(def!type constant-displacement (lowtag element-size data-offset)
  (flet ((integerify (x)
           (etypecase x
             (integer x)
             (symbol (symbol-value x)))))
    (let ((lowtag (integerify lowtag))
          (element-size (integerify element-size))
          (data-offset (integerify data-offset)))
      (multiple-value-bind (min max) (displacement-bounds lowtag
                                                          element-size
                                                          data-offset)
        `(integer ,min ,max)))))

;;; Similar to FUNCTION, but the result type is "exactly" specified:
;;; if it is an object type, then the function returns exactly one
;;; value, if it is a short form of VALUES, then this short form
;;; specifies the exact number of values.
(def!type sfunction (args &optional result)
  (let ((result (cond ((eq result '*) '*)
                      ((or (atom result)
                           (not (eq (car result) 'values)))
                       `(values ,result &optional))
                      ((intersection (cdr result) sb!xc:lambda-list-keywords)
                       result)
                      (t `(values ,@(cdr result) &optional)))))
    `(function ,args ,result)))

;;; a type specifier
;;;
;;; FIXME: The SB!KERNEL:INSTANCE here really means CL:CLASS.
;;; However, the CL:CLASS type is only defined once PCL is loaded,
;;; which is before this is evaluated.  Once PCL is moved into cold
;;; init, this might be fixable.
(def!type type-specifier () '(or list symbol instance))

;;; the default value used for initializing character data. The ANSI
;;; spec says this is arbitrary, so we use the value that falls
;;; through when we just let the low-level consing code initialize
;;; all newly-allocated memory to zero.
;;;
;;; KLUDGE: It might be nice to use something which is a
;;; STANDARD-CHAR, both to reduce user surprise a little and, probably
;;; more significantly, to help SBCL's cross-compiler (which knows how
;;; to dump STANDARD-CHARs). Unfortunately, the old CMU CL code is
;;; shot through with implicit assumptions that it's #\NULL, and code
;;; in several places (notably both DEFUN MAKE-ARRAY and DEFTRANSFORM
;;; MAKE-ARRAY) would have to be rewritten. -- WHN 2001-10-04
(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; an expression we can use to construct a DEFAULT-INIT-CHAR value
  ;; at load time (so that we don't need to teach the cross-compiler
  ;; how to represent and dump non-STANDARD-CHARs like #\NULL)
  (defparameter *default-init-char-form* '(code-char 0)))

;;; CHAR-CODE values for ASCII characters which we care about but
;;; which aren't defined in section "2.1.3 Standard Characters" of the
;;; ANSI specification for Lisp
;;;
;;; KLUDGE: These are typically used in the idiom (CODE-CHAR
;;; FOO-CHAR-CODE). I suspect that the current implementation is
;;; expanding this idiom into a full call to CODE-CHAR, which is an
;;; annoying overhead. I should check whether this is happening, and
;;; if so, perhaps implement a DEFTRANSFORM or something to stop it.
;;; (or just find a nicer way of expressing characters portably?) --
;;; WHN 19990713
(def!constant bell-char-code 7)
(def!constant backspace-char-code 8)
(def!constant tab-char-code 9)
(def!constant line-feed-char-code 10)
(def!constant form-feed-char-code 12)
(def!constant return-char-code 13)
(def!constant escape-char-code 27)
(def!constant rubout-char-code 127)

;;;; type-ish predicates

;;; X may contain cycles -- a conservative approximation. This
;;; occupies a somewhat uncomfortable niche between being fast for
;;; common cases (we don't want to allocate a hash-table), and not
;;; falling down to exponential behaviour for large trees (so we set
;;; an arbitrady depth limit beyond which we punt).
(defun maybe-cyclic-p (x &optional (depth-limit 12))
  (and (listp x)
       (labels ((safe-cddr (cons)
                  (let ((cdr (cdr cons)))
                    (when (consp cdr)
                      (cdr cdr))))
                (check-cycle (object seen depth)
                  (when (and (consp object)
                             (or (> depth depth-limit)
                                 (member object seen)
                                 (circularp object seen depth)))
                    (return-from maybe-cyclic-p t)))
                (circularp (list seen depth)
                  ;; Almost regular circular list detection, with a twist:
                  ;; we also check each element of the list for upward
                  ;; references using CHECK-CYCLE.
                  (do ((fast (cons (car list) (cdr list)) (safe-cddr fast))
                       (slow list (cdr slow)))
                      ((not (consp fast))
                       ;; Not CDR-circular, need to check remaining CARs yet
                       (do ((tail slow (and (cdr tail))))
                           ((not (consp tail))
                            nil)
                         (check-cycle (car tail) (cons tail seen) (1+ depth))))
                    (check-cycle (car slow) (cons slow seen) (1+ depth))
                    (when (eq fast slow)
                      (return t)))))
         (circularp x (list x) 0))))

;;; Is X a (possibly-improper) list of at least N elements?
(declaim (ftype (function (t index)) list-of-length-at-least-p))
(defun list-of-length-at-least-p (x n)
  (or (zerop n) ; since anything can be considered an improper list of length 0
      (and (consp x)
           (list-of-length-at-least-p (cdr x) (1- n)))))

;;; Is X is a positive prime integer?
(defun positive-primep (x)
  ;; This happens to be called only from one place in sbcl-0.7.0, and
  ;; only for fixnums, we can limit it to fixnums for efficiency. (And
  ;; if we didn't limit it to fixnums, we should use a cleverer
  ;; algorithm, since this one scales pretty badly for huge X.)
  (declare (fixnum x))
  (if (<= x 5)
      (and (>= x 2) (/= x 4))
      (and (not (evenp x))
           (not (zerop (rem x 3)))
           (do ((q 6)
                (r 1)
                (inc 2 (logxor inc 6)) ;; 2,4,2,4...
                (d 5 (+ d inc)))
               ((or (= r 0) (> d q)) (/= r 0))
             (declare (fixnum inc))
             (multiple-value-setq (q r) (truncate x d))))))

;;; Could this object contain other objects? (This is important to
;;; the implementation of things like *PRINT-CIRCLE* and the dumper.)
(defun compound-object-p (x)
  (or (consp x)
      (%instancep x)
      (typep x '(array t *))))

;;;; the COLLECT macro
;;;;
;;;; comment from CMU CL: "the ultimate collection macro..."

;;; helper functions for COLLECT, which become the expanders of the
;;; MACROLET definitions created by COLLECT
;;;
;;; COLLECT-NORMAL-EXPANDER handles normal collection macros.
;;;
;;; COLLECT-LIST-EXPANDER handles the list collection case. N-TAIL
;;; is the pointer to the current tail of the list, or NIL if the list
;;; is empty.
(eval-when (#-sb-xc :compile-toplevel :load-toplevel :execute)
  (defun collect-normal-expander (n-value fun forms)
    `(progn
       ,@(mapcar (lambda (form) `(setq ,n-value (,fun ,form ,n-value))) forms)
       ,n-value))
  (defun collect-list-expander (n-value n-tail forms)
    (let ((n-res (gensym)))
      `(progn
         ,@(mapcar (lambda (form)
                     `(let ((,n-res (cons ,form nil)))
                        (cond (,n-tail
                               (setf (cdr ,n-tail) ,n-res)
                               (setq ,n-tail ,n-res))
                              (t
                               (setq ,n-tail ,n-res  ,n-value ,n-res)))))
                   forms)
         ,n-value))))

;;; Collect some values somehow. Each of the collections specifies a
;;; bunch of things which collected during the evaluation of the body
;;; of the form. The name of the collection is used to define a local
;;; macro, a la MACROLET. Within the body, this macro will evaluate
;;; each of its arguments and collect the result, returning the
;;; current value after the collection is done. The body is evaluated
;;; as a PROGN; to get the final values when you are done, just call
;;; the collection macro with no arguments.
;;;
;;; INITIAL-VALUE is the value that the collection starts out with,
;;; which defaults to NIL. FUNCTION is the function which does the
;;; collection. It is a function which will accept two arguments: the
;;; value to be collected and the current collection. The result of
;;; the function is made the new value for the collection. As a
;;; totally magical special-case, FUNCTION may be COLLECT, which tells
;;; us to build a list in forward order; this is the default. If an
;;; INITIAL-VALUE is supplied for COLLECT, the stuff will be RPLACD'd
;;; onto the end. Note that FUNCTION may be anything that can appear
;;; in the functional position, including macros and lambdas.
(defmacro collect (collections &body body)
  (let ((macros ())
        (binds ()))
    (dolist (spec collections)
      (unless (proper-list-of-length-p spec 1 3)
        (error "malformed collection specifier: ~S" spec))
      (let* ((name (first spec))
             (default (second spec))
             (kind (or (third spec) 'collect))
             (n-value (gensym (concatenate 'string
                                           (symbol-name name)
                                           "-N-VALUE-"))))
        (push `(,n-value ,default) binds)
        (if (eq kind 'collect)
          (let ((n-tail (gensym (concatenate 'string
                                             (symbol-name name)
                                             "-N-TAIL-"))))
            (if default
              (push `(,n-tail (last ,n-value)) binds)
              (push n-tail binds))
            (push `(,name (&rest args)
                     (collect-list-expander ',n-value ',n-tail args))
                  macros))
          (push `(,name (&rest args)
                   (collect-normal-expander ',n-value ',kind args))
                macros))))
    `(macrolet ,macros (let* ,(nreverse binds) ,@body))))

;;;; some old-fashioned functions. (They're not just for old-fashioned
;;;; code, they're also used as optimized forms of the corresponding
;;;; general functions when the compiler can prove that they're
;;;; equivalent.)

;;; like (MEMBER ITEM LIST :TEST #'EQ)
(defun memq (item list)
  #!+sb-doc
  "Return tail of LIST beginning with first element EQ to ITEM."
  ;; KLUDGE: These could be and probably should be defined as
  ;;   (MEMBER ITEM LIST :TEST #'EQ)),
  ;; but when I try to cross-compile that, I get an error from
  ;; LTN-ANALYZE-KNOWN-CALL, "Recursive known function definition". The
  ;; comments for that error say it "is probably a botched interpreter stub".
  ;; Rather than try to figure that out, I just rewrote this function from
  ;; scratch. -- WHN 19990512
  (do ((i list (cdr i)))
      ((null i))
    (when (eq (car i) item)
      (return i))))

;;; like (ASSOC ITEM ALIST :TEST #'EQ):
;;;   Return the first pair of ALIST where ITEM is EQ to the key of
;;;   the pair.
(defun assq (item alist)
  ;; KLUDGE: CMU CL defined this with
  ;;   (DECLARE (INLINE ASSOC))
  ;;   (ASSOC ITEM ALIST :TEST #'EQ))
  ;; which is pretty, but which would have required adding awkward
  ;; build order constraints on SBCL (or figuring out some way to make
  ;; inline definitions installable at build-the-cross-compiler time,
  ;; which was too ambitious for now). Rather than mess with that, we
  ;; just define ASSQ explicitly in terms of more primitive
  ;; operations:
  (dolist (pair alist)
    ;; though it may look more natural to write this as
    ;;   (AND PAIR (EQ (CAR PAIR) ITEM))
    ;; the temptation to do so should be resisted, as pointed out by PFD
    ;; sbcl-devel 2003-08-16, as NIL elements are rare in association
    ;; lists.  -- CSR, 2003-08-16
    (when (and (eq (car pair) item) (not (null pair)))
      (return pair))))

;;; like (DELETE .. :TEST #'EQ):
;;;   Delete all LIST entries EQ to ITEM (destructively modifying
;;;   LIST), and return the modified LIST.
(defun delq (item list)
  (let ((list list))
    (do ((x list (cdr x))
         (splice '()))
        ((endp x) list)
      (cond ((eq item (car x))
             (if (null splice)
               (setq list (cdr x))
               (rplacd splice (cdr x))))
            (t (setq splice x)))))) ; Move splice along to include element.


;;; like (POSITION .. :TEST #'EQ):
;;;   Return the position of the first element EQ to ITEM.
(defun posq (item list)
  (do ((i list (cdr i))
       (j 0 (1+ j)))
      ((null i))
    (when (eq (car i) item)
      (return j))))

(declaim (inline neq))
(defun neq (x y)
  (not (eq x y)))

;;; not really an old-fashioned function, but what the calling
;;; convention should've been: like NTH, but with the same argument
;;; order as in all the other indexed dereferencing functions, with
;;; the collection first and the index second
(declaim (inline nth-but-with-sane-arg-order))
(declaim (ftype (function (list index) t) nth-but-with-sane-arg-order))
(defun nth-but-with-sane-arg-order (list index)
  (nth index list))

(defun adjust-list (list length initial-element)
  (let ((old-length (length list)))
    (cond ((< old-length length)
           (append list (make-list (- length old-length)
                                   :initial-element initial-element)))
          ((> old-length length)
           (subseq list 0 length))
          (t list))))

;;;; miscellaneous iteration extensions

;;; like Scheme's named LET
;;;
;;; (CMU CL called this ITERATE, and commented it as "the ultimate
;;; iteration macro...". I (WHN) found the old name insufficiently
;;; specific to remind me what the macro means, so I renamed it.)
(defmacro named-let (name binds &body body)
  (dolist (x binds)
    (unless (proper-list-of-length-p x 2)
      (error "malformed NAMED-LET variable spec: ~S" x)))
  `(labels ((,name ,(mapcar #'first binds) ,@body))
     (,name ,@(mapcar #'second binds))))

(defun filter-dolist-declarations (decls)
  (mapcar (lambda (decl)
            `(declare ,@(remove-if
                         (lambda (clause)
                           (and (consp clause)
                                (or (eq (car clause) 'type)
                                    (eq (car clause) 'ignore))))
                         (cdr decl))))
          decls))
;;; just like DOLIST, but with one-dimensional arrays
(defmacro dovector ((elt vector &optional result) &body body)
  (multiple-value-bind (forms decls) (parse-body body :doc-string-allowed nil)
    (with-unique-names (index length vec)
      `(let ((,vec ,vector))
        (declare (type vector ,vec))
        (do ((,index 0 (1+ ,index))
             (,length (length ,vec)))
            ((>= ,index ,length) (let ((,elt nil))
                                   ,@(filter-dolist-declarations decls)
                                   ,elt
                                   ,result))
          (let ((,elt (aref ,vec ,index)))
            ,@decls
            (tagbody
               ,@forms)))))))

;;; Iterate over the entries in a HASH-TABLE, first obtaining the lock
;;; if the table is a synchronized table.
(defmacro dohash (((key-var value-var) table &key result locked) &body body)
  (multiple-value-bind (forms decls) (parse-body body :doc-string-allowed nil)
    (with-unique-names (gen n-more n-table)
      (let ((iter-form `(with-hash-table-iterator (,gen ,n-table)
                         (loop
                           (multiple-value-bind (,n-more ,key-var ,value-var) (,gen)
                             ,@decls
                             (unless ,n-more (return ,result))
                             ,@forms)))))
        `(let ((,n-table ,table))
           ,(if locked
                `(with-locked-system-table (,n-table)
                   ,iter-form)
                iter-form))))))

;;; Executes BODY for all entries of PLIST with KEY and VALUE bound to
;;; the respective keys and values.
(defmacro doplist ((key val) plist &body body)
  (with-unique-names (tail)
    `(let ((,tail ,plist) ,key ,val)
       (loop (when (null ,tail) (return nil))
             (setq ,key (pop ,tail))
             (when (null ,tail)
               (error "malformed plist, odd number of elements"))
             (setq ,val (pop ,tail))
             (progn ,@body)))))


;;;; hash cache utility

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *profile-hash-cache* nil))

;;; Define a hash cache that associates some number of argument values
;;; with a result value. The TEST-FUNCTION paired with each ARG-NAME
;;; is used to compare the value for that arg in a cache entry with a
;;; supplied arg. The TEST-FUNCTION must not error when passed NIL as
;;; its first arg, but need not return any particular value.
;;; TEST-FUNCTION may be any thing that can be placed in CAR position.
;;;
;;; This code used to store all the arguments / return values directly
;;; in the cache vector. This was both interrupt- and thread-unsafe, since
;;; it was possible that *-CACHE-ENTER would scribble over a region of the
;;; cache vector which *-CACHE-LOOKUP had only partially processed. Instead
;;; we now store the contents of each cache bucket as a separate array, which
;;; is stored in the appropriate cell in the cache vector. A new bucket array
;;; is created every time *-CACHE-ENTER is called, and the old ones are never
;;; modified. This means that *-CACHE-LOOKUP will always work with a set
;;; of consistent data. The overhead caused by consing new buckets seems to
;;; be insignificant on the grand scale of things. -- JES, 2006-11-02
;;;
;;; NAME is used to define these functions:
;;; <name>-CACHE-LOOKUP Arg*
;;;   See whether there is an entry for the specified ARGs in the
;;;   cache. If not present, the :DEFAULT keyword (default NIL)
;;;   determines the result(s).
;;; <name>-CACHE-ENTER Arg* Value*
;;;   Encache the association of the specified args with VALUE.
;;; <name>-CACHE-CLEAR
;;;   Reinitialize the cache, invalidating all entries and allowing
;;;   the arguments and result values to be GC'd.
;;;
;;; These other keywords are defined:
;;; :HASH-BITS <n>
;;;   The size of the cache as a power of 2.
;;; :HASH-FUNCTION function
;;;   Some thing that can be placed in CAR position which will compute
;;;   a fixnum with at least (* 2 <hash-bits>) of information in it.
;;; :VALUES <n>
;;;   the number of return values cached for each function call
(defvar *cache-vector-symbols* nil)

(defun drop-all-hash-caches ()
  (dolist (name *cache-vector-symbols*)
    (set name nil)))

;; Make a new hash-cache and optionally create the statistics vector.
(defun alloc-hash-cache (size symbol)
  (let (cache)
    ;; It took me a while to figure out why infinite recursion could occur
    ;; in VALUES-SPECIFIER-TYPE. It's because SET calls VALUES-SPECIFIER-TYPE.
    (macrolet ((set! (symbol value)
                 `(#+sb-xc-host set
                   #-sb-xc-host sb!kernel:%set-symbol-global-value
                   ,symbol ,value))
               (reset-stats ()
                 ;; If statistics gathering is not not compiled-in,
                 ;; no sense in setting a symbol that is never used.
                 ;; While this uses SYMBOLICATE at runtime,
                 ;; it is inconsequential to performance.
                 (if *profile-hash-cache*
                     `(let ((statistics
                             (let ((*package* (symbol-package symbol)))
                               (symbolicate symbol "STATISTICS"))))
                        (unless (boundp statistics)
                          (set! statistics
                                (make-array 3 :element-type 'fixnum
                                              :initial-contents '(1 0 0))))))))
      ;; It would be bad if another thread sees MAKE-ARRAY's result in the
      ;; global variable before the vector's header+length have been set.
      ;; This is theoretically possible if the architecture allows out-of-order
      ;; memory writes.  A barrier will prevent that, but a meta-bug prevents
      ;; using SB!THREAD:BARRIER here. The macro isn't defined yet? (FIXME)
      ;; Note that this bug already existed and I'm just documenting it.
      ;; Most likely all caches are made before ever starting multiple threads.
      (progn ; sb!thread:barrier (:write)
        (reset-stats)
        (setq cache (make-array size :initial-element 0)))
      (set! symbol cache))))

;; At present we make a new vector every time a line is re-written,
;; to make it thread-safe and interrupt-safe. A multi-word compare-and-swap
;; is tricky to code and stronger than we need. It is possible instead
;; to provide multi-word reads that can detect failure of atomicity,
;; and on x86 it's possible to have atomic double-wide read/write,
;; so a 1-arg/1-result cache line needn't cons at all except once
;; (and maybe not even that if we make the cache into pairs of cells).
;; But this way is easier to understand, for now anyway.
(macrolet ((def (n)
             (let* ((ftype `(sfunction ,(make-list n :initial-element t) t))
                    (fn (symbolicate "ALLOC-HASH-CACHE-LINE/"
                                     (write-to-string n)))
                    (args (loop for i from 1 to n
                                collect (make-symbol (write-to-string i)))))
               `(progn
                  (declaim (ftype ,ftype ,fn))
                  (defun ,fn ,args
                    (declare (optimize (safety 0)))
                    ,(if (<= n 3)
                         `(list* ,@args)
                         ;; FIXME: (VECTOR ,@args) should emit exactly the
                         ;; same code as this, except it is worse.
                         `(let ((a (make-array ,n)))
                            ,@(loop for i from 0 for arg in args
                                    collect `(setf (svref a ,i) ,arg))
                            a)))))))
  (def 2)
  (def 3)
  (def 4)
  (def 5)
  (def 6))

;; Should this be !DEFINE-HASH-CACHE ?
(defmacro define-hash-cache (name args
                             &key hash-function hash-bits memoizer
                                  (values 1))
  (declare (ignore memoizer))
  (dolist (arg args)
    (unless (= (length arg) 2)
      (error "bad argument spec: ~S" arg)))
  (assert (typep hash-bits '(integer 5 14))) ; reasonable bounds
  (let* ((fun-name (symbolicate name "-MEMO-WRAPPER"))
         (var-name (symbolicate "**" name "-CACHE-VECTOR**"))
         (statistics-name
          (when *profile-hash-cache*
            (symbolicate var-name "STATISTICS")))
         (nargs (length args))
         (size (ash 1 hash-bits))
         (hashval (make-symbol "HASH"))
         (cache (make-symbol "CACHE"))
         (entry (make-symbol "LINE"))
         (thunk (make-symbol "THUNK"))
         (arg-vars (mapcar #'first args))
         (result-temps (loop for i from 1 to values
                             collect (make-symbol (format nil "RES~D" i))))
         (temps (append (mapcar (lambda (x) (make-symbol (string x)))
                                arg-vars)
                        result-temps))
         (tests (mapcar (lambda (arg temp) ; -> (EQx ARG #:ARG)
                          `(,(cadr arg) ,(car arg) ,temp))
                        args temps))
         (cache-type `(simple-vector ,size))
         (line-type (let ((n (+ nargs values)))
                      (if (<= n 3) 'cons `(simple-vector ,n))))
         (binds
          (case (length temps)
            (2 `((,(first temps) (car ,entry))
                 (,(second temps) (cdr ,entry))))
            (3 (let ((arg-temp (sb!xc:gensym "ARGS")))
                 `((,arg-temp (cdr ,entry))
                   (,(first temps) (car ,entry))
                   (,(second temps) (car (truly-the cons ,arg-temp)))
                   (,(third temps) (cdr ,arg-temp)))))
            (t (loop for i from 0 for x in temps
                     collect `(,x (svref ,entry ,i))))))
         (fun
          `(defun ,fun-name (,thunk ,@arg-vars)
             ,@(when *profile-hash-cache* ; count seeks
                 `((when (boundp ',statistics-name)
                     (incf (aref ,statistics-name 0)))))
             (let ((,hashval (the fixnum (funcall ,hash-function ,@arg-vars)))
                   (,cache ,var-name))
               (when ,cache
                 (let ((,hashval ,hashval))
                   (declare (fixnum ,hashval))
                   (loop repeat 2 do
                     (let ((,entry (svref (truly-the ,cache-type ,cache)
                                          (ldb (byte ,hash-bits 0) ,hashval))))
                       (unless (eql ,entry 0)
                         (locally (declare (type ,line-type ,entry))
                           (let* ,binds
                             (when (and ,@tests)
                               (return-from ,fun-name
                                 (values ,@result-temps))))))
                       (setq ,hashval (ash ,hashval ,(- hash-bits)))))))
               (multiple-value-bind ,result-temps (funcall ,thunk)
                 (let ((,entry
                        (,(let ((*package* (symbol-package 'alloc-hash-cache)))
                            (symbolicate "ALLOC-HASH-CACHE-LINE/"
                                         (write-to-string (+ nargs values))))
                         ,@arg-vars ,@result-temps))
                       (,cache
                        (truly-the ,cache-type
                         (or ,cache (alloc-hash-cache ,size ',var-name))))
                       (idx1 (ldb (byte ,hash-bits 0) ,hashval))
                       (idx2 (ldb (byte ,hash-bits ,hash-bits) ,hashval)))
                   ,@(when *profile-hash-cache*
                       `((incf (aref ,statistics-name 1)))) ; count misses
                   (cond ((eql (svref ,cache idx1) 0)
                          (setf (svref ,cache idx1) ,entry))
                         ((eql (svref ,cache idx2) 0)
                          (setf (svref ,cache idx2) ,entry))
                         (t
                           ,@(when *profile-hash-cache* ; count evictions
                               `((incf (aref ,statistics-name 2))))
                             ;; Use one bit of randomness to pick a victim.
                           (setf (svref ,cache ; [revisit- PVK says pick idx1]
                                     (if #-sb-xc-host
                                         (logbitp 4 (sb!kernel:get-lisp-obj-address
                                                     ,(car arg-vars)))
                                         #+sb-xc-host (zerop (random 2))
                                         idx1 idx2))
                              ,entry))))
                 (values ,@result-temps))))))
    `(progn
       (pushnew ',var-name *cache-vector-symbols*)
       (defglobal ,var-name nil)
       ,@(when *profile-hash-cache*
           `((declaim (type (simple-array fixnum (3)) ,statistics-name))
             (defvar ,statistics-name)))
       (declaim (type (or null ,cache-type) ,var-name))
       (defun ,(symbolicate name "-CACHE-CLEAR") () (setq ,var-name nil))
       (declaim (inline ,fun-name))
       ,fun)))

;;; some syntactic sugar for defining a function whose values are
;;; cached by DEFINE-HASH-CACHE
;;; These keywords are mostly defined at DEFINE-HASH-CACHE.
;;; Additional options:
;;; :MEMOIZER <name>
;;;   If provided, it is the name of a local macro that must be called
;;;   within the body forms to perform cache lookup/insertion.
;;;   If not provided, then the function's behavior is to automatically
;;;   attempt cache lookup, and on miss, execute the body code and
;;;   insert into the cache.
;;;   Manual control over memoization is useful if there are cases for
;;;   which computing the result is simpler than cache lookup.

(defmacro defun-cached ((name &rest options &key
                              (memoizer (make-symbol "MEMOIZE")
                                        memoizer-supplied-p)
                              &allow-other-keys)
                        args &body body-decls-doc)
  (let ((arg-names (mapcar #'car args)))
    ;; What I wouldn't give to be able to use BINDING*, right?
    (multiple-value-bind (forms decls doc) (parse-body body-decls-doc)
      `(progn
        (define-hash-cache ,name ,args ,@options)
        (defun ,name ,arg-names
          ,@decls
          ,@(if doc (list doc))
          (macrolet ((,memoizer (&body body)
                       ;; We don't need (DX-FLET ((,thunk () ,@body)) ...)
                       ;; This lambda is a single-use local call within
                       ;; the inline memoizing wrapper.
                       `(,',(symbolicate name "-MEMO-WRAPPER")
                         (lambda () ,@body) ,@',arg-names)))
             ,@(if memoizer-supplied-p
                   forms
                   `((,memoizer ,@forms)))))))))

(defmacro define-cached-synonym
    (name &optional (original (symbolicate "%" name)))
  (let ((cached-name (symbolicate "%%" name "-CACHED")))
    `(progn
       (defun-cached (,cached-name :hash-bits 8 :hash-function #'sxhash)
           ((args equal))
         (apply #',original args))
       (defun ,name (&rest args)
         (,cached-name args)))))

;;; FIXME: maybe not the best place
;;;
;;; FIXME: think of a better name -- not only does this not have the
;;; CAR recursion of EQUAL, it also doesn't have the special treatment
;;; of pathnames, bit-vectors and strings.
;;;
;;; KLUDGE: This means that we will no longer cache specifiers of the
;;; form '(INTEGER (0) 4).  This is probably not a disaster.
;;;
;;; A helper function for the type system, which is the main user of
;;; these caches: we must be more conservative than EQUAL for some of
;;; our equality tests, because MEMBER and friends refer to EQLity.
;;; So:
(defun equal-but-no-car-recursion (x y)
  (do () (())
    (cond ((eql x y) (return t))
          ((and (consp x)
                (consp y)
                (eql (pop x) (pop y))))
          (t
           (return)))))

;;;; package idioms

;;; Note: Almost always you want to use FIND-UNDELETED-PACKAGE-OR-LOSE
;;; instead of this function. (The distinction only actually matters when
;;; PACKAGE-DESIGNATOR is actually a deleted package, and in that case
;;; you generally do want to signal an error instead of proceeding.)
(defun %find-package-or-lose (package-designator)
  (or (find-package package-designator)
      (error 'simple-package-error
             :package package-designator
             :format-control "The name ~S does not designate any package."
             :format-arguments (list package-designator))))

;;; ANSI specifies (in the section for FIND-PACKAGE) that the
;;; consequences of most operations on deleted packages are
;;; unspecified. We try to signal errors in such cases.
(defun find-undeleted-package-or-lose (package-designator)
  (let ((maybe-result (%find-package-or-lose package-designator)))
    (if (package-name maybe-result)     ; if not deleted
        maybe-result
        (error 'simple-package-error
               :package maybe-result
               :format-control "The package ~S has been deleted."
               :format-arguments (list maybe-result)))))

;;;; various operations on names

;;; Is NAME a legal function name?
(declaim (inline legal-fun-name-p))
(defun legal-fun-name-p (name)
  (values (valid-function-name-p name)))

(deftype function-name () '(satisfies legal-fun-name-p))

;;; Signal an error unless NAME is a legal function name.
(defun legal-fun-name-or-type-error (name)
  (unless (legal-fun-name-p name)
    (error 'simple-type-error
           :datum name
           :expected-type 'function-name
           :format-control "invalid function name: ~S"
           :format-arguments (list name))))

;;; Given a function name, return the symbol embedded in it.
;;;
;;; The ordinary use for this operator (and the motivation for the
;;; name of this operator) is to convert from a function name to the
;;; name of the BLOCK which encloses its body.
;;;
;;; Occasionally the operator is useful elsewhere, where the operator
;;; name is less mnemonic. (Maybe it should be changed?)
(declaim (ftype (function ((or symbol cons)) symbol) fun-name-block-name))
(defun fun-name-block-name (fun-name)
  (if (symbolp fun-name)
      fun-name
      (multiple-value-bind (legalp block-name)
          (valid-function-name-p fun-name)
        (if legalp
            block-name
            (error "not legal as a function name: ~S" fun-name)))))

(defun looks-like-name-of-special-var-p (x)
  (and (symbolp x)
       (symbol-package x)
       (let ((name (symbol-name x)))
         (and (> (length name) 2) ; to exclude '* and '**
              (char= #\* (aref name 0))
              (char= #\* (aref name (1- (length name))))))))

;;; If COLD-FSET occurs not at top level, just treat it as an ordinary
;;; assignment instead of doing cold static linking. That way things like
;;;   (FLET ((FROB (X) ..))
;;;     (DEFUN FOO (X Y) (FROB X) ..)
;;;     (DEFUN BAR (Z) (AND (FROB X) ..)))
;;; can still "work" for cold init: they don't do magical static
;;; linking the way that true toplevel DEFUNs do, but at least they do
;;; the linking eventually, so as long as #'FOO and #'BAR aren't
;;; needed until "cold toplevel forms" have executed, it's OK.
(defmacro cold-fset (name lambda)
  (style-warn
   "~@<COLD-FSET ~S not cross-compiled at top level: demoting to ~
(SETF FDEFINITION)~:@>"
   name)
  ;; We convert the LAMBDA expression to the corresponding NAMED-LAMBDA
  ;; expression so that the compiler can use NAME in debug names etc.
  (destructuring-bind (lambda-symbol &rest lambda-rest) lambda
    (assert (eql lambda-symbol 'lambda)) ; else dunno how to do conversion
    `(setf (fdefinition ',name)
           (named-lambda ,name ,@lambda-rest))))

;;;; ONCE-ONLY
;;;;
;;;; "The macro ONCE-ONLY has been around for a long time on various
;;;; systems [..] if you can understand how to write and when to use
;;;; ONCE-ONLY, then you truly understand macro." -- Peter Norvig,
;;;; _Paradigms of Artificial Intelligence Programming: Case Studies
;;;; in Common Lisp_, p. 853

;;; ONCE-ONLY is a utility useful in writing source transforms and
;;; macros. It provides a concise way to wrap a LET around some code
;;; to ensure that some forms are only evaluated once.
;;;
;;; Create a LET* which evaluates each value expression, binding a
;;; temporary variable to the result, and wrapping the LET* around the
;;; result of the evaluation of BODY. Within the body, each VAR is
;;; bound to the corresponding temporary variable.
(defmacro once-only (specs &body body)
  (named-let frob ((specs specs)
                   (body body))
    (if (null specs)
        `(progn ,@body)
        (let ((spec (first specs)))
          ;; FIXME: should just be DESTRUCTURING-BIND of SPEC
          (unless (proper-list-of-length-p spec 2)
            (error "malformed ONCE-ONLY binding spec: ~S" spec))
          (let* ((name (first spec))
                 (exp-temp (gensym "ONCE-ONLY")))
            `(let ((,exp-temp ,(second spec))
                   (,name (sb!xc:gensym ,(symbol-name name))))
               `(let ((,,name ,,exp-temp))
                  ,,(frob (rest specs) body))))))))

;;;; various error-checking utilities

;;; This function can be used as the default value for keyword
;;; arguments that must be always be supplied. Since it is known by
;;; the compiler to never return, it will avoid any compile-time type
;;; warnings that would result from a default value inconsistent with
;;; the declared type. When this function is called, it signals an
;;; error indicating that a required &KEY argument was not supplied.
;;; This function is also useful for DEFSTRUCT slot defaults
;;; corresponding to required arguments.
(declaim (ftype (function () nil) missing-arg))
(defun missing-arg ()
  #!+sb-doc
  (/show0 "entering MISSING-ARG")
  (error "A required &KEY or &OPTIONAL argument was not supplied."))

;;; like CL:ASSERT and CL:CHECK-TYPE, but lighter-weight
;;;
;;; (As of sbcl-0.6.11.20, we were using some 400 calls to CL:ASSERT.
;;; The CL:ASSERT restarts and whatnot expand into a significant
;;; amount of code when you multiply them by 400, so replacing them
;;; with this should reduce the size of the system by enough to be
;;; worthwhile. ENFORCE-TYPE is much less common, but might still be
;;; worthwhile, and since I don't really like CERROR stuff deep in the
;;; guts of complex systems anyway, I replaced it too.)
(defmacro aver (expr)
  `(unless ,expr
     (%failed-aver ',expr)))

(defun %failed-aver (expr)
  ;; hackish way to tell we're in a cold sbcl and output the
  ;; message before signalling error, as it may be this is too
  ;; early in the cold init.
  (when (find-package "SB!C")
    (fresh-line)
    (write-line "failed AVER:")
    (write expr)
    (terpri))
  (bug "~@<failed AVER: ~2I~_~A~:>" expr))

(defun bug (format-control &rest format-arguments)
  (error 'bug
         :format-control format-control
         :format-arguments format-arguments))

(defmacro enforce-type (value type)
  (once-only ((value value))
    `(unless (typep ,value ',type)
       (%failed-enforce-type ,value ',type))))

(defun %failed-enforce-type (value type)
  ;; maybe should be TYPE-BUG, subclass of BUG?  If it is changed,
  ;; check uses of it in user-facing code (e.g. WARN)
  (error 'simple-type-error
         :datum value
         :expected-type type
         :format-control "~@<~S ~_is not a ~_~S~:>"
         :format-arguments (list value type)))

;;; Return a function like FUN, but expecting its (two) arguments in
;;; the opposite order that FUN does.
(declaim (inline swapped-args-fun))
(defun swapped-args-fun (fun)
  (declare (type function fun))
  (lambda (x y)
    (funcall fun y x)))

;;; Return the numeric value of a type bound, i.e. an interval bound
;;; more or less in the format of bounds in ANSI's type specifiers,
;;; where a bare numeric value is a closed bound and a list of a
;;; single numeric value is an open bound.
;;;
;;; The "more or less" bit is that the no-bound-at-all case is
;;; represented by NIL (not by * as in ANSI type specifiers); and in
;;; this case we return NIL.
(defun type-bound-number (x)
  (if (consp x)
      (destructuring-bind (result) x result)
      x))

;;; some commonly-occuring CONSTANTLY forms
(macrolet ((def-constantly-fun (name constant-expr)
             `(setf (symbol-function ',name)
                    (constantly ,constant-expr))))
  (def-constantly-fun constantly-t t)
  (def-constantly-fun constantly-nil nil)
  (def-constantly-fun constantly-0 0))

;;; If X is a symbol, see whether it is present in *FEATURES*. Also
;;; handle arbitrary combinations of atoms using NOT, AND, OR.
(defun featurep (x)
  (typecase x
    (cons
     (case (car x)
       ((:not not)
        (cond
          ((cddr x)
           (error "too many subexpressions in feature expression: ~S" x))
          ((null (cdr x))
           (error "too few subexpressions in feature expression: ~S" x))
          (t (not (featurep (cadr x))))))
       ((:and and) (every #'featurep (cdr x)))
       ((:or or) (some #'featurep (cdr x)))
       (t
        (error "unknown operator in feature expression: ~S." x))))
    (symbol (not (null (memq x *features*))))
    (t
      (error "invalid feature expression: ~S" x))))


;;;; utilities for two-VALUES predicates

(defmacro not/type (x)
  (let ((val (gensym "VAL"))
        (win (gensym "WIN")))
    `(multiple-value-bind (,val ,win)
         ,x
       (if ,win
           (values (not ,val) t)
           (values nil nil)))))

(defmacro and/type (x y)
  `(multiple-value-bind (val1 win1) ,x
     (if (and (not val1) win1)
         (values nil t)
         (multiple-value-bind (val2 win2) ,y
           (if (and val1 val2)
               (values t t)
               (values nil (and win2 (not val2))))))))

;;; sort of like ANY and EVERY, except:
;;;   * We handle two-VALUES predicate functions, as SUBTYPEP does.
;;;     (And if the result is uncertain, then we return (VALUES NIL NIL),
;;;     as SUBTYPEP does.)
;;;   * THING is just an atom, and we apply OP (an arity-2 function)
;;;     successively to THING and each element of LIST.
(defun any/type (op thing list)
  (declare (type function op))
  (let ((certain? t))
    (dolist (i list (values nil certain?))
      (multiple-value-bind (sub-value sub-certain?) (funcall op thing i)
        (if sub-certain?
            (when sub-value (return (values t t)))
            (setf certain? nil))))))
(defun every/type (op thing list)
  (declare (type function op))
  (let ((certain? t))
    (dolist (i list (if certain? (values t t) (values nil nil)))
      (multiple-value-bind (sub-value sub-certain?) (funcall op thing i)
        (if sub-certain?
            (unless sub-value (return (values nil t)))
            (setf certain? nil))))))

;;;; DEFPRINTER

;;; These functions are called by the expansion of the DEFPRINTER
;;; macro to do the actual printing.
(declaim (ftype (function (symbol t stream) (values))
                defprinter-prin1 defprinter-princ))
(defun defprinter-prin1 (name value stream)
  (defprinter-prinx #'prin1 name value stream))
(defun defprinter-princ (name value stream)
  (defprinter-prinx #'princ name value stream))
(defun defprinter-prinx (prinx name value stream)
  (declare (type function prinx))
  (when *print-pretty*
    (pprint-newline :linear stream))
  (format stream ":~A " name)
  (funcall prinx value stream)
  (values))
(defun defprinter-print-space (stream)
  (write-char #\space stream))

;;; Define some kind of reasonable PRINT-OBJECT method for a
;;; STRUCTURE-OBJECT class.
;;;
;;; NAME is the name of the structure class, and CONC-NAME is the same
;;; as in DEFSTRUCT.
;;;
;;; The SLOT-DESCS describe how each slot should be printed. Each
;;; SLOT-DESC can be a slot name, indicating that the slot should
;;; simply be printed. A SLOT-DESC may also be a list of a slot name
;;; and other stuff. The other stuff is composed of keywords followed
;;; by expressions. The expressions are evaluated with the variable
;;; which is the slot name bound to the value of the slot. These
;;; keywords are defined:
;;;
;;; :PRIN1    Print the value of the expression instead of the slot value.
;;; :PRINC    Like :PRIN1, only PRINC the value
;;; :TEST     Only print something if the test is true.
;;;
;;; If no printing thing is specified then the slot value is printed
;;; as if by PRIN1.
;;;
;;; The structure being printed is bound to STRUCTURE and the stream
;;; is bound to STREAM.
(defmacro defprinter ((name
                       &key
                       (conc-name (concatenate 'simple-string
                                               (symbol-name name)
                                               "-"))
                       identity)
                      &rest slot-descs)
  (let ((first? t)
        maybe-print-space
        (reversed-prints nil)
        (stream (sb!xc:gensym "STREAM")))
    (flet ((sref (slot-name)
             `(,(symbolicate conc-name slot-name) structure)))
      (dolist (slot-desc slot-descs)
        (if first?
            (setf maybe-print-space nil
                  first? nil)
            (setf maybe-print-space `(defprinter-print-space ,stream)))
        (cond ((atom slot-desc)
               (push maybe-print-space reversed-prints)
               (push `(defprinter-prin1 ',slot-desc ,(sref slot-desc) ,stream)
                     reversed-prints))
              (t
               (let ((sname (first slot-desc))
                     (test t))
                 (collect ((stuff))
                   (do ((option (rest slot-desc) (cddr option)))
                       ((null option)
                        (push `(let ((,sname ,(sref sname)))
                                 (when ,test
                                   ,maybe-print-space
                                   ,@(or (stuff)
                                         `((defprinter-prin1
                                             ',sname ,sname ,stream)))))
                              reversed-prints))
                     (case (first option)
                       (:prin1
                        (stuff `(defprinter-prin1
                                  ',sname ,(second option) ,stream)))
                       (:princ
                        (stuff `(defprinter-princ
                                  ',sname ,(second option) ,stream)))
                       (:test (setq test (second option)))
                       (t
                        (error "bad option: ~S" (first option)))))))))))
    `(def!method print-object ((structure ,name) ,stream)
       (pprint-logical-block (,stream nil)
         (print-unreadable-object (structure
                                   ,stream
                                   :type t
                                   :identity ,identity)
           ,@(nreverse reversed-prints))))))

;;;; etc.

;;; Given a pathname, return a corresponding physical pathname.
(defun physicalize-pathname (possibly-logical-pathname)
  (if (typep possibly-logical-pathname 'logical-pathname)
      (translate-logical-pathname possibly-logical-pathname)
      possibly-logical-pathname))

;;;; Deprecating stuff

(defun normalize-deprecation-replacements (replacements)
  (if (or (not (listp replacements))
          (eq 'setf (car replacements)))
      (list replacements)
      replacements))

(defun deprecation-error (since name replacements)
  (error 'deprecation-error
          :name name
          :replacements (normalize-deprecation-replacements replacements)
          :since since))

(defun deprecation-warning (state since name replacements
                            &key (runtime-error (neq :early state)))
  (warn (ecase state
          (:early 'early-deprecation-warning)
          (:late 'late-deprecation-warning)
          (:final 'final-deprecation-warning))
        :name name
        :replacements (normalize-deprecation-replacements replacements)
        :since since
        :runtime-error runtime-error))

(defun deprecated-function (since name replacements)
  (lambda (&rest deprecated-function-args)
    (declare (ignore deprecated-function-args))
    (deprecation-error since name replacements)))

(defun deprecation-compiler-macro (state since name replacements)
  (lambda (form env)
    (declare (ignore env))
    (deprecation-warning state since name replacements)
    form))

;;; STATE is one of
;;;
;;;   :EARLY, for a compile-time style-warning.
;;;   :LATE, for a compile-time full warning.
;;;   :FINAL, for a compile-time full warning and runtime error.
;;;
;;; Suggested duration of each stage is one year, but some things can move faster,
;;; and some widely used legacy APIs might need to move slower. Internals we don't
;;; usually add deprecation notes for, but sometimes an internal API actually has
;;; several external users, in which case we try to be nice about it.
;;;
;;; When you deprecate something, note it here till it is fully gone: makes it
;;; easier to keep things progressing orderly. Also add the relevant section
;;; (or update it when deprecation proceeds) in the manual, in
;;; deprecated.texinfo.
;;;
;;; EARLY:
;;; - SB-THREAD::GET-MUTEX, since 1.0.37.33 (04/2010)               -> Late: 01/2013
;;;   ^- initially deprecated without compile-time warning, hence the schedule
;;; - SB-THREAD::SPINLOCK (type), since 1.0.53.11 (08/2011)         -> Late: 08/2012
;;; - SB-THREAD::MAKE-SPINLOCK, since 1.0.53.11 (08/2011)           -> Late: 08/2012
;;; - SB-THREAD::WITH-SPINLOCK, since 1.0.53.11 (08/2011)           -> Late: 08/2012
;;; - SB-THREAD::WITH-RECURSIVE-SPINLOCK, since 1.0.53.11 (08/2011) -> Late: 08/2012
;;; - SB-THREAD::GET-SPINLOCK, since 1.0.53.11 (08/2011)            -> Late: 08/2012
;;; - SB-THREAD::RELEASE-SPINLOCK, since 1.0.53.11 (08/2011)        -> Late: 08/2012
;;; - SB-THREAD::SPINLOCK-VALUE, since 1.0.53.11 (08/2011)          -> Late: 08/2012
;;; - SB-THREAD::SPINLOCK-NAME, since 1.0.53.11 (08/2011)           -> Late: 08/2012
;;; - SETF SB-THREAD::SPINLOCK-NAME, since 1.0.53.11 (08/2011)      -> Late: 08/2012
;;; - SB-C::MERGE-TAIL-CALLS (policy), since 1.0.53.74 (11/2011)    -> Late: 11/2012
;;; - SB-EXT:QUIT, since 1.0.56.55 (05/2012)                        -> Late: 05/2013
;;; - SB-UNIX:UNIX-EXIT, since 1.0.56.55 (05/2012)                  -> Late: 05/2013
;;; - SB-DEBUG:*SHOW-ENTRY-POINT-DETAILS*, since 1.1.4.9 (02/2013)  -> Late: 02/2014
;;;
;;; LATE:
;;; - SB-SYS:OUTPUT-RAW-BYTES, since 1.0.8.16 (06/2007)                 -> Final: anytime
;;;   Note: make sure CLX doesn't use it anymore!
;;; - SB-C::STACK-ALLOCATE-DYNAMIC-EXTENT (policy), since 1.0.19.7      -> Final: anytime
;;; - SB-C::STACK-ALLOCATE-VECTOR (policy), since 1.0.19.7              -> Final: anytime
;;; - SB-C::STACK-ALLOCATE-VALUE-CELLS (policy), since 1.0.19.7         -> Final: anytime
;;; - SB-INTROSPECT:FUNCTION-ARGLIST, since 1.0.24.5 (01/2009)          -> Final: anytime
;;; - SB-THREAD:JOIN-THREAD-ERROR-THREAD, since 1.0.29.17 (06/2009)     -> Final: 09/2012
;;; - SB-THREAD:INTERRUPT-THREAD-ERROR-THREAD since 1.0.29.17 (06/2009) -> Final: 06/2012

(defmacro define-deprecated-function (state since name replacements lambda-list &body body)
  (let* ((replacements (normalize-deprecation-replacements replacements))
         #!+sb-doc
         (doc
           (let ((*package* (find-package :keyword))
                 (*print-pretty* nil))
             (apply #'format nil
                    "~S has been deprecated as of SBCL ~A.~
                    ~#[~;~2%Use ~S instead.~;~2%~
                            Use ~S or ~S instead.~:;~2%~
                            Use~@{~#[~; or~] ~S~^,~} instead.~]"
                    name since replacements))))
    `(progn
       ,(ecase state
          ((:early :late)
           `(progn
              (defun ,name ,lambda-list
                #!+sb-doc ,doc
                ,@body)))
          ((:final)
           `(progn
              (declaim (ftype (function * nil) ,name))
              (setf (fdefinition ',name)
                    (deprecated-function ',name ',replacements ,since))
              #!+sb-doc
              (setf (documentation ',name 'function) ,doc))))
       (setf (compiler-macro-function ',name)
             (deprecation-compiler-macro ,state ,since ',name ',replacements)))))

(defun check-deprecated-variable (name)
  (let ((info (info :variable :deprecated name)))
    (when info
      (deprecation-warning (car info) (cdr info) name nil))))

(defmacro define-deprecated-variable (state since name &key (value nil valuep) replacement)
  (declare (ignorable replacement))
  `(progn
     (setf (info :variable :deprecated ',name) (cons ,state ,since))
     ,@(when (member state '(:early :late))
         `((defvar ,name ,@(when valuep (list value))
             #!+sb-doc
             ,(let ((*package* (find-package :keyword)))
                (format nil
                        "~@<~S has been deprecated as of SBCL ~A~@[, use ~S instead~].~:>"
                        name since replacement)))))))

;;; Anaphoric macros
(defmacro awhen (test &body body)
  `(let ((it ,test))
     (when it ,@body)))

(defmacro acond (&rest clauses)
  (if (null clauses)
      `()
      (destructuring-bind ((test &body body) &rest rest) clauses
        (once-only ((test test))
          `(if ,test
               (let ((it ,test)) (declare (ignorable it)),@body)
               (acond ,@rest))))))

;; Given DECLS as returned by from parse-body, and SYMBOLS to be bound
;; (with LET, MULTIPLE-VALUE-BIND, etc) return two sets of declarations:
;; those which pertain to the variables and those which don't.
(defun extract-var-decls (decls symbols)
  (labels ((applies-to-variables (decl)
             (let ((id (car decl)))
               (remove-if (lambda (x) (not (memq x symbols)))
                          (cond ((eq id 'type)
                                 (cddr decl))
                                ((or (listp id) ; must be a type-specifier
                                     (memq id '(special ignorable ignore
                                                dynamic-extent
                                                truly-dynamic-extent))
                                     (info :type :kind id))
                                 (cdr decl))))))
           (partition (spec)
             (let ((variables (applies-to-variables spec)))
               (cond ((not variables)
                      (values nil spec))
                     ((eq (car spec) 'type)
                      (let ((more (set-difference (cddr spec) variables)))
                        (values `(type ,(cadr spec) ,@variables)
                                (if more `(type ,(cadr spec) ,@more)))))
                     (t
                      (let ((more (set-difference (cdr spec) variables)))
                        (values `(,(car spec) ,@variables)
                                (if more `(,(car spec) ,@more)))))))))
    ;; This loop is less inefficient than theoretically possible,
    ;; reconstructing the tree even if no need,
    ;; but it's just a macroexpander, so... fine.
    (collect ((binding-decls))
      (let ((filtered
             (mapcar (lambda (decl-expr) ; a list headed by DECLARE
                       (mapcan (lambda (spec)
                                 (multiple-value-bind (binding other)
                                     (partition spec)
                                   (when binding
                                     (binding-decls binding))
                                   (if other (list other))))
                               (cdr decl-expr)))
                     decls)))
        (values (awhen (binding-decls) `(declare ,@it))
                (mapcan (lambda (x) (if x (list `(declare ,@x)))) filtered))))))

;;; (binding* ({(names initial-value [flag])}*) body)
;;; FLAG may be NIL or :EXIT-IF-NULL
;;;
;;; This form unites LET*, MULTIPLE-VALUE-BIND and AWHEN.
;;; Any name in a list of names may be NIL to ignore the respective value.
;;; If NAMES itself is nil, the initial-value form is evaluated only for effect.
;;;
;;; Clauses with no flags and one binding per clause are equivalent to LET*.
;;; We reduce to LET* when possible so that the body can contain declarations
;;; without having to split out declarations which affect variables and insert
;;; them into the appropriate places. This qualifies as an extreme KLUDGE,
;;; but has desirable behavior of allowing declarations in the innermost form.
;;;
;;; Caution: don't use declarations of the form (<non-builtin-type-id> <var>)
;;; before the INFO database is set up in building the cross-compiler,
;;; or you will probably lose.
;;; Of course, since some other host Lisps don't seem to think that's
;;; acceptable syntax anyway, you're pretty much prevented from writing it.
;;;
(defmacro binding* ((&rest bindings) &body body)
  (multiple-value-bind (forms decls) (parse-body body :doc-string-allowed nil)
    (labels
      ((recurse (bindings decls &aux ignores)
         (cond
           ((some (lambda (x)
                    (destructuring-bind (names value-form &optional flag) x
                      (declare (ignore value-form))
                      (or flag (not (symbolp names)))))
                  bindings)
            (destructuring-bind (names value-form &optional flag) (car bindings)
              (etypecase names
                ;; () for names is esoteric. Does anyone really need that?
                (null   (setq names (list (gensym)) ignores names))
                (symbol (setq names (list names)))
                (list
                 (setq names (mapcar (lambda (name)
                                       (or name (car (push (gensym) ignores))))
                                     names))))
              (multiple-value-bind (binding-decls rest-decls)
                  ;; If no more bindings, and no (WHEN ...) before the FORMS,
                  ;; then don't bother parsing decls.
                  (if (or (cdr bindings) flag)
                      (extract-var-decls decls
                                         (filter-names names (cdr bindings)))
                      (values nil decls))
                (let ((continue (acond ((cdr bindings) (recurse it rest-decls))
                                       (t (append decls forms)))))
                  `((multiple-value-bind ,names ,value-form
                      ,@(decl-expr binding-decls ignores)
                      ,@(ecase flag
                          ((nil) continue)
                          ((:exit-if-null)
                           `((when ,(first names) ,@continue))))))))))
           (t
            ;; This case is not strictly necessary now that declarations that
            ;; affect variables are correctly inserted into the M-V-BIND,
            ;; but it makes the expansion more legible/concise when applicable.
            `((let* ,(mapcar (lambda (binding)
                               (if (car binding)
                                   binding
                                   (let ((var (gensym)))
                                     (push var ignores)
                                     (cons var (cdr binding)))))
                             bindings)
                ,@(decl-expr nil ignores)
                ,@body)))))
       (filter-names (names more-bindings)
         ;; Return the subset of SYMBOLs that does not intersect any
         ;; symbol in MORE-BINDINGS. This makes declarations apply only
         ;; to the final occurrence of a repeated name, as is the custom.
         (remove-if (lambda (x) (subsequently-bound-p x more-bindings)) names))
       (subsequently-bound-p (name more-bindings)
         (member-if (lambda (binding)
                      (let ((names (car binding)))
                        (if (listp names) (memq name names) (eq name names))))
                    more-bindings))
       (decl-expr (binding-decls ignores)
         (nconc (if binding-decls (list binding-decls))
         ;; IGNORABLE, not IGNORE, just in case :EXIT-IF-NULL reads a gensym
               (if ignores `((declare (ignorable ,@ignores)))))))
    ;; Zero bindings have to be special-cased. RECURSE returns a list of forms
    ;; because we musn't wrap BODY in a PROGN if it contains declarations,
    ;; so we unwrap once here, but if the body was returned as the base case
    ;; of recursion then (CAR (RECURSE)) would be wrong.
    (if bindings (car (recurse bindings decls)) `(locally ,@body)))))

;;; Delayed evaluation
(defmacro delay (form)
  `(cons nil (lambda () ,form)))

(defun force (promise)
  (cond ((not (consp promise)) promise)
        ((car promise) (cdr promise))
        (t (setf (car promise) t
                 (cdr promise) (funcall (cdr promise))))))

(defun promise-ready-p (promise)
  (or (not (consp promise))
      (car promise)))

;;; toplevel helper
(defmacro with-rebound-io-syntax (&body body)
  `(%with-rebound-io-syntax (lambda () ,@body)))

(defun %with-rebound-io-syntax (function)
  (declare (type function function))
  (let ((*package* *package*)
        (*print-array* *print-array*)
        (*print-base* *print-base*)
        (*print-case* *print-case*)
        (*print-circle* *print-circle*)
        (*print-escape* *print-escape*)
        (*print-gensym* *print-gensym*)
        (*print-length* *print-length*)
        (*print-level* *print-level*)
        (*print-lines* *print-lines*)
        (*print-miser-width* *print-miser-width*)
        (*print-pretty* *print-pretty*)
        (*print-radix* *print-radix*)
        (*print-readably* *print-readably*)
        (*print-right-margin* *print-right-margin*)
        (*read-base* *read-base*)
        (*read-default-float-format* *read-default-float-format*)
        (*read-eval* *read-eval*)
        (*read-suppress* *read-suppress*)
        (*readtable* *readtable*))
    (funcall function)))

;;; Bind a few "potentially dangerous" printer control variables to
;;; safe values, respecting current values if possible.
(defmacro with-sane-io-syntax (&body forms)
  `(call-with-sane-io-syntax (lambda () ,@forms)))

(defun call-with-sane-io-syntax (function)
  (declare (type function function))
  (macrolet ((true (sym)
               `(and (boundp ',sym) ,sym)))
    (let ((*print-readably* nil)
          (*print-level* (or (true *print-level*) 6))
          (*print-length* (or (true *print-length*) 12)))
      (funcall function))))

;;; Returns a list of members of LIST. Useful for dealing with circular lists.
;;; For a dotted list returns a secondary value of T -- in which case the
;;; primary return value does not include the dotted tail.
;;; If the maximum length is reached, return a secondary value of :MAYBE.
(defun list-members (list &key max-length)
  (when list
    (do ((tail (cdr list) (cdr tail))
         (members (list (car list)) (cons (car tail) members))
         (count 0 (1+ count)))
        ((or (not (consp tail)) (eq tail list)
             (and max-length (>= count max-length)))
         (values members (or (not (listp tail))
                             (and (>= count max-length) :maybe)))))))

;;; Default evaluator mode (interpeter / compiler)

(declaim (type (member :compile #!+sb-eval :interpret) *evaluator-mode*))
(!defparameter *evaluator-mode* :compile
  #!+sb-doc
  "Toggle between different evaluator implementations. If set to :COMPILE,
an implementation of EVAL that calls the compiler will be used. If set
to :INTERPRET, an interpreter will be used.")

;;; Helper for making the DX closure allocation in macros expanding
;;; to CALL-WITH-FOO less ugly.
(defmacro dx-flet (functions &body forms)
  `(flet ,functions
     (declare (#+sb-xc-host dynamic-extent #-sb-xc-host truly-dynamic-extent
               ,@(mapcar (lambda (func) `(function ,(car func))) functions)))
     ,@forms))

;;; Another similar one.
(defmacro dx-let (bindings &body forms)
  `(let ,bindings
     (declare (#+sb-xc-host dynamic-extent #-sb-xc-host truly-dynamic-extent
               ,@(mapcar (lambda (bind) (if (consp bind) (car bind) bind))
                         bindings)))
     ,@forms))

;; This is not my preferred name for this function, but chosen for harmony
;; with everything else that refers to these as 'hash-caches'.
;; Hashing is just one particular way of memoizing, and it would have been
;; slightly more abstract and yet at the same time more concrete to say
;; "memoized-function-caches". "hash-caches" is pretty nonspecific.
#.(if *profile-hash-cache*
'(defun show-hash-cache-statistics ()
  (flet ((cache-stats (symbol)
           (let* ((name (string symbol))
                  (statistics (let ((*package* (symbol-package symbol)))
                                (symbolicate symbol "STATISTICS")))
                  (prefix
                   (subseq name 0 (- (length name) (length "VECTOR**")))))
             (values (if (boundp statistics)
                         (symbol-value statistics)
                         (make-array 3 :element-type 'fixnum))
                     (subseq prefix 2 (1- (length prefix)))))))
    (format t "~%Type function memoization:~%     Seek       Hit      (%)~:
    Evict      (%) Size    full~%")
    ;; Sort by descending seek count to rank by likely relative importance
    (dolist (symbol (sort (copy-list *cache-vector-symbols*) #'>
                          :key (lambda (x) (aref (cache-stats x) 0))))
      ;; Sadly we can't use BINDING* within this file
      (multiple-value-bind (stats short-name) (cache-stats symbol)
        (let* ((seek (aref stats 0))
               (miss (aref stats 1))
               (hit (- seek miss))
               (evict (aref stats 2))
               (cache (symbol-value symbol)))
          (format t "~9d ~9d (~5,1f%) ~8d (~5,1f%) ~4d ~6,1f% ~A~%"
                  seek hit
                  (if (plusp seek) (* 100 (/ hit seek)))
                  evict
                  (if (plusp seek) (* 100 (/ evict seek)))
                  (length cache)
                  (if (plusp (length cache))
                      (* 100 (/ (count-if-not #'fixnump cache)
                                (length cache))))
                  short-name)))))))

(in-package "SB!KERNEL")

(defun fp-zero-p (x)
  (typecase x
    (single-float (zerop x))
    (double-float (zerop x))
    #!+long-float
    (long-float (zerop x))
    (t nil)))

(defun neg-fp-zero (x)
  (etypecase x
    (single-float
     (if (eql x 0.0f0)
         (make-unportable-float :single-float-negative-zero)
         0.0f0))
    (double-float
     (if (eql x 0.0d0)
         (make-unportable-float :double-float-negative-zero)
         0.0d0))
    #!+long-float
    (long-float
     (if (eql x 0.0l0)
         (make-unportable-float :long-float-negative-zero)
         0.0l0))))

;;; Signalling an error when trying to print an error condition is
;;; generally a PITA, so whatever the failure encountered when
;;; wondering about FILE-POSITION within a condition printer, 'tis
;;; better silently to give up than to try to complain.
(defun file-position-or-nil-for-error (stream &optional (pos nil posp))
  ;; Arguably FILE-POSITION shouldn't be signalling errors at all; but
  ;; "NIL if this cannot be determined" in the ANSI spec doesn't seem
  ;; absolutely unambiguously to prohibit errors when, e.g., STREAM
  ;; has been closed so that FILE-POSITION is a nonsense question. So
  ;; my (WHN) impression is that the conservative approach is to
  ;; IGNORE-ERRORS. (I encountered this failure from within a homebrew
  ;; defsystemish operation where the ERROR-STREAM had been CL:CLOSEd,
  ;; I think by nonlocally exiting through a WITH-OPEN-FILE, by the
  ;; time an error was reported.)
  (ignore-errors
   (if posp
       (file-position stream pos)
       (file-position stream))))

(defun stream-error-position-info (stream &optional position)
  ;; Give up early for interactive streams and non-character stream.
  (when (or (ignore-errors (interactive-stream-p stream))
            (not (subtypep (ignore-errors (stream-element-type stream))
                           'character)))
    (return-from stream-error-position-info))

  (flet ((read-content (old-position position)
           "Read the content of STREAM into a buffer in order to count
lines and columns."
           (unless (and old-position position
                        (< position sb!xc:array-dimension-limit))
             (return-from read-content))
           (let ((content
                   (make-string position :element-type (stream-element-type stream))))
             (when (and (file-position-or-nil-for-error stream :start)
                        (eql position (ignore-errors (read-sequence content stream))))
               (file-position-or-nil-for-error stream old-position)
               content)))
         ;; Lines count from 1, columns from 0. It's stupid and
         ;; traditional.
         (line (string)
           (1+ (count #\Newline string)))
         (column (string position)
           (- position (or (position #\Newline string :from-end t) 0))))
   (let* ((stream-position (file-position-or-nil-for-error stream))
          (position (or position
                        ;; FILE-POSITION is the next character --
                        ;; error is at the previous one.
                        (and stream-position (plusp stream-position)
                             (1- stream-position))))
          (content (read-content stream-position position)))
     `(,@(when content `((:line ,(line content))
                         (:column ,(column content position))))
       ,@(when position `((:file-position ,position)))))))

(declaim (inline schwartzian-stable-sort-list))
(defun schwartzian-stable-sort-list (list comparator &key key)
  (if (null key)
      (stable-sort (copy-list list) comparator)
      (let* ((key (if (functionp key)
                      key
                      (symbol-function key)))
             (wrapped (mapcar (lambda (x)
                                (cons x (funcall key x)))
                              list))
             (sorted (stable-sort wrapped comparator :key #'cdr)))
        (map-into sorted #'car sorted))))
