;;;; src/library.lisp -- finding and opening the Objective-C runtime.
;;;;
;;;; One file owns discovery, loading and reporting.  USE-FOREIGN-LIBRARY is
;;;; never called anywhere else, because the image dump/restore hooks at the
;;;; bottom have to see every library we opened.

(in-package #:objc)

;;; The runtime itself -------------------------------------------------------

;;; Absolute path first.  /usr/lib/libobjc.A.dylib does not exist on disk on
;;; modern macOS -- it lives only in the dyld shared cache -- but dlopen still
;;; resolves it, so PROBE-FILE would lie and the bare soname is what actually
;;; needs to work.  Both spellings are listed so the failure message can say
;;; which were tried.
(cffi:define-foreign-library libobjc
  (:darwin (:or "/usr/lib/libobjc.A.dylib" "libobjc.A.dylib" "libobjc.dylib"))
  (t (:default "libobjc")))

(defparameter +libobjc-candidates+
  '("/usr/lib/libobjc.A.dylib" "libobjc.A.dylib" "libobjc.dylib")
  "Exactly what LIBOBJC tries, in order, so a load failure can name them.")

;;; Frameworks whose paths appear in the LispWorks manual and examples.  These
;;; are the strings ENSURE-OBJC-INITIALIZED is documented to take as :MODULES,
;;; and the ones the shipped examples pass verbatim, so they are spelled the
;;; same way here.
(defparameter +foundation-path+
  "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation")
(defparameter +cocoa-path+
  "/System/Library/Frameworks/Cocoa.framework/Versions/A/Cocoa")
(defparameter +appkit-path+
  "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit")
(defparameter +corefoundation-path+
  "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation")

(defvar *loaded-modules* '()
  "Module paths successfully opened, most recent first.
Kept so the image restore hook can reopen exactly what was open before the
dump, and so REGISTER-MODULE can stay idempotent.")

(defvar *module-lock* (bt:make-lock "objc module lock"))

(defun register-module (path &key (errorp t))
  "Open the foreign module at PATH.  Returns PATH on success, NIL on failure.

This is the FLI:REGISTER-MODULE workalike that ENSURE-OBJC-INITIALIZED's
:MODULES argument and the ported examples go through, which is why it accepts
the full framework paths from the manual verbatim rather than a library name."
  (bt:with-lock-held (*module-lock*)
    (cond ((member path *loaded-modules* :test #'string=) path)
          (t
           (handler-case
               (progn (cffi:load-foreign-library path)
                      (push path *loaded-modules*)
                      path)
             (error (e)
               (declare (ignorable e))
               (when errorp
                 (error 'library-not-found :name path :candidates (list path)))
               nil))))))

(defun ensure-libobjc ()
  "Open libobjc if it is not already open.  Signals LIBRARY-NOT-FOUND otherwise."
  (unless (cffi:foreign-library-loaded-p 'libobjc)
    (handler-case (cffi:use-foreign-library libobjc)
      (error ()
        (error 'library-not-found
               :name "Objective-C runtime"
               :candidates +libobjc-candidates+))))
  t)

(defun ensure-foundation ()
  "Open Foundation.  Almost everything interesting needs it, including the
NSGetSizeAndAlignment we use to check struct layouts."
  (register-module +foundation-path+))

(defun ensure-appkit ()
  "Open AppKit.  Separate from Foundation because a headless process should not
have to load it, and on a machine with no window server loading it is the point
where things start going wrong."
  (register-module +cocoa-path+ :errorp nil)
  (register-module +appkit-path+ :errorp nil))

;;; Image dump and restore ---------------------------------------------------
;;;
;;; CFFI records that a library is open in a Lisp-side table, and that table
;;; survives SAVE-LISP-AND-DIE.  In a dumped image USE-FOREIGN-LIBRARY then
;;; short-circuits on the stale record and never dlopens, so the first foreign
;;; call in the restarted binary jumps into an address that is no longer mapped.
;;; Closing on the way out and reopening on the way in is what prevents that.
;;;
;;; The restore hook is also where dispatch caches get invalidated -- compiled
;;; trampolines embed objc_msgSend's address as an immediate, and sb-alien
;;; callables do not survive a dump at all.  DISPATCH and METHOD-DEF push their
;;; own invalidation thunks onto *IMAGE-RESTORE-THUNKS* rather than this file
;;; reaching forward into theirs.

(defvar *image-restore-thunks* '()
  "Functions run after an image restart, before anything else touches the
runtime.  Each clears or rebuilds one cache.  Pushed by the files that own the
caches, so this file needs no knowledge of them.")

(defvar *needs-restore* nil
  "True in a restarted image until the restore has run.

Set when the image is dumped and cleared by the restore, which is what makes
the restore idempotent -- it is registered with both UIOP and SBCL, and whether
one or both fire depends on how the image was saved.")

(defun add-image-restore-thunk (function)
  (pushnew function *image-restore-thunks*))

(defun %prepare-for-dump ()
  "Close every foreign library before the image is written.

CFFI records that a library is open in a Lisp-side table, and that table
survives the dump.  In a restarted image USE-FOREIGN-LIBRARY then
short-circuits on the stale record and never dlopens, so the first foreign call
jumps into an address that is no longer mapped."
  (setf *needs-restore* t)
  (let ((modules *loaded-modules*))
    (ignore-errors (cffi:close-foreign-library 'libobjc))
    (dolist (path modules)
      (ignore-errors (cffi:close-foreign-library path)))
    ;; Keep the list: it is the record of what to reopen on the way back in.
    (setf *loaded-modules* modules))
  (values))

(defun %reinitialize ()
  "Reopen the foreign libraries and invalidate everything that cannot survive.

Idempotent: whichever of the UIOP and SBCL hooks fires first does the work."
  (when *needs-restore*
    (setf *needs-restore* nil)
    (let ((modules (reverse *loaded-modules*)))
      (setf *loaded-modules* '())
      (ignore-errors (ensure-libobjc))
      (dolist (path modules)
        (register-module path :errorp nil)))
    (mapc #'funcall *image-restore-thunks*))
  (values))

;;; Registered with UIOP and with SBCL both, because they fire under different
;;; circumstances and neither covers the other.  UIOP's hooks run from
;;; UIOP:DUMP-IMAGE; a plain SB-EXT:SAVE-LISP-AND-DIE -- which is what most
;;; people reach for, and what ASDF's PROGRAM-OP ends up doing -- bypasses them
;;; entirely.  Registering only with UIOP means a dumped executable segfaults on
;;; its first message send, with a stale class pointer, a long way from the
;;; cause.
(uiop:register-image-dump-hook '%prepare-for-dump)
(uiop:register-image-restore-hook '%reinitialize nil)
(pushnew '%prepare-for-dump sb-ext:*save-hooks*)
(pushnew '%reinitialize sb-ext:*init-hooks*)
