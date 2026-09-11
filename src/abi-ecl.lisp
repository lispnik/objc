;;;; src/abi-ecl.lisp -- the implementation seam, for ECL.
;;;;
;;;; The counterpart to abi.lisp.  Same ten-function contract, different
;;;; machinery underneath.  Where abi.lisp JITs through sb-alien, this reaches
;;;; the ABI two ways:
;;;;
;;;;   dynamic    SI:CALL-CFUN and SI::MAKE-DYNAMIC-CALLBACK, which are libffi.
;;;;              No compiler involved, so it works in an interpreted image and
;;;;              therefore on a phone and at a REPL attached to one.  Since ECL
;;;;              learned to pass a structure by value through them, this is
;;;;              nearly the whole of what Cocoa needs.
;;;;
;;;;   compiled   FFI:C-INLINE, generated per call shape and compiled with the
;;;;              C compiler that a Mac has and a phone does not.  Faster, and
;;;;              the only way to make a genuinely variadic call.
;;;;
;;;; There used to be a third: a pool of trampolines and IMPs compiled into the
;;;; application before it shipped, because the dynamic FFI could not name a
;;;; structure and a libffi closure was believed to kill the process on iOS.
;;;; Neither was true of ECL itself.  The first was a closed table of scalars in
;;;; src/c/ffi.d, since opened; the second was FFI:CALLBACK handing out a
;;;; closure's writable record instead of its entry point, since fixed -- both
;;;; on lispnik/ecl.  What survives of the pool is OBJC:DEFINE-OBJC-TRAMPOLINE,
;;;; for the one shape the dynamic path still cannot make: a variadic send, on
;;;; a platform with no compiler.
;;;;
;;;; This file needs that ECL.  On one without those fixes, a structure result
;;;; is refused with a message that says so, and a dynamic callback crashes on
;;;; arm64 the first time it is called.

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

;;; Dynamic FFI designators ---------------------------------------------------
;;;
;;; SI:CALL-CFUN and SI::MAKE-DYNAMIC-CALLBACK read their types in C and cannot
;;; look a name up, so an aggregate is handed to them as the (:STRUCT (name
;;; type) ...) list its layout resolves to.  libffi takes it from there: size,
;;; alignment, and -- the part nothing in Lisp should be deciding -- which
;;; registers the members travel in, when the whole thing goes to memory, and
;;; when the callee is handed a hidden pointer to write its result through.

(defun ecl-dffi-type (node)
  "The dynamic FFI designator for NODE.

A scalar or pointer is what ECL-FOREIGN-TYPE says.  A structure is its resolved
layout as a (:STRUCT ...) list, nested structures nested and an array member as
(:ARRAY type count); the member names are not read by anything.  A union is
refused, because libffi has no union type and the usual imitation -- a
structure of the largest member -- classifies wrongly for register passing
exactly when the members disagree about their class, which is the case that
matters."
  (etypecase node
    (keyword (ecl-foreign-type node))
    (cons
     (ecase (first node)
       (:pointer :pointer-void)
       (:qualified (ecl-dffi-type (third node)))
       (:array (list :array (ecl-dffi-type (third node)) (second node)))
       (:struct
        (let ((fields (third (%resolved-struct node))))
          (unless fields
            (%unsupported "ECL-DFFI-TYPE"
                          (format nil "~s has no layout; the runtime elides ~
                                       them, and one cannot be guessed" node)))
          (list* :struct (mapcar (lambda (field) (list :m (ecl-dffi-type field)))
                                 fields))))
       (:union
        (%unsupported "ECL-DFFI-TYPE"
                      (format nil "~s is a union, which libffi cannot describe ~
                                   in a way that is right for every ABI" node)))
       (:bitfield
        (%unsupported "ECL-DFFI-TYPE"
                      (format nil "~s is a bitfield" node)))))))

(defun %resolved-struct (node)
  "NODE with its layout, resolving through the runtime if it came without one."
  (if (third node) node (resolve-struct-layout node)))

(defun %struct-size (node)
  (values (node-size-and-alignment (%resolved-struct node))))

(defun %copy-foreign-bytes (from to size)
  "SIZE bytes from foreign pointer FROM to foreign pointer TO."
  (loop for i below size
        do (setf (cffi:mem-aref to :uint8 i) (cffi:mem-aref from :uint8 i))))

(defun %zeroed-foreign-buffer (size)
  "SIZE bytes of collector-managed foreign memory, zero-filled.

Collector-managed rather than FOREIGN-ALLOC, because a structure returned from
a callback is read by libffi after the Lisp function has returned and there is
no moment at which to free it."
  (let ((buffer (si::allocate-foreign-data :void size)))
    (loop for i below size do (setf (cffi:mem-aref buffer :uint8 i) 0))
    buffer))

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
;;; be compiled at all.  Structures go by value in both directions: an argument
;;; is read from the memory its SAP names, and a result comes back as fresh
;;; foreign data that is copied into OUT to keep the contract.
;;;
;;; What it cannot do is a variadic call.  arm64 passes variadic arguments on
;;; the stack, a fixed cif puts them in registers, and ECL does not expose
;;; libffi's variadic preparation.  That falls through to a compiled strategy,
;;; or on a phone to a declared one.

(defun %dynamic-signature (result-node arg-nodes)
  "(VALUES RESULT-TYPE ARG-TYPES), or NIL if the dynamic FFI cannot describe them."
  (let ((result-type (ignore-errors (ecl-dffi-type result-node)))
        (arg-types (ignore-errors (mapcar #'ecl-dffi-type arg-nodes))))
    (and result-type
         (or arg-types (null arg-nodes))
         (values result-type arg-types))))

(defun %dynamic-result-handler (result-node result-type)
  "A function of (raw out) producing the contract's value for a raw CALL-CFUN result."
  (cond ((struct-node-p result-node)
         (let ((size (%struct-size result-node)))
           (lambda (raw out) (%copy-foreign-bytes raw out size) nil)))
        ((eq result-type :void)
         (lambda (raw out) (declare (ignore raw out)) nil))
        (t
         (lambda (raw out) (declare (ignore out)) raw))))

(defun %dynamic-trampoline (kind result-node arg-nodes n-fixed)
  "A trampoline built on SI:CALL-CFUN, or NIL if this signature is out of reach."
  (when n-fixed                         ; variadic: stack, not registers
    (return-from %dynamic-trampoline nil))
  (multiple-value-bind (result-type arg-types) (%dynamic-signature result-node arg-nodes)
    (unless result-type (return-from %dynamic-trampoline nil))
    (ensure-dispatch-addresses)
    (let ((entry (ecase kind
                   (:send *msgsend-address*)
                   (:super *msgsend-super-address*)))
          (finish (%dynamic-result-handler result-node result-type)))
      (lambda (out &rest args)
        (funcall finish
                 (with-fp-traps-masked (si:call-cfun entry result-type arg-types args))
                 out)))))


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
;;; there yields bytecode. The dynamic path covers a phone; a variadic send is
;;; the one thing it cannot, and DEFINE-OBJC-TRAMPOLINE is for that.

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


;;; Declared trampolines --------------------------------------------------------
;;;
;;; For a variadic send on a platform with no compiler.  Everything else the
;;; dynamic path does; this is what remains of the pool that used to cover
;;; structure results as well.
;;;
;;; A trampoline depends only on the ABI shape of a signature and not on the
;;; selector, so one declaration serves every method that looks like it.

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

For a variadic send on iOS, where nothing can be compiled at run time and the
dynamic FFI cannot make one.  RESULT and ARGUMENTS are ordinary type
descriptors, ARGUMENTS names every C parameter including the two hidden ones,
and VARIADIC-NUM-OF-FIXED says where the variadic part begins:

    (objc:define-objc-trampoline
      (:result objc:objc-object-pointer
       :arguments (objc:objc-object-pointer objc:sel objc:objc-object-pointer
                   objc:objc-object-pointer)
       :variadic-num-of-fixed 3))

covers +stringWithFormat: with one argument, and every other selector that
looks like it.  The shape is what is matched, so one of these serves many.

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

Only a variadic send reaches here: everything else the dynamic path makes at
run time.  The shape is known and the form to paste is a mechanical function of
it, so the message ends the search rather than starting one."
  (%unsupported
   "BUILD-TRAMPOLINE"
   (format nil
           "no trampoline for this ~:[call~;variadic call~], and none can be ~
            built here -- there is no C compiler on this platform.~2%~
            Add this to a file listed in :BUNDLE-TRAMPOLINES:~2%~
            ~2t(objc:define-objc-trampoline~%~
            ~5t(~@[:kind ~(~s~) ~]:result ~(~s~)~%~
            ~6t:arguments ~(~s~)~@[~%~6t:variadic-num-of-fixed ~d~]))~2%~
            and rebuild."
           n-fixed
           (unless (eq kind :send) kind)
           (ignore-errors (fli-type-for-node result-node))
           (mapcar (lambda (node) (or (ignore-errors (fli-type-for-node node)) node))
                   arg-nodes)
           n-fixed)))

(defun build-trampoline (kind result-node arg-nodes &optional n-fixed)
  "Compile a function that sends one exact call signature.

The contract is abi.lisp's, unchanged:

    (out-sap arg...) => scalar-or-NIL

The dynamic path first, because it costs nothing and reaches everything but a
variadic call; then a declared trampoline, which is what a phone has for those;
then one compiled now, which is what a Mac has."
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
  (multiple-value-bind (result-type arg-types) (%dynamic-signature result-node arg-nodes)
    (unless result-type (return-from %dynamic-block-caller nil))
    (let ((finish (%dynamic-result-handler result-node result-type)))
      (lambda (out block &rest args)
        ;; The invoke pointer, read from this particular block.
        (let ((entry (cffi:mem-ref block :pointer invoke-offset)))
          (funcall finish
                   (with-fp-traps-masked
                     (si:call-cfun entry result-type arg-types (cons block args)))
                   out))))))

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
      (%unsupported "BUILD-BLOCK-CALLER" "this signature cannot be described")))

;;; Inbound: real IMPs ---------------------------------------------------------
;;;
;;; The other direction. An Objective-C class defined in Lisp needs a real C
;;; function pointer per method, and SI::MAKE-DYNAMIC-CALLBACK makes one: a
;;; libffi closure, whose entry point is a slot in a page of trampolines the
;;; platform maps executable once.  No compiler, no shim, and a structure in
;;; either direction is described the same way a call is.
;;;
;;; Two obligations from abi.lisp are met in the Lisp function the closure
;;; calls rather than in C.  Float traps are masked, because Cocoa generates
;;; invalid operations freely and an unmasked one takes the process out.  And
;;; no condition may escape, because there is no handler on the Objective-C
;;; side and an unwind past the closure aborts.
;;;
;;; One obligation is not met, and was not by the C shims this replaces either:
;;; a callback arriving on a thread ECL did not create.  libffi's executor
;;; asks for the current thread's environment and does not import one, so a
;;; block invoked on a libdispatch worker is still the gap the README records.
;;; Every IMP UIKit calls arrives on the main thread, which is ECL's own.

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

(defun %dynamic-callable (name result-node arg-nodes n-hidden body noun)
  "A libffi closure calling BODY, or NIL if the signature cannot be described.

Returns the closure's entry point.  ECL keeps what the closure needs alive on
NAME's plist, and NAME is interned, so the address stays valid for the life of
the image -- which is what an address handed to class_addMethod requires."
  (multiple-value-bind (result-type arg-types) (%dynamic-signature result-node arg-nodes)
    (unless result-type (return-from %dynamic-callable nil))
    (let* ((structp (struct-node-p result-node))
           (size (and structp (%struct-size result-node))))
      (flet ((call (args)
               ;; RESULT-SAP is the structure result buffer, or a null pointer
               ;; when the result is a scalar and the body's value is the C
               ;; return.  A structure result is the buffer itself: libffi
               ;; copies it out after this returns.
               (let* ((result-sap (if structp (%zeroed-foreign-buffer size) (cffi:null-pointer)))
                      (value (apply body (append (subseq args 0 n-hidden)
                                                 (list result-sap)
                                                 (nthcdr n-hidden args)))))
                 (if structp result-sap value)))
             (zero ()
               (if structp (%zeroed-foreign-buffer size) (zero-value result-node))))
        (si::make-dynamic-callback
         (lambda (&rest args)
           (with-fp-traps-masked
             (handler-case (call args)
               (serious-condition (condition)
                 (report-imp-error condition name noun)
                 (zero)))))
         name result-type arg-types)))))

(defun build-callable (name result-node arg-nodes n-hidden body &optional (noun "method"))
  "Build a real C function that calls BODY, and return (VALUES SAP NAME).

The contract is abi.lisp's: ARG-NODES describes every C parameter including the
hidden leading ones, N-HIDDEN says how many are the calling convention's, and
BODY is called as

    (funcall BODY hidden... result-sap user-args...)"
  (let ((sap (%dynamic-callable name result-node arg-nodes n-hidden body noun)))
    (if sap
        (values sap name)
        (%unsupported (format nil "BUILD-~:@(~a~)" noun)
                      (format nil "the signature of ~a cannot be described to ~
                                   the dynamic FFI" name)))))

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
