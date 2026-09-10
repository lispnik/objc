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

(defun %trampoline-source (kind result-node arg-nodes n-fixed function-name)
  "The Lisp source for one compiled trampoline, as a string."
  (let* ((*trampoline-counter* 0)
         (definitions '())
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
    (with-output-to-string (out)
      (format out ";;;; Generated by objc for one call signature. Not for editing.~%")
      (format out "(in-package #:objc)~%~%")
      (format out "(ffi:clines~%  \"#include <objc/runtime.h>\"~%~
                   ~2t\"#include <objc/message.h>\"~%  \"#include <stdint.h>\"")
      (dolist (definition (reverse definitions))
        (format out "~%  ~s" definition))
      (format out ")~%~%")
      ;; The OUT parameter is the struct result buffer; for a scalar result it
      ;; is a null pointer and unused, which keeps one contract for both.
      (format out "(defun ~a (out~{ ~a~})~%" function-name lisp-args)
      (format out "  (ffi:c-inline (out~{ ~a~}) (:pointer-void~{ ~s~}) ~s \"{~%"
              lisp-args ecl-arg-types
              (cond (structp :object)
                    ((member result-node '(:void :unknown)) :void)
                    (t (ecl-foreign-type result-node))))
      (cond
        (structp
         (format out "    ~a r = ((~a(*)(~a))~a)(~{~a~^, ~});~%"
                 result-c result-c prototype-args entry call-args)
         (format out "    *(~a *)#0 = r;~%" result-c)
         (format out "    @(return) = ECL_NIL;~%"))
        ((member result-node '(:void :unknown))
         (format out "    ((void(*)(~a))~a)(~{~a~^, ~});~%"
                 prototype-args entry call-args))
        (t
         (format out "    @(return) = ((~a(*)(~a))~a)(~{~a~^, ~});~%"
                 result-c prototype-args entry call-args)))
      (format out "  }\" :one-liner nil :side-effects t))~%"))))

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

(defun build-trampoline (kind result-node arg-nodes &optional n-fixed)
  "Compile a function that sends one exact call signature.

The contract is abi.lisp's, unchanged:

    (out-sap arg...) => scalar-or-NIL

Strategies are tried in order of what they cost. The dynamic one needs no
compiler and reaches every scalar and pointer signature, which is most of
Cocoa; the rest -- struct results, variadics, and the struct arguments AAPCS64
does not pass like separate scalars -- needs a compiled trampoline."
  (or (%dynamic-trampoline kind result-node arg-nodes n-fixed)
      (%compiled-trampoline kind result-node arg-nodes n-fixed)
      (%unsupported
       "BUILD-TRAMPOLINE"
       (format nil "~a~@[ ~a~] and no C compiler is available to build one"
               (if (struct-node-p result-node)
                   "a struct result"
                   "this signature")
               (and n-fixed "variadic")))))

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
