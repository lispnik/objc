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

;;; The demo entry points -----------------------------------------------------

(test every-demo-returns-its-window-first
  "Uniform so that RUN-UNTIL-CLOSED wraps straight around any of them."
  (with-gui
    (dolist (thunk (list (lambda () (objc/examples:test-area-calculator))
                         (lambda () (objc/examples:test-pdf-kit))
                         (lambda () (objc/examples:test-movie-view))))
      (let ((window (funcall thunk)))
        (unwind-protect
             (is (string= "NSWindow"
                          (objc:objc-class-name (objc:invoke window "class"))))
          (objc:invoke window "close"))))))


(test run-until-closed-uses-appkits-own-loop-and-returns-on-stop
  "RUN-UNTIL-CLOSED runs -[NSApplication runModalForWindow:] rather than
pumping by hand, and STOP-RUNNING ends it.

The reason is measurable, not stylistic: a hand-rolled
nextEventMatchingMask:/sendEvent: loop never gets to block, because AppKit
keeps a supply of AppKitDefined events coming.  It spins at 100% CPU
re-dispatching them, which makes a window sluggish rather than dead -- text
still goes in, but the machine works flat out for it.  This asserts the loop
idles instead."
  (with-gui
    (let ((window (objc/examples::make-window :title "modal test"
                                              :rect #(540d0 540d0 240d0 140d0))))
      (unwind-protect
           (progn
             (objc/examples::show-window window :seconds 0.1d0)
             ;; End the modal loop from a timer, standing in for a click on the
             ;; close button.
             ;; Grab the application on THIS thread: SHARED-APPLICATION refuses
             ;; to run off thread 1, which is the check working as intended.
             (let ((app (objc.runloop:shared-application)))
               (bt:make-thread
                (lambda ()
                  (sleep 1)
                  (objc:invoke app "performSelectorOnMainThread:withObject:waitUntilDone:"
                               (objc:coerce-to-selector "stopModal") nil nil))))
             (let ((cpu-before (get-internal-run-time))
                   (wall-before (get-internal-real-time)))
               (is-true (objc/examples:run-until-closed window))
               (let* ((cpu (/ (float (- (get-internal-run-time) cpu-before))
                              internal-time-units-per-second))
                      (wall (/ (float (- (get-internal-real-time) wall-before))
                               internal-time-units-per-second)))
                 (is (< wall 10d0) "returned when the loop was stopped")
                 (is (< (/ cpu wall) 0.5)
                     "idles rather than spinning: ~,1f% CPU" (* 100 (/ cpu wall))))))
        (objc:invoke window "close")))))

(test the-window-delegate-is-restored-afterwards
  (with-gui
    (let ((window (objc/examples::make-window :title "delegate test"
                                              :rect #(560d0 560d0 200d0 120d0))))
      (unwind-protect
           (progn
             (objc/examples::show-window window :seconds 0.1d0)
             (is (cffi:null-pointer-p (objc:invoke window "delegate")))
             (let ((app (objc.runloop:shared-application)))
               (bt:make-thread
                (lambda ()
                  (sleep 0.5)
                  (objc:invoke app "performSelectorOnMainThread:withObject:waitUntilDone:"
                               (objc:coerce-to-selector "stopModal") nil nil))))
             (objc/examples:run-until-closed window)
             (is (cffi:null-pointer-p (objc:invoke window "delegate"))
                 "the stopper delegate was removed again"))
        (objc:invoke window "close")))))

(test closing-the-window-ends-the-loop-and-leaves-it-valid
  "The close-button path, which the stopModal-from-a-timer test never touched.

NSWindow's -releasedWhenClosed defaults to YES, so clicking close DEALLOCATES
the window -- and RUN-UNTIL-CLOSED then restores the previous delegate on freed
memory.  That is a use-after-free, which hangs or corrupts rather than erroring,
and it is timing dependent, so it presents as \"it worked, then the close button
hung\".  MAKE-WINDOW turns the flag off and RUN-UNTIL-CLOSED retains for the
duration; this checks both by messaging the window afterwards."
  (with-gui
    (dotimes (i 3)
      (let* ((window (objc/examples::make-window
                      :title "close cycle" :rect #(580d0 580d0 220d0 140d0)))
             (app (objc.runloop:shared-application)))
        (declare (ignorable app))
        (objc/examples::show-window window :seconds 0.1d0)
        (is-false (objc:invoke-bool window "isReleasedWhenClosed")
                  "MAKE-WINDOW hands window ownership to Lisp")
        (bt:make-thread
         (lambda ()
           (sleep 0.3)
           (objc:invoke window "performSelectorOnMainThread:withObject:waitUntilDone:"
                        (objc:coerce-to-selector "performClose:") nil nil)))
        (is-true (objc/examples:run-until-closed window))
        ;; If the window had been freed this would hang or return rubbish.
        (is (string= "close cycle" (objc:invoke-into 'string window "title"))
            "the window survived its own close")))))

(test run-until-closed-timeout-returns-control
  "The watchdog.  Whatever goes wrong -- including -windowWillClose: never
reaching Lisp -- a caller who passed :TIMEOUT gets the REPL back."
  (with-gui
    (let ((window (objc/examples::make-window :title "watchdog"
                                              :rect #(600d0 600d0 220d0 140d0))))
      (unwind-protect
           (progn
             (objc/examples::show-window window :seconds 0.1d0)
             (let ((start (get-internal-real-time)))
               (is-true (objc/examples:run-until-closed window :timeout 2))
               (let ((elapsed (/ (float (- (get-internal-real-time) start))
                                 internal-time-units-per-second)))
                 (is (< 1.5 elapsed 12d0)
                     "returned on the watchdog with nobody closing the window"))))
        (objc:invoke window "close")))))
