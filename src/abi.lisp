;;;; src/abi.lisp -- the implementation seam.
;;;;
;;;; THIS IS THE ONLY FILE ALLOWED TO MENTION sb-alien: OR sb-sys:.
;;;; test/seam-tests.lisp greps the sources to enforce that, because a seam
;;;; nobody checks stops being a seam.
;;;;
;;;; Why sb-alien and not CFFI.  CFFI's foreign-funcall, foreign-funcall-pointer
;;;; and defcallback are macros: the types are fixed when the form is
;;;; macroexpanded, which is exactly what dynamic dispatch cannot promise.  That
;;;; alone would be workable -- we compile the form at runtime anyway -- but
;;;; without libffi, CFFI cannot express a struct passed or returned by value at
;;;; all: FOREIGN-FUNCALL-POINTER signals COMPILED-PROGRAM-ERROR and DEFCALLBACK
;;;; signals CASE-FAILURE.  Struct returns are not an edge case here.
;;;; -[NSView frame], -[NSString rangeOfString:] and the manual's own "pair"
;;;; example all need them.  Pulling in cffi-libffi would fix that and break two
;;;; other things: it needs cffi-grovel and therefore a C toolchain at build
;;;; time, and it can never make an Apple arm64 variadic call, because CFFI only
;;;; ever calls ffi_prep_cif and never ffi_prep_cif_var.
;;;;
;;;; sb-alien does all three, in both directions, with one mechanism.  Measured
;;;; on this machine: CGRectInset (a 32-byte homogeneous float aggregate, passed
;;;; and returned in v0-v3) and CGAffineTransformMakeRotation (48 bytes, non-HFA,
;;;; returned indirectly through x8) both give correct results, as does an
;;;; alien callable that returns a struct by value.  SBCL's arm64 backend
;;;; implements AAPCS64 properly and we lean on that.
;;;;
;;;; This is also why there is no objc_msgSend_stret anywhere in this library:
;;;; it does not exist on arm64.  Large structs come back through x8 from plain
;;;; objc_msgSend, and SBCL sets x8 up when the return type says to.

(in-package #:objc)

;;; Floating point traps -----------------------------------------------------
;;;
;;; SBCL runs with :INVALID and :DIVIDE-BY-ZERO unmasked.  CoreGraphics does
;;; not: the very first NSWindow creation raises FLOATING-POINT-INVALID-OPERATION
;;; and takes the process out with SIGFPE.  Masking around the call fixes it,
;;; and this is almost certainly why earlier attempts at an SBCL Objective-C
;;; bridge reported that everything worked except that the window never showed.
;;;
;;; LispWorks has no equivalent and documents none, because it runs with FP
;;; exceptions masked by default and never had the problem.  There is no prior
;;; art to copy here.
;;;
;;; Masked per entry point, never globally: masking globally would change Lisp's
;;; own arithmetic, so that (/ 1d0 0d0) quietly returned infinity instead of
;;; signalling.

(defmacro with-fp-traps-masked (&body body)
  "Run BODY with the floating point traps Cocoa violates masked.
Wrapped around every message send and the body of every Lisp-implemented
method.  See the commentary above -- this is load bearing, not defensive."
  `(float-features:with-float-traps-masked (:invalid :divide-by-zero :overflow)
     ,@body))

;;; Encoding node -> alien type ---------------------------------------------

(defvar *alien-struct-types* (make-hash-table :test 'equal)
  "Canonical struct encoding -> the symbol naming its alien type.
Defining an alien type calls the compiler, so they are memoized; the table is
cleared on image restore because the types do not survive a dump.")

(defvar *alien-struct-counter* 0)

(defun alien-struct-type (node)
  "Return a symbol naming the alien struct type for NODE, defining it if needed."
  (let* ((node (resolve-struct-layout node))
         (key (canonical-encoding node)))
    (or (gethash key *alien-struct-types*)
        (setf (gethash key *alien-struct-types*)
              (let* ((name (intern (format nil "OBJC-STRUCT-~D" (incf *alien-struct-counter*))
                                   '#:objc))
                     (slots (loop for field in (third node)
                                  for i from 0
                                  collect (list (intern (format nil "S~D" i) '#:objc)
                                                (alien-type field)))))
                (eval `(sb-alien:define-alien-type ,name
                           (sb-alien:struct ,name ,@slots)))
                name)))))

(defun alien-type (node)
  "The sb-alien type specifier for encoding node NODE.

Every pointer-ish thing becomes SYSTEM-AREA-POINTER rather than a typed alien
pointer.  That keeps the trampoline's Lisp-level contract uniform -- callers
hand in and receive SAPs -- and means the marshalling code above never has to
know an alien type at all."
  (etypecase node
    (keyword
     (ecase node
       ;; SB-ALIEN:VOID, not the keyword :VOID.  The keyword macroexpands into
       ;; a COMPILED-PROGRAM-ERROR at the call site rather than failing here,
       ;; so every void-returning method -- -release among them -- breaks.
       (:void 'sb-alien:void)
       (:unknown 'sb-alien:void)
       (:char '(sb-alien:signed 8))
       (:uchar '(sb-alien:unsigned 8))
       (:short '(sb-alien:signed 16))
       (:ushort '(sb-alien:unsigned 16))
       (:int '(sb-alien:signed 32))
       (:uint '(sb-alien:unsigned 32))
       ;; 'l' and 'L' are 32 bits by definition of the encoding; see types.lisp.
       (:long '(sb-alien:signed 32))
       (:ulong '(sb-alien:unsigned 32))
       (:long-long '(sb-alien:signed 64))
       (:ulong-long '(sb-alien:unsigned 64))
       (:float 'sb-alien:single-float)
       (:double 'sb-alien:double-float)
       ;; C99 _Bool is one byte.  This is what BOOL is on Apple silicon.
       (:bool '(sb-alien:boolean 8))
       ((:id :class :sel :cstring :block) 'sb-alien:system-area-pointer)))
    (cons
     (ecase (first node)
       (:pointer 'sb-alien:system-area-pointer)
       (:qualified (alien-type (third node)))
       (:array 'sb-alien:system-area-pointer)
       (:bitfield '(sb-alien:signed 32))
       ((:struct :union) (alien-struct-type node))))))

(defun struct-node-p (node)
  (and (consp node) (member (first node) '(:struct :union))))

;;; Dispatch entry points ----------------------------------------------------

(defvar *msgsend-address* nil)
(defvar *msgsend-super-address* nil)
(defvar *msgsend-stret-address* nil
  "objc_msgSend_stret, or NIL where it does not exist.

Its presence is the signal for whether this architecture returns large
structures through a separate entry point, and it is measured rather than
assumed: the symbol is simply absent from libobjc on arm64.  See
STRET-REQUIRED-P.")
(defvar *msgsend-super-stret-address* nil)

(defun ensure-dispatch-addresses ()
  "Resolve the objc_msgSend family once, as integers.

Integers rather than SAPs so they inline into a compiled trampoline as
immediates instead of being fetched through a closure cell on every call.  The
_stret pair is optional and stays NIL where the architecture has no such
function."
  (unless *msgsend-address*
    (let ((send (cffi:foreign-symbol-pointer "objc_msgSend"))
          (super (cffi:foreign-symbol-pointer "objc_msgSendSuper"))
          (stret (cffi:foreign-symbol-pointer "objc_msgSend_stret"))
          (super-stret (cffi:foreign-symbol-pointer "objc_msgSendSuper_stret")))
      (when (or (null send) (null super))
        (error 'library-not-found
               :name "objc_msgSend"
               :candidates +libobjc-candidates+))
      (setf *msgsend-address* (cffi:pointer-address send)
            *msgsend-super-address* (cffi:pointer-address super)
            *msgsend-stret-address* (and stret (cffi:pointer-address stret))
            *msgsend-super-stret-address* (and super-stret
                                               (cffi:pointer-address super-stret)))))
  (values *msgsend-address* *msgsend-super-address*))

(defparameter +max-register-returned-struct+ 16
  "Largest structure the x86-64 SysV ABI returns in registers.

Anything bigger is classified MEMORY and comes back through a hidden pointer,
which is what objc_msgSend_stret exists to arrange.  CGRect is 32 bytes, so
-[NSView frame] is on the wrong side of this line.")

(defun stret-required-p (node)
  "True when a structure result must go through the separate _stret entry.

Two conditions, both necessary.  The architecture has to have such an entry at
all -- on arm64 it does not, because a large structure comes back through x8
from plain objc_msgSend and objc_msgSend_stret is not even a symbol there.  And
the structure has to be one the ABI returns in memory rather than in registers.

Getting this wrong is not a graceful failure.  objc_msgSend cannot perform an
sret call: the hidden result pointer displaces the receiver into the wrong
register, so the receiver is read as garbage."
  (and *msgsend-stret-address*
       (struct-node-p node)
       (> (node-size-and-alignment (resolve-struct-layout node))
          +max-register-returned-struct+)))

;;; Trampolines --------------------------------------------------------------

(defun build-trampoline (kind result-node arg-nodes &optional n-fixed)
  "Compile a function that sends one exact call signature.

KIND is :SEND or :SUPER, and selects only the entry address -- objc_msgSend and
objc_msgSendSuper take a pointer first either way, so the alien signature is
byte identical and the generated code is the same shape.

The returned function's contract is uniform and struct free:

    (out-sap arg...) => scalar-or-NIL

Every pointer, struct and SEL is a SAP; every number is a Lisp number.  A struct
result is written through OUT-SAP and the function returns NIL, so that callers
never have to branch on whether a result came back in registers or through x8.
All the Cocoa flavoured conversion happens above this, outside the compiler.

N-FIXED, when non-NIL, is the number of arguments before the variadic ones.
Splicing &optional into an alien signature is what makes a genuine Darwin arm64
variadic call: with it, snprintf(\"%d\", 42) prints \"The integer 42\"; without
it, \"The integer 1232\", because arm64 passes variadic arguments on the stack
while a fixed signature passes them in registers."
  (ensure-dispatch-addresses)
  (let* ((structp (struct-node-p result-node))
         (stretp (stret-required-p result-node))
         (entry (ecase kind
                  (:send (if stretp *msgsend-stret-address* *msgsend-address*))
                  (:super (if stretp
                              *msgsend-super-stret-address*
                              *msgsend-super-address*))))
         (result-node (if structp (resolve-struct-layout result-node) result-node))
         (rtype (alien-type result-node))
         (out (gensym "OUT"))
         (syms (loop for i from 0 below (length arg-nodes)
                     collect (gensym (format nil "A~D-" i))))
         (atypes (mapcar #'alien-type arg-nodes))
         ;; A struct argument arrives as a SAP and is loaded by value here; a
         ;; scalar is passed straight through.
         (args (loop for sym in syms
                     for node in arg-nodes
                     collect (if (struct-node-p node)
                                 `(sb-alien:deref
                                   (sb-alien:sap-alien ,sym (sb-alien:* ,(alien-type node))))
                                 sym)))
         (ftype `(sb-alien:function
                  ,rtype
                  ,@(if n-fixed
                        (append (subseq atypes 0 (min n-fixed (length atypes)))
                                (list '&optional)
                                (subseq atypes (min n-fixed (length atypes))))
                        atypes))))
    (compile
     nil
     `(lambda (,out ,@syms)
        (declare (optimize (speed 3) (safety 0))
                 (ignorable ,out)
                 (type sb-sys:system-area-pointer ,out)
                 ,@(loop for sym in syms
                         for node in arg-nodes
                         when (or (struct-node-p node)
                                  (member node '(:id :class :sel :cstring :block))
                                  (and (consp node)
                                       (member (first node) '(:pointer :array))))
                           collect `(type sb-sys:system-area-pointer ,sym)))
        ,(let ((call `(sb-alien:alien-funcall
                       (sb-alien:sap-alien (sb-sys:int-sap ,entry) ,ftype)
                       ,@args)))
           (cond
             (structp
              `(progn
                 (setf (sb-alien:deref (sb-alien:sap-alien ,out (sb-alien:* ,rtype)))
                       ,call)
                 nil))
             ((eq result-node :void) `(progn ,call nil))
             (t call)))))))


;;; Implementations -- the other direction ----------------------------------
;;;
;;; A Lisp-implemented Objective-C method needs a real function pointer with the
;;; method's exact C signature, because the runtime will call it with arguments
;;; in registers per the ABI.  SB-ALIEN:DEFINE-ALIEN-CALLABLE builds one, and it
;;; handles struct arguments and struct returns in this direction too -- which
;;; CFFI:DEFCALLBACK does not: a struct return there signals CASE-FAILURE.  That
;;; is what makes the manual's "pair" example, and -drawRect:, work.
;;;
;;; Plain function pointers rather than imp_implementationWithBlock: a Block
;;; would mean constructing a Clang Block literal and would buy nothing here.
;;; LispWorks does not use blocks for this either.

(defvar *imp-registry* (make-hash-table :test 'equal)
  "(objc-class-name selector class-method-p) -> the alien callable's name.

Every IMP lives here forever.  SBCL recycles a callback's trampoline once the
callable becomes garbage, and a recycled IMP is a jump into freed memory the
next time Cocoa sends that message -- a crash arbitrarily far from the cause.
Redefining a method replaces the entry and keeps the old callable alive, which
leaks a few hundred bytes per redefinition and is the right trade against
crashing during interactive development.")

(defvar *imp-counter* 0)

(defun report-imp-error (condition selector)
  (format *error-output*
          "~&Error in Objective-C method ~A: ~A~%~
             Returning a zero value; the Objective-C caller has no handler.~%"
          selector condition)
  (finish-output *error-output*))

(defun zero-value-form (node)
  "A form for the value to return when a Lisp method body signals."
  (cond ((struct-node-p node) nil)
        ((member node '(:float)) 0.0)
        ((member node '(:double)) 0d0)
        ((member node '(:void :unknown)) nil)
        ((eq node :bool) nil)
        ((or (member node '(:id :class :sel :cstring :block))
             (and (consp node) (member (first node) '(:pointer :array))))
         '(sb-sys:int-sap 0))
        (t 0)))

(defun build-imp (result-node arg-nodes body)
  "Build a real IMP that calls BODY, and return (VALUES SAP CALLABLE-NAME).

BODY is a function of (self-sap cmd-sap result-sap . args).  ARG-NODES includes
self and _cmd, as every Objective-C method signature does.

Two things happen at the boundary and both are necessary.  The float traps Cocoa
violates are masked, because AppKit generates invalid operations freely and an
unmasked one here takes the process out.  And no Lisp condition is allowed to
escape: there is no handler on the Objective-C side, so an unwind past this
frame aborts.  LispWorks does the same thing, calling it a catch-all frame --
its message is \"Capturing attempt to throw out of Cocoa handler\"."
  (let* ((name (intern (format nil "OBJC-IMP-~D" (incf *imp-counter*)) '#:objc))
         (structp (struct-node-p result-node))
         (result-node (if structp (resolve-struct-layout result-node) result-node))
         (syms (loop for i from 0 below (length arg-nodes)
                     collect (intern (format nil "A~D" i) '#:objc)))
         (params (loop for sym in syms
                       for node in arg-nodes
                       collect (list sym (alien-type node))))
         ;; A struct parameter arrives by value, and a callable's parameter is
         ;; not addressable -- (addr p) is rejected with "P is not a valid
         ;; L-value".  Copying it into a WITH-ALIEN local gives us something we
         ;; can take the address of, which keeps the contract above uniform:
         ;; everything non-scalar reaches the body as a SAP.
         (struct-temps (loop for sym in syms
                             for node in arg-nodes
                             when (struct-node-p node)
                               collect (list (gensym (format nil "~A-COPY-" sym))
                                             sym (alien-type node))))
         (body-args (loop for sym in syms
                          for node in arg-nodes
                          collect (if (struct-node-p node)
                                      (let ((temp (first (find sym struct-temps
                                                               :key #'second))))
                                        `(sb-alien:alien-sap (sb-alien:addr ,temp)))
                                      sym)))
         (result-sym (gensym "RESULT")))
    (eval
     `(sb-alien:define-alien-callable ,name ,(alien-type result-node) ,params
        (with-fp-traps-masked
          (sb-alien:with-alien ,(loop for (temp nil type) in struct-temps
                                      collect (list temp type))
            ,@(loop for (temp sym) in struct-temps
                    collect `(setf ,temp ,sym))
          ,(if structp
               ;; A struct result is built in a local and returned by value; the
               ;; body fills it through a pointer, which is what
               ;; DEFINE-OBJC-METHOD's result-style variable binds to.
               `(sb-alien:with-alien ((,result-sym ,(alien-type result-node)))
                  (handler-case
                      (funcall ,body ,(first syms) ,(second syms)
                               (sb-alien:alien-sap (sb-alien:addr ,result-sym))
                               ,@(cddr body-args))
                    (serious-condition (c) (report-imp-error c ',name)))
                  ,result-sym)
               `(handler-case
                    (funcall ,body ,(first syms) ,(second syms) (sb-sys:int-sap 0)
                             ,@(cddr body-args))
                  (serious-condition (c)
                    (report-imp-error c ',name)
                    ,(zero-value-form result-node))))))))
    ;; ALIEN-CALLABLE-FUNCTION returns an ALIEN-VALUE; class_addMethod needs the
    ;; address, and passing the alien value is a type error.
    (values (sb-alien:alien-sap (sb-alien:alien-callable-function name)) name)))

;;; Small helpers the layers above need, kept here so they need not know sb-sys.

(declaim (inline sap-of pointer-of))

(defun sap-of (pointer)
  "The system area pointer for a CFFI pointer."
  (sb-sys:int-sap (cffi:pointer-address pointer)))

(defun pointer-of (sap)
  "The CFFI pointer for a system area pointer."
  (cffi:make-pointer (sb-sys:sap-int sap)))

(defun sb-sap-zero ()
  "A null system area pointer, for the OUT argument of a non-struct send."
  (sb-sys:int-sap 0))

(defun clear-abi-caches ()
  (clrhash *alien-struct-types*)
  (setf *msgsend-address* nil
        *msgsend-super-address* nil
        *msgsend-stret-address* nil
        *msgsend-super-stret-address* nil))

(add-image-restore-thunk 'clear-abi-caches)
