;;;; src/selectors.lisp -- selectors.

(in-package #:objc)

(defvar *selector-cache* (make-hash-table :test 'equal)
  "Selector name -> registered SEL.  sel_registerName is cheap but not free,
and dispatch looks a selector up on every send.")

(defun objc-pointer-p (object)
  (and (cffi:pointerp object) (not (cffi:null-pointer-p object))))

(defun coerce-to-selector (method)
  "Return the selector named by METHOD.

If METHOD is a string the registered selector is found, or a new one is
registered -- registering is what the manual specifies, so asking for a
selector no class implements still yields a valid SEL.  Otherwise METHOD should
already be a selector and is returned unchanged.

The opposite operation is SELECTOR-NAME."
  (etypecase method
    (string (or (gethash method *selector-cache*)
                (progn
                  (ensure-libobjc)
                  (setf (gethash method *selector-cache*)
                        (%sel-register-name method)))))
    (symbol (coerce-to-selector (string method)))
    (t (unless (cffi:pointerp method)
         (error "~S is not a method name or selector." method))
       method)))

(defun selector-name (selector)
  "Return the name of SELECTOR as a string.

A string is returned unchanged -- verified against LispWorks 8.1, where
(selector-name \"notAColonName\") is \"notAColonName\" -- so this is safe to
apply to something that may already be a name.

The opposite operation is COERCE-TO-SELECTOR."
  (etypecase selector
    (string selector)
    (t (unless (cffi:pointerp selector)
         (error "~S is not a method name or selector." selector))
       (%sel-get-name selector))))

(defun clear-selector-cache () (clrhash *selector-cache*))
(add-image-restore-thunk 'clear-selector-cache)
