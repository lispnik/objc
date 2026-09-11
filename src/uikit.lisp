;;;; src/uikit.lisp -- the few conveniences a UIKit interface in Lisp keeps
;;;; reaching for.
;;;;
;;;; Not a UIKit binding.  OBJC:INVOKE is the binding, and everything a view
;;;; can do is reachable through it without help.  What is here is the dozen
;;;; things every UIKit program does on every screen -- make a view with
;;;; autoresizing translation off, pin an anchor, get the root view, put a
;;;; Lisp function behind a button -- each of which is three lines of INVOKE
;;;; and a fact worth not rediscovering (the button type, the event mask, that
;;;; UIKit holds a target weakly).
;;;;
;;;; iOS only in practice, because the classes named here exist only there;
;;;; the file loads anywhere OBJC does, so that a program can be compiled and
;;;; its host-side parts tested on a Mac.

(defpackage #:uikit
  (:use #:cl)
  (:export
   ;; views
   #:new #:system-button #:key-window #:root-controller #:root-view
   ;; appearance
   #:color #:system-color #:font #:mono-font #:bold-font
   ;; auto layout
   #:anchor #:pin #:fix
   ;; Lisp behind UIKit's target/action
   #:on-tap #:action-target #:action-target-function #:after-every
   ;; lifetime
   #:keep #:unkeep))

(in-package #:uikit)

;;; Views --------------------------------------------------------------------

(defun new (class-name)
  "An instance of CLASS-NAME by -alloc -init, with autoresizing translation off.

Off, because that is what every view about to be constrained wants, and
forgetting it is the single most common way to get an invisible interface:
the translated mask constraints fight the ones you add, and the view ends up
somewhere with no size."
  (let ((view (objc:alloc-init-object class-name)))
    (objc:invoke view "setTranslatesAutoresizingMaskIntoConstraints:" nil)
    view))

(defun system-button (title)
  "A UIButton of the system type, carrying TITLE.

Not (NEW \"UIButton\"): -init gives the *custom* type, whose title colour is
white.  On a white background that is indistinguishable from a button that
failed to appear, and one can lose a while to it."
  (let ((button (objc:invoke "UIButton" "buttonWithType:" 1)))  ; UIButtonTypeSystem
    (objc:invoke button "setTranslatesAutoresizingMaskIntoConstraints:" nil)
    (objc:invoke button "setTitle:forState:" title 0)          ; UIControlStateNormal
    button))

(defun key-window ()
  (objc:invoke (objc:invoke "UIApplication" "sharedApplication") "keyWindow"))

(defun root-controller ()
  (objc:invoke (key-window) "rootViewController"))

(defun root-view ()
  (objc:invoke (root-controller) "view"))

;;; Appearance ---------------------------------------------------------------

(defun color (red green blue &optional (alpha 1))
  "A UIColor.  Components in [0,1]; any real will do, they are coerced."
  (objc:invoke "UIColor" "colorWithRed:green:blue:alpha:" red green blue alpha))

(defun system-color (name)
  "A named UIColor: \"systemBackground\", \"label\", \"secondarySystemBackground\".
The \"Color\" suffix is supplied."
  (objc:invoke "UIColor" (concatenate 'string name "Color")))

(defun font (size &optional (weight 0))
  "The system font.  WEIGHT is a UIFontWeight: 0 is regular, 0.4 semibold,
0.6 bold, -0.4 light."
  (objc:invoke "UIFont" "systemFontOfSize:weight:" size weight))

(defun mono-font (size &optional (weight 0))
  (objc:invoke "UIFont" "monospacedSystemFontOfSize:weight:" size weight))

(defun bold-font (size)
  (objc:invoke "UIFont" "boldSystemFontOfSize:" size))

;;; Auto layout --------------------------------------------------------------
;;;
;;; An anchor is an object and a constant is a CGFloat, so a whole interface
;;; can be described without naming a rectangle.  The rectangle is available
;;; now -- (objc:invoke view \"bounds\") is a vector of four doubles -- but
;;; constraints are still the way UIKit wants to be told about layout.

(defun anchor (view name)
  "VIEW's layout anchor called NAME: \"topAnchor\", \"centerXAnchor\", ..."
  (objc:invoke view name))

(defun pin (view name other other-name &optional (constant 0))
  "VIEW's NAME anchor equals OTHER's OTHER-NAME anchor, plus CONSTANT.

Both anchor names, always, even when they are the same.  A shorter version
that took one name and used it for both looked tidier and was a trap: the two
arities read almost identically at the call site, and getting them confused is
a PROGRAM-ERROR at run time -- which on a phone means an entry point that dies
before anything reaches the screen."
  (objc:invoke (objc:invoke (anchor view name) "constraintEqualToAnchor:constant:"
                            (anchor other other-name) constant)
               "setActive:" t))

(defun fix (view name constant)
  "VIEW's NAME dimension anchor equals CONSTANT."
  (objc:invoke (objc:invoke (anchor view name) "constraintEqualToConstant:" constant)
               "setActive:" t))

;;; Lisp behind target/action --------------------------------------------------
;;;
;;; UIKit's oldest mechanism: a control, a gesture recognizer or a timer is
;;; given an object and a selector, and sends the selector when something
;;; happens.  The object here is an Objective-C class defined in Lisp whose one
;;; method calls a Lisp function.  Nothing is evaluated from a string, and the
;;; function can close over whatever it likes.

(objc:define-objc-class action-target ()
  ((function :initarg :function :reader action-target-function))
  (:objc-class-name "UIKitActionTarget"))

(objc:define-objc-method ("fire:" :void)
    ((self action-target) (sender objc:objc-object-pointer))
  ;; Nothing may escape into UIKit; the backend reports and returns on a
  ;; condition, but a target that swallows its own errors reads better.
  (handler-case (funcall (action-target-function self) sender)
    (error (condition)
      (format *error-output* "~&uikit action: ~a~%" condition)
      (finish-output *error-output*))))

(defun action-target (function)
  "A pointer to an object that calls FUNCTION with the sender when sent fire:.

Kept for the life of the image: UIKit holds a target weakly, and a Lisp object
that nothing references is collected and its Objective-C half freed -- and the
next tap is a jump into freed memory.  A prototype may leak these; a real
program can UNKEEP one it has finished with."
  (let ((target (make-instance 'action-target :function function)))
    (keep target)
    (objc:objc-object-pointer target)))

(defun on-tap (control function)
  "Call FUNCTION with CONTROL when CONTROL is tapped.  Returns CONTROL."
  (objc:invoke control "addTarget:action:forControlEvents:"
               (action-target function) "fire:"
               64)                                    ; UIControlEventTouchUpInside
  control)

(defun after-every (seconds function &key (repeats t))
  "An NSTimer that calls FUNCTION every SECONDS.  -invalidate it to stop."
  (keep (objc:invoke "NSTimer"
                     "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"
                     seconds (action-target function) "fire:" nil repeats)))

;;; Lifetime -----------------------------------------------------------------

(defvar *kept* '()
  "Objects held for the life of the image, because something on the
Objective-C side holds them only weakly: targets, delegates, data sources,
timers.")

(defun keep (object)
  "Hold OBJECT until UNKEEP.  A foreign pointer is also retained, since a
weak holder will not.  Returns OBJECT."
  (when (cffi:pointerp object)
    (objc:invoke object "retain"))
  (push object *kept*)
  object)

(defun unkeep (object)
  (when (member object *kept*)
    (setf *kept* (remove object *kept*))
    (when (cffi:pointerp object)
      (objc:invoke object "release")))
  object)
