;;;; test/seam-tests.lisp -- the implementation seam stays a seam.

(in-package #:objc/test)

(def-suite seam :in all-tests
  :description "Implementation-specific code stays in one file.")

(in-suite seam)

(defparameter +seam-file+ "abi.lisp"
  "The one source file allowed to use sb-alien and sb-sys.")

(defparameter +seam-exceptions+ '("runloop.lisp")
  "runloop.lisp uses SB-THREAD:MAIN-THREAD-P, which is a threading question
rather than a foreign-ABI one and has no portable equivalent.")

(test only-abi-lisp-knows-about-sb-alien
  "src/abi.lisp is the only file that may mention sb-alien: or sb-sys:.

Everything implementation-specific about calling Objective-C lives there --
building trampolines, building IMPs, masking floating point traps -- so that
porting this library to another Lisp is one file's work rather than an
archaeology exercise.  A seam nobody checks stops being a seam, so this checks."
  (let ((offenders '()))
    (dolist (path (directory (asdf:system-relative-pathname :objc "src/*.lisp")))
      (let ((name (file-namestring path)))
        (unless (or (string= name +seam-file+)
                    (member name +seam-exceptions+ :test #'string=))
          (with-open-file (stream path)
            (loop for line = (read-line stream nil)
                  for number from 1
                  while line
                  when (or (search "sb-alien:" line) (search "sb-sys:" line))
                    do (push (format nil "~A:~D: ~A" name number (string-trim " " line))
                             offenders))))))
    (is (null offenders)
        "sb-alien or sb-sys outside src/~A:~%~{  ~A~%~}" +seam-file+ (reverse offenders))))

(test every-exported-symbol-is-documented
  "A symbol exported from OBJC or COCOA is a promise of LispWorks source
compatibility, and someone porting code will ask DESCRIBE what it is."
  (let ((undocumented '()))
    (dolist (package '(:objc :cocoa))
      (do-external-symbols (symbol (find-package package))
        (unless (or (documentation symbol 'function)
                    (documentation symbol 'variable)
                    (documentation symbol 'type)
                    (documentation symbol 'structure)
                    (and (find-class symbol nil) (documentation (find-class symbol) t)))
          (push symbol undocumented))))
    (is (null undocumented) "undocumented exported symbols: ~S" (reverse undocumented))))

(test the-exported-surface-is-exactly-the-lispworks-one
  "42 symbols in OBJC and 11 in COCOA.  The manual has 43 OBJC reference pages,
but OBJC-OBJECT-POINTER gets two of them -- one for the reader, one for the FLI
type -- and it is one symbol.

Adding to these lists is not a small decision: it turns an implementation detail
into a compatibility promise nothing else keeps."
  (let ((objc-count 0) (cocoa-count 0))
    (do-external-symbols (s (find-package :objc)) (declare (ignore s)) (incf objc-count))
    (do-external-symbols (s (find-package :cocoa)) (declare (ignore s)) (incf cocoa-count))
    (is (= 42 objc-count))
    (is (= 11 cocoa-count))))

(test no-package-exports-an-undefined-name
  "An exported symbol with nothing behind it is a broken promise that nothing
else catches: it compiles, it loads, and it fails only when someone calls it.

This caught OBJC/EXAMPLES:RUN-MANUAL-EXAMPLES, which was listed in the package's
export list and never defined."
  (let ((missing '()))
    (dolist (package '(:objc :cocoa :objc.runloop :objc/examples))
      (let ((package (find-package package)))
        (when package
          (do-external-symbols (symbol package)
            (unless (or (fboundp symbol)
                        (boundp symbol)
                        (macro-function symbol)
                        (find-class symbol nil)
                        ;; The FLI type descriptors are names, not definitions;
                        ;; they carry documentation and nothing else.
                        (documentation symbol 'type))
              (push (format nil "~A:~A" (package-name package) (symbol-name symbol))
                    missing))))))
    (is (null missing) "exported but undefined: ~{~A~^, ~}" (reverse missing))))
