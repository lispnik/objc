;;;; test/method-tests.lisp -- DEFINE-OBJC-METHOD and friends.

(in-package #:objc/test)

(def-suite methods :in all-tests
  :description "Defining Objective-C methods in Lisp.")

(in-suite methods)

(objc:define-objc-class test-methods ()
  ()
  (:objc-class-name "ObjcTestMethods"))

;;; Scalars, in and out.

(objc:define-objc-method ("addA:b:" :int)
    ((self test-methods) (a :int) (b :int))
  (+ a b))

(objc:define-objc-method ("scaleDouble:" :double)
    ((self test-methods) (x :double))
  (* 2d0 x))

(objc:define-objc-method ("isEven:" objc:objc-bool)
    ((self test-methods) (n :int))
  (evenp n))

;;; Objects, with and without conversion styles.

(objc:define-objc-method ("shout:" objc:objc-object-pointer)
    ((self test-methods) (text objc:objc-object-pointer string))
  (string-upcase text))

(objc:define-objc-method ("joined:" objc:objc-object-pointer)
    ((self test-methods) (items objc:objc-object-pointer (array string)))
  (format nil "~{~A~^,~}" (coerce items 'list)))

(objc:define-objc-method ("rawPointerArg:" :int)
    ((self test-methods) (object objc:objc-object-pointer :foreign))
  (if (cffi:pointerp object) 1 0))

;;; Cocoa structs, in and out.

(objc:define-objc-method ("areaOfRect:" :double)
    ((self test-methods) (rect cocoa:ns-rect))
  (* (aref rect 2) (aref rect 3)))

(objc:define-objc-method ("unitRect" cocoa:ns-rect)
    ((self test-methods))
  #(1d0 2d0 3d0 4d0))

(objc:define-objc-method ("rangeOfIt" cocoa:ns-range)
    ((self test-methods))
  (cons 7 8))

;;; A declared structure, in and out, as a sequence.
;;;
;;; The Cocoa structures have hand-written converters.  One declared with
;;; DEFINE-OBJC-STRUCT is written from a sequence by the generic rule: one
;;; element per field, coerced to the field's type, at the field's offset.
;;; UIEdgeInsets-shaped, because that is the structure that first wanted it.

(objc:define-objc-struct (test-insets (:foreign-name "ObjcTestInsets"))
  (:top :double)
  (:left :double)
  (:bottom :double)
  (:right :double))

(objc:define-objc-struct (test-mixed (:foreign-name "ObjcTestMixed"))
  (:flag :char)
  (:count :int)
  (:weight :double)
  (:inner (:struct test-insets)))

(objc:define-objc-method ("insetsAsVector" (:struct test-insets))
    ((self test-methods))
  #(1 2 3 4))

(objc:define-objc-method ("insetsAsList" (:struct test-insets))
    ((self test-methods))
  (list 5 6 7 8))

(objc:define-objc-method ("sumOfInsets:" :double)
    ((self test-methods) (insets (:struct test-insets)))
  ;; A declared structure ARRIVES as a pointer to its bytes, as the manual
  ;; has it; only the outbound and result directions take a sequence.
  (loop for i below 4 sum (cffi:mem-aref insets :double i)))

(objc:define-objc-method ("mixedAsSequence" (:struct test-mixed))
    ((self test-methods))
  ;; A char, an int, a double, and a nested structure as a sequence of
  ;; its own: alignment puts the double at 8 and the inner at 16.
  (list 1 2 3.5 #(10 20 30 40)))

(objc:define-objc-method ("weightOfMixed:" :double)
    ((self test-methods) (mixed (:struct test-mixed)))
  (+ (cffi:mem-ref mixed :double 8)
     (cffi:mem-ref mixed :double (+ 16 24))))

;;; The receiver, and the pointer variable.

(objc:define-objc-method ("selfIsLispObject" :int)
    ((self test-methods))
  (if (typep self 'test-methods) 1 0))

(objc:define-objc-method ("pointerVarMatches" :int)
    ((self test-methods pointer))
  (if (cffi:pointer-eq pointer (objc:objc-object-pointer self)) 1 0))

;;; A class method.

(objc:define-objc-class-method ("classAnswer" :int)
    ((class test-methods))
  99)

;;; Errors must not escape into Objective-C.

(objc:define-objc-method ("boom" :int)
    ((self test-methods))
  (error "deliberate"))

;;; ------------------------------------------------------------------------

(defun a-test-object ()
  (objc:alloc-init-object "ObjcTestMethods"))

(test scalar-arguments-and-results
  (with-objc
    (is (= 7 (objc:invoke (a-test-object) "addA:b:" 3 4)))
    (is (= 5d0 (objc:invoke (a-test-object) "scaleDouble:" 2.5d0)))))

(test objc-bool-results
  (with-objc
    (is (eql 1 (objc:invoke (a-test-object) "isEven:" 4)))
    (is (eql 0 (objc:invoke (a-test-object) "isEven:" 5)))
    (is (eq t (objc:invoke-bool (a-test-object) "isEven:" 4)))
    (is (eq nil (objc:invoke-bool (a-test-object) "isEven:" 5)))))

(test string-argument-style-converts-an-ns-string
  (with-objc
    (is (string= "HELLO"
                 (objc:invoke-into 'string (a-test-object) "shout:" "hello")))))

(test a-string-returned-from-a-method-becomes-an-ns-string
  (with-objc
    (let ((result (objc:invoke (a-test-object) "shout:" "hi")))
      (is (cffi:pointerp result))
      (is (string= "HI" (objc:ns-string-to-string result))))))

(test array-argument-style-converts-recursively
  (with-objc
    (is (string= "a,b,c"
                 (objc:invoke-into 'string (a-test-object) "joined:" #("a" "b" "c"))))))

(test foreign-argument-style-gives-the-raw-value
  (with-objc
    (is (eql 1 (objc:invoke (a-test-object) "rawPointerArg:" "anything")))))

(test struct-argument-by-value-into-a-lisp-method
  "A CGRect is four doubles: a homogeneous float aggregate, so it arrives in
v0-v3 rather than through a pointer.  This is the -drawRect: shape."
  (with-objc
    (is (= 1200d0 (objc:invoke (a-test-object) "areaOfRect:" #(0d0 0d0 30d0 40d0))))))

(test struct-result-from-a-lisp-method
  (with-objc
    (is (equalp #(1d0 2d0 3d0 4d0) (objc:invoke (a-test-object) "unitRect")))))

(test ns-range-result-from-a-lisp-method-is-a-cons
  (with-objc
    (is (equal '(7 . 8) (objc:invoke (a-test-object) "rangeOfIt")))))

(test a-declared-struct-result-may-be-a-sequence
  "A method whose result type is a DEFINE-OBJC-STRUCT may return a vector or
a list with one element per field, as a Cocoa one may; before, only a
pointer to foreign memory was accepted and the error named the structure."
  (with-objc
    (cffi:with-foreign-object (p :double 4)
      (objc:invoke-into p (a-test-object) "insetsAsVector")
      (is (equalp #(1d0 2d0 3d0 4d0)
                  (coerce (loop for i below 4 collect (cffi:mem-aref p :double i)) 'vector))))
    (cffi:with-foreign-object (p :double 4)
      (objc:invoke-into p (a-test-object) "insetsAsList")
      (is (equalp #(5d0 6d0 7d0 8d0)
                  (coerce (loop for i below 4 collect (cffi:mem-aref p :double i)) 'vector))))))

(test a-declared-struct-argument-may-be-a-sequence
  "The outbound direction too: a vector or a list where a message wants a
declared structure by value, written field by field at the field offsets."
  (with-objc
    (is (= 10d0 (objc:invoke (a-test-object) "sumOfInsets:" #(1 2 3 4))))
    (is (= 26d0 (objc:invoke (a-test-object) "sumOfInsets:" '(5 6 7 8))))
    ;; A pointer still works, as the manual says.
    (cffi:with-foreign-object (p :double 4)
      (dotimes (i 4) (setf (cffi:mem-aref p :double i) (float (1+ i) 1d0)))
      (is (= 10d0 (objc:invoke (a-test-object) "sumOfInsets:" p))))))

(test a-declared-struct-with-mixed-fields-lays-out-by-alignment
  "Fields of different sizes, and a nested structure given as a sequence
of its own: each lands at the offset the ABI gives it."
  (with-objc
    ;; The node as a signature carries it: parsed from the encoding the
    ;; declaration registered, with the fields in it.
    (is (equal '(0 4 8 16)
               (objc::struct-field-offsets
                (objc::parse-type (objc::struct-encoding-for-symbol 'test-mixed)))))
    (is (= (+ 3.5d0 40d0)
           (objc:invoke (a-test-object) "weightOfMixed:" (list 1 2 3.5 #(10 20 30 40)))))
    (cffi:with-foreign-object (p :uint8 48)
      (objc:invoke-into p (a-test-object) "mixedAsSequence")
      (is (= 1 (cffi:mem-ref p :int8 0)))
      (is (= 2 (cffi:mem-ref p :int32 4)))
      (is (= 3.5d0 (cffi:mem-ref p :double 8)))
      (is (= 40d0 (cffi:mem-ref p :double (+ 16 24)))))))

(test a-sequence-of-the-wrong-length-is-refused-by-name
  (with-objc
    (signals error (objc:invoke (a-test-object) "sumOfInsets:" #(1 2 3)))
    (handler-case (progn (objc:invoke (a-test-object) "sumOfInsets:" #(1 2 3)) (fail "no error"))
      (error (condition)
        (is (search "4 fields" (princ-to-string condition)))))))

(test the-receiver-is-the-lisp-object
  (with-objc
    (is (eql 1 (objc:invoke (make-instance 'test-methods) "selfIsLispObject")))))

(test the-pointer-variable-is-the-receiver-pointer
  (with-objc
    (is (eql 1 (objc:invoke (make-instance 'test-methods) "pointerVarMatches")))))

(test class-methods
  (with-objc
    (is (= 99 (objc:invoke "ObjcTestMethods" "classAnswer")))))

(test current-super-calls-the-superclass
  (with-objc
    ;; test-point-child adds one to what test-point returns.
    (is (= 21 (objc:invoke (objc:alloc-init-object "ObjcTestPointChild") "doubled:" 10)))
    (is (= 20 (objc:invoke (objc:alloc-init-object "ObjcTestPoint") "doubled:" 10)))))

(test current-super-is-unbound-outside-a-method-body
  "It is a MACROLET, so this is a compile-time fact rather than a convention."
  (is (null (ignore-errors (eval '(objc:current-super))))))

(test a-lisp-error-does-not-escape-into-objective-c
  "There is no handler on the Objective-C side; an unwind past the callback
frame aborts the process.  The body's condition is reported and a zero value
returned instead -- the same thing LispWorks does with its catch-all frame."
  (with-objc
    (let ((output (make-string-output-stream)))
      (let ((*error-output* output))
        (is (eql 0 (objc:invoke (a-test-object) "boom"))))
      (is (search "deliberate" (get-output-stream-string output))))))

(test selector-arity-is-checked-at-macroexpansion
  "The colon count is the arity, and a mismatch is a bug worth catching before
it becomes a garbage argument register."
  (signals error
    (macroexpand-1 '(objc:define-objc-method ("takesTwo:andTwo:" :int)
                     ((self test-methods) (a :int))
                     a))))

(test redefining-a-method-replaces-it
  (with-objc
    (eval '(objc:define-objc-method ("addA:b:" :int)
            ((self test-methods) (a :int) (b :int))
            (* a b)))
    (is (= 12 (objc:invoke (a-test-object) "addA:b:" 3 4)))
    ;; Put it back so test order cannot matter.
    (eval '(objc:define-objc-method ("addA:b:" :int)
            ((self test-methods) (a :int) (b :int))
            (+ a b)))
    (is (= 7 (objc:invoke (a-test-object) "addA:b:" 3 4)))))

(test every-imp-is-retained
  "SBCL recycles a callback's trampoline once it becomes garbage, and Cocoa
would still be holding the address.  The registry is what stops that."
  (is (plusp (hash-table-count objc::*imp-registry*))))

;;; Class methods ------------------------------------------------------------
;;;
;;; DEFINE-OBJC-CLASS-METHOD had one test for a long time.  These cover the
;;; parts that differ from an instance method: what the receiver is bound to,
;;; and what CURRENT-SUPER reaches.

(objc:define-objc-class class-method-base ()
  ()
  (:objc-class-name "ObjcClassMethodBase"))

(objc:define-objc-class-method ("baseAnswer" :int) ((class class-method-base)) 10)
(objc:define-objc-method ("instanceAnswer" :int) ((self class-method-base)) 20)

(objc:define-objc-class class-method-derived (class-method-base)
  ()
  (:objc-class-name "ObjcClassMethodDerived"))

(objc:define-objc-class-method ("baseAnswer" :int) ((class class-method-derived))
  (+ 1 (objc:invoke (objc:current-super) "baseAnswer")))

(test a-class-method-is-reachable-through-a-string-receiver
  (with-objc
    (is (= 10 (objc:invoke "ObjcClassMethodBase" "baseAnswer")))))

(test a-class-method-is-inherited
  (with-objc
    (is (= 10 (objc:invoke "ObjcClassMethodBase" "baseAnswer")))))

(test current-super-in-a-class-method-reaches-the-superclass-class-method
  "For a class method the search starts in the superclass's METAclass, not its
class -- getting that wrong finds the method being defined and recurses."
  (with-objc
    (is (= 11 (objc:invoke "ObjcClassMethodDerived" "baseAnswer")))))

(test a-class-receiver-does-not-find-instance-methods
  "The lookup for a string receiver goes to the metaclass, so an instance
method is correctly invisible there."
  (with-objc
    (signals error (objc:invoke "ObjcClassMethodBase" "instanceAnswer"))
    (is (= 20 (objc:invoke (objc:alloc-init-object "ObjcClassMethodBase")
                           "instanceAnswer")))))
