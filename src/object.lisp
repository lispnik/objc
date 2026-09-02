;;;; src/object.lisp -- STANDARD-OBJC-OBJECT and the identity map.
;;;;
;;;; The map from an Objective-C pointer back to its Lisp object is a side
;;;; table keyed on the pointer's address, which is what LispWorks does too --
;;;; its *POINTER-OBJC-OBJECTS*.  Notably it is NOT objc_setAssociatedObject:
;;;; that function appears nowhere in the LispWorks image, and it would cost an
;;;; allocation and a message send on every lookup.
;;;;
;;;; Address reuse is not a hazard because -dealloc removes the entry, and
;;;; -dealloc is one of the three methods installed on every Lisp-defined root
;;;; class.  That also gives the lifetime the manual documents exactly: the Lisp
;;;; object "is recorded in the runtime system and cannot be removed by the
;;;; garbage collector.  When its reference count becomes zero, the object is
;;;; removed."  A weak table would break that promise, and a Lisp finalizer
;;;; would run RELEASE on whatever thread triggered the collection, which for an
;;;; AppKit object is a bug rather than a style question.

(in-package #:objc)

(defvar *pointer-objc-objects* (make-hash-table :test 'eql)
  "Pointer address -> the Lisp object standing for it.
A strong reference, deliberately: see the file header.")

(defvar *objc-object-lock* (bt:make-lock "objc object map"))

(defclass standard-objc-object ()
  ((pointer :initform nil :reader objc-object-pointer-slot))
  (:documentation
   "Abstract superclass for Lisp classes that implement an Objective-C class.

Subclasses are normally made with DEFINE-OBJC-CLASS, which supplies the
Objective-C class name.  An instance has an associated Objective-C object whose
pointer OBJC-OBJECT-POINTER returns and which OBJC-OBJECT-FROM-POINTER maps
back.

There are two ways an instance comes into being.  MAKE-INSTANCE allocates the
Objective-C object by sending +alloc, then sends -init, or calls the
:INIT-FUNCTION initarg with the new pointer and the initargs so that a specific
initializer such as -initWithFrame: can be used instead.  Alternatively the
Objective-C side allocates first, through +allocWithZone:, and the Lisp instance
is made for it with the :POINTER initarg."))

(defmethod objc-object-pointer ((object standard-objc-object))
  (objc-object-pointer-slot object))

(defun register-objc-object (object pointer)
  (bt:with-lock-held (*objc-object-lock*)
    (setf (gethash (cffi:pointer-address pointer) *pointer-objc-objects*) object))
  object)

(defun unregister-objc-object (pointer)
  (bt:with-lock-held (*objc-object-lock*)
    (remhash (cffi:pointer-address pointer) *pointer-objc-objects*)))

(defun objc-object-from-pointer (pointer)
  "Return the Lisp object associated with the Objective-C object at POINTER.

For an instance this is a STANDARD-OBJC-OBJECT; for a class object it is the
Lisp class defined by DEFINE-OBJC-CLASS.  Returns NIL when the object has no
Lisp counterpart, which is the case for everything Cocoa allocated itself.

This is the inverse of OBJC-OBJECT-POINTER."
  (when (and (cffi:pointerp pointer) (not (cffi:null-pointer-p pointer)))
    (or (bt:with-lock-held (*objc-object-lock*)
          (gethash (cffi:pointer-address pointer) *pointer-objc-objects*))
        (when (objc-class-pointer-p pointer)
          (lisp-class-for-objc-name (%class-get-name pointer))))))

;;; Lisp class <-> Objective-C class ----------------------------------------

(defvar *lisp-class-by-objc-name* (make-hash-table :test 'equal)
  "Objective-C class name -> the Lisp class implementing it.")

(defvar *objc-name-by-lisp-class* (make-hash-table :test 'eq)
  "Lisp class -> the name of the Objective-C class it implements.")

(defun lisp-class-for-objc-name (name)
  (gethash name *lisp-class-by-objc-name*))

(defun objc-name-for-lisp-class (class)
  (gethash class *objc-name-by-lisp-class*))

(defun objc-class-of-lisp-class (class)
  "The Objective-C class object implementing CLASS, or NIL for a mixin."
  (let ((name (objc-name-for-lisp-class class)))
    (and name (coerce-to-objc-class name))))

;;; A class defined by DEFINE-OBJC-CLASS answers OBJC-OBJECT-POINTER with its
;;; class object, so that
;;;   (objc-object-pointer (find-class 'my-object))
;;; and
;;;   (coerce-to-objc-class "MyObject")
;;; are the same foreign object, as the manual promises.

(defmethod objc-object-pointer ((class class))
  (or (objc-class-of-lisp-class class)
      (error "~S does not implement an Objective-C class." class)))

;;; Lifecycle hooks ----------------------------------------------------------

(defgeneric objc-object-destroyed (object)
  (:documentation
   "Called when OBJECT's Objective-C object is destroyed, that is when its
reference count reaches zero.  Defining an :AFTER method is the equivalent of
implementing -dealloc.  Do not call this yourself.")
  (:method ((object standard-objc-object))
    ;; The built-in primary method does nothing, per the manual.
    nil))

(defgeneric objc-object-copied (old-object new-object)
  (:documentation
   "Called when OLD-OBJECT is copied through NSCopying, with NEW-OBJECT the
copy.  Defining an :AFTER method is the equivalent of implementing
-copyWithZone:.  Do not call this yourself.")
  (:method ((old-object standard-objc-object) (new-object standard-objc-object))
    ;; The built-in primary method copies the slots, per the manual.
    (let ((class (class-of old-object)))
      (dolist (slot (c2mop:class-slots class) new-object)
        (let ((name (c2mop:slot-definition-name slot)))
          (when (and (slot-boundp old-object name) (not (eq name 'pointer)))
            (setf (slot-value new-object name) (slot-value old-object name))))))))

;;; Instantiation ------------------------------------------------------------

(defmethod initialize-instance :around ((self standard-objc-object)
                                        &rest initargs
                                        &key pointer init-function
                                        &allow-other-keys)
  (cond
    ;; The Objective-C side allocated first, through +allocWithZone:.  The
    ;; foreign object already exists; do not make another.
    (pointer
     (call-next-method)
     (setf (slot-value self 'pointer) pointer)
     (register-objc-object self pointer))

    (t
     (let ((objc-class (objc-class-of-lisp-class (class-of self))))
       (unless objc-class
         (error "Attempting to make an instance of class ~S, which does not ~
implement an Objective-C class."
                (class-name (class-of self))))
       (let ((raw (invoke objc-class "alloc")))
         ;; +alloc runs OUR +allocWithZone:, which has already made and
         ;; registered a Lisp instance of this class.  MAKE-INSTANCE has to
         ;; return the object the caller asked for, with the caller's initargs,
         ;; so adopt that pointer and drop the shadow's registration.  Without
         ;; this one foreign object ends up with two Lisp objects and
         ;; OBJC-OBJECT-FROM-POINTER returns the one with unset slots -- which
         ;; looks like a slot bug and is not.
         (let ((shadow (objc-object-from-pointer raw)))
           (when (and shadow (not (eq shadow self)))
             (unregister-objc-object raw)))
         (call-next-method)
         (let ((final (if init-function
                          ;; The manual passes the pointer and the initargs, so
                          ;; that an :init-function can be (pointer &key frame).
                          ;; That works because the caller also passes
                          ;; :allow-other-keys t, which suppresses the unknown
                          ;; key error for :init-function itself.
                          (apply init-function raw initargs)
                          (invoke raw "init"))))
           ;; -init may return a DIFFERENT object than +alloc did; class
           ;; clusters do it routinely.  Register on the final pointer, or
           ;; every later lookup finds nothing.
           (unless (cffi:pointer-eq final raw)
             (unregister-objc-object raw))
           (setf (slot-value self 'pointer) final)
           (register-objc-object self final)))))))

;;; Instance variables -------------------------------------------------------

(defun ivar-info (class name)
  "Return (VALUES OFFSET NODE) for the ivar NAME of CLASS."
  (let ((ivar (%class-get-instance-variable class name)))
    (when (or (null ivar) (cffi:null-pointer-p ivar))
      (error "No instance variable ~S in class ~S." name (%class-get-name class)))
    (values (%ivar-get-offset ivar)
            (parse-type (%ivar-get-type-encoding ivar)))))

(defun objc-object-var-value (object var-name &key result-pointer)
  "Return the value of the instance variable VAR-NAME of OBJECT.

Only instance variables declared in Lisp with the :OBJC-INSTANCE-VARS option
can be reached; those inherited from a class implemented in Objective-C cannot.

Reading is a typed access at self + offset rather than object_getIvar, which is
only valid for object-typed variables and would silently misread an int one."
  (let* ((pointer (objc-object-pointer object))
         (class (%object-get-class pointer)))
    (multiple-value-bind (offset node) (ivar-info class var-name)
      (let ((address (cffi:inc-pointer pointer offset)))
        (if (struct-node-p node)
            (let ((size (node-size-and-alignment node)))
              (unless result-pointer
                (error "Reading the structure-valued instance variable ~S ~
needs a :RESULT-POINTER to copy into." var-name))
              (dotimes (i size)
                (setf (cffi:mem-aref result-pointer :uint8 i)
                      (cffi:mem-aref address :uint8 i)))
              result-pointer)
            (read-ivar address node))))))

(defun (setf objc-object-var-value) (value object var-name &key result-pointer)
  (declare (ignore result-pointer))
  (let* ((pointer (objc-object-pointer object))
         (class (%object-get-class pointer)))
    (multiple-value-bind (offset node) (ivar-info class var-name)
      (let ((address (cffi:inc-pointer pointer offset)))
        (if (struct-node-p node)
            (let ((size (node-size-and-alignment node)))
              (dotimes (i size)
                (setf (cffi:mem-aref address :uint8 i)
                      (cffi:mem-aref value :uint8 i))))
            (write-ivar address node value))
        value))))

(defun read-ivar (address node)
  (case node
    ((:id :class :sel :cstring :block) (cffi:mem-ref address :pointer))
    (:char (cffi:mem-ref address :int8))
    (:uchar (cffi:mem-ref address :uint8))
    (:short (cffi:mem-ref address :int16))
    (:ushort (cffi:mem-ref address :uint16))
    ((:int :long) (cffi:mem-ref address :int32))
    ((:uint :ulong) (cffi:mem-ref address :uint32))
    (:long-long (cffi:mem-ref address :int64))
    (:ulong-long (cffi:mem-ref address :uint64))
    (:float (cffi:mem-ref address :float))
    (:double (cffi:mem-ref address :double))
    (:bool (/= 0 (cffi:mem-ref address :uint8)))
    (t (if (and (consp node) (eq (first node) :qualified))
           (read-ivar address (third node))
           (cffi:mem-ref address :pointer)))))

(defun write-ivar (address node value)
  (case node
    ((:id :class :sel :cstring :block)
     (setf (cffi:mem-ref address :pointer)
           (cond ((null value) (cffi:null-pointer))
                 ((cffi:pointerp value) value)
                 (t (objc-object-pointer value)))))
    (:char (setf (cffi:mem-ref address :int8) value))
    (:uchar (setf (cffi:mem-ref address :uint8) value))
    (:short (setf (cffi:mem-ref address :int16) value))
    (:ushort (setf (cffi:mem-ref address :uint16) value))
    ((:int :long) (setf (cffi:mem-ref address :int32) value))
    ((:uint :ulong) (setf (cffi:mem-ref address :uint32) value))
    (:long-long (setf (cffi:mem-ref address :int64) value))
    (:ulong-long (setf (cffi:mem-ref address :uint64) value))
    (:float (setf (cffi:mem-ref address :float) (coerce value 'single-float)))
    (:double (setf (cffi:mem-ref address :double) (coerce value 'double-float)))
    (:bool (setf (cffi:mem-ref address :uint8) (if value 1 0)))
    (t (if (and (consp node) (eq (first node) :qualified))
           (write-ivar address (third node) value)
           (setf (cffi:mem-ref address :pointer) value)))))
