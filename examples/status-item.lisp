;;;; examples/status-item.lisp -- a macOS menu-bar item, run from Lisp.
;;;;
;;;; Another example not in the manual.  It shows the other half of AppKit
;;;; interop from the canvas: not a view you draw, but a control whose actions
;;;; are Lisp methods.  An NSStatusItem sits in the system menu bar; its menu's
;;;; items each carry a target and an action selector, and AppKit sends that
;;;; selector -- to a Lisp object, invoking a Lisp method -- when the item is
;;;; chosen.  Target/action is how the whole of Cocoa's UI is wired, and here
;;;; the far end of it is a closure you can redefine at the REPL.

(in-package #:objc/examples)

(defvar *status-running* nil
  "T while RUN-STATUS-ITEM is pumping; the Quit menu item sets it NIL.")

(defvar *status-count* 0
  "State the menu mutates, so a Lisp method visibly changes the menu-bar item.")

(objc:define-objc-class status-controller ()
  ()
  (:objc-class-name "LispStatusController")
  (:objc-instance-vars ("statusItem" objc:objc-object-pointer)))

(defun %status-item-of (controller)
  "The controller's NSStatusItem, or NIL before one is stored."
  (let ((item (objc:objc-object-var-value controller "statusItem")))
    (unless (cffi:null-pointer-p (if (cffi:pointerp item)
                                     item
                                     (objc:objc-object-pointer item)))
      item)))

(defun %update-status-title (controller)
  "Reflect *STATUS-COUNT* in the menu-bar button -- the visible proof a Lisp
method ran."
  (let ((item (%status-item-of controller)))
    (when item
      (objc:invoke (objc:invoke item "button") "setTitle:"
                   (format nil "~C ~D" #\GREEK_SMALL_LETTER_LAMDA *status-count*)))))

;;; The actions, each a Lisp method an NSMenuItem points at ------------------

(objc:define-objc-method ("greet:" :void)
    ((self status-controller) (sender objc:objc-object-pointer))
  (declare (ignore sender))
  (format t "~&Hello from a Lisp method, sent by an NSMenuItem.~%")
  (finish-output))

(objc:define-objc-method ("increment:" :void)
    ((self status-controller) (sender objc:objc-object-pointer))
  (declare (ignore sender))
  (incf *status-count*)
  (%update-status-title self))

(objc:define-objc-method ("resetCount:" :void)
    ((self status-controller) (sender objc:objc-object-pointer))
  (declare (ignore sender))
  (setf *status-count* 0)
  (%update-status-title self))

(objc:define-objc-method ("quit:" :void)
    ((self status-controller) (sender objc:objc-object-pointer))
  (declare (ignore sender))
  (setf *status-running* nil)
  (stop-the-application))

;;; Building and running ------------------------------------------------------

(defun stop-the-application ()
  "End -[NSApplication run].

-stop: alone is not enough: it sets a flag the loop notices only when it next
finishes processing an event, so a loop sitting idle waiting for input can stay
there indefinitely -- which reads as a hang.  Posting a dummy application-defined
event behind it guarantees there is an event to finish, so the loop wakes,
notices the flag, and returns.  Safe from a menu action and from another thread's
performSelectorOnMainThread:."
  (let ((app (objc:invoke "NSApplication" "sharedApplication")))
    (objc:invoke app "stop:" (cffi:null-pointer))
    (objc:invoke app "postEvent:atStart:"
                 (objc:invoke "NSEvent"
                              "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:"
                              15          ; NSEventTypeApplicationDefined
                              #(0d0 0d0)  ; NSPoint, by value
                              0 0d0 0 (cffi:null-pointer) 0 0 0)
                 t))
  (values))

(objc:define-objc-method ("stopTheApplication:" :void)
    ((self status-controller) (sender objc:objc-object-pointer))
  ;; A selector the watchdog thread can send to the main thread; calling
  ;; STOP-THE-APPLICATION from the watchdog itself would post the event from
  ;; the wrong thread.
  (declare (ignore sender))
  (stop-the-application))

(defun %menu-item (title action target)
  "An NSMenuItem titled TITLE whose action selector ACTION is sent to TARGET."
  (let ((item (objc:invoke (objc:invoke "NSMenuItem" "alloc")
                           "initWithTitle:action:keyEquivalent:"
                           title (objc:coerce-to-selector action) "")))
    (objc:invoke item "setTarget:" target)
    item))

(defparameter +variable-status-item-length+ -1d0
  "NSVariableStatusItemLength: the item is as wide as its content.")

(defconstant +activation-policy-accessory+ 1
  "NSApplicationActivationPolicyAccessory.

The policy a menu-bar-only application must have, and the reason clicking the
item did nothing at first.  SHARED-APPLICATION defaults to Regular (0), which is
right for a process that owns windows: it gets a Dock icon and its windows can
come to the front.  A status item is not a window, and a Regular application
with no windows that has never been activated does not get its status-item menu
driven -- the item draws, the click lands nowhere.  Accessory means \"no Dock
icon, no menu bar of my own, but I do have UI\", which is exactly a menu-bar
app, and AppKit then tracks the item's menu normally.")

(defun make-status-item (&key (title "λ"))
  "Put an item in the menu bar whose menu's actions are Lisp methods.

Returns (VALUES STATUS-ITEM CONTROLLER).  The system status bar retains the
item until REMOVE-STATUS-ITEM, so keep the value only if you want to change it;
RUN-STATUS-ITEM removes it for you."
  (objc:ensure-objc-initialized)
  ;; Accessory, not the default Regular -- see +ACTIVATION-POLICY-ACCESSORY+.
  ;; SET-ACTIVATION-POLICY rather than the SHARED-APPLICATION keyword, so this
  ;; holds even in a session that already brought AppKit up as Regular (a REPL
  ;; where you ran one of the window demos first).
  (objc.runloop:shared-application)
  (objc.runloop:set-activation-policy +activation-policy-accessory+)
  (setf *status-count* 0)
  (let* ((controller (make-instance 'status-controller))
         (target (objc:objc-object-pointer controller))
         (bar (objc:invoke "NSStatusBar" "systemStatusBar"))
         (item (objc:invoke bar "statusItemWithLength:" +variable-status-item-length+))
         (menu (objc:invoke (objc:invoke "NSMenu" "alloc") "init")))
    (objc:invoke (objc:invoke item "button") "setTitle:" title)
    (objc:invoke menu "addItem:" (%menu-item "Greet from Lisp" "greet:" target))
    (objc:invoke menu "addItem:" (%menu-item "Increment" "increment:" target))
    (objc:invoke menu "addItem:" (%menu-item "Reset" "resetCount:" target))
    (objc:invoke menu "addItem:" (objc:invoke "NSMenuItem" "separatorItem"))
    (objc:invoke menu "addItem:" (%menu-item "Quit" "quit:" target))
    (objc:invoke item "setMenu:" menu)
    (setf (objc:objc-object-var-value controller "statusItem") item)
    (values item controller)))

(defun remove-status-item (item)
  "Take ITEM out of the menu bar."
  (objc:invoke (objc:invoke "NSStatusBar" "systemStatusBar") "removeStatusItem:" item))

(defun run-status-item (&key (title "λ") timeout)
  "Show the menu-bar item and keep the app live until its Quit item is chosen.

Run it from a plain sbcl REPL (AppKit needs thread 1).  Click the item in the
macOS menu bar: Greet prints from a Lisp method, Increment and Reset change the
item's title, Quit ends the loop and hands the REPL back.  TIMEOUT in seconds
arranges for the loop to stop anyway, so a session cannot be stuck.  Returns T.

This uses AppKit's own loop -- -[NSApplication run] -- and not PUMP-EVENTS, and
that is the difference between a menu that works and one that does nothing when
clicked.  A status item's menu is tracked in AppKit's own nested run loop mode
while the mouse is down.  PUMP-EVENTS dequeues in kCFRunLoopDefaultMode only,
which is right for keeping a window responsive from a REPL, and starves menu
tracking: the item draws, the click opens nothing, and no action is ever sent.
-run pumps every mode AppKit needs, at the cost of not returning until
something stops it -- which for a menu-bar app is no cost at all, since there
is no REPL interaction to preserve while it runs.  The Quit action calls -stop:
(and posts an event behind it, so the stop is noticed promptly)."
  (multiple-value-bind (item controller) (make-status-item :title title)
    (setf *status-running* t)
    (let ((app (objc.runloop:shared-application))
          (target (objc:objc-object-pointer controller)))
      (when timeout
        ;; Stopping has to happen on the main thread -- both the -stop: and the
        ;; event posted behind it -- so the watchdog sends a selector there
        ;; rather than doing it itself.
        (bt:make-thread
         (lambda ()
           (loop repeat (ceiling (* 10 timeout))
                 while *status-running*
                 do (sleep 0.1))
           (when *status-running*
             (setf *status-running* nil)
             (ignore-errors
              (objc:invoke target "performSelectorOnMainThread:withObject:waitUntilDone:"
                           (objc:coerce-to-selector "stopTheApplication:") nil nil))))
         :name "objc status item watchdog"))
      (unwind-protect
           (objc:invoke app "run")
        (setf *status-running* nil)
        (remove-status-item item)
        (objc.runloop:restore-frontmost)))
    t))
