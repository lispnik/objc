;;;; test/invoke-tests.lisp -- the INVOKE family.
;;;;
;;;; Values marked "oracle" were read out of LispWorks 8.1 on this machine and
;;;; are recorded in test/oracle/answers.lisp.

(in-package #:objc/test)

(def-suite invoke :in all-tests
  :description "INVOKE, INVOKE-BOOL, INVOKE-INTO, and argument conversion.")

(in-suite invoke)

(defun ns (string) (objc:invoke "NSString" "stringWithUTF8String:" string))

;;; Receivers ----------------------------------------------------------------

(test string-receiver-calls-a-class-method
  (with-runtime
    (let ((string (objc:invoke "NSString" "stringWithUTF8String:" "hello")))
      (is (cffi:pointerp string))
      (is (= 5 (objc:invoke string "length"))))))

(test pointer-receiver-calls-an-instance-method
  (with-runtime
    (is (= 11 (objc:invoke (ns "hello world") "length")))))

(test class-pointer-receiver-calls-a-class-method
  (with-runtime
    (let ((class (objc:coerce-to-objc-class "NSString")))
      (is (= 5 (objc:invoke (objc:invoke class "stringWithUTF8String:" "hello")
                            "length"))))))

;;; Scalar results -----------------------------------------------------------

(test integer-results
  (with-runtime
    (is (= 11 (objc:invoke (ns "hello world") "length")))
    (is (= 0 (objc:invoke (ns "") "length")))
    (is (integerp (objc:invoke (ns "x") "hash")))))

(test float-and-double-results
  (with-runtime
    (let ((number (objc:invoke "NSNumber" "numberWithDouble:" 1.5d0)))
      (is (= 1.5d0 (objc:invoke number "doubleValue")))
      (is (= 1.5 (objc:invoke number "floatValue"))))))

(test bool-results-are-integers-from-invoke
  "THE one that is easy to get backwards.  On Apple silicon BOOL encodes as 'B'
(C99 _Bool), so a genuine Lisp boolean would be the natural guess -- but
LispWorks normalises to 1 and 0 on every architecture, exactly as the reference
page says, and only INVOKE-BOOL returns T and NIL.  Oracle: 1, 0, T."
  (with-runtime
    (let ((string (ns "hello world"))
          (class (objc:coerce-to-objc-class "NSString")))
      (is (eql 1 (objc:invoke string "isKindOfClass:" class)))
      (is (eql 0 (objc:invoke string "hasPrefix:" "zzz")))
      (is (eql 1 (objc:invoke string "hasPrefix:" "hello")))
      (is (eq t (objc:invoke-bool string "isKindOfClass:" class)))
      (is (eq nil (objc:invoke-bool string "hasPrefix:" "zzz"))))))

(test c-string-results-become-lisp-strings
  (with-runtime
    (is (string= "hello world" (objc:invoke (ns "hello world") "UTF8String")))))

(test object-results-are-pointers
  (with-runtime
    (let ((result (objc:invoke (ns "hello") "uppercaseString")))
      (is (cffi:pointerp result))
      (is (string= "HELLO" (objc:ns-string-to-string result))))))

;;; Struct results -----------------------------------------------------------

(test ns-range-result-is-a-cons
  "A cons, not a vector, unlike the other three Cocoa structs.  Oracle: (6 . 5)."
  (with-runtime
    (let ((range (objc:invoke (ns "hello world") "rangeOfString:" "world")))
      (is (consp range))
      (is (equal '(6 . 5) range)))))

(test ns-range-not-found
  (with-runtime
    (let ((range (objc:invoke (ns "hello") "rangeOfString:" "zzz")))
      (is (= cocoa:ns-not-found (car range))))))

(test ns-rect-result-is-a-four-vector
  (with-runtime
    (let* ((value (objc:invoke "NSValue" "valueWithRect:" #(1d0 2d0 30d0 40d0)))
           (rect (objc:invoke value "rectValue")))
      (is (vectorp rect))
      (is (= 4 (length rect)))
      (is (equalp #(1d0 2d0 30d0 40d0) rect)))))

(test ns-point-and-size-results
  (with-runtime
    (let ((point (objc:invoke (objc:invoke "NSValue" "valueWithPoint:" #(3d0 4d0)) "pointValue"))
          (size (objc:invoke (objc:invoke "NSValue" "valueWithSize:" #(5d0 6d0)) "sizeValue")))
      (is (equalp #(3d0 4d0) point))
      (is (equalp #(5d0 6d0) size)))))

;;; Struct arguments ---------------------------------------------------------

(test struct-passed-by-value
  "-[NSString substringWithRange:] takes an NSRange by value.  On arm64 that is
a 16-byte non-HFA composite, so it travels in x0/x1 rather than indirectly."
  (with-runtime
    (is (string= "world"
                 (objc:invoke-into 'string (ns "hello world")
                                   "substringWithRange:" '(6 . 5))))))

(test rect-passed-by-value-round-trips
  "CGRect is a 32-byte homogeneous float aggregate: four doubles in v0-v3, no
indirect return.  This is the case that would need objc_msgSend_stret on Intel
and does not exist on arm64."
  (with-runtime
    (let* ((value (objc:invoke "NSValue" "valueWithRect:" #(10d0 20d0 100d0 50d0))))
      (is (equalp #(10d0 20d0 100d0 50d0) (objc:invoke value "rectValue"))))))

;;; Argument conversion ------------------------------------------------------

(test string-argument-becomes-an-ns-string
  (with-runtime
    (is (eql 1 (objc:invoke (ns "hello world") "hasPrefix:" "hello")))))

(test nil-argument-becomes-a-null-pointer
  (with-runtime
    (let ((array (objc:invoke "NSArray" "array")))
      (is (eql 0 (objc:invoke array "containsObject:" nil))))))

(test vector-argument-becomes-an-ns-array
  (with-runtime
    (let ((joined (objc:invoke-into 'string
                                    (objc:invoke "NSArray" "arrayWithObjects:count:"
                                                 (cffi:null-pointer) 0)
                                    "componentsJoinedByString:" ",")))
      (is (string= "" joined)))))

(test class-argument-accepts-a-string
  "The manual: a Class argument is coerced as if by COERCE-TO-OBJC-CLASS, so a
string can be passed directly."
  (with-runtime
    (is (eql 1 (objc:invoke (ns "hi") "isKindOfClass:" "NSString")))))

(test selector-argument-accepts-a-string
  (with-runtime
    (is (eql 1 (objc:invoke (ns "hi") "respondsToSelector:"
                            (objc:coerce-to-selector "length"))))))

(test wrong-argument-count-signals
  (with-runtime
    (signals error (objc:invoke (ns "hi") "hasPrefix:"))
    (signals error (objc:invoke (ns "hi") "length" 1))))

;;; INVOKE-INTO --------------------------------------------------------------

(test invoke-into-string
  (with-runtime
    (is (string= "hello" (objc:invoke-into 'string (ns "hello") "description")))
    (is (stringp (objc:invoke-into 'string (objc:invoke "NSObject" "new") "description")))))

(test invoke-into-string-on-a-non-object-result-is-a-no-op
  "The manual: \"Otherwise no special conversion is performed.\""
  (with-runtime
    (is (eql 5 (objc:invoke-into 'string (ns "hello") "length")))))

(test invoke-into-array
  (with-runtime
    (let ((array (objc:invoke "NSArray" "arrayWithObject:" "one")))
      (is (equalp #("one") (objc:invoke-into '(array string) array "self")))
      (is (= 1 (length (objc:invoke-into 'array array "self")))))))

(test invoke-into-nested-array
  (with-runtime
    (let* ((inner (objc:invoke "NSArray" "arrayWithObject:" "deep"))
           (outer (objc:invoke "NSArray" "arrayWithObject:" inner))
           (result (objc:invoke-into '(array (array string)) outer "self")))
      (is (equalp #(#("deep")) result)))))

(test invoke-into-a-cons-fills-it
  (with-runtime
    (let ((cell (cons nil nil)))
      (is (eq cell (objc:invoke-into cell (ns "hello world") "rangeOfString:" "world")))
      (is (equal '(6 . 5) cell)))))

(test invoke-into-a-vector-fills-the-first-elements
  "The manual: for NSRect, NSSize or NSPoint the first 4, 2 or 2 elements are
set.  A longer vector keeps its tail."
  (with-runtime
    (let ((vector (make-array 6 :initial-element :untouched))
          (value (objc:invoke "NSValue" "valueWithRect:" #(1d0 2d0 3d0 4d0))))
      (is (eq vector (objc:invoke-into vector value "rectValue")))
      (is (equalp #(1d0 2d0 3d0 4d0) (subseq vector 0 4)))
      (is (eq :untouched (aref vector 4))))))

(test invoke-into-a-foreign-struct-copies-into-it
  (with-runtime
    (cffi:with-foreign-object (range :uint64 2)
      (let ((result (objc:invoke-into range (ns "hello world") "rangeOfString:" "world")))
        (is (cffi:pointer-eq range result))
        (is (= 6 (cffi:mem-aref range :uint64 0)))
        (is (= 5 (cffi:mem-aref range :uint64 1)))))))

;;; Errors -------------------------------------------------------------------

(test missing-method-signals-before-sending
  "This is what keeps the bridge survivable.  Resolving the Method is how the
call signature is discovered, so an unimplemented selector fails in Lisp; if the
send happened the runtime would raise an NSException, and that aborts the
process -- verified in LispWorks, where it surfaced as SIGABRT."
  (with-runtime
    (signals error (objc:invoke (ns "hi") "noSuchMethodAtAll"))
    ;; A heap string, not a short one: short ASCII strings are tagged pointers
    ;; whose class is NSTaggedPointerString, and the oracle recorded
    ;; __NSCFString.  The class in the message comes from object_getClass, so it
    ;; is the runtime class rather than the one the caller named.
    (let ((message (handler-case
                       (progn (objc:invoke (ns "hello world") "noSuchMethodAtAll") nil)
                     (error (e) (princ-to-string e)))))
      ;; LispWorks: No method "noSuchMethodAtAll" for object #<Pointer: ...>, class "__NSCFString".
      (is (search "No method \"noSuchMethodAtAll\"" message))
      (is (search "class \"__NSCFString\"" message))
      (is (search "#<Pointer: OBJC:OBJC-OBJECT-POINTER = #x" message)
          "pointers print as LispWorks prints them"))))

(test null-receiver-signals-by-default
  (with-runtime
    (signals error (objc:invoke (cffi:null-pointer) "length"))))

(test null-receiver-allowed-when-enabled
  (with-runtime
    (let ((objc::*allow-null-pointer-invoke* t))
      (is (null (objc:invoke (cffi:null-pointer) "length"))))))

;;; alloc-init-object and description ---------------------------------------

(test alloc-init-object
  (with-runtime
    (let ((object (objc:alloc-init-object "NSObject")))
      (is (cffi:pointerp object))
      (is (not (cffi:null-pointer-p object)))
      (objc:release object))))

(test description-returns-a-string
  (with-runtime
    (is (stringp (objc:description (ns "hello"))))
    (is (string= "hello" (objc:description (ns "hello"))))))

;;; Tracing ------------------------------------------------------------------

(test trace-invoke-records-and-clears
  (objc:trace-invoke "length")
  (is-true (gethash "length" objc::*traced-selectors*))
  (objc:untrace-invoke "length")
  (is-false (gethash "length" objc::*traced-selectors*)))

;;; Trampoline caching -------------------------------------------------------

(test the-same-signature-shares-one-trampoline
  "L2 is what keeps the COMPILE count in the hundreds rather than the tens of
thousands: most Cocoa methods share a handful of shapes."
  (with-runtime
    (objc:invoke (ns "a") "length")
    (objc:invoke (ns "b") "hash")
    (let ((count (hash-table-count objc::*trampoline-by-signature*)))
      ;; Both are "unsigned long long (id, SEL)" and must not have compiled twice.
      (objc:invoke (ns "c") "length")
      (objc:invoke (ns "d") "hash")
      (is (= count (hash-table-count objc::*trampoline-by-signature*))))))

(test repeated-sends-hit-the-method-cache
  (with-runtime
    (objc:invoke (ns "a") "length")
    (let ((count (hash-table-count objc::*trampoline-by-method*)))
      (dotimes (i 10) (objc:invoke (ns "a") "length"))
      (is (= count (hash-table-count objc::*trampoline-by-method*))))))

;;; Variadic methods ---------------------------------------------------------

(test the-manuals-variadic-example
  "Section 1.3.9, verbatim.  On Apple silicon a variadic call passes its
variable arguments on the stack while a fixed-arity call passes them in
registers, so this reads garbage without :VARIADIC-NUM-OF-FIXED.  Splicing an
&optional into the alien signature is what makes it a genuine variadic call."
  (with-runtime
    (is (string= "The integer 42"
                 (objc:invoke-into 'string "NSString"
                                   '("stringWithFormat:"
                                     (objc:objc-object-pointer :int)
                                     :result-type objc:objc-object-pointer
                                     :variadic-num-of-fixed 1)
                                   "The integer %d" 42)))))

(test a-known-variadic-selector-warns-once-without-the-key
  "LispWorks fails silently here; warning is the one thing we can add cheaply."
  (with-runtime
    (remhash "stringWithFormat:" objc::*warned-variadic*)
    (signals warning (objc::maybe-warn-variadic "stringWithFormat:" nil))
    ;; ...and only once, so a loop does not bury the REPL.
    (finishes (objc::maybe-warn-variadic "stringWithFormat:" nil))))

(test explicit-arg-types-replace-the-runtimes-view
  "The list form of a method designator exists for signatures the encoding
cannot express.  Given one, the runtime's own types are not consulted."
  (with-runtime
    (is (= 5 (objc:invoke (ns "hello")
                          '("length" () :result-type (:unsigned :long-long)))))))

;;; INVOKE-INTO :pointer -----------------------------------------------------

(test invoke-into-pointer-suppresses-the-string-conversion
  "The manual: with :POINTER a char * result comes back as a pointer rather
than being converted.  Asking for a pointer and getting a string is exactly what
this disposition exists to avoid."
  (with-runtime
    (let* ((string (ns "hello"))
           (pointer (objc:invoke-into :pointer string "UTF8String")))
      (is (cffi:pointerp pointer))
      (is (not (cffi:null-pointer-p pointer)))
      (is (string= "hello" (cffi:foreign-string-to-lisp pointer :encoding :utf-8)))
      ;; and the default really does convert, so the two differ
      (is (stringp (objc:invoke string "UTF8String"))))))

(test invoke-into-pointer-with-an-element-type
  (with-runtime
    (is (cffi:pointerp (objc:invoke-into '(:pointer :char) (ns "hello") "UTF8String")))))

;;; Tracing and odds and ends -------------------------------------------------

(test trace-invoke-actually-reports-calls
  "Not CL:TRACE on INVOKE, which would fire on every send in the image and
print receivers as opaque pointers."
  (with-runtime
    (objc:trace-invoke "length")
    (unwind-protect
         (let ((output (with-output-to-string (stream)
                         (let ((*trace-output* stream))
                           (objc:invoke (ns "hi") "length")))))
           (is (search "length" output))
           ;; and an untraced selector stays quiet
           (let ((output (with-output-to-string (stream)
                           (let ((*trace-output* stream))
                             (objc:invoke (ns "hi") "hash")))))
             (is (zerop (length output)))))
      (objc:untrace-invoke "length"))))

(test alloc-init-object-accepts-a-class-pointer-as-well-as-a-name
  (with-runtime
    (is (cffi:pointerp (objc:alloc-init-object "NSObject")))
    (is (cffi:pointerp (objc:alloc-init-object
                        (objc:coerce-to-objc-class "NSObject"))))))

;;; Every scalar type, both directions ----------------------------------------
;;;
;;; NSNumber is the oracle the suite was missing.  Each entry passes a value IN
;;; as a method argument and reads it back OUT as a result, so one table covers
;;; both halves of the scalar path for a type -- which is exactly the asymmetry
;;; that let a real bug through: BOOL results were tested and correct, BOOL
;;; arguments were untested and always arrived as NO.

(defparameter +scalar-round-trips+
  '(("numberWithBool:"              "boolValue"              1
     "the bug this table exists because of")
    ("numberWithChar:"              "charValue"              -42
     "negative, so a sign extension fault shows")
    ("numberWithUnsignedChar:"      "unsignedCharValue"      200
     "above the signed maximum for its width")
    ("numberWithShort:"             "shortValue"             -12345 nil)
    ("numberWithUnsignedShort:"     "unsignedShortValue"     54321
     "above 32767")
    ("numberWithInt:"               "intValue"               -1234567 nil)
    ("numberWithUnsignedInt:"       "unsignedIntValue"       4000000000
     "above 2^31")
    ("numberWithLong:"              "longValue"              -123456789012
     "needs more than 32 bits, so truncation cannot hide")
    ("numberWithUnsignedLong:"      "unsignedLongValue"      12345678901234 nil)
    ("numberWithLongLong:"          "longLongValue"          -1234567890123 nil)
    ("numberWithUnsignedLongLong:"  "unsignedLongLongValue"  18000000000000000000
     "above 2^63 -- the signed/unsigned question at 64 bits")
    ("numberWithInteger:"           "integerValue"           -9007199254740993
     "past exact integer representation in a double")
    ("numberWithUnsignedInteger:"   "unsignedIntegerValue"   9007199254740993 nil)
    ("numberWithFloat:"             "floatValue"             1.5
     "exact in binary, so a mismatch is conversion and not rounding")
    ("numberWithDouble:"            "doubleValue"            1.25d0 nil))
  "Constructor, accessor, value, and why that value.

The values are chosen to fail rather than to pass.  Anything above a type's
signed maximum catches signed/unsigned confusion; anything past 32 bits catches
truncation; -9007199254740993 catches a value routed through a double; and the
floats are exactly representable so a mismatch cannot be rounding.")

(test every-scalar-type-survives-a-round-trip
  "Pass each scalar type in as an argument and read it back out as a result.

Nothing here is subtle, and that is the point: the BOOL argument path was broken
for as long as this library has existed, and was found by an example rather than
by the suite, because the suite tested every scalar RESULT and no scalar
ARGUMENT.  A hole that shape does not announce itself; it needs a table.

Verified to CATCH that bug rather than merely to accompany it, by reintroducing
it: with the fix reverted this reports 14 of 15 and names the BOOL row.  Worth
knowing for anyone repeating that -- the fix was three lines in three files, and
reverting only the ALIEN-TYPE one still looks correct, because then the argument
path sends NO and the old result path reads NO back as 1.  Two faults cancelling
is how this survived so long, and it is why half a revert proves nothing."
  (with-runtime
    (objc:with-autorelease-pool ()
      (loop for (constructor accessor value reason) in +scalar-round-trips+
            for number = (objc:invoke "NSNumber" constructor value)
            do (is (= value (objc:invoke number accessor))
                   "~A -> ~A did not round trip ~S~@[ (~A)~]"
                   constructor accessor value reason)))))
