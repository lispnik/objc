;;;; test/abi-ecl-tests.lisp -- the ECL backend's own obligations.
;;;;
;;;; Loaded only under ECL.  What is here is what the backend could get wrong
;;;; without saying so: how an aggregate is described to the dynamic FFI, what
;;;; the foreign types are, that traps are masked, and that the two paths a
;;;; phone has -- dynamic calls and libffi closures -- actually carry a
;;;; structure both ways with no compiler in the picture.

(in-package #:objc/test)

(def-suite abi-ecl :in all-tests
  :description "The ECL ABI backend: dynamic FFI designators, foreign types, FP traps, closures.")

(in-suite abi-ecl)

(defun ecl-foundation-available-p ()
  (handler-case (progn (objc::ensure-libobjc) (objc::ensure-foundation) t)
    (error () nil)))

(defun node-of (encoding)
  (objc::resolve-struct-layout (objc::parse-type encoding)))

(defun dffi-type-of (encoding)
  (objc::ecl-dffi-type (node-of encoding)))

;;; Dynamic FFI designators ---------------------------------------------------
;;;
;;; The dynamic FFI reads these in C and cannot look a name up, so an aggregate
;;; reaches it as its resolved layout.  What matters is that the layout is
;;; described truthfully -- nesting kept, arrays as arrays -- and that libffi is
;;; left to classify it.  Nothing here decides which register anything goes in,
;;; which is the whole improvement over the decomposition this replaced: that
;;; was right for four shapes, silently wrong for the rest, and tested for
;;; exactly the shapes it was wrong on.

(test a-structure-is-described-as-its-layout
  (is (equal '(:struct (:m :double) (:m :double)) (dffi-type-of "{CGPoint=dd}")))
  (is (equal '(:struct (:m :unsigned-long-long) (:m :unsigned-long-long))
             (dffi-type-of "{_NSRange=QQ}")))
  ;; Nested stays nested: libffi flattens for classification itself.
  (is (equal '(:struct (:m (:struct (:m :double) (:m :double)))
                       (:m (:struct (:m :double) (:m :double))))
             (dffi-type-of "{CGRect={CGPoint=dd}{CGSize=dd}}")))
  ;; The shapes the old decomposition refused are ordinary here.
  (is (equal '(:struct (:m :long-long) (:m :double)) (dffi-type-of "{mixed=qd}")))
  (is (= 6 (length (rest (dffi-type-of "{CGAffineTransform=dddddd}"))))))

(test an-array-member-is-an-array
  (is (equal '(:struct (:m :byte) (:m (:array :int 3)))
             (dffi-type-of "{tagged=c[3i]}"))))

(test pointers-and-scalars-are-what-ecl-foreign-type-says
  (dolist (encoding '("@" "#" ":" "*" "^v" "^{CGRect=}"))
    (is (eq :pointer-void (dffi-type-of encoding))))
  (is (eq :byte (dffi-type-of "B")))
  (is (eq :double (dffi-type-of "d"))))

(test a-union-and-an-unresolved-layout-are-refused
  "Refused, not guessed at: libffi has no union type, and the runtime elides
layouts -- \"{CGRect=}\" -- so a field-less struct cannot be described."
  (signals objc::ecl-abi-unsupported
    (objc::ecl-dffi-type '(:union "u" (:id :double))))
  ;; A struct with no fields is sent to the runtime for its layout first, and
  ;; the runtime's refusal is the one that arrives. Either way it is an error
  ;; and not a guess, which is the property under test.
  (signals error
    (objc::ecl-dffi-type '(:struct "Unknown" nil))))

;;; Foreign types ------------------------------------------------------------

(test foreign-types-follow-the-encodings-widths
  "'l' is 32 bits by definition of the encoding, whatever a C long is here."
  (is (eq :int32-t (objc::ecl-foreign-type :long)))
  (is (eq :uint32-t (objc::ecl-foreign-type :ulong)))
  (is (eq :long-long (objc::ecl-foreign-type :long-long)))
  (is (eq :int (objc::ecl-foreign-type :int))))

(test bool-and-char-are-bytes-not-characters
  "ECL's :CHAR is a Lisp CHARACTER.  Declaring a BOOL callback :CHAR makes
returning 0 fail inside CHAR-CODE, and a signed-char result come back as #\\Nul."
  (is (eq :byte (objc::ecl-foreign-type :bool)))
  (is (eq :byte (objc::ecl-foreign-type :char)))
  (is (eq :unsigned-byte (objc::ecl-foreign-type :uchar))))

(test every-pointer-is-one-opaque-type
  "Including :CSTRING, which must not be ECL's converting :CSTRING -- the
layers above already speak addresses."
  (dolist (node '(:id :class :sel :cstring :block (:pointer :char)))
    (is (eq :pointer-void (objc::ecl-foreign-type node)))))

(test naming-an-aggregate-is-refused
  "An aggregate reaches here only as a bug upstream; it must not be guessed at."
  (signals objc::ecl-abi-unsupported
    (objc::ecl-foreign-type '(:struct "CGPoint" (:double :double)))))

;;; Floating point -----------------------------------------------------------

(test fp-traps-are-masked-and-restored
  "ECL traps division by zero out of the box -- measured, not assumed -- and
CoreGraphics trips it internally on an empty rect.  Unmasked, that raises a
Lisp condition in the middle of a Cocoa call."
  (let ((before (objc::%fpe-bits)))
    (objc::with-fp-traps-masked
      (is (zerop (objc::%fpe-bits)))
      ;; The point of the exercise: this must not signal.
      (is (ext:float-infinity-p (/ 1.0d0 0.0d0))))
    (is (eql before (objc::%fpe-bits)))))

(test fp-traps-are-restored-after-a-nonlocal-exit
  "UNWIND-PROTECT, not a cleanup at the end of the body: a trampoline whose
Lisp side throws must not leave the thread with traps disabled."
  (let ((before (objc::%fpe-bits)))
    (ignore-errors
     (objc::with-fp-traps-masked
       (error "deliberate")))
    (is (eql before (objc::%fpe-bits)))))

;;; IMP liveness -------------------------------------------------------------

(test the-imp-registry-exists
  "method-def.lisp and class-def.lisp both write to it; without it the first
method install fails on an undefined variable."
  (is-true (hash-table-p objc::*imp-registry*)))

;;; SAP representation -------------------------------------------------------

(test saps-survive-a-tagged-pointer
  "Apple returns tagged pointers for short NSStrings and small NSNumbers: the
payload lives in the pointer with the top bit set. The address of one exceeds
ECL's 62-bit fixnum, so representing a SAP as an integer round-tripped every
heap object correctly and failed on exactly the objects Foundation hands back
most often -- CFFI:MAKE-POINTER signalled a type error inside COERCE."
  ;; The property the layers above rely on, whatever the representation is.
  (dolist (address (list 0 8 #x7fffffff))
    (let ((pointer (cffi:make-pointer address)))
      (is (cffi:pointer-eq pointer (objc::pointer-of (objc::sap-of pointer))))))
  (is-true (cffi:null-pointer-p (objc::sb-sap-zero)))
  ;; And the case that broke: a pointer whose address does not fit a fixnum.
  ;; Constructed rather than obtained, so this holds with no runtime present.
  (if (not (ecl-foundation-available-p))
      (skip "Foundation not available")
      (let* ((tagged (objc:invoke "NSString" "stringWithUTF8String:" "hi"))
             (address (cffi:pointer-address tagged)))
        (is-true (integerp address))
        (is (cffi:pointer-eq tagged (objc::pointer-of (objc::sap-of tagged))))
        ;; Not an assertion about Apple's tagging -- a note in the output when
        ;; the interesting case is not being exercised on this machine.
        (when (<= address most-positive-fixnum)
          (format t "~&  (note: ~s is not tagged here)~%" address)))))

(test a-tagged-pointer-round-trips-through-the-seam
  "The concrete case: -UTF8String on a short string returns a tagged pointer."
  (if (not (ecl-foundation-available-p))
      (skip "Foundation not available")
      (let ((string (objc:invoke "NSString" "stringWithUTF8String:" "hello")))
        (is (string= "hello" (objc:ns-string-to-string string))))))

;;; Strategy A ---------------------------------------------------------------

(test the-dynamic-path-handles-scalars-and-pointers
  "No C compiler involved -- this is the path that works at a remote REPL."
  (if (not (ecl-foundation-available-p))
      (skip "Foundation not available")
      (let ((string (objc:invoke "NSString" "stringWithUTF8String:" "hello world")))
        (is (eql 11 (objc:invoke string "length")))
        (is (eql 42 (objc:invoke (objc:invoke "NSNumber" "numberWithInt:" 42)
                                 "intValue")))
        (is-true (objc:invoke-bool string "isEqualToString:" string))
        (is (string= "7" (objc:ns-string-to-string
                          (objc:invoke (objc:invoke "NSNumber" "numberWithInt:" 7)
                                       "description")))))))

(test a-struct-result-comes-back-whole
  "Through SI:CALL-CFUN, with no compiler consulted.

This used to be the case the dynamic path could never do and the reason a pool
of trampolines shipped with every iOS app.  It is now an ordinary send."
  (let ((range '(:struct "_NSRange" (:ulong-long :ulong-long))))
    ;; The dynamic path claims it ...
    (is-true (objc::%dynamic-trampoline :send range '(:id :sel :id) nil)))
  (if (not (ecl-foundation-available-p))
      (skip "Foundation not available")
      (let ((string (objc:invoke "NSString" "stringWithUTF8String:" "hello world")))
        ;; ... and gets it right.
        (is (equal '(6 . 5)
                   (objc:invoke string "rangeOfString:"
                                (objc:invoke "NSString" "stringWithUTF8String:"
                                             "world")))))))

(test a-struct-argument-goes-by-value-whatever-its-shape
  "A long beside a double is the shape scalar decomposition got wrong: the two
halves go to x0 and v0, and decomposed, the double went to v0 and the callee
read x1.  libffi puts it where it belongs."
  (if (not (ecl-foundation-available-p))
      (skip "Foundation not available")
      ;; -[NSValue valueWithRange:] takes an NSRange by value and hands it back.
      (let ((value (objc:invoke "NSValue" "valueWithRange:" '(7 . 9))))
        (is (equal '(7 . 9) (objc:invoke value "rangeValue"))))))

(test a-struct-crosses-into-a-lisp-method-and-back
  "Both directions through a libffi closure: an NSRect argument arrives as a
vector of doubles, an NSRange result goes back as a cons.  No compiler."
  (if (not (ecl-foundation-available-p))
      (skip "Foundation not available")
      (progn
        ;; Run alone, this is the first thing to define a class.
        (objc:ensure-objc-initialized)
        (eval '(objc:define-objc-class abi-ecl-shape () ()
                (:objc-class-name "AbiEclShape")))
        (eval '(objc:define-objc-method ("areaOf:" :double)
                ((self abi-ecl-shape) (r cocoa:ns-rect))
                (* (aref r 2) (aref r 3))))
        (eval '(objc:define-objc-method ("spanFrom:" cocoa:ns-range)
                ((self abi-ecl-shape) (n (:unsigned :int)))
                (cons n (* 2 n))))
        (let ((object (objc:alloc-init-object "AbiEclShape")))
          (is (= 42d0 (objc:invoke object "areaOf:" '(0d0 0d0 6d0 7d0))))
          (is (equal '(3 . 6) (objc:invoke object "spanFrom:" 3)))))))

;;; Closures -----------------------------------------------------------------

(test a-callable-is-a-closure-that-can-be-called
  "BUILD-CALLABLE's result is an address C can call.  Here it is called through
SI:CALL-CFUN, which is C as far as the closure is concerned, with a structure
in and a structure out and no Objective-C anywhere."
  (let ((seen nil))
    (multiple-value-bind (sap name)
        (objc::build-callable
         'abi-ecl-test-callable
         '(:struct "_NSRange" (:ulong-long :ulong-long))
         '(:id (:struct "CGPoint" (:double :double)) :int)
         1
         (lambda (self result-sap point n)
           (setf seen (list (cffi:pointer-address self)
                            (cffi:mem-ref point :double 0)
                            (cffi:mem-ref point :double 8)
                            n))
           (setf (cffi:mem-ref result-sap :uint64 0) n
                 (cffi:mem-ref result-sap :uint64 8) (* 2 n))
           nil)
         "test callable")
      (is (eq name 'abi-ecl-test-callable))
      (is-true (cffi:pointerp sap))
      (cffi:with-foreign-object (point :double 2)
        (setf (cffi:mem-aref point :double 0) 1.5d0
              (cffi:mem-aref point :double 1) -2d0)
        (let ((result (si:call-cfun sap
                                    '(:struct (:m :unsigned-long-long) (:m :unsigned-long-long))
                                    '(:pointer-void (:struct (:m :double) (:m :double)) :int)
                                    (list (cffi:make-pointer 4096) point 21))))
          (is (equal '(4096 1.5d0 -2d0 21) seen))
          (is (= 21 (cffi:mem-ref result :uint64 0)))
          (is (= 42 (cffi:mem-ref result :uint64 8))))))))

(test a-condition-in-a-callable-does-not-escape
  "There is no handler on the C side, so the closure reports and returns a
zero value -- and for a structure result, a zeroed structure rather than NIL,
which libffi could not copy."
  (let ((sap (objc::build-callable
              'abi-ecl-test-failing
              '(:struct "_NSRange" (:ulong-long :ulong-long))
              '(:id)
              1
              (lambda (self result-sap) (declare (ignore self result-sap))
                (error "deliberate"))
              "test callable")))
    (let* ((*error-output* (make-string-output-stream))
           (result (si:call-cfun sap
                                 '(:struct (:m :unsigned-long-long) (:m :unsigned-long-long))
                                 '(:pointer-void)
                                 (list (cffi:null-pointer)))))
      (is (= 0 (cffi:mem-ref result :uint64 0)))
      (is (= 0 (cffi:mem-ref result :uint64 8)))
      (is (search "deliberate" (get-output-stream-string *error-output*))))))

;;; Variadic sends -----------------------------------------------------------
;;;
;;; What remained of the pool was a variadic send on a phone: arm64 passes
;;; variadic arguments on the stack, a fixed cif puts them in registers, and
;;; ECL did not expose libffi's variadic preparation.  It does now, so the
;;; dynamic path makes these too, and nothing is compiled ahead of time.

(test the-dynamic-path-makes-a-variadic-send
  "A signature with a fixed count is claimed by the dynamic path -- it used to
be the one shape it declined."
  (is-true (objc::%dynamic-trampoline :send :id '(:id :sel :id :id) 3))
  (if (not (ecl-foundation-available-p))
      (skip "Foundation not available")
      ;; And with no compiler to fall back on, +stringWithFormat: reads its
      ;; variadic arguments from where the callee looks.
      (let ((objc::*compiled-trampolines-available* nil))
        (is (string= "x 42"
                     (objc:ns-string-to-string
                      (objc:invoke "NSString"
                                   '("stringWithFormat:"
                                     (objc:objc-object-pointer objc:objc-object-pointer :int)
                                     :result-type objc:objc-object-pointer
                                     :variadic-num-of-fixed 1)
                                   "%@ %d" "x" 42)))))))

(test a-variadic-float-is-promoted
  "libffi refuses an unpromoted variadic argument, so a float past the fixed
ones is sent as a double -- which is also what the callee, reading a va_list,
expects."
  (is (eq :double (objc::%promoted-type :float)))
  (is (eq :int (objc::%promoted-type :byte)))
  (is (eq :id (objc::%promoted-type :id)))
  (is (typep (objc::%promote-value :double 1.5) 'double-float)))
