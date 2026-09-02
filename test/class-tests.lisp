;;;; test/class-tests.lisp -- DEFINE-OBJC-CLASS, identity, lifecycle.

(in-package #:objc/test)

(def-suite classes :in all-tests
  :description "Defining Objective-C classes from Lisp.")

(in-suite classes)

(defun ensure-initialized ()
  "Alias for RUNTIME-AVAILABLE-P, kept because WITH-GUI and WITH-OBJC read
better with it."
  (runtime-available-p))

(defmacro with-objc (&body body)
  `(if (not (ensure-initialized))
       (skip "Objective-C runtime not available")
       (progn ,@body)))

;;; Test classes.  Defined once, at load time, because an Objective-C class
;;; cannot be un-registered and ivars cannot be added after registration.

(objc:define-objc-class test-point ()
  ((tag :initarg :tag :initform nil :accessor test-point-tag))
  (:objc-class-name "ObjcTestPoint")
  (:objc-instance-vars ("counter" :int)
                       ("label" objc:objc-object-pointer)))

(objc:define-objc-method ("doubled:" :int)
    ((self test-point) (n :int))
  (* 2 n))

(objc:define-objc-class test-point-child (test-point)
  ()
  (:objc-class-name "ObjcTestPointChild"))

(objc:define-objc-method ("doubled:" :int)
    ((self test-point-child) (n :int))
  (+ 1 (objc:invoke (objc:current-super) "doubled:" n)))

;;; Class creation -----------------------------------------------------------

(test the-class-exists-in-the-runtime
  (with-objc
    (let ((class (objc:coerce-to-objc-class "ObjcTestPoint")))
      (is (cffi:pointerp class))
      (is (string= "ObjcTestPoint" (objc:objc-class-name class))))))

(test superclass-defaults-to-ns-object
  (with-objc
    (is (string= "NSObject"
                 (objc:objc-class-name
                  (objc::%class-get-superclass
                   (objc:coerce-to-objc-class "ObjcTestPoint")))))))

(test a-lisp-subclass-inherits-the-objc-superclass
  (with-objc
    (is (string= "ObjcTestPoint"
                 (objc:objc-class-name
                  (objc::%class-get-superclass
                   (objc:coerce-to-objc-class "ObjcTestPointChild")))))))

;;; The identity invariants the manual states --------------------------------

(test class-pointer-identity
  "The manual: (objc-object-pointer (find-class 'my-object)) and
(coerce-to-objc-class \"MyObject\") are the same foreign object."
  (with-objc
    (is (cffi:pointer-eq (objc:objc-object-pointer (find-class 'test-point))
                         (objc:coerce-to-objc-class "ObjcTestPoint")))))

(test object-from-pointer-inverts-object-pointer
  (with-objc
    (let ((object (make-instance 'test-point)))
      (is (eq object (objc:objc-object-from-pointer
                      (objc:objc-object-pointer object)))))))

(test object-from-pointer-on-a-class-gives-the-lisp-class
  (with-objc
    (is (eq (find-class 'test-point)
            (objc:objc-object-from-pointer
             (objc:coerce-to-objc-class "ObjcTestPoint"))))))

(test object-from-pointer-of-a-foreign-object-is-nil
  (with-objc
    (is (null (objc:objc-object-from-pointer
               (objc:invoke "NSString" "stringWithUTF8String:" "not ours"))))))

(test object-from-pointer-of-null-is-nil
  (is (null (objc:objc-object-from-pointer (cffi:null-pointer)))))

;;; make-instance ------------------------------------------------------------

(test make-instance-allocates-and-initializes
  "+alloc runs our own +allocWithZone:, which makes and registers a Lisp
instance of its own.  MAKE-INSTANCE has to return the object the caller asked
for and adopt that pointer; if it does not, one foreign object ends up with two
Lisp objects and the lookup finds the one with unset slots."
  (with-objc
    (let ((object (make-instance 'test-point :tag :hello)))
      (is (typep object 'objc:standard-objc-object))
      (is (eq :hello (test-point-tag object)))
      (is (cffi:pointerp (objc:objc-object-pointer object)))
      (is (eq object (objc:objc-object-from-pointer (objc:objc-object-pointer object)))
          "exactly one Lisp object per foreign object"))))

(test make-instance-of-a-subclass
  (with-objc
    (let ((object (make-instance 'test-point-child)))
      (is (string= "ObjcTestPointChild"
                   (objc:objc-class-name
                    (objc:invoke (objc:objc-object-pointer object) "class")))))))

(test init-function-is-called-with-the-pointer-and-initargs
  "The manual's my-view-init-function shape: (pointer &key frame), which works
because MAKE-INSTANCE is also passed :allow-other-keys t."
  (with-objc
    (let* ((seen nil)
           (object (make-instance 'test-point
                                  :init-function
                                  (lambda (pointer &key tag &allow-other-keys)
                                    (setf seen tag)
                                    (objc:invoke pointer "init"))
                                  :tag :from-init
                                  :allow-other-keys t)))
      (is (eq :from-init seen))
      (is (eq object (objc:objc-object-from-pointer
                      (objc:objc-object-pointer object)))))))

;;; Instance variables -------------------------------------------------------

(test instance-variables-round-trip
  (with-objc
    (let ((object (make-instance 'test-point)))
      (is (= 0 (objc:objc-object-var-value object "counter"))
          "a fresh ivar is zeroed by the runtime")
      (setf (objc:objc-object-var-value object "counter") 17)
      (is (= 17 (objc:objc-object-var-value object "counter"))))))

(test object-typed-instance-variables-round-trip
  (with-objc
    (let ((object (make-instance 'test-point))
          (string (objc:invoke "NSString" "stringWithUTF8String:" "stored")))
      (setf (objc:objc-object-var-value object "label") string)
      (is (cffi:pointer-eq string (objc:objc-object-var-value object "label"))))))

(test unknown-instance-variable-signals
  (with-objc
    (signals error (objc:objc-object-var-value (make-instance 'test-point) "nope"))))

;;; Mixins -------------------------------------------------------------------

(test a-mixin-creates-no-objc-class
  (with-objc
    (is-true (objc::mixin-class-p (find-class 'objc/examples::my-size-mixin)))
    (is (null (objc::objc-class-of-lisp-class
               (find-class 'objc/examples::my-size-mixin))))))

(test a-mixin-method-reaches-every-concrete-subclass
  "The manual's example defines the mixin, then its method, then two unrelated
subclasses -- so propagation has to work in that order as well as the other."
  (with-objc
    (is (= 42 (objc:invoke (objc:alloc-init-object "MyData") "size")))
    (is (= 42 (objc:invoke (objc:alloc-init-object "MyOtherData") "size")))))

;;; Lifecycle ----------------------------------------------------------------

(test dealloc-runs-objc-object-destroyed-and-unregisters
  "The other half of the identity map's lifetime rule."
  (with-objc
    (let* ((object (make-instance 'test-point))
           (pointer (objc:objc-object-pointer object))
           (address (cffi:pointer-address pointer)))
      (is (eq object (objc:objc-object-from-pointer pointer)))
      (objc:release object)
      (is (null (gethash address objc::*pointer-objc-objects*))
          "the map entry goes when the reference count reaches zero, which is
what makes keying on the address safe against reuse"))))

(test the-three-root-methods-are-installed
  "LispWorks installs exactly these three on its root class, and so do we."
  (with-objc
    (let ((class (objc:coerce-to-objc-class "ObjcTestPoint")))
      (is-true (objc:can-invoke-p (make-instance 'test-point) "copyWithZone:"))
      (is-true (objc:can-invoke-p (make-instance 'test-point) "dealloc"))
      (is-true (objc:can-invoke-p "ObjcTestPoint" "allocWithZone:"))
      (is (cffi:pointerp class)))))

(test copy-with-zone-copies-slots
  "The built-in primary method of OBJC-OBJECT-COPIED sets the copy's slots from
the original's, per the manual."
  (with-objc
    (let* ((object (make-instance 'test-point :tag :original))
           (copy-pointer (objc:invoke (objc:objc-object-pointer object) "copy"))
           (copy (objc:objc-object-from-pointer copy-pointer)))
      (is (not (null copy)))
      (is (not (eq object copy)))
      (is (eq :original (test-point-tag copy))))))

;;; The lifecycle generic functions ------------------------------------------
;;;
;;; The manual documents both as the way to do what -dealloc and -copyWithZone:
;;; do in Objective-C, with the built-in primary method doing the boring part
;;; and an :AFTER method doing the class-specific part.

(objc:define-objc-class lifecycle-copy ()
  ((n :initarg :n :initform 0 :accessor lifecycle-copy-n)
   (marked :initform nil :accessor lifecycle-copy-marked))
  (:objc-class-name "ObjcLifecycleCopy"))

(defmethod objc:objc-object-copied :after ((old lifecycle-copy) (new lifecycle-copy))
  (setf (lifecycle-copy-marked new) :copied))

(defvar *lifecycle-destroyed* '())

(objc:define-objc-class lifecycle-dealloc ()
  ((tag :initarg :tag :initform nil :accessor lifecycle-dealloc-tag))
  (:objc-class-name "ObjcLifecycleDealloc"))

(defmethod objc:objc-object-destroyed :after ((object lifecycle-dealloc))
  (push (lifecycle-dealloc-tag object) *lifecycle-destroyed*))

(test objc-object-copied-runs-the-built-in-and-then-the-after-method
  (with-objc
    (let* ((original (make-instance 'lifecycle-copy :n 7))
           (copy (objc:objc-object-from-pointer
                  (objc:invoke (objc:objc-object-pointer original) "copy"))))
      (is (typep copy 'lifecycle-copy) "the copy has its own Lisp object")
      (is (not (eq original copy)))
      (is (= 7 (lifecycle-copy-n copy)) "the built-in primary method copied the slots")
      (is (eq :copied (lifecycle-copy-marked copy)) "the :AFTER method ran"))))

(test objc-object-destroyed-runs-when-the-reference-count-reaches-zero
  (with-objc
    (let ((*lifecycle-destroyed* '()))
      (objc:release (make-instance 'lifecycle-dealloc :tag :gone))
      (is (equal '(:gone) *lifecycle-destroyed*)))))

;;; Protocols -----------------------------------------------------------------

(objc:define-objc-protocol "ObjcAuditProtocol"
  :instance-methods (("auditPing" :int)))

(objc:define-objc-class conforming ()
  ()
  (:objc-class-name "ObjcConforming")
  (:objc-protocols "NSCopying"))

(test define-objc-protocol-records-a-declaration
  "It declares, it does not create: the runtime has not allowed creating
protocols since macOS 10.5, and the manual says so."
  (is (not (null (gethash "ObjcAuditProtocol" objc::*declared-protocols*)))))

(test objc-protocols-makes-the-class-conform
  (with-objc
    (is-true (objc:invoke-bool
              (objc:objc-object-pointer (make-instance 'conforming))
              "conformsToProtocol:" (objc::%objc-get-protocol "NSCopying")))))

(test naming-an-unknown-protocol-warns-rather-than-failing
  "class_addProtocol with a NULL protocol is a silent no-op, so this is the
only place the mistake can be reported."
  (signals warning
    (eval '(objc:define-objc-class unknown-protocol-class ()
            ()
            (:objc-class-name "ObjcUnknownProtocolClass")
            (:objc-protocols "NoSuchProtocolAnywhere")))))
