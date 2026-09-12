;;;; examples/menu-bar-lisp.lisp -- a Lisp in the menu bar, reachable from any
;;;; application with one key.
;;;;
;;;; status-item.lisp put a Lisp method behind a menu-bar item.  This one puts
;;;; a REPL there: copy an expression in any application, press ⌃⌥⌘E, and the
;;;; value replaces it on the clipboard and shows for a moment in a panel.
;;;; The menu item does the same for people who would rather click.
;;;;
;;;; The key works everywhere because of -[NSEvent
;;;; addGlobalMonitorForEventsMatchingMask:handler:], which hands this process
;;;; a copy of key events delivered to other applications.  macOS lets only a
;;;; trusted process see them: the user grants that under Privacy & Security
;;;; > Accessibility (or Input Monitoring), and until then the monitor is
;;;; installed and silent.  AXIsProcessTrusted says which, and the menu says
;;;; so too, so a hotkey that does nothing is never a mystery.  The panel and
;;;; the clipboard need no permission at all.
;;;;
;;;; The clipboard rather than the selection, on purpose: reading another
;;;; application's selection takes the Accessibility API as well, and copying
;;;; first is a habit every Mac user has.

(in-package #:objc/examples)

(defvar *menu-bar-lisp-running* nil
  "T while RUN-MENU-BAR-LISP is in -[NSApplication run]; Quit sets it NIL.")

(defconstant +ns-event-mask-key-down+ (ash 1 10))
(defconstant +ns-event-modifier-control+ (ash 1 18))
(defconstant +ns-event-modifier-option+ (ash 1 19))
(defconstant +ns-event-modifier-command+ (ash 1 20))
(defconstant +hotkey-modifiers+ (logior +ns-event-modifier-control+
                                        +ns-event-modifier-option+
                                        +ns-event-modifier-command+))
(defparameter +hotkey-character+ "e")

(defconstant +utility-panel-style+ (logior 1 (ash 1 4) (ash 1 7) (ash 1 13))
  "Titled, utility, non-activating, HUD: a small dark panel that shows
without taking the keyboard away from the application the user is in.")

(cffi:defcfun ("AXIsProcessTrusted" %ax-is-process-trusted) :boolean)

;;; The clipboard --------------------------------------------------------------

(defun pasteboard-string ()
  "The clipboard's text, or NIL when it holds none."
  (let ((string (objc:invoke (objc:invoke "NSPasteboard" "generalPasteboard")
                             "stringForType:" "public.utf8-plain-text")))
    (if (cffi:null-pointer-p string) nil (objc:ns-string-to-string string))))

(defun (setf pasteboard-string) (string)
  (let ((pasteboard (objc:invoke "NSPasteboard" "generalPasteboard")))
    (objc:invoke pasteboard "clearContents")
    (objc:invoke pasteboard "setString:forType:" string "public.utf8-plain-text")
    string))

;;; The controller ---------------------------------------------------------------

(objc:define-objc-class menu-bar-lisp ()
  ((status-item :initform nil :accessor menu-bar-lisp-status-item)
   (panel :initform nil :accessor menu-bar-lisp-panel)
   (field :initform nil :accessor menu-bar-lisp-field)
   (result-item :initform nil :accessor menu-bar-lisp-result-item)
   (monitor :initform nil :accessor menu-bar-lisp-monitor)
   (last-result :initform nil :accessor menu-bar-lisp-last-result))
  (:objc-class-name "LispMenuBarEvaluator"))

(defun show-panel (controller text)
  "Show TEXT in the panel at the top right of the screen for a few seconds."
  (let ((panel (menu-bar-lisp-panel controller))
        (field (menu-bar-lisp-field controller)))
    (objc:invoke field "setStringValue:" text)
    (let* ((screen (objc:invoke (objc:invoke "NSScreen" "mainScreen") "visibleFrame"))
           (right (+ (aref screen 0) (aref screen 2)))
           (top (+ (aref screen 1) (aref screen 3))))
      (objc:invoke panel "setFrameTopLeftPoint:" (vector (- right 420d0) (- top 8d0))))
    (objc:invoke panel "orderFront:" nil)
    (objc:invoke "NSTimer" "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"
                 3d0 (objc:objc-object-pointer controller)
                 (objc:coerce-to-selector "hidePanel:") nil nil)))

(objc:define-objc-method ("hidePanel:" :void)
    ((self menu-bar-lisp) (timer objc:objc-object-pointer))
  (declare (ignore timer))
  (objc:invoke (menu-bar-lisp-panel self) "orderOut:" nil))

(defun evaluate-clipboard (controller)
  "Evaluate the clipboard's text, put the value back on the clipboard, and
show both.  The evaluator is xpc.lisp's: a printed value or a printed error,
never a debugger, since this is called from AppKit."
  (let ((form (pasteboard-string)))
    (cond
      ((or (null form) (zerop (length (string-trim '(#\Space #\Newline #\Tab) form))))
       (show-panel controller "The clipboard has no text to evaluate."))
      (t
       (multiple-value-bind (value error) (evaluate-request form)
         (let ((result (or value error)))
           (setf (menu-bar-lisp-last-result controller) result)
           (when value
             (setf (pasteboard-string) value))
           (objc:invoke (menu-bar-lisp-result-item controller) "setTitle:"
                        (format nil "Last: ~a" (subseq result 0 (min 60 (length result)))))
           (show-panel controller
                       (format nil "~a~%~a ~a"
                               (string-trim '(#\Newline) form)
                               (if value "⇒" "✗") result))))))))

(objc:define-objc-method ("evaluateClipboard:" :void)
    ((self menu-bar-lisp) (sender objc:objc-object-pointer))
  (declare (ignore sender))
  (evaluate-clipboard self))

(objc:define-objc-method ("quit:" :void)
    ((self menu-bar-lisp) (sender objc:objc-object-pointer))
  (declare (ignore sender))
  (setf *menu-bar-lisp-running* nil)
  (stop-the-application))

(objc:define-objc-method ("stopTheApplication:" :void)
    ((self menu-bar-lisp) (sender objc:objc-object-pointer))
  (declare (ignore sender))
  (stop-the-application))

;;; The hotkey --------------------------------------------------------------------

(objc:define-objc-block-type global-key-handler :void (objc:objc-object-pointer))

(defun hotkey-event-p (event)
  (and (= +hotkey-modifiers+
          (logand (objc:invoke event "modifierFlags") +hotkey-modifiers+))
       (string-equal +hotkey-character+
                     (objc:ns-string-to-string (objc:invoke event "charactersIgnoringModifiers")))))

(defun install-hotkey (controller)
  "Watch key-downs in every application for ⌃⌥⌘E.  The monitor object is
kept on the controller; the block is copied by AppKit, so it may be freed."
  (objc:with-objc-block (block 'global-key-handler
                               (lambda (event)
                                 (when (hotkey-event-p event)
                                   (evaluate-clipboard controller))))
    (setf (menu-bar-lisp-monitor controller)
          (objc:invoke "NSEvent" "addGlobalMonitorForEventsMatchingMask:handler:"
                       +ns-event-mask-key-down+ block))))

(defun hotkey-permitted-p ()
  "Whether macOS will deliver other applications' keys to this process."
  (%ax-is-process-trusted))

;;; The panel and the item ------------------------------------------------------

(defun make-result-panel ()
  "A HUD panel with one label, kept off screen until there is something to show."
  (let* ((frame (vector 0d0 0d0 400d0 72d0))
         (panel (objc:invoke (objc:invoke "NSPanel" "alloc")
                             "initWithContentRect:styleMask:backing:defer:"
                             frame +utility-panel-style+ 2 nil))
         (field (objc:invoke (objc:invoke "NSTextField" "alloc") "initWithFrame:"
                             (vector 12d0 8d0 376d0 56d0))))
    (objc:invoke panel "setReleasedWhenClosed:" nil)
    (objc:invoke panel "setTitle:" "Lisp")
    (objc:invoke panel "setFloatingPanel:" t)
    (objc:invoke panel "setHidesOnDeactivate:" nil)
    (objc:invoke field "setBezeled:" nil)
    (objc:invoke field "setDrawsBackground:" nil)
    (objc:invoke field "setEditable:" nil)
    (objc:invoke field "setSelectable:" t)
    (objc:invoke field "setFont:" (objc:invoke "NSFont" "monospacedSystemFontOfSize:weight:" 13d0 0d0))
    (objc:invoke (objc:invoke panel "contentView") "addSubview:" field)
    (values panel field)))

(defun make-menu-bar-lisp ()
  "Put the evaluator in the menu bar and install its hotkey.
Returns the controller; REMOVE-MENU-BAR-LISP takes it down."
  (objc:ensure-objc-initialized)
  (objc.runloop:shared-application)
  (objc.runloop:set-activation-policy +activation-policy-accessory+)
  (let* ((controller (make-instance 'menu-bar-lisp))
         (target (objc:objc-object-pointer controller))
         (bar (objc:invoke "NSStatusBar" "systemStatusBar"))
         (item (objc:invoke bar "statusItemWithLength:" +variable-status-item-length+))
         (menu (objc:invoke (objc:invoke "NSMenu" "alloc") "init"))
         (evaluate (%menu-item "Evaluate Clipboard" "evaluateClipboard:" target))
         (result (%menu-item "Last: nothing yet" "evaluateClipboard:" target))
         (permission (%menu-item (if (hotkey-permitted-p)
                                     "⌃⌥⌘E works in every application"
                                     "⌃⌥⌘E needs Accessibility permission for this app")
                                 "evaluateClipboard:" target)))
    (objc:invoke (objc:invoke item "button") "setTitle:" "λ")
    (objc:invoke evaluate "setKeyEquivalent:" +hotkey-character+)
    (objc:invoke evaluate "setKeyEquivalentModifierMask:" +hotkey-modifiers+)
    (objc:invoke result "setEnabled:" nil)
    (objc:invoke permission "setEnabled:" nil)
    (objc:invoke menu "addItem:" evaluate)
    (objc:invoke menu "addItem:" result)
    (objc:invoke menu "addItem:" (objc:invoke "NSMenuItem" "separatorItem"))
    (objc:invoke menu "addItem:" permission)
    (objc:invoke menu "addItem:" (objc:invoke "NSMenuItem" "separatorItem"))
    (objc:invoke menu "addItem:" (%menu-item "Quit" "quit:" target))
    (objc:invoke item "setMenu:" menu)
    (multiple-value-bind (panel field) (make-result-panel)
      (setf (menu-bar-lisp-panel controller) panel
            (menu-bar-lisp-field controller) field))
    (setf (menu-bar-lisp-status-item controller) item
          (menu-bar-lisp-result-item controller) result)
    (install-hotkey controller)
    controller))

(defun remove-menu-bar-lisp (controller)
  "Take the item out of the menu bar, stop watching keys, hide the panel."
  (let ((monitor (menu-bar-lisp-monitor controller)))
    (when (and monitor (not (cffi:null-pointer-p monitor)))
      (objc:invoke "NSEvent" "removeMonitor:" monitor)))
  (objc:invoke (menu-bar-lisp-panel controller) "orderOut:" nil)
  (remove-status-item (menu-bar-lisp-status-item controller))
  controller)

(defun run-menu-bar-lisp (&key timeout)
  "Show the evaluator in the menu bar and run until Quit is chosen, or
TIMEOUT seconds pass.  From a plain sbcl REPL, as RUN-STATUS-ITEM explains:
AppKit's own loop, on thread 1.  Returns the last result shown, if any."
  (let* ((controller (make-menu-bar-lisp))
         (app (objc.runloop:shared-application))
         (target (objc:objc-object-pointer controller)))
    (setf *menu-bar-lisp-running* t)
    (when timeout
      (bt:make-thread
       (lambda ()
         (loop repeat (ceiling (* 10 timeout))
               while *menu-bar-lisp-running*
               do (sleep 0.1))
         (when *menu-bar-lisp-running*
           (setf *menu-bar-lisp-running* nil)
           (ignore-errors
            (objc:invoke target "performSelectorOnMainThread:withObject:waitUntilDone:"
                         (objc:coerce-to-selector "stopTheApplication:") nil nil))))
       :name "objc menu-bar lisp watchdog"))
    (unwind-protect (objc:invoke app "run")
      (setf *menu-bar-lisp-running* nil)
      (remove-menu-bar-lisp controller))
    (menu-bar-lisp-last-result controller)))

(defun test-menu-bar-lisp ()
  "Exercise the evaluator without a keyboard: put a form on the clipboard,
have the controller evaluate it as the hotkey and the menu item do, and
report.  Needs a window server; needs no permission.

    (objc/examples:test-menu-bar-lisp)
    => (:VALUE \"3\" :CLIPBOARD \"3\" :PANEL-SHOWN T :HOTKEY-PERMITTED NIL)"
  (let ((controller (make-menu-bar-lisp))
        (saved (pasteboard-string)))
    (unwind-protect
         (progn
           (setf (pasteboard-string) "(+ 1 2)")
           (evaluate-clipboard controller)
           (objc.runloop:pump-events :seconds 0.05d0 :max-seconds 0.5d0 :until (constantly nil))
           (list :value (menu-bar-lisp-last-result controller)
                 :clipboard (pasteboard-string)
                 :panel-shown (objc:invoke-bool (menu-bar-lisp-panel controller) "isVisible")
                 :hotkey-permitted (hotkey-permitted-p)))
      (when saved (setf (pasteboard-string) saved))
      (remove-menu-bar-lisp controller))))
