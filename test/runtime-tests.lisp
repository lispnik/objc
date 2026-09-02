;;;; test/runtime-tests.lisp -- classes, selectors, and signature lookup.

(in-package #:objc/test)

(def-suite runtime :in all-tests
  :description "Classes, selectors, and reading signatures from the runtime.")

(in-suite runtime)

(defun runtime-available-p ()
  (handler-case (progn (objc::ensure-libobjc) (objc::ensure-foundation) t)
    (error () nil)))

(defmacro with-runtime (&body body)
  `(if (not (runtime-available-p))
       (skip "Objective-C runtime not available")
       (progn ,@body)))

;;; Classes ------------------------------------------------------------------

(test coerce-to-objc-class
  (with-runtime
    (let ((class (objc:coerce-to-objc-class "NSString")))
      (is (cffi:pointerp class))
      (is (not (cffi:null-pointer-p class)))
      (is (cffi:pointer-eq class (objc:coerce-to-objc-class class))
          "a class pointer passes through unchanged"))))

(test objc-class-name-round-trips
  (with-runtime
    (dolist (name '("NSString" "NSArray" "NSObject" "NSDictionary" "NSNumber"))
      (is (string= name (objc:objc-class-name (objc:coerce-to-objc-class name)))))))

(test unknown-class-signals
  (with-runtime
    (signals error (objc:coerce-to-objc-class "NoSuchClassAnywhereAtAll"))))

;;; Selectors ----------------------------------------------------------------

(test coerce-to-selector-round-trips
  (with-runtime
    (dolist (name '("length" "setWidth:height:" "close" "objectAtIndex:"))
      (is (string= name (objc:selector-name (objc:coerce-to-selector name)))))))

(test coerce-to-selector-registers-unknown-names
  "The manual says an unregistered name is registered, so a selector no class
implements still yields a usable SEL."
  (with-runtime
    (let ((selector (objc:coerce-to-selector "aSelectorNobodyImplements:")))
      (is (cffi:pointerp selector))
      (is (not (cffi:null-pointer-p selector)))
      (is (string= "aSelectorNobodyImplements:" (objc:selector-name selector))))))

(test selector-name-passes-strings-through
  "Verified against LispWorks 8.1."
  (is (string= "notAColonName" (objc:selector-name "notAColonName"))))

(test selector-pointer-passes-through
  (with-runtime
    (let ((selector (objc:coerce-to-selector "length")))
      (is (cffi:pointer-eq selector (objc:coerce-to-selector selector))))))

;;; can-invoke-p -------------------------------------------------------------

(test can-invoke-p-instance-and-class-methods
  (with-runtime
    (let ((string (objc:invoke "NSString" "stringWithUTF8String:" "hi")))
      (is-true (objc:can-invoke-p string "length"))
      (is-true (objc:can-invoke-p string "substringWithRange:"))
      (is-false (objc:can-invoke-p string "noSuchMethodAtAll"))
      (is-true (objc:can-invoke-p "NSString" "stringWithUTF8String:")
               "a string receiver checks class methods"))))

;;; objc-class-method-signature ---------------------------------------------
;;;
;;; The expected values here were read out of LispWorks 8.1 on this machine;
;;; see test/oracle/answers.lisp.

(test signature-of-length
  (with-runtime
    (multiple-value-bind (args result encoding)
        (objc:objc-class-method-signature "NSString" "length")
      (is (equal '(objc:objc-object-pointer objc:sel) args))
      (is (equal '(:unsigned :long-long) result))
      (is (string= "Q16@0:8" encoding)))))

(test signature-of-struct-returning-method
  (with-runtime
    (multiple-value-bind (args result encoding)
        (objc:objc-class-method-signature "NSString" "rangeOfString:")
      (is (equal '(objc:objc-object-pointer objc:sel objc:objc-object-pointer) args))
      (is (equal '(:struct cocoa:ns-range) result))
      (is (string= "{_NSRange=QQ}24@0:8@16" encoding)))))

(test signature-of-struct-argument-method
  (with-runtime
    (multiple-value-bind (args result encoding)
        (objc:objc-class-method-signature "NSString" "substringWithRange:")
      (is (equal '(objc:objc-object-pointer objc:sel (:struct cocoa:ns-range)) args))
      (is (eq 'objc:objc-object-pointer result))
      (is (string= "@32@0:8{_NSRange=QQ}16" encoding)))))

(test signature-prefers-the-instance-method
  "Given a class NAME and a selector that exists as both a class and an
instance method, LispWorks reports the INSTANCE method: -[NSObject description]
encodes as \"@16@0:8\"."
  (with-runtime
    (multiple-value-bind (args result encoding)
        (objc:objc-class-method-signature "NSObject" "description")
      (is (equal '(objc:objc-object-pointer objc:sel) args))
      (is (eq 'objc:objc-object-pointer result))
      (is (string= "@16@0:8" encoding)))))

(test signature-arg-types-always-start-with-self-and-cmd
  (with-runtime
    (dolist (selector '("length" "description" "hash" "rangeOfString:"))
      (let ((args (objc:objc-class-method-signature "NSString" selector)))
        (is (eq 'objc:objc-object-pointer (first args)))
        (is (eq 'objc:sel (second args)))))))

(test signature-returns-nil-when-not-found
  (with-runtime
    (is (null (objc:objc-class-method-signature "NSString" "noSuchMethodAtAll")))))
