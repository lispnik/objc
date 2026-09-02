;;;; test/oracle-tests.lisp -- differential tests against LispWorks 8.1.
;;;;
;;;; The answers in oracle/answers.lisp were read out of a running LispWorks
;;;; Personal 8.1 by hand -- see oracle/probe.lisp for why by hand -- and
;;;; committed, so these run in CI on a machine with no LispWorks installed.
;;;;
;;;; These are the questions where the manual is silent, self-contradictory, or
;;;; simply stale, and where guessing would have produced something that looked
;;;; right and behaved differently.

(in-package #:objc/test)

(def-suite oracle :in all-tests
  :description "Behaviour matched against a running LispWorks 8.1.")

(in-suite oracle)

(defun oracle (key)
  (let ((entry (assoc key *oracle-answers*)))
    (unless entry (error "No oracle answer recorded for ~S." key))
    (cdr entry)))

(defun ns* (string) (objc:invoke "NSString" "stringWithUTF8String:" string))

(test bool-results-match-lispworks
  "The single most consequential answer.  On Apple silicon BOOL encodes as 'B',
so a Lisp boolean was the natural guess and LispWorks' own precompiled dispatch
table even carries matched (SIGNED CHAR) / OBJC-C++-BOOL pairs.  It still
returns 1 and 0 from INVOKE on every architecture.  Guessing otherwise would
have silently broken every ported (if (invoke ...) ...)."
  (with-runtime
    (let ((s (ns* "hello world"))
          (c (objc:coerce-to-objc-class "NSString")))
      (is (eql (oracle :bool-invoke-true) (objc:invoke s "isKindOfClass:" c)))
      (is (eql (oracle :bool-invoke-false) (objc:invoke s "hasPrefix:" "zzz")))
      (is (eq (oracle :bool-invoke-bool) (objc:invoke-bool s "isKindOfClass:" c))))))

(test scalar-and-struct-results-match-lispworks
  (with-runtime
    (let ((s (ns* "hello world")))
      (is (eql (oracle :length) (objc:invoke s "length")))
      (is (equal (oracle :range-of-string) (objc:invoke s "rangeOfString:" "world"))))))

(test cocoa-struct-sizes-match-lispworks
  "The manual's reference pages say ns-point and ns-size have :FLOAT slots and
ns-range has (:UNSIGNED :INT) slots.  LispWorks itself does not: measured there,
they are 16, 16, 32 and 16 bytes -- doubles and 64-bit integers."
  (with-runtime
    (is (= (oracle :sizeof-ns-point)
           (objc::size-and-alignment (objc::struct-encoding-for-symbol 'cocoa:ns-point))))
    (is (= (oracle :sizeof-ns-size)
           (objc::size-and-alignment (objc::struct-encoding-for-symbol 'cocoa:ns-size))))
    (is (= (oracle :sizeof-ns-rect)
           (objc::size-and-alignment (objc::struct-encoding-for-symbol 'cocoa:ns-rect))))
    (is (= (oracle :sizeof-ns-range)
           (objc::size-and-alignment (objc::struct-encoding-for-symbol 'cocoa:ns-range))))))

(test method-signatures-match-lispworks
  "OBJC-CLASS-METHOD-SIGNATURE's return shape is public API, so it has to match
LispWorks type descriptor for type descriptor."
  (with-runtime
    (flet ((signature (class selector)
             (multiple-value-list (objc:objc-class-method-signature class selector))))
      (is (equal (oracle :sig-length) (signature "NSString" "length")))
      (is (equal (oracle :sig-range-of-string) (signature "NSString" "rangeOfString:")))
      (is (equal (oracle :sig-substring-with-range)
                 (signature "NSString" "substringWithRange:"))))))

(test signature-lookup-prefers-the-instance-method
  "-[NSObject description] encodes as \"@16@0:8\"; +description exists too, and
LispWorks reports the instance one."
  (with-runtime
    (is (equal (oracle :sig-description)
               (multiple-value-list
                (objc:objc-class-method-signature "NSObject" "description"))))))

(test selector-and-class-behaviour-matches-lispworks
  (with-runtime
    (is (eq (oracle :can-invoke-p-bogus)
            (objc:can-invoke-p (ns* "hello world") "noSuchMethodAtAll")))
    (is (string= (oracle :selector-name-string) (objc:selector-name "notAColonName")))
    (is (string= (oracle :selector-name-sel)
                 (objc:selector-name (objc:coerce-to-selector "setWidth:height:"))))
    (is (eql (oracle :retain-count-new)
             (objc:retain-count (objc:invoke "NSObject" "new"))))))

(test the-missing-method-message-matches-lispworks
  "Same wording, same shape of pointer, and the class is the RUNTIME class --
it comes from object_getClass, not from the class the caller named."
  (with-runtime
    (let ((message (handler-case
                       (progn (objc:invoke (ns* "hello world") "noSuchMethodAtAll") nil)
                     (error (e) (princ-to-string e))))
          (reference (oracle :missing-method-report)))
      ;; The addresses differ between runs, so compare everything else.
      (flet ((strip-address (string)
               (let ((start (search "#x" string)))
                 (if start
                     (concatenate 'string (subseq string 0 (+ start 2))
                                  (subseq string (+ start 18)))
                     string))))
        (is (string= (strip-address reference) (strip-address message)))))))

(test an-objc-exception-is-not-caught-here-either
  "LispWorks appears to catch one, but what it catches is the SIGABRT that
follows: the NSException reached objc_terminate and called abort(), and its
generic fatal-signal handler turned that into SYSTEM::EXCEPTION-ERROR.  There is
no @try/@catch in the LispWorks image and there is none here.

What we do instead is make the common case impossible: resolving the Method is
how the call signature is discovered, so an unimplemented selector is a Lisp
error and never reaches the runtime at all.  That is what this asserts, because
it is the part that is actually testable without aborting the test run."
  (with-runtime
    (is (eq :process-aborts (oracle :objc-exception-outcome)))
    (signals error (objc:invoke (ns* "hello world") "noSuchMethodAtAll"))))
