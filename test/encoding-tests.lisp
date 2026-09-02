;;;; test/encoding-tests.lisp -- the type encoding parser.
;;;;
;;;; Pure: nothing here loads the Objective-C runtime, so this suite runs
;;;; anywhere and is the first thing to go green.  It carries the test density
;;;; on purpose -- the parser is the component most likely to be wrong and the
;;;; cheapest to check.
;;;;
;;;; The encodings quoted as "live" were read from the runtime on macOS 15
;;;; arm64 and are reproduced verbatim.

(in-package #:objc/test)

(def-suite encoding :in all-tests
  :description "Objective-C type encoding parsing.")

(in-suite encoding)

(defun parse (string) (objc::parse-type string))
(defun parse-method (string)
  (multiple-value-list (objc::parse-method-encoding string)))

;;; Primitives ---------------------------------------------------------------

(test primitive-scalars
  (is (eq :char       (parse "c")))
  (is (eq :uchar      (parse "C")))
  (is (eq :short      (parse "s")))
  (is (eq :ushort     (parse "S")))
  (is (eq :int        (parse "i")))
  (is (eq :uint       (parse "I")))
  (is (eq :long-long  (parse "q")))
  (is (eq :ulong-long (parse "Q")))
  (is (eq :float      (parse "f")))
  (is (eq :double     (parse "d")))
  (is (eq :bool       (parse "B")))
  (is (eq :void       (parse "v")))
  (is (eq :cstring    (parse "*")))
  (is (eq :class      (parse "#")))
  (is (eq :sel        (parse ":")))
  (is (eq :unknown    (parse "?"))))

(test l-and-L-are-32-bit
  "'l' and 'L' mean exactly 32 bits even on LP64; NSInteger is 'q'.
Reading them as a C long silently truncates every value that crosses."
  (is (eq :long  (parse "l")))
  (is (eq :ulong (parse "L")))
  (is (= 4 (objc::node-size-and-alignment :long)))
  (is (= 4 (objc::node-size-and-alignment :ulong)))
  (is (= 8 (objc::node-size-and-alignment :long-long))))

;;; Objects, blocks, class names --------------------------------------------

(test object-encodings
  (is (eq :id (parse "@")))
  (is (eq :block (parse "@?")) "@? is a block and must be tested before bare @"))

(test quoted-class-name-is-consumed
  "'@\"NSString\"' must consume the quoted name.  Leaving it behind
desynchronises the parse and every following argument comes out wrong."
  (is (eq :id (parse "@\"NSString\"")))
  (multiple-value-bind (node next) (objc::parse-type "@\"NSString\"i" 0)
    (is (eq :id node))
    (is (= 11 next)))
  (multiple-value-bind (result args) (objc::parse-method-encoding "@\"NSArray\"@:@\"NSString\"")
    (is (eq :id result))
    (is (equal '(:id :sel :id) args))))

;;; Frame offsets ------------------------------------------------------------

(test frame-offsets-are-stripped
  "method_getTypeEncoding writes decimal frame offsets that are meaningless on
arm64.  \"Q16@0:8\" is three types, not a type named Q16."
  (is (equal '(:ulong-long (:id :sel)) (parse-method "Q16@0:8")))
  (is (equal '(:void (:id :sel)) (parse-method "v16@0:8"))))

(test live-encodings-from-the-runtime
  "Read from the runtime on macOS 15 arm64, reproduced verbatim."
  (destructuring-bind (result args) (parse-method "Q16@0:8")
    (is (eq :ulong-long result))
    (is (equal '(:id :sel) args)))
  (destructuring-bind (result args) (parse-method "{_NSRange=QQ}24@0:8@16")
    (is (equal '(:struct "_NSRange" (:ulong-long :ulong-long)) result))
    (is (equal '(:id :sel :id) args)))
  (destructuring-bind (result args) (parse-method "@32@0:8{_NSRange=QQ}16")
    (is (eq :id result))
    (is (equal '(:id :sel (:struct "_NSRange" (:ulong-long :ulong-long))) args)))
  (destructuring-bind (result args) (parse-method "@16@0:8")
    (is (eq :id result))
    (is (equal '(:id :sel) args))))

;;; Composites ---------------------------------------------------------------

(test pointers
  (is (equal '(:pointer :void) (parse "^v")))
  (is (equal '(:pointer :int) (parse "^i")))
  (is (equal '(:pointer (:pointer :char)) (parse "^^c")))
  (is (equal '(:pointer :unknown) (parse "^?") ) "^? is a function pointer"))

(test arrays
  (is (equal '(:array 12 (:pointer :float)) (parse "[12^f]")))
  (is (equal '(:array 4 :double) (parse "[4d]")))
  (is (= 96 (objc::node-size-and-alignment '(:array 12 (:pointer :float))))))

(test structs
  (is (equal '(:struct "CGPoint" (:double :double)) (parse "{CGPoint=dd}")))
  (is (equal '(:struct "CGRect" ((:struct "CGPoint" (:double :double))
                                 (:struct "CGSize" (:double :double))))
             (parse "{CGRect={CGPoint=dd}{CGSize=dd}}")))
  (is (equal '(:struct "example" (:id :cstring :int)) (parse "{example=@*i}"))))

(test anonymous-and-name-only-structs
  (is (equal '(:struct nil (:double :double)) (parse "{?=dd}"))
      "{?=...} is an anonymous struct")
  (is (equal '(:struct "CGRect" nil) (parse "{CGRect=}"))
      "a name-only struct records no layout")
  (is (equal '(:struct "CGRect" nil) (parse "{CGRect}")))
  (is (equal '(:pointer (:struct "example" nil)) (parse "^{example}"))))

(test unions-and-bitfields
  (is (equal '(:union "u" (:int :float)) (parse "(u=if)")))
  (is (equal '(:bitfield 8) (parse "b8"))))

(test qualifiers
  (is (equal '(:qualified (:const) :cstring) (parse "r*")))
  (is (equal '(:qualified (:out) :int) (parse "oi")))
  (is (equal '(:qualified (:inout) (:pointer :id)) (parse "N^@")))
  (is (equal '(:qualified (:oneway) :void) (parse "Vv")))
  (is (equal '(:qualified (:const :in) :id) (parse "rn@"))
      "qualifiers stack"))

;;; Errors -------------------------------------------------------------------

(test malformed-encodings-signal
  "Signalling beats guessing: a struct of the wrong size passed by value
corrupts the argument registers of everything after it."
  (signals objc::unsupported-type-encoding (parse ""))
  (signals objc::unsupported-type-encoding (parse "Z"))
  (signals objc::unsupported-type-encoding (parse "{unterminated=i"))
  (signals objc::unsupported-type-encoding (parse "[12"))
  (signals objc::unsupported-type-encoding (parse "[d]"))
  (signals objc::unsupported-type-encoding (parse "b"))
  (signals objc::unsupported-type-encoding (parse "@\"unterminated")))

(test unknown-name-only-struct-signals
  (signals objc::unsupported-type-encoding
    (objc::resolve-struct-layout '(:struct "NoSuchStructAnywhere" nil))))

(test known-name-only-struct-resolves
  (is (equal '(:struct "CGPoint" (:double :double))
             (objc::resolve-struct-layout '(:struct "CGPoint" nil))))
  (is (equal '(:struct "_NSRange" (:ulong-long :ulong-long))
             (objc::resolve-struct-layout '(:struct "NSRange" nil)))))

;;; Round tripping -----------------------------------------------------------

(test unparse-round-trips
  (dolist (encoding '("c" "C" "i" "I" "q" "Q" "f" "d" "B" "v" "*" "#" ":" "@"
                      "^v" "^^c" "[12^f]" "{CGPoint=dd}"
                      "{CGRect={CGPoint=dd}{CGSize=dd}}" "{_NSRange=QQ}"
                      "(u=if)" "@?"))
    (is (string= encoding (objc::unparse-type (parse encoding)))
        "~S should round trip" encoding)))

(test canonical-encoding-drops-qualifiers
  "Qualifiers do not change the ABI, so two signatures that differ only in them
must share one compiled trampoline."
  (is (string= (objc::canonical-encoding (parse "i"))
               (objc::canonical-encoding (parse "oi"))))
  (is (string= (objc::canonical-encoding (parse "@"))
               (objc::canonical-encoding (parse "rn@")))))

(test canonical-encoding-survives-name-only-structs
  "UNPARSE-TYPE signals on a struct with no layout; the cache key must not,
because such a node still needs to be distinguishable."
  (is (string= "{CGRect}" (objc::canonical-encoding '(:struct "CGRect" nil))))
  (is (string/= (objc::canonical-encoding '(:struct "CGRect" nil))
                (objc::canonical-encoding '(:struct "CGSize" nil)))))

;;; Selector arity -----------------------------------------------------------

(test selector-argument-count
  "Arity is the colon count and nothing else in the API conveys it."
  (is (= 0 (objc::selector-argument-count "close")))
  (is (= 1 (objc::selector-argument-count "setWidth:")))
  (is (= 2 (objc::selector-argument-count "setWidth:height:")))
  (is (= 2 (objc::selector-argument-count "setObject:forKey:")))
  (is (= 3 (objc::selector-argument-count "webView:didReceiveTitle:forFrame:"))))
