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

(defun frameworks-are-linked-in-p ()
  "True where the Objective-C runtime and Foundation are already in the image
rather than something to dlopen.

That is every iOS build: an app links them statically, there are no
.framework bundles at the paths this file knows, and si:load-foreign-module is
refused outright in a statically linked ECL. The runtime is nonetheless right
there, so the question is answered by asking it for a class rather than by
testing a feature -- a Mac that has already loaded Foundation gets the same
fast path, correctly.

The class asked for must come from FOUNDATION, not from libobjc. NSObject is
defined by libobjc, which macOS maps into every process, so probing it answers
yes on a Mac where Foundation has never been opened -- and then nothing loads
it and every Foundation class is missing."
  (handler-case
      (not (cffi:null-pointer-p
            (cffi:foreign-funcall "objc_getClass" :string "NSString" :pointer)))
    (error () nil)))

(defun ensure-libobjc ()
  "Open libobjc if it is not already open.  Signals LIBRARY-NOT-FOUND otherwise."
  (when (frameworks-are-linked-in-p)
    (return-from ensure-libobjc t))
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
  (if (frameworks-are-linked-in-p)
      t
      (register-module +foundation-path+)))

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

;;; Runtime entry points -------------------------------------------------------
;;;
;;; DEFINE-RUNTIME-FUNCTION is DEFCFUN with the address resolved once.  On SBCL
;;; that is what DEFCFUN already is.  On ECL, CFFI's backend runs in its :DFFI
;;; mode, where every call of a DEFCFUN'd function begins with
;;; SI:FIND-FOREIGN-SYMBOL -- a dlsym across every loaded image -- and only then
;;; calls.  Measured (bench/RESULTS.md, 2026-09-16): 623 ns with Foundation
;;; alone, 7 µs once GameplayKit is loaded, against 61 ns for the call itself;
;;; a send makes two such calls, which was 14 of ECL's 15.9 µs per send.  So on
;;; ECL the address is looked up on first use, kept in a variable of its own,
;;; and forgotten on image restore, where the libraries land somewhere else.

#-ecl
(defmacro define-runtime-function ((c-name lisp-name) return-type &rest args)
  `(cffi:defcfun (,c-name ,lisp-name) ,return-type ,@args))

#+ecl
(defvar *runtime-address-cells* '()
  "The variables holding resolved runtime addresses, cleared on restore.")

#+ecl
(defun %runtime-address (c-name)
  (or (cffi:foreign-symbol-pointer c-name)
      (error "The Objective-C runtime function ~S cannot be found." c-name)))

#+ecl
(defun clear-runtime-addresses ()
  (dolist (cell *runtime-address-cells*) (setf (symbol-value cell) nil)))

#+ecl
(add-image-restore-thunk 'clear-runtime-addresses)

#+ecl
(defmacro define-runtime-function ((c-name lisp-name) return-type &rest args)
  (let ((cell (intern (format nil "*ADDRESS-OF-~A*" lisp-name) :objc))
        (names (mapcar #'first args)))
    `(progn
       (defvar ,cell nil)
       (pushnew ',cell *runtime-address-cells*)
       (defun ,lisp-name ,names
         (cffi:foreign-funcall-pointer
          (or ,cell (setf ,cell (%runtime-address ,c-name)))
          ()
          ,@(loop for (name type) in args append (list type name))
          ,return-type)))))

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
;; Image dump and restore hooks. SBCL only: ECL's image saving works
;; differently, and an iOS application never dumps one anyway.
#+sbcl (pushnew '%prepare-for-dump sb-ext:*save-hooks*)
#+sbcl (pushnew '%reinitialize sb-ext:*init-hooks*)
