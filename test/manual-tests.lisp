;;;; test/manual-tests.lisp -- the manual's own examples, asserted.
;;;;
;;;; examples/manual.lisp is a near-verbatim port of the file LispWorks ships.
;;;; Every OBJC form in it is unchanged from the original, so these assertions
;;;; are the closest thing to a direct answer to "does LispWorks source run
;;;; here".

(in-package #:objc/test)

(def-suite manual :in all-tests
  :description "The LispWorks manual's section 1.4 examples.")

(in-suite manual)

(test my-object-area
  (with-objc
    (is (= 42 (objc:invoke (objc:alloc-init-object "MyObject")
                           "areaOfWidth:height:" 6 7)))))

(test my-special-object-multiplies-the-superclass-result
  "(* 4 (invoke (current-super) \"areaOfWidth:height:\" width height))"
  (with-objc
    (is (= 168 (objc:invoke (objc:alloc-init-object "MySpecialObject")
                            "areaOfWidth:height:" 6 7)))))

(test my-other-object-uses-objc-superclass-name
  "Defined with (:objc-superclass-name \"MyObject\") rather than by Lisp
inheritance, so it inherits the Objective-C implementation without inheriting
the Lisp class."
  (with-objc
    (is (string= "MyObject"
                 (objc:objc-class-name
                  (objc::%class-get-superclass (objc:coerce-to-objc-class "MyOtherObject")))))
    (is (= 12 (objc:invoke (objc:alloc-init-object "MyOtherObject")
                           "areaOfWidth:height:" 3 4)))))

(test the-class-pointer-identity-from-the-manual
  (with-objc
    (is (cffi:pointer-eq
         (objc:objc-object-pointer (find-class 'objc/examples::my-object))
         (objc:coerce-to-objc-class "MyObject")))))

(test the-pair-struct-method
  "(define-objc-method (\"pair\" (:struct pair) result-pair) ...) -- a method
that returns a structure by value, filling it through the result variable."
  (with-objc
    (fli:with-dynamic-foreign-objects ((p (:struct objc/examples::pair)))
      (objc:invoke-into p (objc:alloc-init-object "MyObject") "pair")
      (is (= 1.0 (cffi:mem-aref p :float 0)))
      (is (= 2.0 (cffi:mem-aref p :float 1))))))

(test the-size-mixin-reaches-both-subclasses
  (with-objc
    (is (= 42 (objc:invoke (objc:alloc-init-object "MyData") "size")))
    (is (= 42 (objc:invoke (objc:alloc-init-object "MyOtherData") "size")))))

(test the-mixin-itself-has-no-objective-c-class
  (with-objc
    (is-true (objc::mixin-class-p (find-class 'objc/examples::my-size-mixin)))))

(test my-data-and-my-other-data-are-unrelated-in-objective-c
  "They share an implementation through the mixin without sharing a superclass."
  (with-objc
    (is (string= "NSObject"
                 (objc:objc-class-name
                  (objc::%class-get-superclass (objc:coerce-to-objc-class "MyData")))))
    (is (string= "NSObject"
                 (objc:objc-class-name
                  (objc::%class-get-superclass (objc:coerce-to-objc-class "MyOtherData")))))))

(test make-instance-on-a-manual-class
  (with-objc
    (let ((object (make-instance 'objc/examples::my-object :slot1 :value)))
      (is (eq :value (slot-value object 'objc/examples::slot1)))
      (is (eq object (objc:objc-object-from-pointer (objc:objc-object-pointer object)))))))
