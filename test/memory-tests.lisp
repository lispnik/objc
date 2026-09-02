;;;; test/memory-tests.lisp -- reference counting, pools, and ownership.
;;;;
;;;; The ownership tests are the ones most likely to catch a real regression:
;;;; the manual's rules are asymmetric, and getting them backwards leaks or
;;;; double-frees rather than failing visibly.

(in-package #:objc/test)

(def-suite memory :in all-tests
  :description "retain/release/autorelease, pools, and ownership rules.")

(in-suite memory)

(test retain-count-of-a-fresh-object
  "Oracle: 1."
  (with-runtime
    (let ((object (objc:invoke "NSObject" "new")))
      (is (= 1 (objc:retain-count object)))
      (objc:release object))))

(test retain-increments-and-returns-its-argument
  "The manual says retain \"decrements\"; that is a typo in the LispWorks
documentation and this increments, as -retain does."
  (with-runtime
    (let* ((object (objc:invoke "NSObject" "new"))
           (returned (objc:retain object)))
      (is (cffi:pointer-eq object returned))
      (is (= 2 (objc:retain-count object)))
      (objc:release object)
      (is (= 1 (objc:retain-count object)))
      (objc:release object))))

(test autorelease-returns-its-argument
  (with-runtime
    (objc:with-autorelease-pool ()
      (let* ((object (objc:invoke "NSObject" "new"))
             (returned (objc:autorelease object)))
        (is (cffi:pointer-eq object returned))))))

(test with-autorelease-pool-returns-the-body-value
  (with-runtime
    (is (= 42 (objc:with-autorelease-pool () 41 42)))))

(test with-autorelease-pool-drains-on-a-non-local-exit
  (with-runtime
    (is (eq :thrown
            (catch 'out
              (objc:with-autorelease-pool ()
                (objc:autorelease (objc:invoke "NSObject" "new"))
                (throw 'out :thrown)))))))

(test with-autorelease-pool-rejects-options
  (signals error (macroexpand-1 '(objc:with-autorelease-pool (:bogus) nil))))

(test make-autorelease-pool-returns-a-pool
  (with-runtime
    (let ((pool (objc:make-autorelease-pool)))
      (is (cffi:pointerp pool))
      (is (string= "NSAutoreleasePool"
                   (objc:objc-class-name (objc:invoke pool "class"))))
      (objc:invoke pool "drain"))))

;;; Ownership ----------------------------------------------------------------

(defparameter +heap-string+
  "a string long enough that Foundation will not tag it"
  "Short ASCII strings come back as NSTaggedPointerString, which stores the
characters in the pointer itself.  Those objects are immortal: their retainCount
is NSUIntegerMax and release does nothing.  Any test that means to observe real
reference counting has to use a string too long to tag.")

(test tagged-pointer-strings-are-immortal
  "Not a defect, and worth pinning down because it otherwise looks like one:
a short string's retain count is NSUIntegerMax and never changes."
  (with-runtime
    (let ((tagged (objc:string-to-ns-string "hi")))
      (is (string= "NSTaggedPointerString"
                   (objc:objc-class-name (objc:invoke tagged "class"))))
      (is (= (1- (expt 2 64)) (objc:retain-count tagged))))))

(test string-to-ns-string-is-caller-owned-by-default
  "The manual: with AUTORELEASEP nil \"you are responsible for ensuring that
ns-string is released when no longer needed\"."
  (with-runtime
    (let ((string (objc:string-to-ns-string +heap-string+)))
      (is (= 1 (objc:retain-count string)))
      (is (string= +heap-string+ (objc:ns-string-to-string string)))
      (objc:release string))))

(test string-to-ns-string-autoreleased
  (with-runtime
    (objc:with-autorelease-pool ()
      (let ((string (objc:string-to-ns-string "hello" t)))
        (is (string= "hello" (objc:ns-string-to-string string)))))))

(test string-arguments-do-not-leak
  "A string argument becomes a temporary NSString that INVOKE releases on
return.  If it leaked, the count of live NSStrings would grow without bound;
what we can check cheaply is that the call works repeatedly and the receiver is
undisturbed."
  (with-runtime
    (let ((string (ns "hello world")))
      (dotimes (i 100)
        (is (eql 1 (objc:invoke string "hasPrefix:" "hello"))))
      (is (= 11 (objc:invoke string "length"))))))

;;; String conversion --------------------------------------------------------

(test ns-string-round-trip
  (with-runtime
    (dolist (string '("" "hello" "hello world" "unicode: éèê"))
      (let ((ns (objc:string-to-ns-string string)))
        (is (string= string (objc:ns-string-to-string ns)))
        (objc:release ns)))))

(test ns-string-to-string-of-null-is-nil
  (is (null (objc:ns-string-to-string (cffi:null-pointer))))
  (is (null (objc:ns-string-to-string nil))))

(test ns-string-line-terminators
  "By default CR and CRLF both normalise to a single newline; with
PRESERVE-LINE-TERMINATORS a CR stays a #\\Return."
  (with-runtime
    (flet ((round-trip (string &optional preserve)
             (let ((ns (objc:string-to-ns-string string)))
               (prog1 (objc:ns-string-to-string ns preserve)
                 (objc:release ns)))))
      (is (string= (format nil "a~%b") (round-trip (format nil "a~Cb" #\Return))))
      (is (string= (format nil "a~%b") (round-trip (format nil "a~C~%b" #\Return))))
      (is (string= (format nil "a~Cb" #\Return)
                   (round-trip (format nil "a~Cb" #\Return) t))))))

;;; Arrays -------------------------------------------------------------------

(test ns-array-round-trip
  (with-runtime
    (let ((array (objc:invoke "NSArray" "arrayWithObject:" "one")))
      (is (equalp #("one") (objc::ns-array-to-vector array 'string))))))

(test empty-ns-array
  (with-runtime
    (is (equalp #() (objc::ns-array-to-vector (objc:invoke "NSArray" "array") 'string)))))

(test ns-array-to-vector-of-null-is-nil
  (is (null (objc::ns-array-to-vector (cffi:null-pointer)))))
