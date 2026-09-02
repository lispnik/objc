;;;; examples/appkit.lisp -- the small amount of window plumbing the ported
;;;; examples need.
;;;;
;;;; The LispWorks originals are CAPI programs: they say (capi:contain
;;;; (make-instance 'capi:cocoa-view-pane :view-class "PDFView" :init-function
;;;; ...)).  There is no CAPI on SBCL, and writing a fake one would be a much
;;;; larger project than this library.  So the examples build a real NSWindow
;;;; and put the same Cocoa view in it, through this bridge.
;;;;
;;;; What matters is that every objc: form in the ported examples is unchanged
;;;; from the original.  Only the pane plumbing differs, and that plumbing is
;;;; here rather than scattered through them.

(in-package #:objc/examples)

(defconstant +ns-window-style-titled+ 1)
(defconstant +ns-window-style-closable+ 2)
(defconstant +ns-window-style-miniaturizable+ 4)
(defconstant +ns-window-style-resizable+ 8)
(defconstant +ns-backing-store-buffered+ 2)

(defun standard-window-style ()
  (logior +ns-window-style-titled+ +ns-window-style-closable+
          +ns-window-style-miniaturizable+ +ns-window-style-resizable+))

(defun make-window (&key (title "objc") (rect #(200 200 640 480)))
  "Create a titled window.  The CAPI original's equivalent is CAPI:CONTAIN."
  (objc.runloop:shared-application)
  (let ((window (objc:invoke (objc:invoke "NSWindow" "alloc")
                             "initWithContentRect:styleMask:backing:defer:"
                             rect (standard-window-style)
                             +ns-backing-store-buffered+ nil)))
    (objc:invoke window "setTitle:" title)
    ;; NSWindow's -releasedWhenClosed defaults to YES for a window created this
    ;; way, so clicking the close button DEALLOCATES it.  Anything still holding
    ;; the pointer -- RUN-UNTIL-CLOSED restoring a delegate, a caller checking
    ;; -isVisible, the REPL variable you kept -- is then messaging freed memory,
    ;; which hangs or corrupts rather than erroring.  Lisp owns this window
    ;; instead; it stays valid until it is released.
    (objc:invoke window "setReleasedWhenClosed:" nil)
    window))

(defun make-view (class-name rect &key init-function)
  "Allocate a Cocoa view of CLASS-NAME and initialize it.

This is exactly what CAPI:COCOA-VIEW-PANE does with its :VIEW-CLASS and
:INIT-FUNCTION initargs: allocate the named class, then either call the
init-function with the new view or send it -init."
  (let ((view (objc:invoke (objc:coerce-to-objc-class class-name) "alloc")))
    (if init-function
        (funcall init-function view)
        (objc:invoke view "initWithFrame:" rect))))

(defun show-window (window &key (seconds 0.6d0))
  "Order WINDOW to the front and let the run loop draw it.

PUMP-EVENTS rather than [NSApp run]: run never returns, and it would be holding
the thread the REPL is on."
  (objc:invoke window "makeKeyAndOrderFront:" nil)
  (objc:invoke (objc:invoke "NSApplication" "sharedApplication")
               "activateIgnoringOtherApps:" t)
  (objc.runloop:pump-events :seconds 0.05d0 :max-seconds seconds :until (constantly nil))
  window)

(defun add-subview (window view &optional frame)
  (when frame
    (objc:invoke view "setFrame:" frame))
  (objc:invoke (objc:invoke window "contentView") "addSubview:" view)
  view)

(defun make-label (text rect)
  (let ((field (objc:invoke (objc:invoke "NSTextField" "alloc") "initWithFrame:" rect)))
    (objc:invoke field "setStringValue:" text)
    (objc:invoke field "setBezeled:" nil)
    (objc:invoke field "setDrawsBackground:" nil)
    (objc:invoke field "setEditable:" nil)
    (objc:invoke field "setSelectable:" nil)
    field))

(defun make-text-field (rect &key (text ""))
  (let ((field (objc:invoke (objc:invoke "NSTextField" "alloc") "initWithFrame:" rect)))
    (objc:invoke field "setStringValue:" text)
    field))

(defun make-button (title rect &key target action)
  (let ((button (objc:invoke (objc:invoke "NSButton" "alloc") "initWithFrame:" rect)))
    (objc:invoke button "setTitle:" title)
    (objc:invoke button "setBezelStyle:" 1)
    (when target
      (objc:invoke button "setTarget:" target)
      (objc:invoke button "setAction:" (objc:coerce-to-selector action)))
    button))

(defparameter +modal-run-loop-modes+
  #("NSModalPanelRunLoopMode" "kCFRunLoopDefaultMode")
  "The run loop modes a modal session may be running in.

Anything scheduled for delivery during -runModalForWindow: has to name
NSModalPanelRunLoopMode: a modal session runs in that mode, so work queued for
the default mode alone is queued for a mode that is not running and never
arrives.  The vector becomes an NSArray of NSStrings on the way through INVOKE.")

(defun stop-modal-soon ()
  "Ask for -stopModal on the next pass of the run loop.

Never send -stopModal synchronously from inside an AppKit callback.  A real
click on a control runs inside that control's mouse tracking loop, nested
inside the modal loop, and a delegate method fires down there; ending the
session on the spot returns control to the caller while AppKit is still
unwinding, leaving the window drawn but dead with nothing pumping events.
Deferring lets the current event, and everything nested in it, finish first."
  (objc:invoke (objc:invoke "NSApplication" "sharedApplication")
               "performSelector:withObject:afterDelay:inModes:"
               (objc:coerce-to-selector "stopModal")
               nil
               0d0
               +modal-run-loop-modes+))

(objc:define-objc-class modal-stopper ()
  ()
  (:objc-class-name "ObjcModalStopper"))

(objc:define-objc-method ("windowWillClose:" :void)
    ((self modal-stopper) (notification objc:objc-object-pointer))
  (declare (ignore notification))
  ;; AppKit does not end a modal session just because the window closed, so
  ;; something has to send -stopModal.  But NOT synchronously from here.
  ;;
  ;; A real click on the close widget runs inside that button's mouse tracking
  ;; loop, which is itself nested inside the modal loop.  -windowWillClose:
  ;; fires down there, so stopping the modal session on the spot returns
  ;; control to the REPL while AppKit is still unwinding the tracking loop and
  ;; finishing the close -- and with nothing left pumping events, the window is
  ;; stranded on screen, unresponsive.  Sending -performClose: programmatically
  ;; skips the tracking loop entirely, which is why this never showed up in a
  ;; test.
  ;;
  ;; Deferring by zero delay puts -stopModal on the next pass of the run loop,
  ;; after the current event and everything nested in it has completed.
  ;; ...and it has to be scheduled in the MODAL run loop mode as well as the
  ;; default one.  A modal session runs in NSModalPanelRunLoopMode, so a plain
  ;; -performSelector:withObject:afterDelay: is queued for a mode that is not
  ;; running and never fires at all -- which hangs outright rather than late.
  ;; The mode list is a Lisp vector; INVOKE converts it to an NSArray of
  ;; NSStrings on the way in.
  (stop-modal-soon))

(defun run-until-closed (window &key timeout)
  "Keep WINDOW live and responsive until someone closes it.

This is what makes a demo behave like an application from a REPL, and it uses
AppKit's own event loop -- -[NSApplication runModalForWindow:] -- rather than
pumping by hand.

The difference is not stylistic.  A hand-rolled
nextEventMatchingMask:/sendEvent: loop never gets to block: AppKit keeps a
supply of AppKitDefined events coming, so the loop spins at 100% CPU
re-dispatching them, which makes the window sluggish and the fans loud without
ever quite freezing.  -runModalForWindow: idles at a few percent and wakes on
real input.  Measured on this machine: 100.9% CPU pumping, 0.4% modal.

TIMEOUT, in seconds, arranges for the loop to be stopped whatever happens --
including if -windowWillClose: never reaches us.  It costs a watchdog thread
and it means a stuck window cannot hold the REPL indefinitely, so it is worth
passing when you are not sure:

    (run-until-closed (test-area-calculator) :timeout 60)

The window is modal for the duration, which for a demo is what you want.  Any
existing window delegate is restored afterwards.  Returns T."
  (let* ((app (objc.runloop:shared-application))
         (previous (objc:invoke window "delegate"))
         (stopper (make-instance 'modal-stopper))
         (finished nil))
    ;; Retained across the loop as well as MAKE-WINDOW's -setReleasedWhenClosed:
    ;; NO, because a window that reaches here from somewhere else may well still
    ;; be set to release itself on close -- and then the delegate restore below
    ;; would be a use-after-free.
    (objc:retain window)
    (when timeout
      (bt:make-thread
       (lambda ()
         (loop repeat (ceiling (* 10 timeout))
               until finished
               do (sleep 0.1))
         (unless finished
           ;; -stopModal has to run on the main thread, so ask for it there
           ;; rather than calling it from here.
           (ignore-errors
            (objc:invoke app "performSelectorOnMainThread:withObject:waitUntilDone:modes:"
                         (objc:coerce-to-selector "stopModal") nil nil
                         +modal-run-loop-modes+))))
       :name "objc run-until-closed watchdog"))
    (unwind-protect
         (progn
           (objc:invoke window "setDelegate:" (objc:objc-object-pointer stopper))
           (objc:invoke app "runModalForWindow:" window))
      (setf finished t)
      (ignore-errors (objc:invoke window "setDelegate:" previous))
      ;; Let AppKit finish taking the window down before the REPL gets control
      ;; back.  Without this the last of the teardown has nothing to run on and
      ;; the window can sit there, drawn but dead, until something else happens
      ;; to pump the loop.
      (ignore-errors
       (objc:invoke window "orderOut:" nil)
       (objc.runloop:pump-events :seconds 0.02d0 :max-seconds 0.3d0))
      (objc:release window)
      ;; Give the keyboard back.  Showing a window makes this process the
      ;; frontmost macOS application, and it STAYS frontmost after the window
      ;; closes -- activation policy Regular, no windows left.  The REPL is
      ;; then at its prompt while every keystroke goes to an app with nothing
      ;; to type into, which reads exactly like a hang, and which no automated
      ;; test can see because no test types.
      (objc.runloop:restore-frontmost))
    t))

(objc:define-objc-class logging-stopper ()
  ((note :initform nil :accessor logging-stopper-note))
  (:objc-class-name "ObjcLoggingStopper"))

(objc:define-objc-method ("windowShouldClose:" objc:objc-bool)
    ((self logging-stopper) (sender objc:objc-object-pointer))
  (declare (ignore sender))
  (let ((note (logging-stopper-note self)))
    (when note (funcall note "windowShouldClose: reached Lisp")))
  t)

(objc:define-objc-method ("windowWillClose:" :void)
    ((self logging-stopper) (notification objc:objc-object-pointer))
  (declare (ignore notification))
  (let ((note (logging-stopper-note self))
        (app (objc:invoke "NSApplication" "sharedApplication")))
    (when note (funcall note "windowWillClose: reached Lisp; modalWindow=~A"
                        (not (cffi:null-pointer-p (objc:invoke app "modalWindow")))))
    ;; Deferred, exactly as MODAL-STOPPER does it.  This carried the
    ;; synchronous version until a sweep for the pattern found it: the
    ;; diagnostic written to investigate the hang still contained the hang.
    (stop-modal-soon)
    (when note (funcall note "stopModal scheduled"))))

(defun stop-running ()
  "End the modal loop RUN-UNTIL-CLOSED is in.

The escape hatch when a window has no close button, or you would rather not
reach for the mouse.  Scheduled rather than sent, so it is also safe from
inside an AppKit callback, where a synchronous -stopModal would hand control
back while AppKit was still unwinding."
  (stop-modal-soon)
  t)

(defun diagnose-close (&key (log "/tmp/objc-close.log"))
  "Run the area calculator with every step of closing logged, to LOG and to
*ERROR-OUTPUT*.

For working out why closing a window does not hand the REPL back.  Run it,
click the close button, and send the log: it records whether -windowWillClose:
reached Lisp, whether -stopModal was sent, and whether -runModalForWindow:
returned.  Whichever of those three is missing says where the fault is."
  (with-open-file (stream log :direction :output :if-exists :supersede)
    (flet ((note (control &rest args)
             (let ((line (apply #'format nil control args)))
               (format stream "~&~A~%" line)
               (format *error-output* "~&[objc] ~A~%" line)
               (finish-output stream)
               (finish-output *error-output*))))
      (note "window server: ~A" (objc.runloop:window-server-p))
      (let* ((window (test-area-calculator))
             (app (objc.runloop:shared-application))
             (previous (objc:invoke window "delegate"))
             (stopper (make-instance 'logging-stopper)))
        (setf (logging-stopper-note stopper) #'note)
        (note "window built, isReleasedWhenClosed=~A visible=~A"
              (objc:invoke-bool window "isReleasedWhenClosed")
              (objc:invoke-bool window "isVisible"))
        (objc:retain window)
        (objc:invoke window "setDelegate:" (objc:objc-object-pointer stopper))
        (note "delegate installed; entering runModalForWindow: -- click close now")
        (let ((start (get-internal-real-time)))
          (unwind-protect
               (objc:invoke app "runModalForWindow:" window)
            (note "runModalForWindow: RETURNED after ~,1fs"
                  (/ (float (- (get-internal-real-time) start))
                     internal-time-units-per-second))
            (ignore-errors (objc:invoke window "setDelegate:" previous))
            (objc:release window)))
        (note "done; log written to ~A" log))))
  (values))
