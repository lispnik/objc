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

(defparameter +minimum-source-files+ 20
  "A floor under the file count src/ must produce, well below the real number.

Not a count to keep current -- it is a tripwire.  A test that greps a directory
reports \"no offenders\" just as happily when the directory came back empty, and
this project has already shipped one that did exactly that for want of this
line.  Deliberately loose: it should fire when the scan finds nothing, and never
because somebody added or removed a file.")

(test only-abi-lisp-knows-about-sb-alien
  "src/abi.lisp is the only file that may mention sb-alien: or sb-sys:.

Everything implementation-specific about calling Objective-C lives there --
building trampolines, building IMPs, masking floating point traps -- so that
porting this library to another Lisp is one file's work rather than an
archaeology exercise.  A seam nobody checks stops being a seam, so this checks.

UIOP:DIRECTORY-FILES rather than DIRECTORY on a merged wild pathname.
ASDF:SYSTEM-RELATIVE-PATHNAME quotes the wildcard -- \"src/*.lisp\" comes back as
#P\"/.../src/\\\\*.lisp\", naming one file that does not exist -- so DIRECTORY
returned NIL and this test passed by scanning nothing.  Verified by putting
sb-alien: into src/cocoa.lisp: the test was green.  A seam nobody checks stops
being a seam, and so does one whose check enumerates an empty list.

Hence the count assertion, which comes FIRST.  \"No offenders in nothing\" is a
true statement and a useless one, and it is what this reported for however long
the bug was there.  Any test that draws its evidence from the filesystem needs a
floor under it, or the day the directory moves is the day it stops testing and
does not say so."
  (let* ((paths (uiop:directory-files
                 (asdf:system-relative-pathname :objc "src/") "*.lisp"))
         (offenders '()))
    (is (<= +minimum-source-files+ (length paths))
        "expected at least ~D files in src/, found ~D -- this test is scanning ~
nothing and its other assertion is vacuous"
        +minimum-source-files+ (length paths))
    (dolist (path paths)
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
    ;; ECL discards (SETF (DOCUMENTATION x 'FUNCTION)) -- measured on 26.5.5,
    ;; for an ordinary DEFUN as well as for a structure accessor, where the
    ;; setter returns the string and DOCUMENTATION then answers NIL. The
    ;; library attaches a docstring that way for the one exported name
    ;; DEFSTRUCT gives nowhere to put one, so the symbol is documented in the
    ;; source and unreachable at run time on that implementation. Asserted
    ;; where it can be, rather than deleted or quietly weakened everywhere.
    #+ecl (setf undocumented (remove 'objc:objc-block-pointer undocumented))
    (is (null undocumented) "undocumented exported symbols: ~S" (reverse undocumented))))

(defparameter +lispworks-objc-symbols+
  '("ENSURE-OBJC-INITIALIZED"
    "INVOKE" "INVOKE-BOOL" "INVOKE-INTO" "CAN-INVOKE-P" "CURRENT-SUPER"
    "ALLOC-INIT-OBJECT" "DESCRIPTION" "TRACE-INVOKE" "UNTRACE-INVOKE"
    "COERCE-TO-OBJC-CLASS" "OBJC-CLASS-NAME" "COERCE-TO-SELECTOR" "SELECTOR-NAME"
    "OBJC-CLASS-METHOD-SIGNATURE"
    "OBJC-OBJECT-POINTER" "OBJC-CLASS" "SEL" "OBJC-C-STRING" "OBJC-BOOL"
    "OBJC-C++-BOOL" "OBJC-UNKNOWN" "OBJC-AT-QUESTION-MARK"
    "RETAIN" "RELEASE" "AUTORELEASE" "RETAIN-COUNT" "MAKE-AUTORELEASE-POOL"
    "WITH-AUTORELEASE-POOL"
    "NS-STRING-TO-STRING" "STRING-TO-NS-STRING"
    "STANDARD-OBJC-OBJECT" "DEFINE-OBJC-CLASS" "DEFINE-OBJC-METHOD"
    "DEFINE-OBJC-CLASS-METHOD" "DEFINE-OBJC-PROTOCOL" "DEFINE-OBJC-STRUCT"
    "DEFINE-OBJC-TYPEDEF"
    "OBJC-OBJECT-FROM-POINTER" "OBJC-OBJECT-VAR-VALUE" "OBJC-OBJECT-COPIED"
    "OBJC-OBJECT-DESTROYED")
  "The 42 symbols the LispWorks 8.1 manual documents in its OBJC package.

The manual has 43 reference pages: OBJC-OBJECT-POINTER gets two of them, one for
the reader function and one for the FLI type descriptor, and it is one symbol.")

(defparameter +sbcl-additions+
  '("DEFINE-OBJC-BLOCK-TYPE" "MAKE-OBJC-BLOCK" "FREE-OBJC-BLOCK" "WITH-OBJC-BLOCK"
    "CALL-OBJC-BLOCK" "OBJC-BLOCK" "OBJC-BLOCK-POINTER" "OBJC-BLOCK-LIVE-P")
  "Block creation, which LispWorks has no OBJC interface for at all.

There it lives in the FLI -- ALLOCATE-FOREIGN-BLOCK and
DEFINE-FOREIGN-BLOCK-CALLABLE-TYPE -- and there is no FLI here.  Exported from
OBJC rather than a sibling package because a block is Objective-C's own notion
and belongs beside INVOKE, and listed separately here so the line between what
LispWorks promises and what this library adds stays legible.")

(test the-exported-surface-is-the-lispworks-one-plus-the-block-api
  "OBJC exports the 42 documented LispWorks symbols and the 8 block symbols, and
COCOA exports 11.  Deliberately the exact sets rather than the counts: widening
the surface is a decision to write down, and a count would let the next
accidental export through as soon as someone adjusted the number to match."
  (flet ((exported (package)
           (sort (let ((names '()))
                   (do-external-symbols (symbol (find-package package))
                     (push (symbol-name symbol) names))
                   names)
                 #'string<)))
    (let ((expected (sort (append (copy-list +lispworks-objc-symbols+)
                                  (copy-list +sbcl-additions+))
                          #'string<))
          (actual (exported :objc)))
      (is (null (set-difference actual expected :test #'string=))
          "OBJC exports symbols on neither list: ~S"
          (set-difference actual expected :test #'string=))
      (is (null (set-difference expected actual :test #'string=))
          "OBJC no longer exports: ~S"
          (set-difference expected actual :test #'string=)))
    (is (= 11 (length (exported :cocoa))))))

(test no-package-exports-an-undefined-name
  "An exported symbol with nothing behind it is a broken promise that nothing
else catches: it compiles, it loads, and it fails only when someone calls it.

This caught OBJC/EXAMPLES:RUN-MANUAL-EXAMPLES, which was listed in the package's
export list and never defined.

A package that cannot be found FAILS here rather than being skipped.  It was a
WHEN, which meant a renamed or unloaded package quietly removed itself from the
test's scope -- the same shape as the seam test that spent its life scanning an
empty directory.  If a package on this list is genuinely gone, the list is what
should change, visibly."
  (let ((missing '())
        (unfound '()))
    (dolist (package '(:objc :cocoa :objc.runloop :objc/examples))
      (let ((found (find-package package)))
        (if (null found)
            (push package unfound)
          (do-external-symbols (symbol found)
            (unless (or (fboundp symbol)
                        (boundp symbol)
                        (macro-function symbol)
                        (find-class symbol nil)
                        ;; The FLI type descriptors are names, not definitions;
                        ;; they carry documentation and nothing else.
                        (documentation symbol 'type)
                        ;; A DEFINE-OBJC-STRUCT name is a real definition too --
                        ;; the docstring says (:struct name) is usable in INVOKE
                        ;; and DEFINE-OBJC-METHOD -- but it lives in a table
                        ;; rather than in any of the namespaces above, so
                        ;; without this the test calls an exported struct type
                        ;; a broken promise.  Found by exporting one.
                        (gethash symbol objc::*struct-encodings*))
              (push (format nil "~A:~A" (package-name found) (symbol-name symbol))
                    missing))))))
    (is (null unfound) "no such package, so it was not checked: ~{~A~^, ~}"
        (reverse unfound))
    (is (null missing) "exported but undefined: ~{~A~^, ~}" (reverse missing))))
