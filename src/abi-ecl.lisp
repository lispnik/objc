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

(defparameter +all-fpe-bits+ #b111111
  "Enough bits to name every FE_* exception EXT:TRAP-FPE will accept.
It masks with FE_ALL_EXCEPT on the way in, so an over-wide value is safe and
an under-wide one silently leaves traps enabled.")

(defun %fpe-bits ()
  "The calling thread's current trap mask, without disturbing it.
EXT:TRAP-FPE with 'LAST re-applies the bits already in force and returns them."
  (ext:trap-fpe 'last t))

(defun %set-fpe-bits (bits)
  "Set the trap mask to exactly BITS.

Two calls, because EXT:TRAP-FPE only ever ORs bits in or ANDs them out -- there
is no `set to this'.  Clearing everything first is what makes the restore exact
rather than cumulative."
  (ext:trap-fpe +all-fpe-bits+ nil)
  (unless (zerop bits)
    (ext:trap-fpe bits t))
  bits)

(defmacro with-fp-traps-masked (&body body)
  "Run BODY with floating point traps disabled, restoring them afterwards.

Not a no-op, though this file said it was for a while.  The claim was that ECL
never unmasks these in the first place; it does -- measured on ECL 26.5.5,
(/ 1.0d0 0.0d0) signals DIVISION-BY-ZERO out of the box, which is exactly the
trap CoreGraphics trips internally on an empty rect.  Left unmasked it raises a
Lisp condition in the middle of a Cocoa call, which is the one thing that must
not happen inside a trampoline.

Per thread, because ECL keeps the mask in the environment, which is the same
scope SBCL's equivalent has."
  (let ((saved (gensym "FPE-BITS")))
    `(let ((,saved (%fpe-bits)))
       (unwind-protect
            (progn (ext:trap-fpe +all-fpe-bits+ nil)
                   ,@body)
         (%set-fpe-bits ,saved)))))

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

;;; Foreign types -----------------------------------------------------------

(defun ecl-foreign-type (node)
  "The ECL foreign type keyword for encoding node NODE.

The counterpart of ALIEN-TYPE in abi.lisp, and it keeps the same promise: every
pointer-ish thing becomes one opaque pointer type, so the trampoline's Lisp
contract stays uniform and nothing above here has to know a foreign type.

Three of these are worth stating rather than reading past.

:CSTRING is deliberately NOT used for the :CSTRING node.  ECL's :CSTRING
converts -- it wants a Lisp string and hands back a fresh one aliased to the
foreign buffer -- while everything above this line already speaks addresses.
abi.lisp maps it to SYSTEM-AREA-POINTER for the same reason.

:BYTE for :CHAR, not :CHAR.  ECL's :CHAR is a Lisp CHARACTER, so a method
returning a signed char comes back as #\Nul rather than 0 -- and worse,
returning 0 from a callback declared :CHAR fails inside CHAR-CODE.

:BYTE for :BOOL too, one byte holding 1 or 0, matching abi.lisp's (UNSIGNED 8)
and the fourteen lines there recording why: the manual's contract is that a
BOOL is the integer 1 or 0 at both ends, and anything that converts turns every
BOOL argument into NO without erroring."
  (etypecase node
    (keyword
     (ecase node
       ((:void :unknown) :void)
       (:char :byte)
       (:uchar :unsigned-byte)
       (:short :short)
       (:ushort :unsigned-short)
       (:int :int)
       (:uint :unsigned-int)
       ;; 'l' and 'L' are 32 bits by definition of the encoding, whatever a C
       ;; long is on this machine; see types.lisp.  ECL's :LONG is 64 here, so
       ;; naming it would be a silent widening.
       (:long :int32-t)
       (:ulong :uint32-t)
       (:long-long :long-long)
       (:ulong-long :unsigned-long-long)
       (:float :float)
       (:double :double)
       (:bool :byte)
       ((:id :class :sel :cstring :block) :pointer-void)))
    (cons
     (ecase (first node)
       (:pointer :pointer-void)
       (:qualified (ecl-foreign-type (third node)))
       ;; An array or a struct only ever reaches here already reduced to
       ;; scalars, or as a pointer to itself.  Naming one is a bug upstream.
       ((:struct :union :array :bitfield)
        (%unsupported "ECL-FOREIGN-TYPE"
                      (format nil "~s is an aggregate; the dynamic FFI cannot ~
                                   name one" node)))))))

;;; Struct decomposition -----------------------------------------------------
;;;
;;; ECL's foreign type table is a closed enum of scalars, so a struct can only
;;; be smuggled through SI:CALL-CFUN as the scalars it is made of.  That is
;;; right exactly when AAPCS64 happens to put those fields where the same
;;; number of separate scalars would have gone, and wrong -- silently, with no
;;; condition signalled and a plausible number returned -- otherwise.
;;;
;;; The two classes that work were measured on-device rather than reasoned
;;; about (asdf-ios-app/examples/abi-probe):
;;;
;;;   an HFA of at most four floats of one type   CGPoint CGSize CGRect
;;;   two 8-byte integer-or-pointer fields        NSRange
;;;
;;; and the ones that do not:
;;;
;;;   {long, double}    16 bytes and not an HFA, so BOTH halves go in general
;;;                     registers; decomposed, the double lands in v0 and the
;;;                     callee reads x1
;;;   {d,d,d,d,d,d}     48 bytes, not an HFA, passed BY POINTER; decomposed,
;;;                     the callee dereferences whatever was in x0
;;;
;;; Neither of those faulted when measured.  They returned plausible numbers
;;; that changed between runs.  So this predicate is conservative by
;;; construction: it recognises the two shapes it can prove and refuses
;;; everything else, including shapes that might well work.

(defun %flatten-fields (node)
  "The leaf scalar nodes of NODE, in layout order, or NIL if it has none.
Nested structs flatten: a CGRect is two CGPoints and a CGSize is two doubles,
and AAPCS64 sees four doubles either way."
  (if (struct-node-p node)
      (let ((fields (third node)))
        (and fields
             (loop for field in fields
                   for leaves = (%flatten-fields field)
                   unless leaves return nil
                   append leaves)))
      (list node)))

(defun %homogeneous-float-aggregate-p (leaves)
  "True when LEAVES is an HFA: at most four members, all the same float type."
  (and leaves
       (<= (length leaves) 4)
       (let ((first-leaf (first leaves)))
         (and (member first-leaf '(:float :double))
              (every (lambda (leaf) (eq leaf first-leaf)) leaves)))))

(defun %eight-byte-integer-aggregate-p (leaves)
  "True when LEAVES is one or two fields, each exactly eight bytes.

The eight-byte requirement is the whole of it, and `total size at most 16' is
NOT the rule.  A {int,int,int,int} is sixteen bytes and AAPCS64 packs two ints
into each of x0 and x1; decomposed into four :INT arguments they would go to
x0-x3 and every one would be read from the wrong place.  One field per register
is what makes decomposition equivalent, so that is what this asks for."
  (and leaves
       (<= (length leaves) 2)
       (every (lambda (leaf)
                (and (not (member leaf '(:float :double)))
                     (eql 8 (node-size-and-alignment leaf))))
              leaves)))

(defun decomposable-struct-argument-p (node)
  "True when NODE may be passed as the scalars it is made of.

Arguments only.  A struct RETURN is never decomposable: a scalar return type
names exactly one register, so a CGRect read back as :DOUBLE gives origin.x and
nothing else -- which is -[UIView bounds] returning a quarter of an answer."
  (and (struct-node-p node)
       (let ((leaves (%flatten-fields node)))
         (and leaves
              (or (%homogeneous-float-aggregate-p leaves)
                  (%eight-byte-integer-aggregate-p leaves))))))

(defun struct-argument-scalars (node)
  "The scalar nodes NODE decomposes into, or NIL if it must not be decomposed."
  (and (decomposable-struct-argument-p node)
       (%flatten-fields node)))

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

;;; IMP liveness -------------------------------------------------------------

(defvar *imp-registry* (make-hash-table :test 'equal)
  "(objc-class-name selector class-method-p) -> the callable's name.

The counterpart of the table in abi.lisp, and required rather than optional:
method-def.lisp and class-def.lisp both write to it, so without it the first
method install fails on an undefined variable.

Every IMP lives here forever.  An IMP that becomes garbage while Cocoa still
holds its address is a jump into freed memory the next time that message is
sent -- a crash arbitrarily far from the cause.  Redefining a method replaces
the entry and keeps the old callable alive, which leaks a little per
redefinition and is the right trade against crashing mid-session.")

(defvar *imp-counter* 0)

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
