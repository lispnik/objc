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
;;; ECL has no system-area-pointer, and the CFFI pointer is already the opaque
;;; object the layers above want: they only ever carry the value from SAP-OF
;;; back into an ABI function, so SAP-OF and POINTER-OF are the identity and
;;; (POINTER-OF (SAP-OF p)) is p by construction.
;;;
;;; This used to be an address integer, which is the obvious representation and
;;; is wrong on Darwin. Apple returns TAGGED POINTERS for short NSStrings and
;;; small NSNumbers -- the payload lives in the pointer with the top bit set --
;;; so the address of one exceeds ECL's 62-bit fixnum and CFFI:MAKE-POINTER
;;; cannot take it back:
;;;
;;;     In function COERCE, the value 10501465289614004243
;;;     is not of the expected type FIXNUM
;;;
;;; measured on -[NSString UTF8String] for "hello". The integer round trip
;;; worked for every heap object and failed for exactly the objects Foundation
;;; hands back most often.

(declaim (inline sap-of pointer-of))

(defun sap-of (pointer)
  "The SAP for a CFFI pointer. They are the same thing here."
  pointer)

(defun pointer-of (sap)
  "The CFFI pointer for a SAP. They are the same thing here."
  sap)

(defun sb-sap-zero ()
  "A null pointer, for the OUT argument of a non-struct send."
  (cffi:null-pointer))

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
  "Resolve the dispatch entry points, once.

The variables hold CFFI pointers rather than the integers %SYMBOL-ADDRESS
returns, because a call needs a pointer and these are resolved once while a
send happens constantly. %SYMBOL-ADDRESS keeps its integer contract, which is
what *DISPATCH-ADDRESS-HOOK* is documented to supply."
  (unless *msgsend-address*
    (let ((send (%symbol-address "objc_msgSend"))
          (super (%symbol-address "objc_msgSendSuper")))
      (when (or (null send) (null super))
        (error 'library-not-found
               :name "objc_msgSend"
               :candidates +libobjc-candidates+))
      (setf *msgsend-address* (cffi:make-pointer send)
            *msgsend-super-address* (cffi:make-pointer super)
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

;;; Strategy A: the dynamic path ---------------------------------------------
;;;
;;; SI:CALL-CFUN builds a call frame at run time through libffi, so this needs
;;; no C compiler and works in an interpreted image -- which means a trampoline
;;; built this way is available at a remote REPL on a phone, where nothing can
;;; be compiled at all.
;;;
;;; What it cannot do is a struct RESULT (a scalar return type names exactly one
;;; register) or a variadic call (arm64 passes variadic arguments on the stack,
;;; and a fixed signature puts them in registers). Those fall through to a
;;; compiled strategy.

(defun %leaf-reader (node)
  "A function of (address offset) returning NODE's value ready for SI:CALL-CFUN.

Pointer-ish leaves come back as foreign objects rather than addresses, because
that is what a :POINTER-VOID argument wants; everything above this file speaks
addresses and the conversion happens here."
  (etypecase node
    (keyword
     (ecase node
       (:double (lambda (address offset) (cffi:mem-ref address :double offset)))
       (:float  (lambda (address offset) (cffi:mem-ref address :float offset)))
       (:long-long (lambda (address offset) (cffi:mem-ref address :int64 offset)))
       (:ulong-long (lambda (address offset) (cffi:mem-ref address :uint64 offset)))
       ((:id :class :sel :cstring :block)
        (lambda (address offset) (cffi:mem-ref address :pointer offset)))))
    (cons
     (ecase (first node)
       (:pointer (lambda (address offset)
                   (cffi:mem-ref address :pointer offset)))))))

(defun %struct-argument-expander (node)
  "A function of one SAP returning the list of scalars NODE decomposes into.

The offsets are a simple stride, and provably so: decomposition is only ever
allowed for a homogeneous float aggregate or for fields of exactly eight bytes,
and in both of those every member has the same size. A shape where that is not
true is refused by DECOMPOSABLE-STRUCT-ARGUMENT-P before reaching here."
  (let* ((leaves (struct-argument-scalars node))
         (stride (node-size-and-alignment (first leaves)))
         (readers (mapcar #'%leaf-reader leaves)))
    (lambda (sap)
      (loop for reader in readers
            for offset from 0 by stride
            collect (funcall reader sap offset)))))

(defun %dynamic-argument-plan (arg-nodes)
  "(VALUES TYPES EXPANDERS) for ARG-NODES, or NIL if the dynamic path cannot.

EXPANDERS has one entry per argument: NIL for a scalar passed straight through,
a function of the incoming value otherwise. A struct expands into several
values, which is why every expander returns a list."
  (let ((types '())
        (expanders '()))
    (dolist (node arg-nodes)
      (cond
        ((struct-node-p node)
         (let ((leaves (struct-argument-scalars node)))
           (unless leaves (return-from %dynamic-argument-plan nil))
           (dolist (leaf leaves) (push (ecl-foreign-type leaf) types))
           (push (%struct-argument-expander node) expanders)))
        (t
         (let ((type (ignore-errors (ecl-foreign-type node))))
           (unless type (return-from %dynamic-argument-plan nil))
           (push type types)
           ;; A SAP is already the foreign object libffi wants.
           (push nil expanders)))))
    (values (nreverse types) (nreverse expanders))))

(defun %dynamic-trampoline (kind result-node arg-nodes n-fixed)
  "A trampoline built on SI:CALL-CFUN, or NIL if this signature is out of reach."
  (when (or (struct-node-p result-node)   ; one register, one field
            n-fixed)                      ; variadic: stack, not registers
    (return-from %dynamic-trampoline nil))
  (let ((result-type (ignore-errors (ecl-foreign-type result-node))))
    (unless result-type (return-from %dynamic-trampoline nil))
    (multiple-value-bind (types expanders) (%dynamic-argument-plan arg-nodes)
      (unless (or types (null arg-nodes)) (return-from %dynamic-trampoline nil))
      (ensure-dispatch-addresses)
      (let ((entry (ecase kind
                     (:send *msgsend-address*)
                     (:super *msgsend-super-address*)))
            (void-result-p (eq result-type :void)))
        (lambda (out &rest args)
          (declare (ignore out))         ; no struct result reaches here
          (let ((frame (loop for arg in args
                             for expander in expanders
                             append (if expander (funcall expander arg) (list arg)))))
            (let ((raw (with-fp-traps-masked
                         (si:call-cfun entry result-type types frame))))
              (if void-result-p nil raw))))))))


;;; Strategy B: compiled trampolines ------------------------------------------
;;;
;;; ECL's compiler emits C and shells out to a C compiler, so on a machine that
;;; has one this can do what the dynamic path cannot: hand the ABI to the C
;;; compiler, which is the only thing that reliably knows it. Structs by value
;;; in both directions, homogeneous float aggregates, x8 indirect returns and
;;; genuine variadic calls all come free, because none of them is our problem
;;; any more.
;;;
;;; The cost is a subprocess per distinct call signature. dispatch.lisp already
;;; memoises trampolines by canonical signature, so that is once per shape for
;;; the life of the image -- the same bargain abi.lisp strikes on SBCL, which
;;; JITs per signature and caches too.
;;;
;;; Not available on iOS: there is no C compiler on a phone, and ECL's COMPILE
;;; there yields bytecode. That is what Strategy C is for.

(defvar *compiled-trampolines-available* :unknown
  "T, NIL, or :UNKNOWN before the first attempt. See COMPILED-TRAMPOLINES-AVAILABLE-P.")

(defvar *trampoline-directory* nil)

(defvar *trampoline-counter* 0)

(defparameter *trampoline-linker-libs* "-lobjc -framework Foundation"
  "What a generated trampoline has to be linked against.

A STRING, not a list, because that is what C::*USER-LINKER-LIBS* is despite
defaulting to '() -- a list reaches CHAR and dies. Without it the C compiles
cleanly and the LINK fails on objc_msgSend, which ECL's default link line does
not mention.")

(defun %trampoline-directory ()
  (or *trampoline-directory*
      (setf *trampoline-directory*
            (ensure-directories-exist
             (merge-pathnames (format nil "objc-trampolines-~36r/" (random (expt 36 8)))
                              (uiop:temporary-directory))))))

;;; C type names --------------------------------------------------------------

(defun %c-scalar-name (node)
  "The C spelling of a scalar node."
  (ecase node
    ((:void :unknown) "void")
    (:char "signed char")
    (:uchar "unsigned char")
    (:short "short")
    (:ushort "unsigned short")
    (:int "int")
    (:uint "unsigned int")
    ;; 'l' and 'L' are 32 bits by definition of the encoding.
    (:long "int32_t")
    (:ulong "uint32_t")
    (:long-long "long long")
    (:ulong-long "unsigned long long")
    (:float "float")
    (:double "double")
    ;; One byte holding 1 or 0, matching the manual's contract at both ends.
    (:bool "unsigned char")
    ((:id :class :sel :cstring :block) "void *")))

(defun %c-type-name (node definitions)
  "The C spelling of NODE, pushing any struct typedefs it needs onto DEFINITIONS.

Structs are emitted as real nested C structs rather than flattened to their
leaves. Flattening happens to be layout-identical for the shapes the dynamic
path accepts and is not in general -- padding depends on the member types --
and here there is no reason to take the risk: the C compiler will lay it out
correctly if simply told the truth."
  (etypecase node
    (keyword (values (%c-scalar-name node) definitions))
    (cons
     (ecase (first node)
       (:pointer (values "void *" definitions))
       (:qualified (%c-type-name (third node) definitions))
       (:array
        ;; Only ever inside a struct, where C needs the element type and count.
        (multiple-value-bind (element definitions)
            (%c-type-name (third node) definitions)
          (values (format nil "~a [~d]" element (second node)) definitions)))
       ((:struct :union)
        (let* ((resolved (if (third node) node (resolve-struct-layout node)))
               (fields (third resolved))
               (name (format nil "objc_aggregate_~d" (incf *trampoline-counter*)))
               (members '()))
          (unless fields
            (%unsupported "BUILD-TRAMPOLINE"
                          (format nil "~s has no layout; it cannot be described to C"
                                  node)))
          (loop for field in fields
                for index from 0
                do (multiple-value-bind (type more) (%c-type-name field definitions)
                     (setf definitions more)
                     ;; An array type's brackets belong after the member name.
                     (let ((bracket (position #\[ type)))
                       (push (if bracket
                                 (format nil "  ~a m~d~a;"
                                         (string-right-trim " " (subseq type 0 bracket))
                                         index (subseq type bracket))
                                 (format nil "  ~a m~d;" type index))
                             members))))
          (values name
                  (cons (format nil "typedef ~a {~%~{~a~%~}} ~a;"
                                (if (eq (first resolved) :union) "union" "struct")
                                (nreverse members) name)
                        definitions))))))))

;;; Source generation ---------------------------------------------------------

(defmacro with-readable-forms (&body body)
  "Print generated code so it can be read back.

*PRINT-CIRCLE* would introduce #N# labels a compiler will not accept, and a
*PRINT-LEVEL* or *PRINT-LENGTH* set in someone's init file silently truncates a
nested form into `#' or `...'. Neither fails here; both fail later, in generated
code, pointing away from the setting that caused it."
  `(let ((*print-circle* nil) (*print-level* nil) (*print-length* nil)
         (*print-readably* nil) (*print-pretty* nil) (*print-case* :downcase))
     ,@body))

(defun %trampoline-forms (kind result-node arg-nodes n-fixed function-name)
  "(VALUES CLINES-FORM DEFUN-FORM) for one call signature."
  ;; *TRAMPOLINE-COUNTER* is NOT rebound to zero here, though naming the
  ;; aggregates from 1 for each trampoline reads better in isolation. The
  ;; ahead-of-time pool expands many of these into ONE file, and a per-expansion
  ;; counter gives every one of them an objc_aggregate_1 -- "typedef
  ;; redefinition with different types", from generated C, with nothing in the
  ;; Lisp to suggest why. One counter for the image keeps them distinct wherever
  ;; they land.
  (let* ((definitions '())
         (structp (struct-node-p result-node))
         (result-c (multiple-value-bind (type more)
                       (%c-type-name (if structp
                                         (resolve-struct-layout result-node)
                                         result-node)
                                     definitions)
                     (setf definitions more)
                     type))
         (arg-cs (loop for node in arg-nodes
                       collect (multiple-value-bind (type more)
                                   (%c-type-name node definitions)
                                 (setf definitions more)
                                 type)))
         (entry (ecase kind (:send "objc_msgSend") (:super "objc_msgSendSuper")))
         (lisp-args (loop for i from 0 below (length arg-nodes)
                          collect (format nil "a~d" i)))
         ;; Struct arguments reach us as SAPs and are dereferenced in the C.
         (ecl-arg-types (loop for node in arg-nodes
                              collect (if (struct-node-p node)
                                          :pointer-void
                                          (ecl-foreign-type node))))
         ;; #0 is OUT, so the call's own arguments start at #1. Getting this
         ;; wrong passes the result buffer as the receiver, which segfaults on
         ;; the first send rather than failing to compile.
         (call-args (loop for node in arg-nodes
                          for i from 1
                          for c-type in arg-cs
                          collect (if (struct-node-p node)
                                      (format nil "*(~a *)#~d" c-type i)
                                      (format nil "(~a)#~d" c-type i))))
         ;; The prototype. n-fixed marks where the variadic part begins, and
         ;; splicing the ellipsis in is what makes this a genuine Darwin arm64
         ;; variadic call -- without it the arguments go in registers and the
         ;; callee reads the stack.
         (prototype-args
           (if n-fixed
               (format nil "~{~a~^,~}~@[,...~]"
                       (subseq arg-cs 0 (min n-fixed (length arg-cs))) t)
               (format nil "~{~a~^,~}" arg-cs))))
    (let ((body
            (with-output-to-string (c)
              (format c "{~%")
              (cond
                (structp
                 (format c "    ~a r = ((~a(*)(~a))~a)(~{~a~^, ~});~%"
                         result-c result-c prototype-args entry call-args)
                 (format c "    *(~a *)#0 = r;~%" result-c)
                 (format c "    ~a(return) = ECL_NIL;~%" #\@))
                ((member result-node '(:void :unknown))
                 (format c "    ((void(*)(~a))~a)(~{~a~^, ~});~%"
                         prototype-args entry call-args))
                (t
                 (format c "    ~a(return) = ((~a(*)(~a))~a)(~{~a~^, ~});~%"
                         #\@ result-c prototype-args entry call-args)))
              (format c "  }"))))
      (values
       ;; The clines form and the defun, separately: clines must be its own
       ;; top-level form, and the ahead-of-time path splices both into a file
       ;; while the run-time path prints them into one.
       `(ffi:clines "#include <objc/runtime.h>"
                    "#include <objc/message.h>"
                    "#include <stdint.h>"
                    ,@(reverse definitions))
       ;; OUT is the struct result buffer; for a scalar result it is a null
       ;; pointer and unused, which keeps one contract for both.
       `(defun ,(intern (string-upcase function-name) '#:objc)
            (out ,@(mapcar (lambda (name) (intern (string-upcase name) '#:objc))
                           lisp-args))
          (ffi:c-inline (out ,@(mapcar (lambda (name)
                                         (intern (string-upcase name) '#:objc))
                                       lisp-args))
                        (:pointer-void ,@ecl-arg-types)
                        ,(cond (structp :object)
                               ((member result-node '(:void :unknown)) :void)
                               (t (ecl-foreign-type result-node)))
                        ,body
                        :one-liner nil :side-effects t))))))

(defun %trampoline-source (kind result-node arg-nodes n-fixed function-name)
  "The Lisp source for one compiled trampoline, as a string."
  (multiple-value-bind (clines defun-form)
      (%trampoline-forms kind result-node arg-nodes n-fixed function-name)
    (with-readable-forms
      (format nil ";;;; Generated by objc for one call signature. Not for editing.~%~
                   (in-package #:objc)~%~%~s~%~%~s~%"
              clines defun-form))))

;;; Compilation ---------------------------------------------------------------

(defun %compile-and-load (source function-name)
  "Compile SOURCE and return the function it defines, or NIL."
  (let* ((stem (format nil "objc-tramp-~a" function-name))
         (lisp (make-pathname :name stem :type "lisp"
                             :defaults (%trampoline-directory)))
         (fasl (make-pathname :name stem :type "fas"
                             :defaults (%trampoline-directory))))
    (with-open-file (out lisp :direction :output :if-exists :supersede)
      (write-string source out))
    (handler-case
        (let (;; FFI::*USE-DFFI* NIL or FFI:DEFCALLBACK emits a libffi closure
              ;; rather than a C function. Harmless for a trampoline and
              ;; essential for an IMP, so it is bound for both.
              (ffi::*use-dffi* nil)
              (c::*user-linker-libs* *trampoline-linker-libs*)
              (c::*suppress-compiler-warnings* t)
              (c::*suppress-compiler-notes* t)
              (*compile-verbose* nil)
              (*compile-print* nil))
          (multiple-value-bind (output warnings failure)
              (compile-file lisp :output-file fasl)
            (declare (ignore warnings))
            (when (or failure (null output))
              (return-from %compile-and-load nil))
            (load output)
            (fdefinition (find-symbol (string-upcase function-name) '#:objc))))
      (error () nil))))

(defun compiled-trampolines-available-p ()
  "Whether this image can compile a trampoline, decided by compiling one.

Asked rather than assumed. A C compiler is not a property of the platform: it
is present on a developer's Mac and absent on a phone, and on a Mac it can also
be absent until the command line tools are installed. The answer is cached
because finding it out costs a subprocess."
  (when (eq *compiled-trampolines-available* :unknown)
    (setf *compiled-trampolines-available*
          (and (find-package "C")
               (handler-case
                   (let ((probe (%compile-and-load
                                 (format nil ";;;; capability probe~%~
                                              (in-package #:objc)~%~
                                              (defun objc-tramp-probe (x)~%~
                                                (ffi:c-inline (x) (:int) :int~%~
                                                  \"@(return) = #0 + 1;\"~%~
                                                  :one-liner nil))~%")
                                 "objc-tramp-probe")))
                     (and probe (eql 2 (funcall probe 1))))
                 (error () nil)))))
  *compiled-trampolines-available*)

(defun %compiled-trampoline (kind result-node arg-nodes n-fixed)
  "A trampoline compiled for this exact signature, or NIL."
  (when (compiled-trampolines-available-p)
    (let* ((name (format nil "objc-tramp-~d" (incf *trampoline-counter*)))
           (source (handler-case
                       (%trampoline-source kind result-node arg-nodes n-fixed name)
                     (error () nil))))
      (when source
        (let ((function (%compile-and-load source name)))
          (when function
            ;; The compiled function already has the contract's shape: OUT
            ;; first, a struct result written through it, NIL returned.
            (lambda (&rest args)
              (with-fp-traps-masked (apply function args)))))))))


;;; Strategy C: an ahead-of-time pool -------------------------------------------
;;;
;;; On a phone there is no C compiler and ECL's COMPILE yields bytecode, so a
;;; trampoline that does not exist before the app ships cannot be made. The
;;; dynamic path covers every scalar and pointer signature, which is most of
;;; Cocoa; what it cannot do is a struct result, and -bounds and -frame are how
;;; you ask a view anything.
;;;
;;; So the shapes are compiled in advance, into the application, and looked up
;;; here. A trampoline depends only on the ABI shape of a signature and not on
;;; the selector, so one entry serves every method that looks like it: the
;;; pool is small even though Cocoa is not.

(defvar *trampoline-pool* (make-hash-table :test 'equal)
  "ABI shape -> a trampoline function built before the image shipped.")

(defun %abi-shape (node)
  "NODE reduced to what the calling convention actually distinguishes.

A trampoline is chosen by the shape of a signature, not by the selector or by
the names in it: CGRect and NSRect are one entry, and so are every two methods
that return an object and take an object. Size is carried along with a struct's
leaves because two aggregates with the same leaf sequence and different padding
are not the same shape."
  (if (struct-node-p node)
      (let ((resolved (if (third node) node (resolve-struct-layout node))))
        (list* :struct
               (node-size-and-alignment resolved)
               (mapcar #'%abi-shape (or (%flatten-fields resolved) '(:unknown)))))
      (ecl-foreign-type node)))

(defun %signature-shape (kind result-node arg-nodes n-fixed)
  (list kind (%abi-shape result-node) (mapcar #'%abi-shape arg-nodes) n-fixed))

(defun register-trampoline (kind result-node arg-nodes n-fixed function)
  "Record FUNCTION as the trampoline for this shape. Called by the pool file."
  (setf (gethash (%signature-shape kind result-node arg-nodes n-fixed)
                 *trampoline-pool*)
        function))

(defun %pooled-trampoline (kind result-node arg-nodes n-fixed)
  (let ((function (gethash (%signature-shape kind result-node arg-nodes n-fixed)
                           *trampoline-pool*)))
    (when function
      (lambda (&rest args) (with-fp-traps-masked (apply function args))))))

;;; Declaring one -------------------------------------------------------------

(defmacro define-objc-trampoline ((&key (kind :send) (result :void) (arguments '())
                                        variadic-num-of-fixed)
                                  &environment environment)
  "Compile a trampoline for one call shape into this image, ahead of time.

For iOS, where nothing can be compiled at run time. RESULT and ARGUMENTS are
ordinary type descriptors, and ARGUMENTS names every C parameter including the
two hidden ones:

    (objc:define-objc-trampoline
      (:result cocoa:ns-rect
       :arguments (objc:objc-object-pointer objc:sel)))

covers -bounds, -frame, and every other no-argument method returning a
rectangle. The shape is what is matched, so one of these serves many selectors.

Put these in a file listed in :BUNDLE-TRAMPOLINES: it must be compiled for the
target and never on the host, because FFI:C-INLINE cannot survive the host pass."
  (declare (ignorable environment))
  (let* ((result-node (node-for-fli-type result))
         (arg-nodes (mapcar #'node-for-fli-type arguments))
         (name (format nil "objc-pool-~(~a~)-~d" kind (incf *trampoline-counter*))))
    (multiple-value-bind (clines defun-form)
        (%trampoline-forms kind result-node arg-nodes variadic-num-of-fixed name)
      `(progn
         ,clines
         ,defun-form
         (register-trampoline ,kind ',result-node ',arg-nodes ,variadic-num-of-fixed
                              (function ,(second defun-form)))))))

(defun %no-trampoline (kind result-node arg-nodes n-fixed)
  "Refuse, naming the declaration that would fix it.

The failure a user actually meets on iOS, so it is worth more than \"not
supported\": the shape is known here, and the form to paste is a mechanical
function of it. A message that ends the search is the difference between a
five-minute fix and an afternoon reading this file."
  (%unsupported
   "BUILD-TRAMPOLINE"
   (format nil
           "no trampoline for this call shape, and none can be built here -- ~
            there is no C compiler on this platform.~2%~
            Add this to a file listed in :BUNDLE-TRAMPOLINES:~2%~
            ~2t(objc:define-objc-trampoline~%~
            ~5t(~@[:kind ~(~s~) ~]:result ~(~s~)~%~
            ~6t:arguments ~(~s~)~@[~%~6t:variadic-num-of-fixed ~d~]))~2%~
            and rebuild."
           (unless (eq kind :send) kind)
           (ignore-errors (fli-type-for-node result-node))
           (mapcar (lambda (node) (or (ignore-errors (fli-type-for-node node)) node))
                   arg-nodes)
           n-fixed)))

(defun build-trampoline (kind result-node arg-nodes &optional n-fixed)
  "Compile a function that sends one exact call signature.

The contract is abi.lisp's, unchanged:

    (out-sap arg...) => scalar-or-NIL

Strategies are tried in order of what they cost. The dynamic one needs no
compiler and reaches every scalar and pointer signature, which is most of
Cocoa; the rest -- struct results, variadics, and the struct arguments AAPCS64
does not pass like separate scalars -- needs a compiled trampoline."
  (or (%dynamic-trampoline kind result-node arg-nodes n-fixed)
      (%pooled-trampoline kind result-node arg-nodes n-fixed)
      (%compiled-trampoline kind result-node arg-nodes n-fixed)
      (%no-trampoline kind result-node arg-nodes n-fixed)))


;;; Calling a block ------------------------------------------------------------
;;;
;;; The same contract as BUILD-TRAMPOLINE with one difference that is the whole
;;; point: a message send jumps to objc_msgSend, whose address is known when the
;;; trampoline is built, while a block carries its own function pointer in its
;;; invoke field. So the entry is read out of the block at call time rather than
;;; baked in, and the block is passed back to it as the first argument.

(defun %dynamic-block-caller (result-node arg-nodes invoke-offset)
  "A block caller on SI:CALL-CFUN, or NIL if this signature is out of reach."
  (when (struct-node-p result-node)
    (return-from %dynamic-block-caller nil))
  (let ((result-type (ignore-errors (ecl-foreign-type result-node))))
    (unless result-type (return-from %dynamic-block-caller nil))
    (multiple-value-bind (types expanders) (%dynamic-argument-plan arg-nodes)
      (unless (or types (null arg-nodes)) (return-from %dynamic-block-caller nil))
      (let ((void-result-p (eq result-type :void)))
        (lambda (out block &rest args)
          (declare (ignore out))
          ;; The invoke pointer, read from this particular block.
          (let ((entry (cffi:mem-ref block :pointer invoke-offset))
                (frame (cons block
                             (loop for arg in args
                                   for expander in (rest expanders)
                                   append (if expander
                                              (funcall expander arg)
                                              (list arg))))))
            (let ((raw (with-fp-traps-masked
                         (si:call-cfun entry result-type types frame))))
              (if void-result-p nil raw))))))))

(defun %block-caller-source (result-node arg-nodes invoke-offset function-name)
  "The Lisp source for a compiled block caller."
  (let* ((definitions '())
         (structp (struct-node-p result-node))
         (result-c (multiple-value-bind (type more)
                       (%c-type-name (if structp
                                         (resolve-struct-layout result-node)
                                         result-node)
                                     definitions)
                     (setf definitions more)
                     type))
         (arg-cs (loop for node in arg-nodes
                       collect (multiple-value-bind (type more)
                                   (%c-type-name node definitions)
                                 (setf definitions more)
                                 type)))
         (lisp-args (loop for i from 0 below (length arg-nodes)
                          collect (format nil "a~d" i)))
         (ecl-arg-types (loop for node in arg-nodes
                              collect (if (struct-node-p node)
                                          :pointer-void
                                          (ecl-foreign-type node))))
         ;; #0 is OUT and #1 is the block, so the call's arguments start at #1 --
         ;; the block is itself the first of them.
         (call-args (loop for node in arg-nodes
                          for i from 1
                          for c-type in arg-cs
                          collect (if (struct-node-p node)
                                      (format nil "*(~a *)#~d" c-type i)
                                      (format nil "(~a)#~d" c-type i))))
         (prototype (format nil "~{~a~^,~}" arg-cs)))
    (with-output-to-string (out)
      (format out ";;;; Generated by objc for one block signature.~%")
      (format out "(in-package #:objc)~%~%")
      (format out "(ffi:clines~%  \"#include <stdint.h>\"")
      (dolist (definition (reverse definitions))
        (format out "~%  ~s" definition))
      (format out ")~%~%")
      (format out "(defun ~a (out~{ ~a~})~%" function-name lisp-args)
      (format out "  (ffi:c-inline (out~{ ~a~}) (:pointer-void~{ ~s~}) ~s \"{~%"
              lisp-args ecl-arg-types
              (cond (structp :object)
                    ((member result-node '(:void :unknown)) :void)
                    (t (ecl-foreign-type result-node))))
      (format out "    void *fn = *(void **)((char *)#1 + ~d);~%" invoke-offset)
      (cond
        (structp
         (format out "    ~a r = ((~a(*)(~a))fn)(~{~a~^, ~});~%"
                 result-c result-c prototype call-args)
         (format out "    *(~a *)#0 = r;~%" result-c)
         (format out "    @(return) = ECL_NIL;~%"))
        ((member result-node '(:void :unknown))
         (format out "    ((void(*)(~a))fn)(~{~a~^, ~});~%" prototype call-args))
        (t
         (format out "    @(return) = ((~a(*)(~a))fn)(~{~a~^, ~});~%"
                 result-c prototype call-args)))
      (format out "  }\" :one-liner nil :side-effects t))~%"))))

(defun %compiled-block-caller (result-node arg-nodes invoke-offset)
  (when (compiled-trampolines-available-p)
    (let* ((name (format nil "objc-block-caller-~d" (incf *trampoline-counter*)))
           (source (handler-case
                       (%block-caller-source result-node arg-nodes invoke-offset name)
                     (error () nil))))
      (when source
        (let ((function (%compile-and-load source name)))
          (when function
            (lambda (&rest args)
              (with-fp-traps-masked (apply function args)))))))))

(defun build-block-caller (result-node arg-nodes invoke-offset)
  "Compile a function that calls a block, and return it.

    (out-sap block-sap arg...) => scalar-or-NIL

ARG-NODES includes the block as its first element. INVOKE-OFFSET is where the
invoke field sits in the block literal; the caller passes it from the CFFI
struct definition so the layout has one source of truth."
  (or (%dynamic-block-caller result-node arg-nodes invoke-offset)
      (%compiled-block-caller result-node arg-nodes invoke-offset)
      (%unsupported "BUILD-BLOCK-CALLER"
                    (if (struct-node-p result-node)
                        "a struct result and no C compiler is available"
                        "this signature cannot be described"))))

;;; Inbound: real IMPs ---------------------------------------------------------
;;;
;;; The other direction. An Objective-C class defined in Lisp needs a real C
;;; function pointer per method, and FFI:DEFCALLBACK emits one -- the ECL
;;; compiler handles DEFCALLBACK itself rather than allocating a libffi closure,
;;; provided FFI::*USE-DFFI* is NIL when it is compiled. That matters beyond
;;; tidiness: the closure path needs writable-then-executable memory, which iOS
;;; refuses, so a libffi closure is not slower there, it is fatal.
;;;
;;; What DEFCALLBACK cannot describe is an aggregate, because c1-defcallback
;;; resolves every argument and the return through FOREIGN-ELT-TYPE-CODE. A
;;; method taking or returning a struct by value therefore still needs a
;;; hand-written C shim; -drawRect: is the one everybody wants.

(defun report-imp-error (condition selector &optional (noun "method"))
  "Report a condition that tried to escape a Lisp implementation into Objective-C.

NOUN is what the thing is called in the message -- a block is not a method, and
saying so is the difference between a diagnostic that locates the fault and one
that sends the reader to the wrong file."
  (format *error-output*
          "~&Error in Objective-C ~A ~A: ~A~%~
             Returning a zero value; the Objective-C caller has no handler.~%"
          noun selector condition)
  (finish-output *error-output*))

(defun zero-value (node)
  "The value to return when a Lisp implementation body signals."
  (cond ((struct-node-p node) nil)
        ((eq node :float) 0.0)
        ((eq node :double) 0d0)
        ((member node '(:void :unknown)) nil)
        ;; 0 and not NIL: the foreign type is a byte.
        ((eq node :bool) 0)
        ((or (member node '(:id :class :sel :cstring :block))
             (and (consp node) (member (first node) '(:pointer :array))))
         (cffi:null-pointer))
        (t 0)))

(defvar *callable-bodies* (make-hash-table)
  "Index -> the Lisp side of one generated callable.

The generated DEFCALLBACK is compiled in its own file and cannot close over
anything, so it calls back in here with its index and this supplies the closure,
the hidden-argument count and the result node.")

(defvar *callable-counter* 0)

(defstruct (callable-entry (:constructor %make-callable-entry))
  body n-hidden result-node name noun)

(defun %invoke-callable-body (index result-sap &rest args)
  "The Lisp side of a generated callable. Called from the DEFCALLBACK.

This is BUILD-CALLABLE's contract from abi.lisp, and both halves of it are
obligations rather than politeness. Float traps are masked because Cocoa
generates invalid operations freely and an unmasked one takes the process out.
And no condition may escape: there is no handler on the Objective-C side, so an
unwind past this frame aborts."
  (let ((entry (gethash index *callable-bodies*)))
    (if (null entry)
        (zero-value :void)
        (let ((n-hidden (callable-entry-n-hidden entry))
              (result-node (callable-entry-result-node entry)))
          (with-fp-traps-masked
            (handler-case
                (apply (callable-entry-body entry)
                       (append (subseq args 0 n-hidden)
                               ;; RESULT-SAP is the struct result buffer, or a
                               ;; null pointer when the result is a scalar and
                               ;; the body's value is the C return. One entry
                               ;; point for both, so the two generators differ
                               ;; only in what they pass here.
                               (list result-sap)
                               (nthcdr n-hidden args)))
              (serious-condition (condition)
                (report-imp-error condition (callable-entry-name entry)
                                  (callable-entry-noun entry))
                (zero-value result-node))))))))

(defun %callable-source (result-node arg-nodes index function-name)
  "The Lisp source for one generated callable, as a string."
  (let ((params (loop for node in arg-nodes
                      for i from 0
                      collect (format nil "(a~d ~(~s~))" i (ecl-foreign-type node)))))
    (with-output-to-string (out)
      (format out ";;;; Generated by objc for one callable signature.~%")
      (format out "(in-package #:objc)~%~%")
      (format out "(ffi:defcallback ~a ~(~s~) (~{~a~^ ~})~%"
              function-name (ecl-foreign-type result-node) params)
      ;; A null result pointer: DEFCALLBACK only ever handles a scalar result.
      (format out "  (%invoke-callable-body ~d (cffi:null-pointer)~{ ~a~}))~%~%"
              index (loop for i from 0 below (length arg-nodes)
                          collect (format nil "a~d" i)))
      ;; FFI:CALLBACK is a macro over a compile-time name, so the address has to
      ;; be taken here rather than by the caller.
      (format out "(defun ~a-address () (ffi:callback '~a))~%"
              function-name function-name))))

(defun %callable-describable-p (result-node arg-nodes)
  "Whether DEFCALLBACK can describe this signature at all."
  (and (not (struct-node-p result-node))
       (notany #'struct-node-p arg-nodes)
       (ignore-errors (ecl-foreign-type result-node))
       (every (lambda (node) (ignore-errors (ecl-foreign-type node))) arg-nodes)
       t))


;;; Callables that carry aggregates -------------------------------------------
;;;
;;; FFI:DEFCALLBACK cannot describe a struct, because c1-defcallback resolves
;;; every argument and the return through FOREIGN-ELT-TYPE-CODE. So for a method
;;; like -drawRect: -- the one everybody wants -- the C function is written out
;;; by hand instead, with the exact prototype, and calls back into Lisp through
;;; cl_funcall.
;;;
;;; The Lisp side is the same %INVOKE-CALLABLE-BODY the DEFCALLBACK path uses.
;;; The two differ only in what they can spell, not in what they mean.

(defun %shim-forms (result-node arg-nodes index function-name)
  "(VALUES CLINES-FORM ADDRESS-DEFUN) for one C shim callable."
  (let* ((definitions '())
         (structp (struct-node-p result-node))
         (result-c (multiple-value-bind (type more)
                       (%c-type-name (if structp
                                         (resolve-struct-layout result-node)
                                         result-node)
                                     definitions)
                     (setf definitions more)
                     type))
         (arg-cs (loop for node in arg-nodes
                       collect (multiple-value-bind (type more)
                                   (%c-type-name node definitions)
                                 (setf definitions more)
                                 type)))
         (shim (format nil "objc_shim_~d" index))
         (parameters (loop for c-type in arg-cs
                           for i from 0
                           collect (format nil "~a p~d" c-type i)))
         ;; Every argument reaches Lisp as a foreign pointer or a Lisp number.
         ;; A struct is copied to a local first so its address can be taken:
         ;; a parameter's address is not something to hand out, and the copy is
         ;; what makes the body's SAP contract uniform.
         (copies (loop for node in arg-nodes
                       for i from 0
                       when (struct-node-p node)
                         collect (format nil "  ~a c~d = p~d;" (nth i arg-cs) i i)))
         (actuals (loop for node in arg-nodes
                        for i from 0
                        collect
                        (cond
                          ((struct-node-p node)
                           (format nil "ecl_make_foreign_data(ECL_NIL, 0, &c~d)" i))
                          ((eq (ecl-foreign-type node) :pointer-void)
                           (format nil "ecl_make_foreign_data(ECL_NIL, 0, (void *)p~d)" i))
                          ((member node '(:float :double))
                           (format nil "ecl_make_double_float((double)p~d)" i))
                          (t (format nil "ecl_make_fixnum((long)p~d)" i))))))
    (let ((shim-c
            ;; The shim itself. No `at' sign may appear anywhere ECL reads as
            ;; its own return syntax, which is why the result is assigned to a
            ;; local rather than produced by a return macro.
            (with-output-to-string (c)
                (format c "static ~a ~a(~{~a~^, ~}) {~%" result-c shim parameters)
                ;; Cocoa calls an IMP or a block on whatever thread it likes,
                ;; and libdispatch's workers are threads ECL never created.
                ;; Entering Lisp on one without importing it first is
                ;; undefined -- in practice the callback never returns, which
                ;; is a hang rather than a crash and correspondingly harder to
                ;; read. ECL's own DEFCALLBACK does not do this, which is the
                ;; main reason every callable is generated here rather than
                ;; there.
                (format c "  bool imported = ecl_import_current_thread(ECL_NIL, ECL_NIL);~%")
                (dolist (copy copies) (format c "~a~%" copy))
                (when structp
                  (format c "  ~a out;~%  memset(&out, 0, sizeof out);~%" result-c))
                (unless (member result-node '(:void :unknown))
                  (unless structp (format c "  ~a value;~%" result-c)))
                (format c "  cl_object fn = ecl_make_symbol(\"%INVOKE-CALLABLE-BODY\", \"OBJC\");~%")
                (format c "  cl_object r = cl_funcall(~d, fn, ecl_make_fixnum(~d), ~a~{, ~a~});~%"
                        (+ 3 (length actuals)) index
                        (if structp
                            "ecl_make_foreign_data(ECL_NIL, 0, &out)"
                            "ECL_NIL")
                        actuals)
                ;; The Lisp value is turned into a C one BEFORE the thread is
                ;; released: after that, r is not something to be reading.
                (cond
                  (structp (format c "  (void)r;~%"))
                  ((member result-node '(:void :unknown)) (format c "  (void)r;~%"))
                  ((member result-node '(:float :double))
                   (format c "  value = (~a)ecl_to_double(r);~%" result-c))
                  ((eq (ecl-foreign-type result-node) :pointer-void)
                   (format c "  value = (~a)ecl_foreign_data_pointer_safe(r);~%" result-c))
                  (t (format c "  value = (~a)ecl_to_fixnum(r);~%" result-c)))
                (format c "  if (imported) ecl_release_current_thread();~%")
                (cond
                  (structp (format c "  return out;~%"))
                  ((member result-node '(:void :unknown)))
                  (t (format c "  return value;~%")))
                (format c "}"))))
      (values
       `(ffi:clines "#include <string.h>" ,@(reverse definitions) ,shim-c)
       ;; The address, taken from Lisp. The cast is what class_addMethod wants,
       ;; and the at-sign return syntax is ECL's own -- it is OTHER uses of it
       ;; in a c-inline body that ECL misreads.
       `(defun ,(intern (string-upcase (format nil "~a-address" function-name)) '#:objc) ()
          (ffi:c-inline () () :pointer-void
                        ,(format nil "{ ~a(return) = (void *)~a; }" #\@ shim)
                        :one-liner nil))))))

(defun %shim-source (result-node arg-nodes index function-name)
  "The Lisp source for one C shim callable, as a string."
  (multiple-value-bind (clines address-defun)
      (%shim-forms result-node arg-nodes index function-name)
    (with-readable-forms
      (format nil ";;;; Generated by objc for one callable signature.~%~
                   (in-package #:objc)~%~%~s~%~%~s~%"
              clines address-defun))))

(defun %compiled-shim-callable (name result-node arg-nodes n-hidden body noun)
  "Build a callable for a signature DEFCALLBACK cannot describe, or NIL."
  (let* ((index (incf *callable-counter*))
         (function-name (format nil "objc-shim-~d" index)))
    (setf (gethash index *callable-bodies*)
          (%make-callable-entry :body body :n-hidden n-hidden
                                :result-node result-node :name name :noun noun))
    (let* ((source (handler-case (%shim-source result-node arg-nodes index function-name)
                     (error () nil)))
           (address-fn (and source
                            (%compile-and-load source
                                               (format nil "~a-address" function-name)))))
      (cond (address-fn (funcall address-fn))
            (t (remhash index *callable-bodies*) nil)))))


;;; An ahead-of-time pool of IMPs ---------------------------------------------
;;;
;;; The other half of what iOS needs, and it cannot work the way the trampoline
;;; pool does. A trampoline is looked up and called; an IMP is a bare C function
;;; pointer handed to class_addMethod, and it carries no argument saying which
;;; Lisp function it stands for. One address is one method.
;;;
;;; So the pool holds several shims per shape, each compiled with its own index
;;; baked in, and BUILD-CALLABLE claims one. Defining a method spends an entry;
;;; redefining the same method reuses it, because the body is looked up through
;;; the index at call time and rebinding it is all a redefinition needs.
;;;
;;; Running out is a build-time question with a build-time answer, so the error
;;; says which shape to add and how many.

(defvar *callable-pool* (make-hash-table :test 'equal)
  "Callable shape -> a list of unclaimed (index . address) pairs.")

(defvar *claimed-callables* (make-hash-table :test 'equal)
  "(name . shape) -> the (index . address) already claimed for it.

Redefining a method must not spend a second entry from the pool. The generated
shim reaches its body through the index, so rebinding that is the whole of a
redefinition -- which is also why the old body becomes garbage safely here,
where on SBCL the callable has to be kept alive forever.")

(defun %callable-shape (result-node arg-nodes n-hidden)
  (list (%abi-shape result-node) (mapcar #'%abi-shape arg-nodes) n-hidden))

(defun register-callable (result-node arg-nodes n-hidden index address)
  "Record one pre-compiled shim as available. Called by the pool file."
  (let ((shape (%callable-shape result-node arg-nodes n-hidden)))
    (push (cons index address) (gethash shape *callable-pool*))
    index))

(defun %claim-pooled-callable (name result-node arg-nodes n-hidden body noun)
  "Bind BODY to a pre-compiled shim for this shape, and return its address."
  (let* ((shape (%callable-shape result-node arg-nodes n-hidden))
         (key (cons (string name) shape))
         ;; A redefinition reuses the entry it already has; only a new name
         ;; spends one from the pool.
         (entry (or (gethash key *claimed-callables*)
                    (pop (gethash shape *callable-pool*)))))
    (when entry
      (setf (gethash key *claimed-callables*) entry)
      (setf (gethash (car entry) *callable-bodies*)
            (%make-callable-entry :body body :n-hidden n-hidden
                                  :result-node result-node :name name :noun noun))
      (cdr entry))))

(defmacro define-objc-callable-pool ((&key (result :void) (arguments '())
                                           (hidden 2) (count 4))
                                     &environment environment)
  "Compile COUNT interchangeable IMPs for one method shape, ahead of time.

For iOS, where an IMP cannot be built at run time. RESULT and ARGUMENTS are
ordinary type descriptors and ARGUMENTS names every C parameter, so an ordinary
method starts with the two hidden ones:

    (objc:define-objc-callable-pool
      (:result :void
       :arguments (objc:objc-object-pointer objc:sel cocoa:ns-rect)
       :count 4))

covers four -drawRect:-shaped methods. HIDDEN is 2 for a method and 1 for a
block's invoke function.

COUNT is code in the application whether or not it is used, so it is small by
default. Redefining a method does not spend another."
  (declare (ignorable environment))
  (let* ((result-node (node-for-fli-type result))
         (arg-nodes (mapcar #'node-for-fli-type arguments))
         (forms '()))
    (dotimes (i count)
      (let* ((index (incf *callable-counter*))
             (name (format nil "objc-pooled-callable-~d" index)))
        (multiple-value-bind (clines address-defun)
            (%shim-forms result-node arg-nodes index name)
          (push clines forms)
          (push address-defun forms)
          (push `(register-callable ',result-node ',arg-nodes ,hidden
                                    ,index (,(second address-defun)))
                forms))))
    `(progn ,@(nreverse forms))))

(defun %no-callable (result-node arg-nodes n-hidden noun)
  "Refuse an IMP, naming the declaration that would supply one.

Same reasoning as %NO-TRAMPOLINE: this is the failure a user meets on iOS, the
shape is known here, and a message that ends the search is worth more than one
that starts a reading of this file."
  (%unsupported
   (format nil "BUILD-~:@(~a~)" noun)
   (format nil
           "no ~a left in the pool for this shape, and one cannot be built ~
            here -- there is no C compiler on this platform.~2%~
            Add this to a file listed in :BUNDLE-TRAMPOLINES:~2%~
            ~2t(objc:define-objc-callable-pool~%~
            ~5t(:result ~(~s~)~%~
            ~6t:arguments ~(~s~)~@[~%~6t:hidden ~d~] :count 4))~2%~
            and rebuild. :COUNT is how many methods of this shape you may ~
            define; redefining one does not spend another."
           noun
           (or (ignore-errors (fli-type-for-node result-node)) result-node)
           (mapcar (lambda (node) (or (ignore-errors (fli-type-for-node node)) node))
                   arg-nodes)
           (unless (eql n-hidden 2) n-hidden))))

(defun build-callable (name result-node arg-nodes n-hidden body &optional (noun "method"))
  "Build a real C function that calls BODY, and return (VALUES SAP NAME).

The contract is abi.lisp's: ARG-NODES describes every C parameter including the
hidden leading ones, N-HIDDEN says how many are the calling convention's, and
BODY is called as

    (funcall BODY hidden... result-sap user-args...)"
  ;; A pre-compiled shim first: on a phone it is the only option, and where a
  ;; compiler exists it still saves a subprocess.
  (let ((address (%claim-pooled-callable name result-node arg-nodes n-hidden body noun)))
    (when address
      (return-from build-callable (values address name))))
  (unless (compiled-trampolines-available-p)
    (%no-callable result-node arg-nodes n-hidden noun))
  ;; Every callable goes through the generated C shim, including the ones
  ;; FFI:DEFCALLBACK could describe. Two reasons, and the second is the
  ;; decisive one: DEFCALLBACK cannot spell an aggregate at all, and it does
  ;; not import a foreign thread, so a block reaching Lisp from a libdispatch
  ;; worker hangs. One generator with the C in view handles both.
  (let ((sap (%compiled-shim-callable name result-node arg-nodes n-hidden body noun)))
    (return-from build-callable
      (if sap
          (values sap name)
          (%unsupported (format nil "BUILD-~:@(~a~)" noun)
                        (format nil "the C shim for ~a did not compile" name)))))
  (let* ((index (incf *callable-counter*))
         (function-name (format nil "objc-callable-~d" index)))
    (setf (gethash index *callable-bodies*)
          (%make-callable-entry :body body :n-hidden n-hidden
                                :result-node result-node :name name :noun noun))
    (let ((address-fn (%compile-and-load
                       (%callable-source result-node arg-nodes index function-name)
                       (format nil "~a-address" function-name))))
      (unless address-fn
        (remhash index *callable-bodies*)
        (%unsupported (format nil "BUILD-~:@(~a~)" noun)
                      (format nil "the generated callable for ~a did not compile" name)))
      (values (funcall address-fn) name))))

(defun build-imp (result-node arg-nodes body)
  "Build a real IMP that calls BODY, and return (VALUES SAP CALLABLE-NAME).

BODY is a function of (self-sap cmd-sap result-sap . args). ARG-NODES includes
self and _cmd, as every Objective-C method signature does."
  (build-callable (intern (format nil "OBJC-IMP-~D" (incf *imp-counter*)) '#:objc)
                  result-node arg-nodes 2 body "method"))

(defun build-block-invoke (result-node arg-nodes body)
  "Build a block's invoke function that calls BODY, and return (VALUES SAP NAME).

BODY is a function of (block-sap result-sap . args). ARG-NODES includes the
block pointer as its first element: a block's invoke function takes the block
where a method takes self, and there is no _cmd."
  (build-callable (intern (format nil "OBJC-BLOCK-INVOKE-~D" (incf *imp-counter*)) '#:objc)
                  result-node arg-nodes 1 body "block"))

(defun build-block-helper (arg-count body)
  "Build a block copy or dispose helper, and return (VALUES SAP NAME).

copy(dst, src) with ARG-COUNT 2, dispose(block) with 1. Pointers in, nothing
out, so unlike an invoke function there is no signature to vary -- there are
exactly two of them in the process whatever block types exist."
  (build-callable (intern (format nil "OBJC-BLOCK-HELPER-~D" (incf *imp-counter*)) '#:objc)
                  :void (make-list arg-count :initial-element '(:pointer :void))
                  0 body "block helper"))

;;; -------------------------------------------------------------------------

(defun clear-abi-caches ()
  (setf *msgsend-address* nil
        *msgsend-super-address* nil
        *msgsend-stret-address* nil
        *msgsend-super-stret-address* nil))

(add-image-restore-thunk 'clear-abi-caches)
