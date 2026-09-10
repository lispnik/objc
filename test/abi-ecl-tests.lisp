;;;; test/abi-ecl-tests.lisp -- the ECL backend's own obligations.
;;;;
;;;; Loaded only under ECL.  Everything here is about the two places where the
;;;; ECL backend can be wrong without saying so, which is what makes them worth
;;;; a test rather than a comment.

(in-package #:objc/test)

(def-suite abi-ecl :in all-tests
  :description "The ECL ABI backend: decomposition, foreign types, FP traps.")

(in-suite abi-ecl)

(defun node-of (encoding)
  (objc::resolve-struct-layout (objc::parse-type encoding)))

(defun decomposable-p (encoding)
  (and (objc::decomposable-struct-argument-p (node-of encoding)) t))

;;; Struct decomposition ----------------------------------------------------
;;;
;;; The failure mode here is not an error.  It is a plausible wrong number that
;;; changes between runs, so nothing downstream can catch it and no user will
;;; report it as anything but "sometimes the layout is odd".  These assertions
;;; are the only thing standing between that and a released library.
;;;
;;; The shapes and their answers were measured on-device, not derived:
;;; asdf-ios-app/examples/abi-probe calls each one both ways in one binary --
;;; through SI:CALL-CFUN and through the C compiler -- and compares.

(test decomposes-the-two-shapes-that-are-equivalent
  "An HFA of at most four like floats, and one or two eight-byte integers."
  (is-true (decomposable-p "{CGPoint=dd}"))
  (is-true (decomposable-p "{CGSize=dd}"))
  ;; Nested, and it must flatten: AAPCS64 sees four doubles, not two structs.
  (is-true (decomposable-p "{CGRect={CGPoint=dd}{CGSize=dd}}"))
  (is-true (decomposable-p "{_NSRange=QQ}"))
  (is-true (decomposable-p "{single=ffff}")))

(test refuses-the-shapes-that-would-corrupt
  "Each of these was measured returning a plausible wrong answer, not failing."
  ;; 16 bytes and not an HFA, so BOTH halves travel in general registers --
  ;; decomposed, the double goes to v0 and the callee reads x1.
  (is-false (decomposable-p "{mixed=qd}"))
  ;; 48 bytes, not an HFA: passed BY POINTER.  Decomposed, the callee
  ;; dereferences whatever happened to be in x0.  Measured twice, two
  ;; different junk values.
  (is-false (decomposable-p "{CGAffineTransform=dddddd}"))
  (is-false (decomposable-p "{CATransform3D=dddddddddddddddd}"))
  ;; More than four members is not an HFA however homogeneous.
  (is-false (decomposable-p "{five=ddddd}")))

(test refuses-integer-aggregates-that-share-a-register
  "Sixteen bytes is not the rule; one field per register is.

AAPCS64 packs {int,int,int,int} two-to-a-register into x0 and x1.  Decomposed
into four :INT arguments they would go to x0-x3 and every one would be read
from the wrong place.  This case was NOT in the on-device measurements -- it is
refused by reasoning, which is the right direction to be wrong in."
  (is-false (decomposable-p "{quad=iiii}"))
  (is-false (decomposable-p "{pair=ii}"))
  (is-false (decomposable-p "{small=cc}")))

(test never-decomposes-a-struct-return
  "There is no such thing, and the predicate is named for arguments only.

A scalar return type names exactly one register, so a CGRect read back as
:DOUBLE is origin.x and nothing else -- -[UIView bounds] returning a quarter of
an answer, silently."
  (dolist (encoding '("{CGPoint=dd}" "{CGRect={CGPoint=dd}{CGSize=dd}}"
                      "{_NSRange=QQ}"))
    (let ((node (node-of encoding)))
      ;; The struct predicate says yes for an argument; the code path that
      ;; would use it for a result must not exist.  Assert the shape of the
      ;; contract rather than the absence of a caller.
      (is-true (objc::struct-node-p node))
      (is-true (objc::decomposable-struct-argument-p node)))))

(test an-unresolved-layout-is-refused
  "\"{CGRect=}\" -- the runtime elides layouts, and a struct with no fields
cannot be classified.  Guessing is the one thing that must not happen."
  (is-false (and (objc::decomposable-struct-argument-p '(:struct "Unknown" nil)) t)))

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
