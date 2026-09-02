;;;; src/runtime.lisp -- raw bindings to the Objective-C runtime.
;;;;
;;;; Every entry point here has a signature that is known at compile time, which
;;;; is exactly what CFFI is good at, so all of it is DEFCFUN.  Nothing in this
;;;; file is exported and every name is %-prefixed: these are the plumbing, and
;;;; the API above them is the LispWorks one.
;;;;
;;;; The set is deliberately close to the one LispWorks itself dlsyms, which was
;;;; recovered from its heap.  Two absences are worth stating because they look
;;;; like oversights and are not: objc_setAssociatedObject is not here (the
;;;; pointer -> Lisp object map is a side table, as LispWorks' is), and
;;;; imp_implementationWithBlock is not here (IMPs are plain function pointers,
;;;; which needs no Block ABI).
;;;;
;;;; Not bound at all: objc_msgSend_stret, objc_msgSendSuper_stret and
;;;; objc_msgSend_fpret.  All three are marked OBJC_ARM64_UNAVAILABLE in the
;;;; SDK headers and genuinely do not exist on Apple silicon; arm64 returns
;;;; large structs indirectly through x8 from plain objc_msgSend.

(in-package #:objc)

;;; Opaque runtime pointer types.  These are all just pointers at the FFI
;;; level; the distinctions matter to us, not to C.
;;;   Class, id, SEL, Method, Ivar, Protocol *, IMP

;;; Classes ------------------------------------------------------------------

(cffi:defcfun ("objc_getClass" %objc-get-class) :pointer
  (name :string))

(cffi:defcfun ("objc_getMetaClass" %objc-get-meta-class) :pointer
  (name :string))

(cffi:defcfun ("objc_lookUpClass" %objc-look-up-class) :pointer
  (name :string))

(cffi:defcfun ("class_getName" %class-get-name) :string
  (class :pointer))

(cffi:defcfun ("class_getSuperclass" %class-get-superclass) :pointer
  (class :pointer))

(cffi:defcfun ("class_isMetaClass" %class-is-meta-class) :boolean
  (class :pointer))

(cffi:defcfun ("object_getClass" %object-get-class) :pointer
  (object :pointer))

(cffi:defcfun ("objc_getClassList" %objc-get-class-list) :int
  (buffer :pointer)
  (count :int))

;;; Selectors ----------------------------------------------------------------

(cffi:defcfun ("sel_registerName" %sel-register-name) :pointer
  (name :string))

(cffi:defcfun ("sel_getName" %sel-get-name) :string
  (selector :pointer))

(cffi:defcfun ("sel_isEqual" %sel-is-equal) :boolean
  (lhs :pointer)
  (rhs :pointer))

;;; Methods ------------------------------------------------------------------

(cffi:defcfun ("class_getInstanceMethod" %class-get-instance-method) :pointer
  (class :pointer)
  (selector :pointer))

(cffi:defcfun ("class_getClassMethod" %class-get-class-method) :pointer
  (class :pointer)
  (selector :pointer))

(cffi:defcfun ("class_respondsToSelector" %class-responds-to-selector) :boolean
  (class :pointer)
  (selector :pointer))

;;; The type encoding is the whole reason dispatch works: it is what turns a
;;; selector into a call signature.  Note the string it returns carries decimal
;;; frame offsets ("Q16@0:8") which are meaningless on arm64 and are stripped by
;;; the parser in encoding.lisp.
(cffi:defcfun ("method_getTypeEncoding" %method-get-type-encoding) :string
  (method :pointer))

(cffi:defcfun ("method_getName" %method-get-name) :pointer
  (method :pointer))

(cffi:defcfun ("method_getImplementation" %method-get-implementation) :pointer
  (method :pointer))

(cffi:defcfun ("method_setImplementation" %method-set-implementation) :pointer
  (method :pointer)
  (imp :pointer))

(cffi:defcfun ("method_getNumberOfArguments" %method-get-number-of-arguments) :unsigned-int
  (method :pointer))

(cffi:defcfun ("class_copyMethodList" %class-copy-method-list) :pointer
  (class :pointer)
  (out-count :pointer))

;;; Building classes at runtime ----------------------------------------------

(cffi:defcfun ("objc_allocateClassPair" %objc-allocate-class-pair) :pointer
  (superclass :pointer)
  (name :string)
  (extra-bytes :unsigned-long))

(cffi:defcfun ("objc_registerClassPair" %objc-register-class-pair) :void
  (class :pointer))

(cffi:defcfun ("objc_disposeClassPair" %objc-dispose-class-pair) :void
  (class :pointer))

(cffi:defcfun ("class_addMethod" %class-add-method) :boolean
  (class :pointer)
  (selector :pointer)
  (imp :pointer)
  (types :string))

(cffi:defcfun ("class_replaceMethod" %class-replace-method) :pointer
  (class :pointer)
  (selector :pointer)
  (imp :pointer)
  (types :string))

;;; Ivars must all be added between objc_allocateClassPair and
;;; objc_registerClassPair.  The runtime silently refuses afterwards, which is
;;; why changing :objc-instance-vars needs a fresh image.
(cffi:defcfun ("class_addIvar" %class-add-ivar) :boolean
  (class :pointer)
  (name :string)
  (size :unsigned-long)
  (alignment :uint8)
  (types :string))

(cffi:defcfun ("class_getInstanceVariable" %class-get-instance-variable) :pointer
  (class :pointer)
  (name :string))

(cffi:defcfun ("class_copyIvarList" %class-copy-ivar-list) :pointer
  (class :pointer)
  (out-count :pointer))

(cffi:defcfun ("ivar_getName" %ivar-get-name) :string
  (ivar :pointer))

(cffi:defcfun ("ivar_getOffset" %ivar-get-offset) :long
  (ivar :pointer))

(cffi:defcfun ("ivar_getTypeEncoding" %ivar-get-type-encoding) :string
  (ivar :pointer))

;;; Protocols ----------------------------------------------------------------

(cffi:defcfun ("objc_getProtocol" %objc-get-protocol) :pointer
  (name :string))

(cffi:defcfun ("class_addProtocol" %class-add-protocol) :boolean
  (class :pointer)
  (protocol :pointer))

(cffi:defcfun ("class_conformsToProtocol" %class-conforms-to-protocol) :boolean
  (class :pointer)
  (protocol :pointer))

(cffi:defcfun ("protocol_getName" %protocol-get-name) :string
  (protocol :pointer))

;;; Foundation ---------------------------------------------------------------

;;; Foundation ships a parser for the very encoding notation we hand-write, and
;;; it reports the size and alignment the compiler would have used.  That gives
;;; the struct layout table a ground-truth oracle with no C toolchain in the
;;; build -- strictly better than groveling, because it checks the exact string
;;; we will hand to class_addMethod.  LispWorks does not use it; we do, in
;;; tests.
(cffi:defcfun ("NSGetSizeAndAlignment" %ns-get-size-and-alignment) :pointer
  (type-encoding :string)
  (size-out :pointer)
  (alignment-out :pointer))

(cffi:defcfun ("free" %free) :void
  (pointer :pointer))

;;; Convenience wrappers used all over the rest of the library ---------------

(defun size-and-alignment (encoding)
  "Return (VALUES SIZE ALIGNMENT) for the type ENCODING, per Foundation.
Signals UNSUPPORTED-TYPE-ENCODING if Foundation will not parse it."
  (cffi:with-foreign-objects ((size :unsigned-long) (align :unsigned-long))
    (setf (cffi:mem-ref size :unsigned-long) 0
          (cffi:mem-ref align :unsigned-long) 0)
    (let ((end (%ns-get-size-and-alignment encoding size align)))
      (when (cffi:null-pointer-p end)
        (error 'unsupported-type-encoding
               :encoding encoding
               :detail "Foundation could not parse this encoding"))
      (values (cffi:mem-ref size :unsigned-long)
              (cffi:mem-ref align :unsigned-long)))))
