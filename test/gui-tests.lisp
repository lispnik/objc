;;;; test/gui-tests.lisp -- the AppKit examples.
;;;;
;;;; Gated on there being a window server.  [NSScreen mainScreen] is nil in a
;;;; process with no display, which is what a CI runner looks like, and every
;;;; test here skips rather than fails in that case.  The skip count is printed
;;;; by the suite; a green run on a headless machine is a green run of fewer
;;;; checks, not a green run of these.

(in-package #:objc/test)

(def-suite gui :in all-tests
  :description "The AppKit examples.  Skipped without a window server.")

(in-suite gui)

(defmacro with-gui (&body body)
  `(cond ((not (ensure-initialized)) (skip "Objective-C runtime not available"))
         ((not (objc.runloop:window-server-p)) (skip "no window server"))
         (t ,@body)))

;;; Windows ------------------------------------------------------------------

(test a-window-can-be-created-and-shown
  "The whole reason src/abi.lisp masks floating point traps: without that, this
raises FLOATING-POINT-INVALID-OPERATION and the process dies with SIGFPE before
any window exists."
  (with-gui
    (let ((window (objc/examples::make-window :title "objc test"
                                              :rect #(200d0 200d0 320d0 200d0))))
      (objc/examples::show-window window :seconds 0.2d0)
      (is-true (objc:invoke-bool window "isVisible"))
      (is-false (cffi:null-pointer-p (objc:invoke window "screen"))
                "the window is on a real screen")
      (let ((frame (objc:invoke window "frame")))
        (is (= 200d0 (aref frame 0)))
        (is (= 320d0 (aref frame 2))))
      (objc:invoke window "close"))))

(test the-main-thread-is-thread-one
  "AppKit needs thread 1 and SBCL's REPL already runs there, which is why
LispWorks' MP:INITIALIZE-MULTIPROCESSING has no equivalent here."
  (is-true (objc.runloop:main-thread-p)))

;;; The area calculator ------------------------------------------------------

(test the-area-calculator-computes
  "The manual's :OBJC-INSTANCE-VARS example: the fields are stored in the
controller's Objective-C instance variables and the button's action is a Lisp
method."
  (with-gui
    (multiple-value-bind (controller window) (objc/examples::build-area-calculator)
      (unwind-protect
           (progn
             (objc:invoke (objc:objc-object-pointer controller) "compute:" nil)
             (is (= 42.0 (objc:invoke (objc:objc-object-var-value controller "areaField")
                                      "floatValue")))
             (objc:invoke (objc:objc-object-var-value controller "widthField")
                          "setStringValue:" "3")
             (objc:invoke (objc:objc-object-var-value controller "heightField")
                          "setStringValue:" "5")
             (objc:invoke (objc:objc-object-pointer controller) "compute:" nil)
             (is (= 15.0 (objc:invoke (objc:objc-object-var-value controller "areaField")
                                      "floatValue"))))
        (objc:invoke window "close")))))

(test the-area-controller-has-its-instance-variables
  (with-gui
    (let ((controller (make-instance 'objc/examples::area-controller)))
      (dolist (name '("widthField" "heightField" "areaField"))
        (is (cffi:pointerp (objc:objc-object-var-value controller name)))))))

;;; PDFKit and AVKit ---------------------------------------------------------

(test the-pdf-view-example-builds-a-pdf-view
  "Ported nearly unchanged: PDFKit is current, so the setDisplayMode: /
setAutoScales: / setBackgroundColor: chain is exactly the manual's."
  (with-gui
    (let ((view (objc/examples::make-pdf-view #(0d0 0d0 400d0 300d0))))
      (is (string= "PDFView" (objc:objc-class-name (objc:invoke view "class"))))
      ;; -autoScales reads back NO until the view has a document, so assert the
      ;; setting that does stick.
      (is (= objc/examples::+pdf-display-single-page-continuous+
             (objc:invoke view "displayMode"))))))

(test the-movie-view-example-builds-an-av-player-view
  (with-gui
    (let ((view (objc/examples::make-movie-view #(0d0 0d0 400d0 300d0))))
      (is (string= "AVPlayerView" (objc:objc-class-name (objc:invoke view "class")))))))

;;; WebKit: a Lisp class acting as a Cocoa delegate --------------------------

(test the-web-kit-delegate-conforms-and-responds
  (with-gui
    (let ((delegate (objc:objc-object-pointer
                     (make-instance 'objc/examples::web-kit-test-delegate))))
      (is-true (objc:invoke-bool delegate "conformsToProtocol:"
                                 (objc::%objc-get-protocol "WKNavigationDelegate")))
      (is-true (objc:invoke-bool delegate "respondsToSelector:"
                                 (objc:coerce-to-selector "webView:didFinishNavigation:")))
      (is-true (objc:invoke-bool delegate "respondsToSelector:"
                                 (objc:coerce-to-selector
                                  "webView:didStartProvisionalNavigation:"))))))

(test cocoa-calls-back-into-a-lisp-method
  "The point of the whole exercise: WKWebView knows nothing about Lisp, and it
calls a method whose implementation is a Lisp closure.  Loaded from a string
rather than the network, so the test is hermetic."
  (with-gui
    (let* ((window (objc/examples::make-window :title "wk test"
                                               :rect #(200d0 200d0 400d0 300d0)))
           (view (objc/examples::make-web-view #(0d0 0d0 400d0 300d0)))
           (delegate (make-instance 'objc/examples::web-kit-test-delegate)))
      (unwind-protect
           (progn
             (objc:invoke view "setNavigationDelegate:" (objc:objc-object-pointer delegate))
             (objc/examples::add-subview window view)
             (objc:invoke view "loadHTMLString:baseURL:"
                          "<html><head><title>Hello</title></head><body>hi</body></html>"
                          nil)
             (objc.runloop:pump-events
              :max-seconds 10d0
              :until (lambda () (objc/examples::web-kit-test-delegate-finished-p delegate)))
             (is-true (objc/examples::web-kit-test-delegate-finished-p delegate)
                      "-webView:didFinishNavigation: reached the Lisp method")
             ;; The document title is published a moment after the navigation
             ;; finishes, so keep pumping for it rather than racing.
             (objc.runloop:pump-events
              :max-seconds 5d0
              :until (lambda ()
                       (let ((view (objc/examples::web-kit-test-delegate-web-view delegate)))
                         (when view
                           (setf (objc/examples::web-kit-test-delegate-title delegate)
                                 (objc:invoke-into 'string view "title")))
                         (let ((title (objc/examples::web-kit-test-delegate-title delegate)))
                           (and (stringp title) (plusp (length title)))))))
             (is (string= "Hello"
                          (objc/examples::web-kit-test-delegate-title delegate))
                 "the NSString result was converted to a Lisp string"))
        (objc:invoke window "close")))))

;;; The application delegate from section 3.4.1 ------------------------------

(test the-application-delegate-class-exists
  (with-gui
    (let ((delegate (make-instance 'objc/examples::application-delegate)))
      (is-true (objc:can-invoke-p (objc:objc-object-pointer delegate)
                                  "applicationDidFinishLaunching:"))
      (is-true (objc:can-invoke-p (objc:objc-object-pointer delegate)
                                  "applicationShouldTerminateAfterLastWindowClosed:")))))

;;; Pumping ------------------------------------------------------------------

(test pumping-with-a-window-on-screen-terminates
  "The regression test for a hang that looked exactly like the bug it was
meant to fix.

PUMP-EVENTS waits for one event and then takes whatever else is already queued.
Draining \"until the queue is empty\" cannot work while a window is on screen:
dispatching an event routinely makes AppKit enqueue more -- a window update, a
display, a cursor change -- so the inner loop never finished and the first click
on a window beachballed the process.  It is bounded now."
  (with-gui
    (let ((window (objc/examples::make-window :title "pump test"
                                              :rect #(400d0 400d0 240d0 160d0))))
      (unwind-protect
           (progn
             (objc/examples::show-window window :seconds 0.2d0)
             (let ((elapsed (objc.runloop:pump-events :seconds 0.02d0 :max-seconds 0.5d0)))
               (is (numberp elapsed))
               (is (< elapsed 5d0) "pumping returned rather than hanging")))
        (objc:invoke window "close")))))

(test pump-events-honours-its-bounds
  (with-gui
    ;; Neither bound: one pass.
    (is (< (objc.runloop:pump-events :seconds 0.02d0) 1d0))
    ;; UNTIL alone stops as soon as it is true.
    (let ((passes 0))
      (objc.runloop:pump-events :seconds 0.01d0 :max-seconds 5d0
                                :until (lambda () (>= (incf passes) 3)))
      (is (= 3 passes)))
    ;; MAX-SECONDS alone keeps looping rather than returning after one pass,
    ;; which is what makes (pump-events :max-seconds 30d0) usable from a REPL.
    (let ((elapsed (objc.runloop:pump-events :seconds 0.02d0 :max-seconds 0.3d0)))
      (is (>= elapsed 0.3d0))
      (is (< elapsed 5d0)))))

(test a-click-reaches-a-lisp-method
  "The action half of a click: NSButton -> its target -> a Lisp IMP.
-performClick: exercises the same target/action path a real click takes once
-sendEvent: has routed it to the button."
  (with-gui
    (multiple-value-bind (controller window) (objc/examples::build-area-calculator)
      (unwind-protect
           (let ((button (objc:invoke
                          (objc:invoke (objc:invoke window "contentView") "subviews")
                          "lastObject")))
             (is (string= "NSButton" (objc:objc-class-name (objc:invoke button "class"))))
             (is (cffi:pointer-eq (objc:invoke button "target")
                                  (objc:objc-object-pointer controller)))
             (is (string= "compute:" (objc:selector-name (objc:invoke button "action"))))
             (objc:invoke button "performClick:" nil)
             (objc.runloop:pump-events :seconds 0.02d0 :max-seconds 0.3d0)
             (is (= 42.0 (objc:invoke (objc:objc-object-var-value controller "areaField")
                                      "floatValue"))))
        (objc:invoke window "close")))))
