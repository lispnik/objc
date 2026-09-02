;;;; test/types-tests.lisp -- type descriptors and struct layouts.
;;;;
;;;; These do touch the runtime, but only Foundation, and only for
;;;; NSGetSizeAndAlignment.  That function parses the exact encoding notation
;;;; the layout table is written in and reports the size and alignment the
;;;; compiler would have used, which makes it a ground-truth oracle for
;;;; hand-written layouts -- strictly better than groveling, because it checks
;;;; the very string that will be handed to class_addMethod.

(in-package #:objc/test)

(def-suite types :in all-tests
  :description "FLI type descriptors, struct layouts, and node sizes.")

(in-suite types)

(defun foundation-available-p ()
  (handler-case (progn (objc::ensure-libobjc) (objc::ensure-foundation) t)
    (error () nil)))

;;; The layout table against Foundation -------------------------------------

(test struct-layout-overrides-match-foundation
  "Every hand-written entry must agree with Foundation about size and alignment.
This is the check that makes hand-writing layouts safe."
  (if (not (foundation-available-p))
      (skip "Foundation not available")
      (let ((seen (make-hash-table :test 'equal)))
        (maphash (lambda (name encoding)
                   (declare (ignore name))
                   (unless (gethash encoding seen)
                     (setf (gethash encoding seen) t)
                     (multiple-value-bind (size align)
                         (objc::size-and-alignment encoding)
                       (multiple-value-bind (our-size our-align)
                           (objc::node-size-and-alignment (objc::parse-type encoding))
                         (is (= size our-size)
                             "~S: Foundation says size ~D, we compute ~D"
                             encoding size our-size)
                         (is (= align our-align)
                             "~S: Foundation says alignment ~D, we compute ~D"
                             encoding align our-align)))))
                 objc::*struct-layout-overrides*))))

(test cocoa-struct-sizes
  "Measured in LispWorks 8.1 on this machine: ns-point 16, ns-size 16,
ns-rect 32, ns-range 16.  The manual's reference pages claim :FLOAT slots for
ns-point and (:UNSIGNED :INT) for ns-range; that is stale 32-bit text and the
implementation does not follow it."
  (if (not (foundation-available-p))
      (skip "Foundation not available")
      (progn
        (is (= 16 (objc::size-and-alignment (objc::struct-encoding-for-symbol 'cocoa:ns-point))))
        (is (= 16 (objc::size-and-alignment (objc::struct-encoding-for-symbol 'cocoa:ns-size))))
        (is (= 32 (objc::size-and-alignment (objc::struct-encoding-for-symbol 'cocoa:ns-rect))))
        (is (= 16 (objc::size-and-alignment (objc::struct-encoding-for-symbol 'cocoa:ns-range)))))))

(test scalar-sizes-match-foundation
  (if (not (foundation-available-p))
      (skip "Foundation not available")
      (dolist (encoding '("c" "C" "s" "S" "i" "I" "l" "L" "q" "Q" "f" "d" "B"
                          "@" "#" ":" "*" "^v" "[4d]" "[12^f]"))
        (multiple-value-bind (size align) (objc::size-and-alignment encoding)
          (multiple-value-bind (our-size our-align)
              (objc::node-size-and-alignment (objc::parse-type encoding))
            (is (= size our-size) "~S: size ~D vs ~D" encoding size our-size)
            (is (= align our-align) "~S: alignment ~D vs ~D" encoding align our-align))))))

(test foundation-confirms-l-is-32-bit
  "The one that would otherwise be taken on faith."
  (if (not (foundation-available-p))
      (skip "Foundation not available")
      (progn
        (is (= 4 (objc::size-and-alignment "l")))
        (is (= 4 (objc::size-and-alignment "L")))
        (is (= 8 (objc::size-and-alignment "q"))))))

;;; Node -> FLI type descriptor ---------------------------------------------
;;;
;;; These are the shapes OBJC-CLASS-METHOD-SIGNATURE returns, so they are public
;;; API.  The expected values were read out of LispWorks 8.1 on this machine.

(test fli-type-for-node-matches-lispworks
  (is (eq 'objc:objc-object-pointer (objc::fli-type-for-node :id)))
  (is (eq 'objc:objc-class (objc::fli-type-for-node :class)))
  (is (eq 'objc:sel (objc::fli-type-for-node :sel)))
  (is (eq 'objc:objc-c-string (objc::fli-type-for-node :cstring)))
  (is (eq 'objc:objc-c++-bool (objc::fli-type-for-node :bool)))
  (is (eq :void (objc::fli-type-for-node :void)))
  (is (eq :int (objc::fli-type-for-node :int)))
  ;; -[NSString length] reports exactly this in LispWorks.
  (is (equal '(:unsigned :long-long) (objc::fli-type-for-node :ulong-long)))
  (is (equal '(:signed :char) (objc::fli-type-for-node :char)))
  (is (equal '(:unsigned :int) (objc::fli-type-for-node :uint))))

(test fli-type-for-struct-node-uses-cocoa-symbols
  "-[NSString rangeOfString:] reports (:STRUCT COCOA:NS-RANGE) in LispWorks."
  (is (equal '(:struct cocoa:ns-range)
             (objc::fli-type-for-node (objc::parse-type "{_NSRange=QQ}"))))
  (is (equal '(:struct cocoa:ns-rect)
             (objc::fli-type-for-node (objc::parse-type "{CGRect={CGPoint=dd}{CGSize=dd}}"))))
  (is (equal '(:struct cocoa:ns-point)
             (objc::fli-type-for-node (objc::parse-type "{CGPoint=dd}")))))

(test node-for-fli-type-round-trips
  (dolist (spec '(:void :int :float :double :long-long
                  (:unsigned :int) (:signed :char) (:unsigned :long-long)))
    (is (equal spec (objc::fli-type-for-node (objc::node-for-fli-type spec)))
        "~S should round trip" spec)))

(test fli-long-is-64-bit-but-node-long-is-32
  "The C type long is 64 bits on LP64 and encodes as 'q', while the node :LONG
is the 32-bit 'l' encoding.  The mapping between them is deliberately not the
identity, and confusing the two silently truncates."
  (is (eq :long-long (objc::node-for-fli-type :long)))
  (is (eq :ulong-long (objc::node-for-fli-type '(:unsigned :long))))
  (is (= 4 (objc::node-size-and-alignment :long)))
  (is (= 8 (objc::node-size-and-alignment (objc::node-for-fli-type :long)))))

(test type-descriptors-map-both-ways
  (is (eq :id (objc::node-for-fli-type 'objc:objc-object-pointer)))
  (is (eq :class (objc::node-for-fli-type 'objc:objc-class)))
  (is (eq :sel (objc::node-for-fli-type 'objc:sel)))
  (is (eq :cstring (objc::node-for-fli-type 'objc:objc-c-string)))
  (is (eq :bool (objc::node-for-fli-type 'objc:objc-c++-bool)))
  (is (eq :void (objc::node-for-fli-type 'objc:objc-unknown))
      "the manual says objc-unknown is an alias for :void")
  (is (equal '(:struct cocoa:ns-rect)
             (objc::fli-type-for-node (objc::node-for-fli-type '(:struct cocoa:ns-rect))))))

(test unknown-fli-type-signals
  (signals objc::unsupported-type-encoding (objc::node-for-fli-type 'no-such-type))
  (signals objc::unsupported-type-encoding (objc::node-for-fli-type '(:struct no-such-struct))))

;;; Typedefs -----------------------------------------------------------------

(test define-objc-typedef-registers-a-usable-type
  "DEFINE-OBJC-TYPEDEF registered its name and then nothing consulted the
table, so the macro appeared to work and the first use of the type failed as
unknown."
  (eval '(objc:define-objc-typedef (typedef-test-count
                                    (:foreign-name "TypedefTestCount"))
          :int))
  (is (eq :int (objc::node-for-fli-type 'typedef-test-count)))
  (is (= 4 (objc::node-size-and-alignment
            (objc::node-for-fli-type 'typedef-test-count)))))

(test define-objc-typedef-with-an-explicit-c-type
  "The manual: when :C-TYPE is given it is used as the definition and TYPE and
:FOREIGN-NAME are ignored."
  (eval '(objc:define-objc-typedef (typedef-test-alias
                                    (:foreign-name "ignored")
                                    (:c-type :double))
          :int))
  (is (eq :double (objc::node-for-fli-type 'typedef-test-alias))))

;;; Struct return ABI -------------------------------------------------------

(test stret-policy-is-measured-not-assumed
  "Whether a large structure result needs objc_msgSend_stret is decided by
whether that function exists, which differs by architecture and is read from
libobjc rather than chosen by a read-time conditional.

On arm64 the symbol is absent -- a large structure comes back through x8 from
plain objc_msgSend -- so nothing should ever select the _stret path.  On x86-64
the symbol is present and anything over 16 bytes must take it, because
objc_msgSend cannot perform an sret call: the hidden result pointer displaces
the receiver into the wrong register."
  (if (not (runtime-available-p))
      (skip "Objective-C runtime not available")
      (let ((cgrect (objc::parse-type "{CGRect={CGPoint=dd}{CGSize=dd}}"))
            (nsrange (objc::parse-type "{_NSRange=QQ}")))
        (is (= 32 (objc::node-size-and-alignment cgrect)))
        (is (= 16 (objc::node-size-and-alignment nsrange)))
        (cond
          ((null objc::*msgsend-stret-address*)
           ;; arm64: no such entry point, so nothing may ask for it.
           (is-false (objc::stret-required-p cgrect))
           (is-false (objc::stret-required-p nsrange))
           (is-false (objc::stret-required-p :id)))
          (t
           ;; x86-64: over sixteen bytes goes through _stret, at or under does not.
           (is-true (objc::stret-required-p cgrect))
           (is-false (objc::stret-required-p nsrange))
           (is-false (objc::stret-required-p :id)))))))

(test struct-returns-work-whichever-entry-point-is-used
  "The point of the policy, exercised end to end.  CGRect is 32 bytes and is on
the _stret side of the line on x86-64; NSRange is 16 and is not."
  (if (not (runtime-available-p))
      (skip "Objective-C runtime not available")
      (let ((value (objc:invoke "NSValue" "valueWithRect:" #(1d0 2d0 30d0 40d0)))
            (string (objc:invoke "NSString" "stringWithUTF8String:" "hello world")))
        (is (equalp #(1d0 2d0 30d0 40d0) (objc:invoke value "rectValue"))
            "a 32-byte structure result")
        (is (equal '(6 . 5) (objc:invoke string "rangeOfString:" "world"))
            "a 16-byte structure result"))))
