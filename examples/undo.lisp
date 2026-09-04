;;;; examples/undo.lisp -- NSUndoManager, with Lisp methods as the operations.
;;;;
;;;; An undo manager is a stack of "how to put it back".  Register a target, a
;;;; selector and an argument; call -undo and it sends that message.  Since the
;;;; target can be a Lisp object and the selector a Lisp-implemented method, the
;;;; undo operations are ordinary Lisp code that Cocoa decides when to run.
;;;;
;;;; TWO THINGS ARE NOT OBVIOUS AND BOTH BITE IMMEDIATELY.
;;;;
;;;; -groupsByEvent defaults to YES, which means the manager expects a run loop
;;;; to open and close a group around each event.  From a REPL, a script or a
;;;; test there is no such loop, so the first registration raises:
;;;;
;;;;   NSInternalInconsistencyException: _registerUndoObject:: NSUndoManager is
;;;;   in invalid state, must begin a group before registering undo
;;;;
;;;; -- and an NSException here ends the process.  Turn it off and manage the
;;;; groups yourself, which is what WITH-UNDO-GROUP does.
;;;;
;;;; AN UNDO OPERATION MUST REGISTER ITS OWN INVERSE, or there is no redo.  This
;;;; reads like a curiosity and is the whole design: while -undo is running the
;;;; manager records registrations onto the REDO stack instead of the undo one,
;;;; so a method that always registers the inverse of what it is about to do
;;;; gives you undo and redo from one piece of code.  Leave it out and undo
;;;; works once, -canRedo answers NO, and nothing tells you why.
;;;;
;;;; AND ONE THING THAT CANNOT BE DONE FROM HERE.
;;;; -prepareWithInvocationTarget: is the other registration style: it returns a
;;;; proxy, you send the proxy the message you want undone, and it records the
;;;; NSInvocation.  It does not work with this library and cannot be made to.
;;;; The proxy is an NSUndoManagerProxy, which does not IMPLEMENT the selector --
;;;; it forwards it -- and this library resolves the Method before sending.  That
;;;; resolution is the thing that turns an unimplemented selector into a Lisp
;;;; error instead of an NSException, and the price is that a forwarding object
;;;; is invisible: CAN-INVOKE-P answers NIL and INVOKE signals NO-SUCH-METHOD.
;;;;
;;;; That is not really about undo.  It is true of every proxy that relies on
;;;; -forwardInvocation:, which includes NSXPCConnection's remote object and
;;;; NSDistantObject.  Worth knowing before reaching for one.

(in-package #:objc/examples)

;;; A thing to undo -------------------------------------------------------------------
;;;
;;; A counter is enough: the point is that -setValueFrom: is a Lisp method and
;;; the manager is what decides when to run it.

(defvar *undo-manager* nil
  "The manager COUNTER registers with.  A real document would own one.")

(objc:define-objc-class counter ()
  ((value :initarg :value :initform 0 :accessor counter-value))
  (:objc-class-name "LispUndoCounter"))

;;; The inverse is registered BEFORE the change, and that single line is what
;;; makes redo work: during an undo, the manager is recording onto the redo
;;; stack, so this registers the redo.  The same method serves set, undo and
;;; redo.  NSNumber because the target/selector/object form takes exactly one
;;; object argument.
(objc:define-objc-method ("setValueFrom:" :void)
    ((self counter) (number objc:objc-object-pointer))
  (when *undo-manager*
    (objc:invoke *undo-manager* "registerUndoWithTarget:selector:object:"
                 self (objc:coerce-to-selector "setValueFrom:")
                 (objc:invoke "NSNumber" "numberWithInt:" (counter-value self))))
  (setf (counter-value self) (objc:invoke number "intValue")))

;;; Driving it ---------------------------------------------------------------------------

(defun make-undo-manager ()
  "An NSUndoManager that does not expect a run loop.

-setGroupsByEvent: NO is not optional outside an application: with it left on,
the first registration raises and the process ends.  See the header."
  (objc:ensure-objc-initialized)
  (let ((manager (objc:alloc-init-object "NSUndoManager")))
    (objc:invoke manager "setGroupsByEvent:" nil)
    manager))

(defmacro with-undo-group ((manager &optional name) &body body)
  "Run BODY as one undoable action on MANAGER, named NAME if given.

Groups are what -undo undoes: everything registered between the begin and the
end comes back together."
  (let ((m (gensym "MANAGER")))
    `(let ((,m ,manager))
       (objc:invoke ,m "beginUndoGrouping")
       (unwind-protect (locally ,@body)
         ,@(when name `((objc:invoke ,m "setActionName:" ,name)))
         (objc:invoke ,m "endUndoGrouping")))))

(defun make-counter (&key (value 0) manager)
  "A counter whose changes register undo operations with MANAGER."
  (objc:ensure-objc-initialized)
  (setf *undo-manager* manager)
  (make-instance 'counter :value value))

(defun set-counter (counter value)
  "Set COUNTER, registering the inverse.  Undoable."
  (objc:invoke counter "setValueFrom:"
               (objc:invoke "NSNumber" "numberWithInt:" value))
  (counter-value counter))

(defun undo (manager)
  (objc:invoke manager "undo")
  manager)

(defun redo (manager)
  (objc:invoke manager "redo")
  manager)

(defun undo-state (manager)
  "What MANAGER can do next, as a plist."
  (list :can-undo (objc:invoke-bool manager "canUndo")
        :can-redo (objc:invoke-bool manager "canRedo")
        :undo-name (objc:invoke-into 'string manager "undoActionName")
        :redo-name (objc:invoke-into 'string manager "redoActionName")))

;;; A worked example ---------------------------------------------------------------------

(defun test-undo ()
  "Change a counter, undo it, redo it, and check Cocoa ran the Lisp method.

    (objc/examples:test-undo)
    => (:VALUES (42 0 42 7 42) :ACTION-NAME \"Set Value\" :CAN-REDO-AFTER-UNDO T
        :PROXY-REFUSED T)

:VALUES walks the whole stack: set to 42, undo to 0, redo to 42, set to 7, undo
back to 42.  The last one is the assertion that matters -- undoing after a new
change must return the value from BEFORE that change, which only works if each
call registered its own inverse.

:PROXY-REFUSED records the limitation rather than pretending it is not there:
-prepareWithInvocationTarget: hands back a forwarding proxy, and this library
cannot send to one.  See the header; it is not specific to undo."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (let* ((manager (make-undo-manager))
           (counter (make-counter :manager manager))
           (values '())
           (action nil)
           (can-redo nil))
      (with-undo-group (manager "Set Value")
        (set-counter counter 42))
      (push (counter-value counter) values)
      (setf action (objc:invoke-into 'string manager "undoActionName"))
      (undo manager)
      (push (counter-value counter) values)
      (setf can-redo (objc:invoke-bool manager "canRedo"))
      (redo manager)
      (push (counter-value counter) values)
      (with-undo-group (manager "Set Again")
        (set-counter counter 7))
      (push (counter-value counter) values)
      (undo manager)
      (push (counter-value counter) values)
      (list :values (nreverse values)
            :action-name action
            :can-redo-after-undo can-redo
            :proxy-refused
            (let ((proxy (objc:invoke manager "prepareWithInvocationTarget:" counter)))
              (and (not (objc:can-invoke-p proxy "setValueFrom:"))
                   (handler-case
                       (progn (objc:invoke proxy "setValueFrom:"
                                           (objc:invoke "NSNumber" "numberWithInt:" 1))
                              nil)
                     (error () t))))))))

(defun report-undo ()
  "Print an undo and a redo, with the manager's state at each step."
  (objc:with-autorelease-pool ()
    (let* ((manager (make-undo-manager))
           (counter (make-counter :manager manager)))
      (flet ((show (label)
               (format t "~&~16A value ~3D   ~S~%"
                       label (counter-value counter) (undo-state manager))))
        (show "start")
        (with-undo-group (manager "Set to 42") (set-counter counter 42))
        (show "set 42")
        (undo manager)
        (show "undo")
        (redo manager)
        (show "redo")))))
