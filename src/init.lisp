;;;; src/init.lisp -- ENSURE-OBJC-INITIALIZED.

(in-package #:objc)

(defvar *initialization-lock* (bt:make-lock "objc initialization"))

(defun ensure-objc-initialized (&key modules)
  "Initialize the Objective-C system.  Must be called before anything else here.

MODULES is a list of paths to foreign modules to load; typically the Cocoa
frameworks:

    (objc:ensure-objc-initialized
     :modules
     '(\"/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation\"
       \"/System/Library/Frameworks/Cocoa.framework/Versions/A/Cocoa\"))

Idempotent, and safe to call after the defining macros: DEFINE-OBJC-CLASS and
DEFINE-OBJC-METHOD queue their foreign work and this drains the queue, which is
what lets a file define classes at the top and initialize at the bottom."
  (bt:with-lock-held (*initialization-lock*)
    (ensure-libobjc)
    (ensure-foundation)
    (dolist (module modules)
      (register-module module :errorp nil))
    (ensure-dispatch-addresses)
    ;; Read BOOL's encoding from the runtime rather than choosing it with a
    ;; read-time conditional: it is a signed char on Intel and C99 _Bool on
    ;; Apple silicon.
    (%measure-bool-encoding)
    (unless (objc-pointer-p (%objc-get-class "NSObject"))
      (error "Cannot initialize the Objective-C runtime because the class ~
NSObject is not defined."))
    (setf *objc-initialized* t)
    (drain-pending-definitions)
    t))

;;; The order here matters.  RESET-FOR-IMAGE-RESTORE queues every class and
;;; method to be rebuilt, and the ordinary caches are cleared by their own
;;; thunks; the next ENSURE-OBJC-INITIALIZED does the rebuilding.  It is
;;; registered last so it runs after the cache-clearing thunks.
(add-image-restore-thunk 'reset-for-image-restore)
