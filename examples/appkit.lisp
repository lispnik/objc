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

(defun run-until-closed (window &key (timeout 600))
  "Keep WINDOW live and responsive until someone closes it.

This is what makes a demo behave like an application from a REPL.  A Cocoa
window only responds while something is dispatching events, and PUMP-EVENTS
returns as soon as its bound is reached -- so a plain (pump-events :max-seconds
5) leaves the window frozen five seconds later.  Pumping until the window goes
away is almost always what you actually meant.

TIMEOUT is a backstop in seconds, so a forgotten window cannot wedge the REPL
forever.  Returns T if the window was closed, NIL if the timeout ran out.

\"Closed\" here means -isVisible answering NO, so this expects a window that has
already been ordered front -- every demo shows its window before returning one.
A window that was never shown is not visible either, and this returns
immediately rather than waiting for something that cannot happen."
  (objc.runloop:pump-events
   :seconds 0.02d0
   :max-seconds timeout
   :until (lambda () (not (objc:invoke-bool window "isVisible"))))
  (not (objc:invoke-bool window "isVisible")))
