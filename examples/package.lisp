;;;; examples/package.lisp
;;;;
;;;; The examples are ported from the ones LispWorks ships, and they are kept as
;;;; close to the originals as the platform allows so that they double as
;;;; evidence that LispWorks source really does run here unchanged.
;;;;
;;;; Two of those originals use LispWorks' FLI.  There is no FLI on SBCL, so a
;;;; small #:fli package below provides exactly the handful of operators the
;;;; examples touch.  It lives HERE and not in #:objc on purpose: the
;;;; Objective-C manual documents these names as part of the FLI, not the OBJC
;;;; package, and exporting them from the library would be inventing an API that
;;;; nothing promises to keep.

(defpackage #:fli
  (:use #:cl)
  (:export #:foreign-slot-value
           #:pointer-eq
           #:dereference
           #:size-of
           #:register-module
           #:with-dynamic-foreign-objects))

(defpackage #:objc/examples
  (:use #:cl #:objc)
  (:export #:run-manual-examples
           #:run-until-closed
           #:stop-running
           #:diagnose-close
           #:test-area-calculator #:test-pdf-kit #:test-movie-view #:test-web-kit
           ;; The live drawing canvas (examples/canvas.lisp).
           #:test-canvas #:run-canvas #:animate-canvas #:make-canvas #:refresh
           #:*canvas-draw* #:*current-canvas*
           #:set-color #:fill-rect #:fill-oval #:stroke-oval #:draw-line
           #:draw-default #:draw-clock
           ;; Vision OCR (examples/vision.lisp).
           #:ocr-image #:text-image #:test-ocr #:read-barcodes
           ;; A menu-bar item (examples/status-item.lisp).
           #:make-status-item #:run-status-item #:remove-status-item
           #:*status-count* #:*status-running*
           ;; Grand Central Dispatch (examples/gcd.lisp).
           #:global-queue #:serial-queue #:with-serial-queue #:dispatch-sync
           #:dispatch-apply #:parallel-map #:concurrent-blocks-supported-p
           #:dispatch-group #:make-dispatch-group #:group-async #:group-wait
           #:with-dispatch-group #:test-gcd #:report-gcd
           ;; NSURLSession (examples/url-session.lisp).
           #:fetch #:fetch-async #:fetch-all #:serial-session #:with-url-session
           #:ns-data-to-bytes #:ns-data-to-string #:response-status
           #:test-url-session #:report-url-session
           ;; NaturalLanguage (examples/natural-language.lisp).
           #:language-of #:tokenize #:tag-text #:entities #:parts-of-speech #:lemmas
           #:word-embedding #:word-distance #:neighbours #:class-selectors
           #:test-natural-language #:report-natural-language
           ;; Core Image (examples/core-image.lisp).
           #:apply-filter #:filter-names #:crop #:scale #:render-png #:png-p
           #:rgba #:objc-value #:ci-format #:checkerboard #:gradient #:qr-code
           #:test-core-image #:report-core-image
           ;; Dispatch sources (examples/file-watcher.lisp).
           #:watch #:unwatch #:with-watch #:watcher #:watcher-live
           #:every-seconds #:stop-repeating
           #:test-file-watcher #:report-file-watcher))

(in-package #:fli)

(defun foreign-slot-value (object slot-name)
  "Read SLOT-NAME from a structure the Objective-C bridge handed us."
  (objc::typed-pointer-slot object slot-name))

(defun (setf foreign-slot-value) (value object slot-name)
  (setf (objc::typed-pointer-slot object slot-name) value))

(defun pointer-eq (a b)
  (cffi:pointer-eq a b))

(defun dereference (pointer &key (type :pointer) (index 0))
  (cffi:mem-aref pointer type index))

(defun size-of (type)
  (objc::node-size-and-alignment (objc::node-for-fli-type type)))

(defun register-module (path &rest args)
  (declare (ignore args))
  (objc::register-module path :errorp nil))

(defmacro with-dynamic-foreign-objects (bindings &body body)
  "Allocate foreign objects for the duration of BODY.
Each binding is (var type), where TYPE is an Objective-C type descriptor."
  `(cffi:with-foreign-objects
       ,(loop for (var type) in bindings
              collect `(,var :uint8 ,(objc::node-size-and-alignment
                                      (objc::node-for-fli-type type))))
     ,@body))
