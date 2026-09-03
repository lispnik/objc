;;;; src/blocks.lisp -- Objective-C blocks, in both directions.
;;;;
;;;; A block is C's closure: a struct carrying a function pointer, which Clang
;;;; creates for a ^{...} literal and which every modern Cocoa API that takes a
;;;; completion handler expects.  This file builds one from a Lisp closure, and
;;;; calls one that came from somewhere else.
;;;;
;;;; The layout is the published Block ABI and has been stable since 2009:
;;;;
;;;;     isa         &_NSConcreteStackBlock
;;;;     flags       what the descriptor's optional fields mean
;;;;     reserved
;;;;     invoke      the function pointer; first argument is the block itself
;;;;     descriptor  { reserved, size, signature, layout }
;;;;     ...         imported variables -- a C block's captured state
;;;;
;;;; The one imported variable here is an integer id, and choosing that over the
;;;; obvious alternative is the only subtle thing in the file.  The Lisp closure
;;;; cannot live in the struct, so it lives in a table and the block carries the
;;;; key.  That key cannot be the block's own address: _Block_copy relocates a
;;;; block to the heap whenever one escapes -- which every asynchronous API does
;;;; -- and the copy would then find nothing.  An id inside the struct is copied
;;;; along with it.  Measured: the original and its copy both reach the same
;;;; closure, from two different addresses.
;;;;
;;;; Ids are never reused.  A block invoked after FREE-OBJC-BLOCK then misses
;;;; the table and is reported, rather than reaching whatever closure happened
;;;; to be allocated that id next.
;;;;
;;;; Everything here is CFFI.  The sb-alien half -- building the invoke function
;;;; and the caller -- lives in abi.lisp, which is the only file allowed to
;;;; mention it; see the seam comment at the top of that file.

(in-package #:objc)

;;; The foreign layout -------------------------------------------------------
;;;
;;; Slot names avoid INVOKE and ID because both are taken in this package: this
;;; file is inside #:objc, where OBJC:INVOKE is the message-send entry point.

(cffi:defcstruct block-literal
  (isa        :pointer)
  (flags      :uint32)
  (reserved   :uint32)
  (invoke-ptr :pointer)
  (descriptor :pointer)
  (block-id   :uint64))

;;; The descriptor is three published structures laid end to end, and which of
;;; them are present is read from the block's FLAGS rather than from anything in
;;; the descriptor itself.  _Block_signature walks past Block_descriptor_1, then
;;; past Block_descriptor_2 if and only if BLOCK_HAS_COPY_DISPOSE is set, and
;;; reads what it finds.  So the two fields below are not optional padding: with
;;; that flag set they are where libclosure believes the copy and dispose
;;; helpers live, and without it the signature must sit sixteen bytes earlier.
;;; Both flags are set here, so this is the full layout and the offsets are
;;; asserted in the tests.
(cffi:defcstruct block-descriptor
  (reserved  :unsigned-long)
  ;; The size of the BLOCK LITERAL, not of this descriptor.  _Block_copy copies
  ;; that many bytes, which is what carries BLOCK-ID across a copy.
  (size      :unsigned-long)
  ;; Block_descriptor_2 -- present because BLOCK_HAS_COPY_DISPOSE is set.
  (copy      :pointer)
  (dispose   :pointer)
  ;; Block_descriptor_3 -- present because BLOCK_HAS_SIGNATURE is set.
  (signature :pointer)
  (layout    :pointer))

(defconstant +block-has-copy-dispose+ (ash 1 25))
(defconstant +block-is-global+        (ash 1 28))
(defconstant +block-use-stret+        (ash 1 29))
(defconstant +block-has-signature+    (ash 1 30))

;;; BLOCK_HAS_SIGNATURE and BLOCK_HAS_COPY_DISPOSE are set; the other two are
;;; deliberately clear:
;;;
;;;   BLOCK_IS_GLOBAL          would make _Block_copy return the same pointer;
;;;                            see STACK-BLOCK-ISA for why that is worse.
;;;   BLOCK_NEEDS_FREE         belongs to a block libclosure malloc'd, and ours
;;;                            comes from CFFI.  Leaving it clear is what makes
;;;                            _Block_release on our own storage a no-op --
;;;                            libclosure returns early rather than calling the
;;;                            dispose helper and free()ing a pointer it does
;;;                            not own.  Its copies get the flag from
;;;                            _Block_copy, which is how their disposal is
;;;                            libclosure's business and their bookkeeping ours.
;;;   BLOCK_USE_STRET          left clear even for a block that does return a
;;;                            structure indirectly.  Its one consumer is
;;;                            imp_implementationWithBlock, which this library
;;;                            never calls, and setting it right means keeping
;;;                            an ABI classification right -- on arm64 an NSRect
;;;                            is four doubles and comes back in v0-v3 despite
;;;                            being 32 bytes, so "larger than 16" is the wrong
;;;                            rule and a wrong flag is worse than none.  A
;;;                            consumer that needs to know can read the
;;;                            signature, which is why that flag IS set.

(defun block-literal-size ()
  (cffi:foreign-type-size '(:struct block-literal)))

(defun block-invoke-offset ()
  "Where the invoke field sits, from the struct definition rather than a
literal -- BUILD-BLOCK-CALLER needs it and there should be one source of truth."
  (cffi:foreign-slot-offset '(:struct block-literal) 'invoke-ptr))

;;; _NSConcreteStackBlock, and libclosure ------------------------------------

(defvar *stack-block-isa* nil)

(defun stack-block-isa ()
  "The isa every block created here gets: &_NSConcreteStackBlock.

Stack rather than global, and the difference is a safety property rather than a
formality.  _Block_copy on a global block returns the same pointer, so the
storage would have to outlive every holder and freeing it while something holds
it would be a jump through a freed invoke field.  A stack block makes an
escaping copy land in memory libclosure owns and frees, carrying the id with it
-- and, because the copy helper runs on the way, carrying a reference to the
closure too.  That is what makes FREE-OBJC-BLOCK safe on a block that has
escaped.  BLOCK_NEEDS_FREE is deliberately not set either, which makes a stray
_Block_release on our own storage a documented no-op."
  (or *stack-block-isa*
      (setf *stack-block-isa*
            (or (cffi:foreign-symbol-pointer "_NSConcreteStackBlock")
                (error 'library-not-found
                       :name "_NSConcreteStackBlock"
                       :candidates '("libSystem.B.dylib"))))))

(cffi:defcfun ("_Block_copy" %block-copy) :pointer (block :pointer))
(cffi:defcfun ("_Block_release" %block-release) :void (block :pointer))
(cffi:defcfun ("_Block_signature" %block-signature) :pointer (block :pointer))

;;; Signatures ---------------------------------------------------------------

(defun block-type-encoding (result-node arg-nodes)
  "The Objective-C type encoding of a block signature.

The method encoding's shape with the receiver and selector replaced by the block
itself: a method is \"v@:@\" where the same block is \"v@?@\".  Stored in the
descriptor and readable with _Block_signature, which is what lets lldb and any
introspecting consumer see what the block takes."
  (with-output-to-string (out)
    (write-string (unparse-type result-node) out)
    (write-string "@?" out)
    (dolist (node arg-nodes)
      (write-string (unparse-type node) out))))

;;; Per-signature machinery --------------------------------------------------

(defstruct (block-machinery (:constructor %make-block-machinery))
  invoke-sap callable-name dispatcher descriptor signature-string caller)

(defvar *block-machinery* (make-hash-table :test 'equal)
  "Canonical signature -> BLOCK-MACHINERY.  Never cleared except on image restore.

This table is the GC root for every block invoke callable, exactly as
*IMP-REGISTRY* is for IMPs: SBCL recycles a callable's trampoline once the
callable becomes garbage, and a block Cocoa copied still holds that address.
Clearing this table looks harmless and is a delayed crash, so there is
deliberately no public function that does it.

It is also what keeps MAKE-OBJC-BLOCK cheap.  Building the invoke function
calls the compiler, so it happens once per distinct signature rather than once
per block -- which is why LispWorks splits its API into a load-time
DEFINE-FOREIGN-BLOCK-CALLABLE-TYPE and a run-time ALLOCATE-FOREIGN-BLOCK.  With
the memo, the declaring form is a convenience rather than a necessity.")

(defvar *block-machinery-lock* (bt:make-lock "objc block machinery"))

(defun build-block-dispatcher (result-node arg-nodes)
  "Compile the Lisp side of one signature: raw C arguments in, closure called,
result converted out.

Exactly the conversions DEFINE-OBJC-METHOD gives a Lisp method body, so a
closure sees an NSRect argument as #(x y width height) and may return one the
same way -- a block is a method's shape without the receiver, and it would be a
poor joke to make the argument conventions differ.

Compiled rather than interpreted because the conversions are known once the
signature is, and a block on an enumeration runs per element."
  (let ((raws (loop for i from 0 below (length arg-nodes)
                    collect (gensym (format nil "A~D-" i))))
        (block-sap (gensym "BLOCK"))
        (result-sap (gensym "RESULT"))
        (function (gensym "FUNCTION"))
        (value (gensym "VALUE")))
    (compile
     nil
     `(lambda (,block-sap ,result-sap ,@raws)
        (declare (ignorable ,result-sap))
        (let* ((,function (block-function-for-sap ,block-sap))
               (,value (funcall ,function
                                ,@(loop for raw in raws
                                        for node in arg-nodes
                                        collect (argument-conversion-form raw node nil)))))
          ,(if (struct-node-p result-node)
               ;; A structure result is not returned; it is written into the
               ;; buffer BUILD-CALLABLE holds, which then returns it by value.
               `(write-method-struct-result ,value ',result-node ,result-sap)
               `(convert-method-result ,value ',result-node)))))))

(defun ensure-block-machinery (result-node arg-nodes)
  "The machinery for one signature, building it the first time.

ARG-NODES is the user's argument list; the block itself is prepended here, so
callers describe the signature the way it reads in C."
  (let ((key (canonical-signature result-node (cons :block arg-nodes))))
    (bt:with-lock-held (*block-machinery-lock*)
      (or (gethash key *block-machinery*)
          (setf (gethash key *block-machinery*)
                (build-block-machinery result-node arg-nodes key))))))

(defun build-block-machinery (result-node arg-nodes key)
  (declare (ignore key))
  (let ((dispatcher (build-block-dispatcher result-node arg-nodes))
        (signature (block-type-encoding result-node arg-nodes)))
    (multiple-value-bind (sap name)
        (build-block-invoke result-node (cons :block arg-nodes) dispatcher)
      (%make-block-machinery
       :invoke-sap sap
       :callable-name name
       :dispatcher dispatcher
       :signature-string (cffi:foreign-string-alloc signature :encoding :utf-8)
       :descriptor (make-block-descriptor signature)
       :caller (build-block-caller result-node (cons :block arg-nodes)
                                   (block-invoke-offset))))))

;;; The copy and dispose helpers ---------------------------------------------
;;;
;;; There are exactly two in the process, shared by every descriptor, because
;;; neither of them depends on the block's signature.  Together they are what
;;; makes an escaped block safe to free: libclosure tells us when it has made a
;;; copy and when it has finally destroyed one, and the closure stays registered
;;; in between.
;;;
;;; Only the FIRST copy calls the copy helper.  _Block_copy on an already-heap
;;; block just bumps libclosure's own refcount and returns the same pointer, and
;;; the matching releases run that count back down before one dispose call
;;; arrives.  So these count allocations, one dispose per copy helper call, and
;;; the two schemes nest rather than fight.

(defvar *block-copy-helper* nil)
(defvar *block-dispose-helper* nil)

(defun ensure-block-helpers ()
  "Build the copy and dispose helpers on first use; return them.

Rooted in these variables forever, for the reason *BLOCK-MACHINERY* is: SBCL
recycles a callable's trampoline once the callable is garbage, and every
descriptor in the process points at these two."
  (unless *block-copy-helper*
    (setf *block-copy-helper*
          (build-block-helper 2 (lambda (result-sap destination source)
                                  (declare (ignore result-sap source))
                                  ;; The id was memmove'd into the copy already;
                                  ;; both ends carry it, and DESTINATION is the
                                  ;; one that will outlive this call.
                                  (retain-block-id (block-id-at destination))))
          *block-dispose-helper*
          (build-block-helper 1 (lambda (result-sap block)
                                  (declare (ignore result-sap))
                                  (release-block-id (block-id-at block))))))
  (values *block-copy-helper* *block-dispose-helper*))

(defun make-block-descriptor (signature)
  "Allocate the descriptor for a signature.  Shared by every block of that shape.

Always the full six fields and always zeroed, whatever the flags say.
_Block_signature computes the signature field's offset from the flags, so a
descriptor shorter than the flags imply is a read past the allocation -- making
the allocation unconditionally full makes that class of bug impossible rather
than merely untested."
  (multiple-value-bind (copy dispose) (ensure-block-helpers)
    (let ((descriptor (cffi:foreign-alloc :uint8
                                          :count (cffi:foreign-type-size
                                                  '(:struct block-descriptor))
                                          :initial-element 0)))
      (setf (cffi:foreign-slot-value descriptor '(:struct block-descriptor) 'reserved) 0
            (cffi:foreign-slot-value descriptor '(:struct block-descriptor) 'size)
            (block-literal-size)
            (cffi:foreign-slot-value descriptor '(:struct block-descriptor) 'copy)
            (pointer-of copy)
            (cffi:foreign-slot-value descriptor '(:struct block-descriptor) 'dispose)
            (pointer-of dispose)
            (cffi:foreign-slot-value descriptor '(:struct block-descriptor) 'signature)
            (cffi:foreign-string-alloc signature :encoding :utf-8)
            (cffi:foreign-slot-value descriptor '(:struct block-descriptor) 'layout)
            (cffi:null-pointer))
      descriptor)))

;;; Block types --------------------------------------------------------------

(defstruct (block-type (:constructor %make-block-type))
  name result-node arg-nodes)

(defvar *block-types* (make-hash-table :test 'eq)
  "Name -> BLOCK-TYPE.  Pure Lisp; survives a dump intact.")

(defun parse-block-designator (designator)
  "A block type designator as (VALUES RESULT-NODE ARG-NODES).

Either a symbol naming a type defined with DEFINE-OBJC-BLOCK-TYPE, or the
inline form (RESULT-TYPE (ARG-TYPE...)) for a one-off."
  (cond
    ((symbolp designator)
     (let ((type (gethash designator *block-types*)))
       (unless type
         (error "~S does not name a block type.  Define it with ~
                 DEFINE-OBJC-BLOCK-TYPE, or pass (result-type (arg-type...))."
                designator))
       (values (block-type-result-node type) (block-type-arg-nodes type))))
    ((and (consp designator) (= 2 (length designator)) (listp (second designator)))
     (values (node-for-fli-type (first designator))
             (mapcar #'node-for-fli-type (second designator))))
    (t (error "~S is not a block type: expected a name or ~
               (result-type (arg-type...))." designator))))

(defmacro define-objc-block-type (name result-type arg-types)
  "Define NAME as a block signature returning RESULT-TYPE and taking ARG-TYPES.

    (objc:define-objc-block-type comparator :long-long
      (objc:objc-object-pointer objc:objc-object-pointer))

    (objc:make-objc-block 'comparator (lambda (a b) ...))

Types are the ordinary FLI type descriptors.  Naming a signature is optional --
MAKE-OBJC-BLOCK also takes (result-type (arg-type...)) inline -- but a name
documents the C prototype at the point it is written, and the definition is
checked when the file loads rather than when a block is first made."
  `(progn
     (setf (gethash ',name *block-types*)
           (%make-block-type :name ',name
                             :result-node (node-for-fli-type ',result-type)
                             :arg-nodes (mapcar #'node-for-fli-type ',arg-types)))
     ',name))

;;; The registry -------------------------------------------------------------

(defstruct (objc-block (:constructor %make-objc-block) (:print-object print-objc-block))
  "A block made by MAKE-OBJC-BLOCK: its foreign storage, its id, and its signature.

A wrapper rather than the bare pointer so that freeing is answerable.  A raw
pointer cannot say whether it has been freed, which makes a double free
indistinguishable from a first one and a use-after-free indistinguishable from
ordinary use; with the wrapper, FREE-OBJC-BLOCK is idempotent and
OBJC-BLOCK-LIVE-P has an answer.  It passes straight to INVOKE anyway, through
the OBJC-OBJECT-POINTER method below."
  id pointer signature)

;;; DEFSTRUCT has nowhere to put a docstring on a generated accessor, and this
;;; one is exported, so it gets one the only way available.
(setf (documentation 'objc-block-pointer 'function)
      "The foreign pointer to BLOCK's literal, or NIL once it has been freed.

Rarely needed: a block passes to INVOKE as it stands.  Reach for this when
handing the block to a foreign function directly -- a dispatch_async, say -- and
remember that a block that escapes must not then be freed.")

(defun print-objc-block (block stream)
  (print-unreadable-object (block stream :type t :identity nil)
    (format stream "~A ~A" (objc-block-signature block)
            (if (objc-block-pointer block) "live" "freed"))))

(defstruct (block-record (:constructor %make-block-record (block function)))
  "One live block id: the wrapper, the Lisp closure, and how many holders there
are.

The count starts at one, for the OBJC-BLOCK the caller was given.  _Block_copy
adds one through the copy helper and libclosure's own free subtracts it again
through the dispose helper, so the closure outlives FREE-OBJC-BLOCK exactly as
long as something Cocoa holds still needs it."
  block
  function
  (refcount 1))

(defvar *block-records* (make-hash-table :test 'eql)
  "Block id -> BLOCK-RECORD.

A strong reference to the Lisp closure, deliberately.  There are no finalizers
anywhere in this library -- SBCL runs them on whatever thread triggered the
collection, and this one would have to reach foreign memory -- so an entry
leaves when its last holder does, and that is what the refcount is counting.")

(defvar *block-id-counter* 0
  "Monotonic, and never reset -- not even on image restore.

Reusing an id would turn the one remaining use-after-free -- invoking a copy of
a block whose storage libclosure has already disposed of -- from a reported miss
into a call to whatever closure was allocated that id next.")

(defvar *block-lock* (bt:make-lock "objc block registry"))

(defun block-id-at (pointer)
  "The id embedded in the block literal at POINTER."
  (cffi:mem-ref (pointer-of pointer) :uint64
                (cffi:foreign-slot-offset '(:struct block-literal) 'block-id)))

(defun retain-block-id (id)
  "Note that one more holder exists for ID.  Called by the copy helper."
  (bt:with-lock-held (*block-lock*)
    (let ((record (gethash id *block-records*)))
      (when record (incf (block-record-refcount record))))))

(defun release-block-id (id)
  "Note that one holder of ID is gone, and forget the closure at the last one.

Called by the dispose helper, and by FREE-OBJC-BLOCK for the creator's own
reference.  The record is dropped only at zero, which is what lets an escaped
block outlive the FREE-OBJC-BLOCK that would once have stranded it."
  (bt:with-lock-held (*block-lock*)
    (let ((record (gethash id *block-records*)))
      (when (and record (<= (decf (block-record-refcount record)) 0))
        (remhash id *block-records*)
        t))))

(defun block-function-for-sap (block-sap)
  "The Lisp closure a block invocation belongs to.

The lock covers the lookup and nothing else: the closure is funcalled after it
is released, because a completion handler that frees a block -- its own or
another's -- would otherwise deadlock against its own invocation."
  (let* ((id (cffi:mem-ref (pointer-of block-sap) :uint64
                           (cffi:foreign-slot-offset '(:struct block-literal) 'block-id)))
         (record (bt:with-lock-held (*block-lock*) (gethash id *block-records*))))
    (unless record
      (error "Objective-C block ~D was invoked after its last holder let go.~%~
              Every copy libclosure made has been disposed of and the original ~
              was freed, so the closure is gone.  Reaching a block in that ~
              state means something kept the raw pointer rather than a copy." id))
    (block-record-function record)))

;;; The public API -----------------------------------------------------------

(defun make-objc-block (type function)
  "Make an Objective-C block that calls FUNCTION, and return an OBJC-BLOCK.

TYPE is a name defined with DEFINE-OBJC-BLOCK-TYPE, or (result-type (arg-type...)).
The result can be passed straight to INVOKE wherever a block is wanted:

    (objc:with-objc-block (b '(:void (objc:objc-object-pointer
                                      (:unsigned :long-long)
                                      (:pointer objc:objc-c++-bool)))
                             (lambda (object index stop)
                               (declare (ignore stop))
                               (print (list index (objc:ns-string-to-string object)))))
      (objc:invoke array \"enumerateObjectsUsingBlock:\" b))

The block must be freed with FREE-OBJC-BLOCK, or created with WITH-OBJC-BLOCK,
which frees it on unwind.  Freeing one an API has kept is safe: anything that
keeps a block copies it, the copy holds its own reference to the closure, and
the closure goes when the last holder does.  So the choice between the two is
about the ordinary question of when the storage is no longer wanted, and not
about escape.

Compiling the invoke function happens once per distinct signature, so the second
block of a shape costs an allocation and a hash-table entry."
  (check-type function function)
  (multiple-value-bind (result-node arg-nodes) (parse-block-designator type)
    (let* ((machinery (ensure-block-machinery result-node arg-nodes))
           (literal (cffi:foreign-alloc :uint8 :count (block-literal-size)
                                               :initial-element 0))
           (record nil))
      (setf (cffi:foreign-slot-value literal '(:struct block-literal) 'isa)
            (stack-block-isa)
            (cffi:foreign-slot-value literal '(:struct block-literal) 'flags)
            (logior +block-has-signature+ +block-has-copy-dispose+)
            (cffi:foreign-slot-value literal '(:struct block-literal) 'reserved)
            0
            (cffi:foreign-slot-value literal '(:struct block-literal) 'invoke-ptr)
            (pointer-of (block-machinery-invoke-sap machinery))
            (cffi:foreign-slot-value literal '(:struct block-literal) 'descriptor)
            (block-machinery-descriptor machinery))
      (bt:with-lock-held (*block-lock*)
        (let ((id (incf *block-id-counter*)))
          (setf (cffi:foreign-slot-value literal '(:struct block-literal) 'block-id) id)
          (setf record (%make-objc-block
                        :id id :pointer literal
                        :signature (block-type-encoding result-node arg-nodes)))
          ;; Refcount one: this OBJC-BLOCK.  Every copy libclosure makes adds
          ;; another through the copy helper.
          (setf (gethash id *block-records*) (%make-block-record record function))))
      record)))

(defun free-objc-block (block)
  "Free BLOCK's storage and drop its reference to the closure.  Idempotent;
returns NIL.

Safe to call on a block something else has kept.  Anything that keeps a block
copies it -- that is what _Block_copy is for and every asynchronous API does it
-- and the copy took its own reference through the copy helper, so what this
releases is only the one this OBJC-BLOCK held.  The closure survives until
libclosure disposes of the last copy.

The remaining way to be wrong is to hand a foreign API this exact pointer and
have it keep the pointer rather than a copy.  Nothing in Cocoa does that."
  (check-type block objc-block)
  (let ((pointer nil))
    (bt:with-lock-held (*block-lock*)
      (when (objc-block-pointer block)
        (setf pointer (objc-block-pointer block)
              (objc-block-pointer block) nil)))
    (when pointer
      ;; Both outside the lock: RELEASE-BLOCK-ID takes it itself, and a free
      ;; must not stall another thread's invocation.
      (release-block-id (objc-block-id block))
      (cffi:foreign-free pointer)))
  nil)

(defun objc-block-live-p (block)
  "True while BLOCK has not been freed and did not lose its foreign storage to
an image dump."
  (check-type block objc-block)
  (and (objc-block-pointer block) t))

(defmacro with-objc-block ((var type function) &body body)
  "Bind VAR to a block for the extent of BODY and free it on unwind.

Usually what you want, including for asynchronous work: a callee that keeps the
block has copied it by the time BODY returns, and the copy holds the closure
until libclosure disposes of it.  Reach for MAKE-OBJC-BLOCK and an explicit
FREE-OBJC-BLOCK when the storage itself has to outlive the form -- when the same
block is handed out repeatedly, say."
  `(let ((,var (make-objc-block ,type ,function)))
     (unwind-protect (locally ,@body)
       (free-objc-block ,var))))

(defun call-objc-block (type block &rest args)
  "Call BLOCK, which may have come from anywhere, and return its result.

The other direction: a block Cocoa handed you is a struct with a function
pointer in it, and this reads that pointer and calls it with the block as the
first argument.  TYPE describes the signature exactly as for MAKE-OBJC-BLOCK --
a block carries a signature string, but the C prototype is what the call needs.

BLOCK is an OBJC-BLOCK, a raw pointer, or anything OBJC-OBJECT-POINTER accepts."
  (multiple-value-bind (result-node arg-nodes) (parse-block-designator type)
    (let ((machinery (ensure-block-machinery result-node arg-nodes))
          (pointer (block-pointer-of block)))
      (when (cffi:null-pointer-p pointer)
        (error "Cannot call a null Objective-C block."))
      (unless (= (length args) (length arg-nodes))
        (error "The block signature takes ~D argument~:P but ~D ~:*~[were~;was~:;were~] given."
               (length arg-nodes) (length args)))
      (with-call-temporaries
        (flet ((call (out-sap)
                 (apply (block-machinery-caller machinery)
                        out-sap
                        (sap-of pointer)
                        (loop for arg in args
                              for node in arg-nodes
                              collect (marshal-argument arg node)))))
          ;; A structure result is written through a buffer rather than
          ;; returned.  For the Cocoa structures that becomes a vector or a cons
          ;; and the buffer's lifetime stops mattering; for anything else the
          ;; only thing there is to hand back is a pointer INTO that buffer,
          ;; which is dead by the time this function returns, so this refuses
          ;; rather than returning one.
          (cond
            ((and (struct-node-p result-node) (cocoa-struct-kind result-node))
             (let ((size (node-size-and-alignment (resolve-struct-layout result-node))))
               (cffi:with-foreign-object (out :uint8 (max 1 size))
                 (call (sap-of out))
                 (read-cocoa-struct (sap-of out) (cocoa-struct-kind result-node)))))
            ((struct-node-p result-node)
             (error "CALL-OBJC-BLOCK cannot return a ~A: it is a structure with no ~
                     Lisp representation, so the only result would be a pointer to a ~
                     buffer this call frees on the way out.  A block that RETURNS such ~
                     a structure to Lisp is the gap; MAKE-OBJC-BLOCK can still create ~
                     one, and a structure ARGUMENT in either direction is fine."
                    (unparse-type result-node)))
            (t (call (sap-of (cffi:null-pointer))))))))))

(defun block-pointer-of (block)
  (etypecase block
    (objc-block (or (objc-block-pointer block)
                    (error "This Objective-C block has been freed.")))
    (t (objc-object-pointer block))))

(defmethod objc-object-pointer ((object objc-block))
  "So a block passes straight to INVOKE wherever a block argument is wanted."
  (or (objc-block-pointer object)
      (error "This Objective-C block has been freed.")))

;;; Image restore ------------------------------------------------------------

(defun clear-block-caches ()
  "Nothing block-related survives SAVE-LISP-AND-DIE.

The invoke functions and the two helpers are alien callables, and the
descriptors and signature strings are malloc'd; all of them are dangling in a
restored image.  The machinery is dropped so the next block of a signature
rebuilds it, the helpers are dropped so the next descriptor rebuilds them, and
every live record is marked freed so a wrapper the program still holds answers
OBJC-BLOCK-LIVE-P NIL instead of handing out a stale pointer.

The records go whatever their refcounts say.  A block that escaped into Cocoa
before the dump is not saved by having a reference outstanding: the copy Cocoa
holds points at an invoke function that no longer exists, so the entry it is
counting is worth nothing, and the alternative is a table that never empties.

The id counter is deliberately not reset: ids must stay unique across a restore
for the same reason they are not reused within a run."
  (bt:with-lock-held (*block-machinery-lock*)
    (clrhash *block-machinery*))
  (setf *block-copy-helper* nil
        *block-dispose-helper* nil)
  (bt:with-lock-held (*block-lock*)
    (maphash (lambda (id record)
               (declare (ignore id))
               (setf (objc-block-pointer (block-record-block record)) nil))
             *block-records*)
    (clrhash *block-records*)))

(add-image-restore-thunk 'clear-block-caches)
