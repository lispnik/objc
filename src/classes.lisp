;;;; src/classes.lisp -- classes, and reading method signatures out of the
;;;; runtime.

(in-package #:objc)

;;; Receivers ----------------------------------------------------------------

(defgeneric objc-object-pointer (object-or-class)
  (:documentation
   "Return the Objective-C pointer for OBJECT-OR-CLASS.

For an instance of STANDARD-OBJC-OBJECT this is its object pointer; for a class
defined by DEFINE-OBJC-CLASS it is the class object.  In both directions this
is the inverse of OBJC-OBJECT-FROM-POINTER."))

(defmethod objc-object-pointer ((object t))
  (if (cffi:pointerp object)
      object
      (error "Expected an objc-object-pointer, got ~S." object)))

(defun receiver-pointer (receiver)
  "The pointer to send to, for any of the receiver designators."
  (cond ((stringp receiver) (coerce-to-objc-class receiver))
        ((cffi:pointerp receiver) receiver)
        (t (objc-object-pointer receiver))))

(defvar *class-cache* (make-hash-table :test 'equal)
  "Class name -> Class pointer.")

(defun objc-class-pointer-p (pointer)
  "True when POINTER is a class object rather than an instance.
A class's own class is its metaclass, which is what distinguishes the two."
  (and (objc-pointer-p pointer)
       (let ((meta (%object-get-class pointer)))
         (and (objc-pointer-p meta) (%class-is-meta-class meta)))))

(defun coerce-to-objc-class (class)
  "Return the Objective-C class pointer for CLASS.

CLASS may be a class name, a class pointer, or a Lisp class defined by
DEFINE-OBJC-CLASS.  The opposite operation is OBJC-CLASS-NAME."
  (etypecase class
    (string (or (gethash class *class-cache*)
                (progn
                  (ensure-libobjc)
                  (let ((pointer (%objc-get-class class)))
                    (when (cffi:null-pointer-p pointer)
                      (error 'no-such-class :name class))
                    (setf (gethash class *class-cache*) pointer)))))
    (symbol (coerce-to-objc-class (string class)))
    (class (objc-object-pointer class))
    (t (unless (cffi:pointerp class)
         (error 'no-such-class :name class))
       class)))

(defun objc-class-name (class)
  "Return the name of the Objective-C class CLASS as a string.
The opposite operation is COERCE-TO-OBJC-CLASS."
  (%class-get-name (if (cffi:pointerp class) class (coerce-to-objc-class class))))

;;; Method lookup ------------------------------------------------------------
;;;
;;; Everything routes through here, and that is the single most important
;;; structural decision in the library.  Resolving the Method in order to read
;;; its type encoding is what makes dispatch possible at all -- the encoding IS
;;; the call signature -- but it also means a selector the class does not
;;; implement fails HERE, in Lisp, before any message is sent.
;;;
;;; That is what keeps the bridge survivable.  If the send happened anyway the
;;; runtime would raise an Objective-C exception, and an NSException unwinding
;;; through Lisp frames aborts the process: verified in LispWorks 8.1, where
;;; -[NSArray objectAtIndex:] out of range surfaced as SIGABRT from
;;; __pthread_kill.  LispWorks resolves first for exactly the same reason, and
;;; its error message -- "No method ~S for object ~S, class ~S." -- is the one
;;; reproduced by the NO-SUCH-METHOD condition.

(defun lookup-class-for-receiver (receiver)
  "The class in which to look a method up, given a receiver.
For an instance that is its class; for a class object it is the metaclass,
because a message to a class runs its class methods."
  (cond ((stringp receiver) (%object-get-class (coerce-to-objc-class receiver)))
        (t (%object-get-class (receiver-pointer receiver)))))

(defun find-method-for (class selector-name)
  "Return the Method for SELECTOR-NAME in CLASS, or NIL.
Instance methods are searched first, then class methods, which is what
LispWorks does: given the class name \"NSObject\" and \"description\", it
reports the instance method's signature \"@16@0:8\"."
  (let* ((selector (coerce-to-selector selector-name))
         (method (%class-get-instance-method class selector)))
    (if (objc-pointer-p method)
        method
        (let ((method (%class-get-class-method class selector)))
          (and (objc-pointer-p method) method)))))

(defun method-encoding (method)
  (%method-get-type-encoding method))

(defun objc-class-method-signature (class-spec method-name)
  "Return three values for the method METHOD-NAME of CLASS-SPEC: its argument
types, its result type, and its type encoding string.  Returns NIL if the
method cannot be found.

ARG-TYPES always begins with OBJC-OBJECT-POINTER and SEL, because every
Objective-C method receives self and _cmd before its declared arguments.

Verified against LispWorks 8.1:

  (objc-class-method-signature \"NSString\" \"length\")
  => ((objc:objc-object-pointer objc:sel) (:unsigned :long-long) \"Q16@0:8\")"
  (let* ((class (etypecase class-spec
                  ;; The class itself, NOT its metaclass.  FIND-METHOD-FOR
                  ;; searches instance methods first and class methods second,
                  ;; and that ordering is what LispWorks does: given "NSObject"
                  ;; and "description" it reports the instance method's
                  ;; signature "@16@0:8", not +description's.  Looking in the
                  ;; metaclass instead would make every instance method of a
                  ;; named class invisible here.
                  (string (coerce-to-objc-class class-spec))
                  (t (if (objc-class-pointer-p class-spec)
                         class-spec
                         (%object-get-class class-spec)))))
         (method (and (objc-pointer-p class) (find-method-for class method-name))))
    (when method
      (let ((encoding (method-encoding method)))
        (multiple-value-bind (result args) (parse-method-encoding encoding)
          (values (mapcar #'fli-type-for-node args)
                  (fli-type-for-node result)
                  encoding))))))

(defun clear-class-cache () (clrhash *class-cache*))
(add-image-restore-thunk 'clear-class-cache)
