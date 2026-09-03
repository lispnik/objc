;;;; examples/kvo.lisp -- key-value observing, from Lisp.
;;;;
;;;; KVO is the third of Cocoa's three callback mechanisms and the only one this
;;;; library had no example for: notifications are in the COCOA package, target
;;;; and action are in status-item.lisp, and this is the other one.  Set a
;;;; property anywhere in the framework and a Lisp closure runs.
;;;;
;;;; What it exercises is a Lisp-defined class on the receiving end of a
;;;; four-argument framework callback -- key path, object, a change dictionary
;;;; and a context pointer -- which nothing else here does.
;;;;
;;;; IT IS ALSO THE EASIEST WAY TO KILL THE IMAGE, and that is why the example is
;;;; shaped the way it is.  KVO reports misuse by raising an NSException, and
;;;; this library has no @try: an NSException is not a condition you can handle,
;;;; it terminates the process.  Three ways to earn one:
;;;;
;;;;   -removeObserver:forKeyPath: for a registration that is not there.  "Cannot
;;;;   remove an observer ... because it is not registered as an observer."  So
;;;;   STOP-OBSERVING below is idempotent and keyed on a record, rather than
;;;;   trusting the caller to remove each registration exactly once.
;;;;
;;;;   Letting an observed object deallocate while observers remain.  Cocoa's
;;;;   own message is "An instance ... was deallocated while key value observers
;;;;   were still registered with it."  WITH-OBSERVATION exists so the common
;;;;   case unregisters on unwind.
;;;;
;;;;   Observing a key path the class does not have.  That one raises on the way
;;;;   IN, which is at least the better end to fail at.
;;;;
;;;; None of the three is assertable in the test suite, because asserting them
;;;; would end the run.  That is worth saying plainly rather than leaving the
;;;; coverage looking thorough.
;;;;
;;;; The CONTEXT pointer is not decoration either.  A superclass may be observing
;;;; the same key path on the same object, and the only thing distinguishing your
;;;; registration from its is that pointer -- so a callback that acts on key path
;;;; alone will act on somebody else's notification.  Here it carries an integer
;;;; naming the record, which is also how the closure is found.

(in-package #:objc/examples)

;;; Change dictionary keys, read from Foundation --------------------------------

(defun foundation-string-constant (name)
  "The NSString an exported Foundation constant points at.

    (foundation-string-constant \"NSKeyValueChangeNewKey\")   ;; => \"new\"

These are pointers TO an NSString, so the symbol's address has to be
dereferenced once before it is an object.  Reading them beats writing the string
in: the values are documented as opaque, and \"new\" being the current one is not
a promise anybody made."
  (let ((symbol (cffi:foreign-symbol-pointer name)))
    (unless symbol
      (error "No such Foundation constant: ~A" name))
    (cffi:mem-ref symbol :pointer)))

(defparameter +change-kinds+
  '((1 . :setting) (2 . :insertion) (3 . :removal) (4 . :replacement)))

(defconstant +observe-new+ 1)
(defconstant +observe-old+ 2)
(defconstant +observe-initial+ 4)
(defconstant +observe-prior+ 8)

;;; The observer class ----------------------------------------------------------
;;;
;;; One Objective-C class serves every observation; which Lisp closure to run is
;;; decided by the context pointer, exactly as the framework intends.

(defvar *observations* (make-hash-table :test 'eql)
  "Context id -> OBSERVATION.  The context pointer carries the id.")

(defvar *observation-counter* 0)

(defvar *observation-lock* (bt:make-lock "kvo observations"))

(defstruct (observation (:constructor %make-observation)
                        (:print-object print-observation))
  "One live KVO registration.  Stop it with STOP-OBSERVING."
  id object key-path function observer (live t))

(defun print-observation (observation stream)
  (print-unreadable-object (observation stream :type t :identity nil)
    (format stream "~A ~A" (observation-key-path observation)
            (if (observation-live observation) "live" "stopped"))))

(objc:define-objc-class kv-observer ()
  ()
  (:objc-class-name "LispKeyValueObserver"))

(objc:define-objc-method ("observeValueForKeyPath:ofObject:change:context:" :void)
    ((self kv-observer)
     (key-path objc:objc-object-pointer)
     (object objc:objc-object-pointer)
     (change objc:objc-object-pointer)
     (context (:pointer :void)))
  (declare (ignore self))
  (let ((observation (bt:with-lock-held (*observation-lock*)
                       (gethash (cffi:pointer-address context) *observations*))))
    ;; A context we do not know is somebody else's registration, not ours, and
    ;; the documented thing to do is pass it to super.  There is no super worth
    ;; calling here, so ignoring it is the whole of the obligation.
    (when observation
      (funcall (observation-function observation)
               (objc:ns-string-to-string key-path)
               object
               (change-plist change)))))

(defun change-plist (change)
  "The change dictionary as a plist: (:KIND :SETTING :NEW 7 :OLD 3).

Values arrive as objects, so a number comes back as an NSNumber; this unwraps
the ones with an obvious Lisp reading and leaves anything else as the object."
  (flet ((entry (constant)
           (let ((value (objc:invoke change "objectForKey:"
                                     (foundation-string-constant constant))))
             (unless (cffi:null-pointer-p (objc:objc-object-pointer value))
               value))))
    (let ((kind (entry "NSKeyValueChangeKindKey"))
          (new (entry "NSKeyValueChangeNewKey"))
          (old (entry "NSKeyValueChangeOldKey")))
      (append (when kind
                (list :kind (or (cdr (assoc (objc:invoke kind "intValue") +change-kinds+))
                                (objc:invoke kind "intValue"))))
              (when new (list :new (unwrap new)))
              (when old (list :old (unwrap old)))))))

(defun unwrap (object)
  "An NSNumber or NSString as a Lisp value; anything else unchanged.

-isKindOfClass: rather than asking whether it answers -intValue, for the reason
RESPONSE-STATUS in url-session.lisp gives: plenty of objects answer a selector
without that being what they are."
  (cond ((objc:invoke-bool object "isKindOfClass:"
                           (objc:coerce-to-objc-class "NSNumber"))
         (objc:invoke object "doubleValue"))
        ((objc:invoke-bool object "isKindOfClass:"
                           (objc:coerce-to-objc-class "NSString"))
         (objc:ns-string-to-string object))
        (t object)))

;;; Observing --------------------------------------------------------------------

(defun observe (object key-path function &key (options (logior +observe-new+
                                                               +observe-old+)))
  "Call FUNCTION when OBJECT's KEY-PATH changes, and return an OBSERVATION.

FUNCTION is called with (KEY-PATH OBJECT CHANGE), where CHANGE is a plist --
(:KIND :SETTING :NEW 7 :OLD 3).  It runs on whichever thread performed the
change, which for a framework object may not be the main one.

    (let ((progress (objc:alloc-init-object \"NSProgress\")))
      (with-observation (o progress \"completedUnitCount\"
                           (lambda (path object change)
                             (declare (ignore path object))
                             (print change)))
        (objc:invoke progress \"setCompletedUnitCount:\" 3)))

Observing a key path the class does not have raises an NSException, which ends
the process; there is no way to check first that is not itself a send."
  (objc:ensure-objc-initialized)
  (let* ((observer (objc:alloc-init-object "LispKeyValueObserver"))
         (id (bt:with-lock-held (*observation-lock*) (incf *observation-counter*)))
         (observation (%make-observation :id id :object object :key-path key-path
                                         :function function :observer observer)))
    (bt:with-lock-held (*observation-lock*)
      (setf (gethash id *observations*) observation))
    ;; The observer is retained by the registration for as long as it is
    ;; registered, and released by STOP-OBSERVING.
    (objc:invoke object "addObserver:forKeyPath:options:context:"
                 observer key-path options (cffi:make-pointer id))
    observation))

(defun stop-observing (observation)
  "Unregister OBSERVATION.  Idempotent, and that is the point.

-removeObserver:forKeyPath:context: raises an NSException when there is no such
registration, and an NSException here ends the process rather than signalling
something a handler could catch.  So this refuses to remove twice rather than
relying on the caller to count."
  (check-type observation observation)
  (when (observation-live observation)
    (setf (observation-live observation) nil)
    (let ((observer (observation-observer observation)))
      (objc:invoke (observation-object observation)
                   "removeObserver:forKeyPath:context:"
                   observer (observation-key-path observation)
                   (cffi:make-pointer (observation-id observation)))
      (objc:release observer))
    (bt:with-lock-held (*observation-lock*)
      (remhash (observation-id observation) *observations*)))
  nil)

(defmacro with-observation ((var object key-path function &rest options) &body body)
  "Observe for the extent of BODY and unregister on unwind.

The right shape almost always: an observed object that deallocates with
observers still attached raises an NSException, so the window in which that can
happen is worth keeping as short as the code allows."
  `(let ((,var (observe ,object ,key-path ,function ,@options)))
     (unwind-protect (locally ,@body)
       (stop-observing ,var))))

;;; A worked example ---------------------------------------------------------------

(defun test-kvo ()
  "Observe an NSProgress and return a plist of what was seen.

    (objc/examples:test-kvo)
    => (:CHANGES ((:KIND :SETTING :NEW 3.0d0 :OLD 0.0d0)
                  (:KIND :SETTING :NEW 7.0d0 :OLD 3.0d0))
        :CONTEXT-RESPECTED T :IDEMPOTENT T :UNREGISTERED T)

:CONTEXT-RESPECTED is the one that is easy to get wrong invisibly: a second
observation of the same key path on the same object must reach its own closure
and not the first one's, and only the context pointer distinguishes them."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (let ((progress (objc:alloc-init-object "NSProgress"))
          (changes '())
          (other '()))
      (objc:invoke progress "setTotalUnitCount:" 10)
      (let ((first nil))
        (with-observation (observation progress "completedUnitCount"
                                       (lambda (path object change)
                                         (declare (ignore path object))
                                         (push change changes)))
          (setf first observation)
          ;; A second observation of the SAME key path on the SAME object.
          (with-observation (second-observation progress "completedUnitCount"
                                                (lambda (path object change)
                                                  (declare (ignore path object change))
                                                  (push :other other)))
            (declare (ignorable second-observation))
            (objc:invoke progress "setCompletedUnitCount:" 3))
          (objc:invoke progress "setCompletedUnitCount:" 7))
        (list :changes (reverse changes)
              :context-respected (= 1 (length other))
              :idempotent (progn (stop-observing first)
                                 (stop-observing first)
                                 t)
              :unregistered (not (observation-live first)))))))

(defun report-kvo ()
  "Print what TEST-KVO found."
  (let ((result (test-kvo)))
    (format t "~&changes seen:~%")
    (loop for change in (getf result :changes)
          do (format t "  ~S~%" change))
    (format t "a second observation got its own callback: ~A~%"
            (getf result :context-respected))
    (format t "stopping twice is safe: ~A~%" (getf result :idempotent))
    result))
