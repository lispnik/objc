;;;; src/abi-ecl.lisp -- the implementation seam, for ECL.
;;;;
;;;; The counterpart to abi.lisp.  Same ten-function contract, different
;;;; machinery underneath, and a much smaller reach: ECL's dynamic FFI can
;;;; describe scalars and pointers and nothing else, so struct-by-value and
;;;; arm64 variadic calls -- both of which abi.lisp does through sb-alien --
;;;; have no equivalent here yet.  The BUILD-* functions below say so out loud
;;;; rather than returning something that would misbehave at the ABI level.
;;;;
;;;; What ECL does have is SI:CALL-CFUN, which builds a call frame at runtime
;;;; through libffi.  That is enough for the ordinary case of an object or
;;;; scalar return, and it is enough on iOS, where FFI:C-INLINE cannot be used
;;;; because it needs a C compiler.
;;;;
;;;; The eventual answer for the hard cases is not more libffi.  It is to
;;;; compile the trampolines ahead of time, on the host, for the target: ECL's
;;;; compiler emits C and shells out to a C compiler, so pointing that compiler
;;;; at an iOS SDK yields a real compiled trampoline in which the *C* compiler
;;;; handles the ABI -- structs, homogeneous float aggregates, x8 indirect
;;;; returns and all.  That requires knowing the signatures at build time,
;;;; which suits an application and not a REPL.

(in-package #:objc)

;;; Floating point -----------------------------------------------------------

(defmacro with-fp-traps-masked (&body body)
  "A no-op on ECL.

SBCL runs with :INVALID and :DIVIDE-BY-ZERO unmasked and has to mask them
around CoreGraphics; ECL does not unmask them in the first place.  On iOS the
question is settled even more firmly, because the embedding disables ECL's
SIGFPE handling at boot."
  `(progn ,@body))

;;; Pointers -----------------------------------------------------------------
;;;
;;; ECL has no system-area-pointer.  The layers above only ever carry the value
;;; from SAP-OF back into an ABI function, so the representation is opaque to
;;; them and an address integer serves.

(declaim (inline sap-of pointer-of))

(defun sap-of (pointer)
  "The address of a CFFI pointer."
  (cffi:pointer-address pointer))

(defun pointer-of (sap)
  "The CFFI pointer for an address."
  (cffi:make-pointer sap))

(defun sb-sap-zero ()
  "A null address, for the OUT argument of a non-struct send."
  0)

;;; Type nodes ---------------------------------------------------------------

(defun struct-node-p (node)
  (and (consp node) (member (first node) '(:struct :union))))

(defparameter +max-register-returned-struct+ 16)

(defun stret-required-p (node)
  "Always NIL: objc_msgSend_stret does not exist on arm64, which is the only
architecture this file targets."
  (declare (ignore node))
  nil)

;;; Dispatch entry points ----------------------------------------------------

(defvar *msgsend-address* nil)
(defvar *msgsend-super-address* nil)
(defvar *msgsend-stret-address* nil)
(defvar *msgsend-super-stret-address* nil)

(defvar *dispatch-address-hook* nil
  "Optional function of one string returning an address.

A statically linked ECL -- which is what an iOS build is -- has ENABLE_DLOPEN
off, so SI:FIND-FOREIGN-SYMBOL refuses to resolve anything and
CFFI:FOREIGN-SYMBOL-POINTER with it.  An embedder hands the addresses in
instead; this is where it does that.")

(defun %symbol-address (name)
  (if *dispatch-address-hook*
      (funcall *dispatch-address-hook* name)
      (let ((pointer (ignore-errors (cffi:foreign-symbol-pointer name))))
        (and pointer (cffi:pointer-address pointer)))))

(defun ensure-dispatch-addresses ()
  (unless *msgsend-address*
    (let ((send (%symbol-address "objc_msgSend"))
          (super (%symbol-address "objc_msgSendSuper")))
      (when (or (null send) (null super))
        (error 'library-not-found
               :name "objc_msgSend"
               :candidates +libobjc-candidates+))
      (setf *msgsend-address* send
            *msgsend-super-address* super
            *msgsend-stret-address* nil
            *msgsend-super-stret-address* nil)))
  (values *msgsend-address* *msgsend-super-address*))

;;; Trampolines --------------------------------------------------------------

(define-condition ecl-abi-unsupported (error)
  ((operation :initarg :operation :reader ecl-abi-unsupported-operation)
   (detail :initarg :detail :initform nil :reader ecl-abi-unsupported-detail))
  (:report (lambda (condition stream)
             (format stream "~A is not implemented in the ECL ABI backend~@[: ~A~]."
                     (ecl-abi-unsupported-operation condition)
                     (ecl-abi-unsupported-detail condition)))))

(defun %unsupported (operation &optional detail)
  (error 'ecl-abi-unsupported :operation operation :detail detail))

(defun build-trampoline (kind result-node arg-nodes &optional n-fixed)
  (declare (ignore kind result-node arg-nodes n-fixed))
  (%unsupported "BUILD-TRAMPOLINE"
                "outbound dispatch still has to be written on SI:CALL-CFUN"))

(defun build-block-caller (result-node arg-nodes invoke-offset)
  (declare (ignore result-node arg-nodes invoke-offset))
  (%unsupported "BUILD-BLOCK-CALLER"))

(defun build-imp (result-node arg-nodes body)
  (declare (ignore result-node arg-nodes body))
  (%unsupported "BUILD-IMP"
                "an IMP needs a C function pointer; ECL's libffi closures are
                 refused on iOS, so these must be pre-compiled"))

(defun build-block-invoke (result-node arg-nodes body)
  (declare (ignore result-node arg-nodes body))
  (%unsupported "BUILD-BLOCK-INVOKE"))

(defun build-block-helper (arg-count body)
  (declare (ignore arg-count body))
  (%unsupported "BUILD-BLOCK-HELPER"))

;;; -------------------------------------------------------------------------

(defun clear-abi-caches ()
  (setf *msgsend-address* nil
        *msgsend-super-address* nil
        *msgsend-stret-address* nil
        *msgsend-super-stret-address* nil))

(add-image-restore-thunk 'clear-abi-caches)
