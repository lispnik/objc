;;;; src/runloop.lisp -- the main thread, NSApplication, and pumping events.
;;;;
;;;; Getting a window on screen from SBCL needs four things in order, and each
;;;; one blocks the next:
;;;;
;;;;  1. Floating point traps masked.  This is first because without it nothing
;;;;     else runs: the very first NSWindow creation raises
;;;;     FLOATING-POINT-INVALID-OPERATION and takes the process out with SIGFPE.
;;;;     SBCL runs with :INVALID and :DIVIDE-BY-ZERO unmasked and CoreGraphics
;;;;     violates both freely.  LispWorks never hit this because it masks them
;;;;     by default, so there is no prior art to copy -- and this is very likely
;;;;     why earlier SBCL bridges reported that everything worked except that
;;;;     the window never appeared.  Handled by WITH-FP-TRAPS-MASKED in abi.lisp,
;;;;     which every entry point here goes through.
;;;;
;;;;  2. Being on thread 1.  Already true in SBCL's REPL.  Checked rather than
;;;;     assumed, because the failure mode off the main thread is a deadlock or
;;;;     a half-drawn window rather than an error.
;;;;
;;;;  3. An activation policy.  An unbundled process gets no Dock presence and
;;;;     cannot become active until it asks for one.
;;;;
;;;;  4. A run loop that returns.  [NSApp run] never does, and it is holding the
;;;;     thread the REPL is on, so PUMP-EVENTS drives CFRunLoopRunInMode in a
;;;;     loop instead.  RUN-COCOA-APPLICATION is the separate, deliberately
;;;;     blocking entry point for a delivered application.

(in-package #:objc.runloop)

(cffi:defcfun ("CFRunLoopRunInMode" %cf-run-loop-run-in-mode) :int32
  (mode :pointer)
  (seconds :double)
  (return-after-source-handled :boolean))

(defvar *default-run-loop-mode* nil)

(defun default-run-loop-mode ()
  "The kCFRunLoopDefaultMode CFStringRef."
  (or *default-run-loop-mode*
      (let ((symbol (cffi:foreign-symbol-pointer "kCFRunLoopDefaultMode")))
        (unless symbol
          (error 'objc::library-not-found
                 :name "kCFRunLoopDefaultMode"
                 :candidates (list objc::+corefoundation-path+)))
        (setf *default-run-loop-mode* (cffi:mem-ref symbol :pointer)))))

(defun main-thread-p ()
  "True on the process's initial thread, which is pthread main.

AppKit requires thread 1, and SBCL's REPL already runs there -- which is why
LispWorks' MP:INITIALIZE-MULTIPROCESSING has no equivalent here and needs none:
its whole purpose is to hand thread 1 over to Cocoa, and on SBCL Cocoa already
has it."
  (sb-thread:main-thread-p))

(defun check-main-thread (&optional operation)
  (unless (main-thread-p)
    (error 'objc::not-main-thread :operation operation))
  t)

(defun window-server-p ()
  "True when there is a window server to draw on.

[NSScreen mainScreen] is nil in a process with no display -- a CI runner, or a
session with no window server -- which is what the GUI tests gate on."
  (handler-case
      (objc::with-fp-traps-masked
        (objc::ensure-appkit)
        (let ((screen (invoke "NSScreen" "mainScreen")))
          (and (cffi:pointerp screen) (not (cffi:null-pointer-p screen)))))
    (error () nil)))

(defvar *previous-frontmost* nil
  "The macOS application that was frontmost before we first activated.

Showing a window makes this process the frontmost application and it STAYS
frontmost after the window closes -- activation policy Regular, no windows.
The REPL is then at its prompt while every keystroke goes to an app with
nothing to type into, which reads exactly like a hang.  Remembering who had the
keyboard is what lets RESTORE-FRONTMOST give it back.

Captured once, before the first activation, and never overwritten with
ourselves.")

(defun remember-frontmost ()
  "Record who had the keyboard, if we have not already and it is not us."
  (unless *previous-frontmost*
    (ignore-errors
     (let* ((workspace (invoke "NSWorkspace" "sharedWorkspace"))
            (front (invoke workspace "frontmostApplication"))
            (self (invoke "NSRunningApplication" "currentApplication")))
       (when (and (not (cffi:null-pointer-p front))
                  (not (invoke-bool front "isEqual:" self)))
         (setf *previous-frontmost* (objc:retain front))))))
  *previous-frontmost*)

(defun restore-frontmost ()
  "Hand the keyboard back to whoever had it before we activated.

Call this after a window closes, or the terminal you launched from will look
frozen: it is still at its prompt, but the window server is sending keystrokes
here."
  (ignore-errors
   (let ((previous *previous-frontmost*))
     (when (and previous (not (cffi:null-pointer-p previous)))
       (invoke previous "activateWithOptions:" 0))
     (invoke (invoke "NSApplication" "sharedApplication") "deactivate")))
  t)

(defvar *activation-policy-set* nil
  "Whether SHARED-APPLICATION has already set an activation policy.

The policy is a property of the process, and the first caller's choice is the
one that means something: a program that asked for Accessory -- a menu-bar
application -- must not have it silently reset to Regular by the next internal
call.  PUMP-EVENTS calls SHARED-APPLICATION on every pass, so before this flag
existed the loop undid an Accessory policy immediately and a status item's menu
stopped being tracked, which presented as \"clicking the item does nothing\".")

(defun shared-application (&key (activation-policy 0))
  "Return the NSApplication, creating it and setting its activation policy.

ACTIVATION-POLICY 0 is NSApplicationActivationPolicyRegular.  Without setting
it, an unbundled process has no Dock presence and its windows cannot come to
the front.  1 is Accessory, which is what a menu-bar-only application wants.

Only the FIRST policy is applied.  Later calls leave it alone unless they pass
one explicitly, so an internal call -- PUMP-EVENTS makes one per pass -- cannot
overwrite the policy the program chose.  Passing ACTIVATION-POLICY NIL never
sets one."
  (check-main-thread "NSApplication")
  (objc::with-fp-traps-masked
    (objc::ensure-appkit)
    ;; Before the activation policy changes, while the answer is still someone
    ;; else.
    (remember-frontmost)
    (let ((app (invoke "NSApplication" "sharedApplication")))
      (when (and activation-policy (not *activation-policy-set*))
        (invoke app "setActivationPolicy:" activation-policy)
        (setf *activation-policy-set* t))
      app)))

(defun set-activation-policy (policy)
  "Set the application's activation policy to POLICY, overriding any earlier
one: 0 Regular, 1 Accessory, 2 Prohibited.

SHARED-APPLICATION honours only the first policy, so this is how a program that
has already brought AppKit up changes its mind."
  (check-main-thread "NSApplication")
  (objc::with-fp-traps-masked
    (let ((app (invoke "NSApplication" "sharedApplication")))
      (invoke app "setActivationPolicy:" policy)
      (setf *activation-policy-set* t)
      app)))

(defconstant +ns-event-mask-any+ (1- (expt 2 64))
  "NSEventMaskAny, which is NSUIntegerMax.")

(defconstant +max-events-per-pass+ 64
  "How many events one pass of PUMP-EVENTS will dispatch before yielding.

See the comment in PUMP-EVENTS: dispatching an event can enqueue more, so this
bound is what makes the loop terminate at all.")

(defvar *events-dispatched* 0
  "How many events PUMP-EVENTS has sent since the counter was last reset.
Exists so that \"the window is unresponsive\" can be told apart from \"the loop
is not running\": if this climbs while you click, events are arriving and the
fault is downstream of the pump.")

(defvar *finished-launching* nil
  "Whether -[NSApplication finishLaunching] has been sent.")

(defun ensure-finished-launching (app)
  "Send -finishLaunching once.

-[NSApplication run] normally does this before it starts dispatching.  Pumping
by hand skips -run, so an application that never got it stays half-initialized:
it will not activate properly and its menus never come up."
  (unless *finished-launching*
    (setf *finished-launching* t)
    (invoke app "finishLaunching"))
  app)

(defun pump-run-loop (&key (seconds 0.05d0))
  "Run the CoreFoundation run loop once, for at most SECONDS.

This services timers, network callbacks and other run loop sources, and is what
a Foundation-only process wants -- an NSURLSession download, say, in a program
with no user interface.  It does NOT dispatch user interface events: see
PUMP-EVENTS."
  (objc::with-fp-traps-masked
    (%cf-run-loop-run-in-mode (default-run-loop-mode)
                              (coerce seconds 'double-float)
                              t)))

(defun pump-events (&key (seconds 0.05d0) (until nil) (max-seconds nil))
  "Run the application event loop so windows draw and respond.

Call this from a REPL instead of [NSApp run], which never returns and is holding
the thread AppKit needs.  UNTIL, when given, is called after each pass and stops
the loop when it returns true; MAX-SECONDS bounds the whole thing.  With neither,
this makes a single pass and returns, which is what a caller who just wants
pending events serviced means.  To leave a window usable for a while:

    (pump-events :max-seconds 30d0)

Running the CoreFoundation run loop is NOT enough on its own, and this is the
one thing about pumping AppKit by hand that is easy to get wrong.
CFRunLoopRunInMode services the run loop sources that put events into
NSApplication's queue, but nothing takes them out again: NSApplication dispatches
events only from -run, or from an explicit
-nextEventMatchingMask:untilDate:inMode:dequeue: and -sendEvent: pair.  With only
the run loop running, a window appears and draws, and then every click queues up
undelivered until the window server decides the application has stopped
responding and shows the spinning wait cursor.

So this dequeues and sends, which is what -run does internally."
  (check-main-thread "The Cocoa event loop")
  (objc::with-fp-traps-masked
    (let ((app (shared-application))
          (start (get-internal-real-time))
          (seconds (coerce seconds 'double-float)))
      (ensure-finished-launching app)
      (loop
        ;; Each pass gets its own pool: dispatching events autoreleases
        ;; liberally, and a REPL session that pumps for a while would otherwise
        ;; accumulate everything AppKit touched.
        (with-autorelease-pool ()
          ;; Wait up to SECONDS for the first event, then take whatever else is
          ;; already queued rather than waiting again for each one -- but only up
          ;; to +MAX-EVENTS-PER-PASS+ of them.
          ;;
          ;; The bound is not defensive tidiness, it is the whole reason this
          ;; loop terminates.  Dispatching an event routinely makes AppKit
          ;; enqueue more -- a window update, a display, a cursor change -- so
          ;; "drain until the queue is empty" can never finish while a window is
          ;; on screen.  Without the cap this hangs the moment you show
          ;; something, which looks exactly like the bug it was meant to fix.
          (let ((deadline (invoke "NSDate" "dateWithTimeIntervalSinceNow:" seconds)))
            (loop repeat +max-events-per-pass+
                  for event = (invoke app
                                      "nextEventMatchingMask:untilDate:inMode:dequeue:"
                                      +ns-event-mask-any+
                                      deadline
                                      "kCFRunLoopDefaultMode"
                                      t)
                  until (cffi:null-pointer-p event)
                  do (incf *events-dispatched*)
                     (invoke app "sendEvent:" event)
                     (setf deadline (invoke "NSDate" "distantPast"))))
          (invoke app "updateWindows"))
        (let ((elapsed (/ (float (- (get-internal-real-time) start) 1d0)
                          internal-time-units-per-second)))
          (when (and until (funcall until)) (return elapsed))
          (when (and max-seconds (>= elapsed max-seconds)) (return elapsed))
          ;; With neither bound this is a single pass, which is what a caller
          ;; who just wants pending events serviced means.  Giving either bound
          ;; keeps it looping.
          (when (and (null until) (null max-seconds)) (return elapsed)))))))

(defun run-cocoa-application (&key (activation-policy 0))
  "Start the Cocoa event loop.  Does not return.

This is what a delivered application's toplevel calls.  In a REPL use
PUMP-EVENTS instead."
  (check-main-thread "The Cocoa event loop")
  (objc::with-fp-traps-masked
    (let ((app (shared-application :activation-policy activation-policy)))
      (invoke app "activateIgnoringOtherApps:" t)
      (invoke app "run"))))

(defun diagnose-pump (&key (seconds 15) (window nil))
  "Pump for SECONDS, reporting each second how many events were dispatched.

An instrument, not part of the API.  Run it, then click and drag on the window
while it counts.  If the count climbs, the event loop is working and anything
still wrong is downstream of it; if it stays at zero while you click, events
are not reaching this process at all and the loop is not the problem either."
  (check-main-thread "The Cocoa event loop")
  (let ((app (shared-application))
        (last 0))
    (ensure-finished-launching app)
    (setf *events-dispatched* 0)
    (format t "~&Pumping for ~D seconds -- click and drag on the window now.~%" seconds)
    (finish-output)
    (dotimes (i seconds)
      (pump-events :seconds 0.02d0 :max-seconds 1d0)
      (format t "  ~2D s: ~4D events this second (~D total)~@[  window visible: ~A~]~%"
              (1+ i) (- *events-dispatched* last) *events-dispatched*
              (when window (invoke-bool window "isVisible")))
      (finish-output)
      (setf last *events-dispatched*))
    *events-dispatched*))
