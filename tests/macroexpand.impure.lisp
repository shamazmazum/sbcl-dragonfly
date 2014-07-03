;;;; This file is for macroexpander tests which have side effects

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; While most of SBCL is derived from the CMU CL system, the test
;;;; files (like this one) were written from scratch after the fork
;;;; from CMU CL.
;;;;
;;;; This software is in the public domain and is provided with
;;;; absolutely no warranty. See the COPYING and CREDITS files for
;;;; more information.

;;; From Matthew Swank on cll 2005-10-06

(defmacro defglobal* (name &optional value)
  (let ((internal (gensym)))
    `(progn
       (defparameter ,internal ,value)
       (define-symbol-macro ,name ,internal))))

(defglobal* glob)

(assert (= (let ((glob 4)) glob)))
(assert (null glob))
(assert (equal (let ((glob nil)) (setf glob (cons 'foo glob)) glob) '(foo)))
(assert (null glob))
(assert (equal (let ((glob nil)) (push 'foo glob) glob) '(foo)))
(assert (null glob))



;;; CLHS 3.1.2.1.1 specifies that symbol macro expansion must also
;;; go through *MACROEXPAND-HOOK*. (2007-09-22, -TCR.)

(define-symbol-macro .foo. 'foobar)

(let* ((expanded-p nil)
      (*macroexpand-hook* #'(lambda (fn form env)
                              (when (eq form '.foo.)
                                (setq expanded-p t))
                              (funcall fn form env))))
  (multiple-value-bind (expansion flag) (macroexpand '.foo.)
    (assert (equal expansion '(quote foobar)))
    (assert flag)
    (assert expanded-p)))

#+sb-eval
(let ((sb-ext::*evaluator-mode* :interpret))
  (let* ((expanded-p nil)
         (*macroexpand-hook* #'(lambda (fn form env)
                                 (when (eq form '.foo.)
                                   (setq expanded-p t))
                                 (funcall fn form env))))
    (eval '.foo.)
    (assert expanded-p)))

(let* ((expanded-p nil)
       (*macroexpand-hook* #'(lambda (fn form env)
                               (when (eq form '/foo/)
                                 (setq expanded-p t))
                               (funcall fn form env))))
  (compile nil '(lambda ()
                 (symbol-macrolet ((/foo/ 'foobar))
                   (macrolet ((expand (symbol &environment env)
                                (macroexpand symbol env)))
                     (expand /foo/)))))
  (assert expanded-p))

;; Check that DEFINE-SYMBOL-MACRO on a variable whose global :KIND
;; was :ALIEN gets a sane error message instead of ECASE failure.
(sb-alien:define-alien-variable ("posix_argv" foo-argv) (* (* char)))
(handler-case (define-symbol-macro foo-argv (silly))
  (error (e)
    (assert (string= "Symbol FOO-ARGV is already defined as an alien variable."
                     (write-to-string e :escape nil))))
  (:no-error () (error "Expected an error")))

(assert (equal (macroexpand-1
                '(sb-int:binding* (((foo x bar zz) (f) :exit-if-null)
                                   ((baz y) (g bar)))
                  (declare (integer x foo) (special foo y))
                  (declare (special zz bar l) (real q foo))
                  (thing)))
               '(MULTIPLE-VALUE-BIND (FOO X BAR ZZ) (F)
                 (DECLARE
                  (INTEGER X FOO) (SPECIAL FOO) (SPECIAL ZZ BAR) (REAL FOO))
                 (WHEN FOO (MULTIPLE-VALUE-BIND (BAZ Y) (G BAR)
                             (DECLARE (SPECIAL Y))
                             (DECLARE (SPECIAL L) (REAL Q)) (THING))))))

(assert (equal (macroexpand-1
                '(sb-int:binding* (((x y) (f))
                                   (x (g y x)))
                  (declare (integer x))
                  (foo)))
               '(MULTIPLE-VALUE-BIND (X Y) (F)
                 (LET* ((X (G Y X)))
                   (DECLARE (INTEGER X))
                   (FOO)))))
