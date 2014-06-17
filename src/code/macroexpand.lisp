;;;; MACROEXPAND and friends

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!IMPL")

;;;; syntactic environment access

(defun sb!xc:special-operator-p (symbol)
  #!+sb-doc
  "If the symbol globally names a special form, return T, otherwise NIL."
  (declare (symbol symbol))
  (eq (info :function :kind symbol) :special-form))

(defvar sb!xc:*macroexpand-hook* 'funcall
  #!+sb-doc
  "The value of this variable must be a designator for a function that can
  take three arguments, a macro expander function, the macro form to be
  expanded, and the lexical environment to expand in. The function should
  return the expanded form. This function is called by MACROEXPAND-1
  whenever a runtime expansion is needed. Initially this is set to
  FUNCALL.")

(defun sb!xc:macroexpand-1 (form &optional env)
  #!+sb-doc
  "If form is a macro (or symbol macro), expand it once. Return two values,
   the expanded form and a T-or-NIL flag indicating whether the form was, in
   fact, a macro. ENV is the lexical environment to expand in, which defaults
   to the null environment."
  (flet ((perform-expansion (expander)
           ;; I disagree that expanders need to receive a "proper" environment
           ;; - whatever that is - in lieu of NIL because an environment is
           ;; opaque, and the only thing an expander can do with it (per the
           ;; CL standard, barring things that code-walkers might want)
           ;; is recursively invoke macroexpand[-1] or one of the handful of
           ;; other builtins (9 or so) accepting an environment.
           ;; Those functions all must in turn accept NIL as an environment.
           ;; Whether or not this is put back to the way it was in CMUCL, it's
           ;; good to have a single entry point for macros and symbol-macros.
           (values (funcall sb!xc:*macroexpand-hook*
                            expander
                            form
                                ;; As far as I can tell, it's not clear from
                                ;; the ANSI spec whether a MACRO-FUNCTION
                                ;; function needs to be prepared to handle
                                ;; NIL as a lexical environment. CMU CL
                                ;; passed NIL through to the MACRO-FUNCTION
                                ;; function, but I prefer SBCL "be conservative
                                ;; in what it sends and liberal in what it
                                ;; accepts" by doing the defaulting itself.
                                ;; -- WHN 19991128
                            (coerce-to-lexenv env))
                   t)))
    (cond ((consp form)
           (let ((expander (and (symbolp (car form))
                                (sb!xc:macro-function (car form) env))))
             (if expander
                 (perform-expansion expander)
                 (values form nil))))
          ((symbolp form)
           (multiple-value-bind (expansion winp)
               (let* ((venv (when env (sb!c::lexenv-vars env)))
                      (local-def (cdr (assoc form venv))))
                 (cond ((not local-def)
                        (info :variable :macro-expansion form))
                       ((and (consp local-def) (eq (car local-def) 'macro))
                        (values (cdr local-def) t))))
             (if winp
                  ;; CLHS 3.1.2.1.1 specifies that symbol-macros are expanded
                  ;; via the macroexpand hook, too.
                 (perform-expansion (lambda (form env)
                                      (declare (ignore form env))
                                      expansion))
                 (values form nil))))
          (t
           (values form nil)))))

(defun sb!xc:macroexpand (form &optional env)
  #!+sb-doc
  "Repetitively call MACROEXPAND-1 until the form can no longer be expanded.
   Returns the final resultant form, and T if it was expanded. ENV is the
   lexical environment to expand in, or NIL (the default) for the null
   environment."
  (labels ((frob (form expanded)
             (multiple-value-bind (new-form newly-expanded-p)
                 (sb!xc:macroexpand-1 form env)
               (if newly-expanded-p
                   (frob new-form t)
                   (values new-form expanded)))))
    (frob form nil)))

;;; Like MACROEXPAND-1, but takes care not to expand special forms.
(defun %macroexpand-1 (form &optional env)
  (if (or (atom form)
          (let ((op (car form)))
            (not (and (symbolp op) (sb!xc:special-operator-p op)))))
      (sb!xc:macroexpand-1 form env)
      (values form nil)))

;;; Like MACROEXPAND, but takes care not to expand special forms.
(defun %macroexpand (form &optional env)
  (labels ((frob (form expanded)
             (multiple-value-bind (new-form newly-expanded-p)
                 (%macroexpand-1 form env)
               (if newly-expanded-p
                   (frob new-form t)
                   (values new-form expanded)))))
    (frob form nil)))
