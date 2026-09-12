;;;; objc.asd
;;;;
;;;; Three systems, one file.  #:objc is the OBJC and COCOA packages -- a
;;;; reimplementation of the LispWorks Objective-C interface for SBCL on macOS.
;;;; #:objc/test is the FiveAM suite.  #:objc/examples is every worked example
;;;; from the LispWorks manual, ported; it is a separate system because half of
;;;; it opens windows, and nothing that merely uses the library should have to
;;;; load AppKit.

(asdf:defsystem #:objc
  :description "The LispWorks OBJC and COCOA interface, reimplemented for SBCL on macOS."
  :long-description
  "A source-compatible reimplementation of the interface documented in the
LispWorks Objective-C and Cocoa Interface User Guide and Reference Manual: the
packages are literally named OBJC and COCOA, the exported symbols have the
LispWorks names and lambda lists, and code written against LispWorks 8.1 is
intended to load and run unchanged.

Dispatch is dynamic.  A method's type encoding is read from the Objective-C
runtime, parsed, and turned into a compiled trampoline that calls objc_msgSend
through one exact non-variadic signature; the trampolines are memoized, so the
compiler runs once per distinct signature and never again.  Objective-C classes
defined from Lisp get real IMPs built the same way in the other direction, so a
Lisp method can take and return C structs by value like any other."
  :author "Matthew Kennedy <burnsidemk@gmail.com>"
  :maintainer "Matthew Kennedy <burnsidemk@gmail.com>"
  :mailto "burnsidemk@gmail.com"
  :license "MIT"
  :version "0.4.1"
  :homepage "https://github.com/lispnik/objc"
  :source-control (:git "https://github.com/lispnik/objc.git")
  :bug-tracker "https://github.com/lispnik/objc/issues"
  :serial t
  ;; No cffi-libffi and no cffi-grovel, so the build needs no C toolchain.
  ;; CFFI cannot express a struct passed or returned by value without libffi --
  ;; FOREIGN-FUNCALL-POINTER signals COMPILED-PROGRAM-ERROR and DEFCALLBACK
  ;; signals CASE-FAILURE -- and libffi cannot make an Apple arm64 variadic
  ;; call, which -[NSString stringWithFormat:] needs.  sb-alien does both.
  ;; See src/abi.lisp, which is the only file allowed to know that.
  :depends-on (#:cffi #:alexandria #:closer-mop #:bordeaux-threads
               #:trivial-features #:float-features)
  :components ((:module "src"
                :serial t
                :components
                ((:file "package")
                 (:file "conditions")
                 (:file "library")
                 (:file "runtime")
                 (:file "encoding")
                 (:file "types")
                 ;; The implementation seam. abi.lisp is sb-alien; abi-ecl
                 ;; is ECL's dynamic FFI, with a narrower reach.
                 #+sbcl (:file "abi")
                 #+ecl (:file "abi-ecl")
                 (:file "selectors")
                 (:file "classes")
                 (:file "dispatch")
                 (:file "convert")
                 (:file "invoke")
                 (:file "memory")
                 (:file "struct")
                 (:file "protocol")
                 (:file "object")
                 (:file "class-def")
                 (:file "method-def")
                 (:file "root")
                 (:file "cocoa")
                 (:file "runloop")
                 (:file "blocks")
                 (:file "init"))))
  :in-order-to ((test-op (test-op #:objc/test))))

(asdf:defsystem #:objc/uikit
  :description "The dozen conveniences a UIKit interface in Lisp keeps reaching for."
  :author "Matthew Kennedy <burnsidemk@gmail.com>"
  :license "MIT"
  :version "0.4.1"
  ;; Loads wherever OBJC does; the classes it names exist only on iOS.  A
  ;; sibling of COCOA rather than part of OBJC, whose exports are the
  ;; LispWorks ones and nothing else.
  :depends-on (#:objc)
  :components ((:module "src"
                :components ((:file "uikit")))))

(asdf:defsystem #:objc/examples
  :description "The LispWorks Objective-C manual's examples, ported."
  :author "Matthew Kennedy <burnsidemk@gmail.com>"
  :maintainer "Matthew Kennedy <burnsidemk@gmail.com>"
  :mailto "burnsidemk@gmail.com"
  :license "MIT"
  :version "0.4.1"
  :homepage "https://github.com/lispnik/objc"
  :serial t
  ;; BABEL is named rather than relied on through CFFI: a few examples convert
  ;; octets to text, and depending on a transitive dependency for that is how a
  ;; build breaks when the intermediate stops needing it.
  :depends-on (#:objc #:babel)
  :components ((:module "examples"
                :serial t
                :components
                ((:file "package")
                 (:file "manual")
                 (:file "appkit")
                 (:file "area-calculator")
                 (:file "pdf-view")
                 (:file "movie-view")
                 (:file "web-kit")
                 (:file "canvas")
                 (:file "vision")
                 (:file "status-item")
                 (:file "gcd")
                 (:file "xpc")
                 (:file "menu-bar-lisp")
                 (:file "url-session")
                 (:file "memory")
                 (:file "notifications")
                 (:file "geometry")
                 (:file "strings")
                 (:file "task")
                 (:file "plugin")
                 (:file "browser")
                 (:file "undo")
                 (:file "natural-language")
                 (:file "core-image")
                 (:file "file-watcher")
                 (:file "kvo")
                 (:file "data-detector")
                 (:file "predicates")
                 (:file "pdf-document")
                 (:file "thumbnail")
                 (:file "workspace")
                 (:file "metal")
                 (:file "scene-kit")
                 (:file "audio")
                 (:file "shader")
                 (:file "map")
                 (:file "speech")
                 (:file "file-coordinator")
                 (:file "collections")
                 (:file "standalone")))))

(asdf:defsystem #:objc/test
  :description "Test suite for objc."
  :author "Matthew Kennedy <burnsidemk@gmail.com>"
  :maintainer "Matthew Kennedy <burnsidemk@gmail.com>"
  :mailto "burnsidemk@gmail.com"
  :license "MIT"
  :version "0.4.1"
  :homepage "https://github.com/lispnik/objc"
  :serial t
  :depends-on (#:objc #:objc/uikit #:objc/examples #:fiveam)
  :components ((:module "test"
                :serial t
                :components
                ((:file "package")
                 (:module "oracle"
                  :components ((:file "answers")))
                 (:file "encoding-tests")
                 (:file "types-tests")
                 (:file "runtime-tests")
                 (:file "invoke-tests")
                 (:file "memory-tests")
                 (:file "cocoa-tests")
                 (:file "class-tests")
                 (:file "method-tests")
                 (:file "block-tests")
                 (:file "example-tests")
                 (:file "manual-tests")
                 (:file "gui-tests")
                 (:file "seam-tests")
                 (:file "uikit-tests")
                 ;; The ECL backend's own obligations: how an aggregate is
                 ;; described to the dynamic FFI, and that the two paths a
                 ;; phone has -- dynamic calls and libffi closures -- carry a
                 ;; structure both ways. Nothing to assert on SBCL, where
                 ;; abi.lisp hands the whole question to the C compiler.
                 #+ecl (:file "abi-ecl-tests")
                 (:file "oracle-tests")
                 (:file "thread-tests")
                 ;; Image dumping, which ECL does not do at all: there is no
                 ;; SAVE-LISP-AND-DIE, and the platform this backend exists for
                 ;; forbids re-executing a dumped image in the first place.
                 ;; Excluded rather than skipped, because the file cannot be
                 ;; read there -- SB-EXT does not exist.
                 #+sbcl (:file "dump-tests"))))
  ;; FIVEAM:RUN! prints its report and returns NIL when anything failed, and
  ;; ASDF discards what a TEST-OP returns.  Reporting by return value is how a
  ;; CI run goes green on a suite that failed, so signal instead.
  :perform (test-op (o c)
             (declare (ignore o c))
             (unless (uiop:symbol-call :objc/test '#:run-tests)
               (error "The objc test suite failed."))))
