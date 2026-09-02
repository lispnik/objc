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

(defun make-window (&key (title "objc") (rect #(200d0 200d0 640d0 480d0)))
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

(objc:define-objc-class modal-stopper ()
  ()
  (:objc-class-name "ObjcModalStopper"))

(objc:define-objc-method ("windowWillClose:" :void)
    ((self modal-stopper) (notification objc:objc-object-pointer))
  (declare (ignore notification))
  ;; AppKit does not end a modal session just because the window closed, so
  ;; this is what makes closing the window hand the REPL back.
  (objc:invoke (objc:invoke "NSApplication" "sharedApplication") "stopModal"))

(defun run-until-closed (window)
  "Keep WINDOW live and responsive until someone closes it.

This is what makes a demo behave like an application from a REPL, and it uses
AppKit's own event loop -- -[NSApplication runModalForWindow:] -- rather than
pumping by hand.

The difference is not stylistic.  A hand-rolled
nextEventMatchingMask:/sendEvent: loop never gets to block: AppKit keeps a
supply of AppKitDefined events coming, so the loop spins at 100% CPU
re-dispatching them, which makes the window sluggish and the fans loud without
ever quite freezing.  -runModalForWindow: idles at a few percent and wakes on
real input.  Measured on this machine: 100.9% CPU pumping, 5.1% modal.

The window is modal for the duration, which for a demo is what you want.  Any
existing window delegate is restored afterwards.  Returns T."
  (let* ((app (objc.runloop:shared-application))
         (previous (objc:invoke window "delegate"))
         (stopper (make-instance 'modal-stopper)))
    ;; Retained across the loop as well as MAKE-WINDOW's -setReleasedWhenClosed:
    ;; NO, because a window that reaches here from somewhere else may well still
    ;; be set to release itself on close -- and then the delegate restore below
    ;; would be a use-after-free.
    (objc:retain window)
    (unwind-protect
         (progn
           (objc:invoke window "setDelegate:" (objc:objc-object-pointer stopper))
           (objc:invoke app "runModalForWindow:" window))
      (ignore-errors (objc:invoke window "setDelegate:" previous))
      (objc:release window))
    t))

(defun stop-running ()
  "End the modal loop RUN-UNTIL-CLOSED is in, from anywhere.
The escape hatch when a window has no close button, or you would rather not
reach for the mouse."
  (objc:invoke (objc.runloop:shared-application) "stopModal")
  t)
