;;;; examples/manual.lisp
;;;;
;;;; The example definitions from the LispWorks Objective-C and Cocoa User Guide
;;;; and Reference Manual, section 1.4, ported to SBCL.
;;;;
;;;; This is a near-verbatim port of the file LispWorks ships at
;;;; Library/lib/8-1-0-0/examples/objc/manual.lisp.  Only the package
;;;; definition differs: (:add-use-defaults t) is a LispWorks extension, so the
;;;; package uses #:cl explicitly instead.  Every OBJC form below is unchanged
;;;; from the original, which is the point -- it is the best single piece of
;;;; evidence that ported code really does run here as written.
;;;;
;;;; The C the manual gives alongside each definition is kept in the same block
;;;; comments the original uses.

(in-package #:objc/examples)

(define-objc-class my-object ()
  ((slot1 :initarg :slot1 :initform nil))
  (:objc-class-name "MyObject"))

#|
@implementation MyObject
- (unsigned int)areaOfWidth:(unsigned int)width
                height:(unsigned int)height
{
  return width*height;
}
@end
|#

(define-objc-method ("areaOfWidth:height:" (:unsigned :int))
    ((self my-object)
     (width (:unsigned :int))
     (height (:unsigned :int)))
  (* width height))

(define-objc-class my-special-object (my-object)
  ()
  (:objc-class-name "MySpecialObject"))

(define-objc-class my-other-object ()
  ()
  (:objc-class-name "MyOtherObject")
  (:objc-superclass-name "MyObject"))

#|
@implementation MySpecialObject
- (unsigned int)areaOfWidth:(unsigned int)width
                height:(unsigned int)height
{
  return 4*[super areaOfWidth:width height:height];
}
@end
|#

(define-objc-method ("areaOfWidth:height:" (:unsigned :int))
    ((self my-special-object)
     (width (:unsigned :int))
     (height (:unsigned :int)))
  (* 4 (invoke (current-super) "areaOfWidth:height:"
                               width height)))

(define-objc-struct (pair
                     (:foreign-name "_Pair"))
  (:first :float)
  (:second :float))

(define-objc-method ("pair" (:struct pair) result-pair)
    ((this my-object))
  (setf (fli:foreign-slot-value result-pair :first) 1f0
        (fli:foreign-slot-value result-pair :second) 2f0))

;;; An abstract class: it names no Objective-C class and inherits none, so no
;;; Objective-C class is created for it.  Its method is installed on each
;;; subclass that does name one -- which is how a mixin gets to contribute an
;;; implementation to classes that are otherwise unrelated.

(define-objc-class my-size-mixin ()
  ())

(define-objc-method ("size" (:unsigned :int))
    ((self my-size-mixin))
  42)

(define-objc-class my-data (my-size-mixin)
  ()
  (:objc-class-name "MyData"))

(define-objc-class my-other-data (my-size-mixin)
  ()
  (:objc-class-name "MyOtherData"))

;;; A headless entry point, so the manual's examples can be exercised without a
;;; window server.  Everything above is pure Objective-C interface; nothing here
;;; touches AppKit.

(defun run-manual-examples (&optional (stream *standard-output*))
  "Run every example from section 1.4 and report what each returned.
Returns true when they all gave the documented answer."
  (objc:ensure-objc-initialized)
  (let ((failures 0))
    (flet ((check (label got want)
             (let ((okp (equalp got want)))
               (unless okp (incf failures))
               (format stream "~&~34a ~:[FAIL: got ~s, wanted ~s~;~s~]~%"
                       label okp got want))))
      (check "MyObject areaOfWidth:6 height:7"
             (invoke (alloc-init-object "MyObject") "areaOfWidth:height:" 6 7)
             42)
      (check "MySpecialObject, via current-super"
             (invoke (alloc-init-object "MySpecialObject") "areaOfWidth:height:" 6 7)
             168)
      (check "MyOtherObject, via :objc-superclass-name"
             (invoke (alloc-init-object "MyOtherObject") "areaOfWidth:height:" 3 4)
             12)
      (check "class pointer identity"
             (cffi:pointer-eq (objc-object-pointer (find-class 'my-object))
                              (coerce-to-objc-class "MyObject"))
             t)
      (check "MyData size, from the mixin"
             (invoke (alloc-init-object "MyData") "size") 42)
      (check "MyOtherData size, same mixin"
             (invoke (alloc-init-object "MyOtherData") "size") 42)
      (fli:with-dynamic-foreign-objects ((p (:struct pair)))
        (invoke-into p (alloc-init-object "MyObject") "pair")
        (check "pair, a struct-returning method"
               (list (cffi:mem-aref p :float 0) (cffi:mem-aref p :float 1))
               (list 1.0 2.0)))
      (let ((object (make-instance 'my-object :slot1 :hello)))
        (check "make-instance, slot value"
               (slot-value object 'slot1) :hello)
        (check "objc-object-from-pointer round trip"
               (eq object (objc-object-from-pointer (objc-object-pointer object)))
               t)))
    (format stream "~&~%~[All examples gave the documented answer.~:;~:*~D failed.~]~%"
            failures)
    (zerop failures)))
