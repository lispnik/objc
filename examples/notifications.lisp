;;;; examples/notifications.lisp -- NSNotificationCenter, and where it delivers.
;;;;
;;;; The one broadcast mechanism in Foundation: a poster names a notification,
;;;; anyone who registered for that name gets sent a message, and neither knows
;;;; about the other.  It is also the half of the COCOA package that had no
;;;; example -- ADD-OBSERVER and REMOVE-OBSERVER are two of the eleven symbols
;;;; that package promises, and every notification in this repository was being
;;;; done by hand through INVOKE instead.
;;;;
;;;; NOT KVO.  kvo.lisp observes a key path with -addObserver:forKeyPath:, which
;;;; is a different mechanism with different rules and a much sharper edge; this
;;;; is -addObserver:selector:name:object:.  The contrast is at the bottom of
;;;; this header and it is the most useful thing here.
;;;;
;;;; THE HANDLER RUNS ON THE THREAD THAT POSTED, not the thread that registered.
;;;; Delivery is a synchronous message send inside -postNotificationName:, so
;;;; posting from a worker runs your handler on that worker.  Measured: register
;;;; from the main thread, post from a thread named "poster", and the handler
;;;; reports "poster".  An observer that touches AppKit is therefore only as
;;;; safe as every caller that posts to it, which is not a property you can see
;;;; by reading the observer.
;;;;
;;;; THE CENTER DOES NOT RETAIN THE OBSERVER.  A retain count of 1 before
;;;; -addObserver: and 1 after.  Keeping the observer alive is entirely yours.
;;;;
;;;; BUT A DEAD OBSERVER IS NOT A CRASH, and this is where the advice you will
;;;; find is out of date.  Deallocate an observer without removing it, then
;;;; post: nothing happens, no handler runs, the process lives.  Modern macOS
;;;; zeroes the reference for the selector-based registration.  Measured, not
;;;; assumed -- and it is worth knowing precisely because the folklore says
;;;; otherwise, so people write -dealloc gymnastics for a hazard that is gone.
;;;;
;;;; It is NOT gone for the other two, which is the contrast worth carrying
;;;; away:
;;;;
;;;;   -addObserverForName:object:queue:usingBlock: returns a TOKEN, and the
;;;;   block is retained until you remove that token.  Forget it and the block
;;;;   is called forever.
;;;;
;;;;   KVO still ends the image.  An observed object that deallocates while
;;;;   registrations remain is an NSException, and there is no catching one
;;;;   here.  See kvo.lisp, which exists to say so.
;;;;
;;;; A RUN-LOOP NOTIFICATION NEEDS THE RUN LOOP.  Everything above is
;;;; synchronous and needs nothing.  Foundation's own notifications mostly are
;;;; not: NSTaskDidTerminateNotification is posted onto the run loop of the
;;;; thread that launched the task, so a SLEEP long after the child has exited
;;;; sees nothing at all, and pumping sees it immediately.  Measured: two
;;;; seconds of sleeping after /bin/echo finishes delivers nothing.  This is
;;;; speech.lisp's lesson arriving somewhere much less expected -- a
;;;; notification feels passive, and this one is not.

(in-package #:objc/examples)

;;; An observer ----------------------------------------------------------------------
;;;
;;; The target of -addObserver:selector:name:object: has to be an Objective-C
;;; object, so it is a Lisp-defined class with one Lisp method.  Notifications
;;; are unpacked into plists on arrival rather than kept: the notification and
;;; its userInfo are autoreleased, and holding one past the pool is a
;;; use-after-free that will not announce itself.

(objc:define-objc-class listener ()
  ((received :initform '() :accessor listener-received))
  (:objc-class-name "LispNotificationListener"))

;;; The thread is recorded HERE, inside the handler, because that is the only
;;; place the question can be answered.  Asking afterwards tells you where you
;;; were standing, not where Foundation ran the method.
(objc:define-objc-method ("noted:" :void)
    ((self listener) (notification objc:objc-object-pointer))
  (push (list* :thread (sb-thread:thread-name sb-thread:*current-thread*)
               (notification-plist notification))
        (listener-received self)))

(defun make-listener ()
  "An object that records every notification sent to it."
  (objc:ensure-objc-initialized)
  (make-instance 'listener))

(defun notifications-received (listener)
  "What LISTENER has been sent, oldest first."
  (reverse (listener-received listener)))

(defun forget-notifications (listener)
  "Discard LISTENER's record and return it."
  (setf (listener-received listener) '())
  listener)

(defun notification-plist (notification)
  "NOTIFICATION as (:NAME string :INFO plist), with the userInfo flattened.

userInfo values are arbitrary objects, so they are taken through -description:
this is a worked example rather than a serialiser, and a string is what you want
to look at.  The sender is deliberately not included -- it is a live pointer,
and the whole point of unpacking here is to not keep one."
  (let ((info (objc:invoke notification "userInfo")))
    (list :name (objc:invoke-into 'string notification "name")
          :info (unless (cffi:null-pointer-p (objc:objc-object-pointer info))
                  (let ((keys (objc:invoke info "allKeys"))
                        (plist '()))
                    (dotimes (i (objc:invoke keys "count") (nreverse plist))
                      (let ((key (objc:invoke keys "objectAtIndex:" i)))
                        (push (objc:invoke-into 'string key "description") plist)
                        (push (objc:invoke-into 'string
                                                (objc:invoke info "objectForKey:" key)
                                                "description")
                              plist))))))))

;;; Registering and posting -------------------------------------------------------------

(defun notification-center ()
  "The default NSNotificationCenter."
  (objc:ensure-objc-initialized)
  (objc:invoke "NSNotificationCenter" "defaultCenter"))

(defun subscribe (listener name &key object)
  "Send LISTENER -noted: for every NAME notification.  Returns LISTENER.

OBJECT filters on the SENDER, not on the receiver: give one and only that
object's postings arrive, which is how you observe one task or one window
rather than all of them.  Leave it out and every posting of NAME arrives,
whoever posted it."
  (cocoa:add-observer listener "noted:" :name name :object object)
  listener)

(defun unsubscribe (listener &key name object)
  "Undo SUBSCRIBE.  With no NAME, removes LISTENER from everything.

Unlike KVO's remover this does not raise when there was no registration, so it
is safe to call unconditionally -- and unlike KVO, failing to call it at all is
no longer a crash.  It is still a leak of a registration that will keep firing
while the listener lives, which is reason enough."
  (cocoa:remove-observer listener :name name :object object))

(defmacro with-subscription ((listener name &key object) &body body)
  "Run BODY with LISTENER observing NAME, removing the registration afterwards."
  (let ((l (gensym "LISTENER"))
        (n (gensym "NAME"))
        (o (gensym "OBJECT")))
    `(let ((,l ,listener) (,n ,name) (,o ,object))
       (subscribe ,l ,n :object ,o)
       (unwind-protect (locally ,@body)
         (unsubscribe ,l :name ,n :object ,o)))))

(defun post-notification (name &key object info)
  "Post NAME, optionally from OBJECT and carrying INFO, a plist of strings.

Synchronous: every observer's handler has run by the time this returns, on THIS
thread.  There is no queue and nothing is deferred."
  (objc:ensure-objc-initialized)
  (objc:invoke (notification-center) "postNotificationName:object:userInfo:"
               name
               (or object (cffi:null-pointer))
               (if info
                   (let ((dictionary (objc:alloc-init-object "NSMutableDictionary")))
                     (loop for (key value) on info by #'cddr
                           do (objc:invoke dictionary "setObject:forKey:"
                                           (princ-to-string value)
                                           ;; A keyword prints as WHO, and the
                                           ;; key is what an observer matches
                                           ;; on, so downcase rather than
                                           ;; hand out shouting.
                                           (if (symbolp key)
                                               (string-downcase (symbol-name key))
                                               (princ-to-string key))))
                     (objc:autorelease dictionary))
                   (cffi:null-pointer)))
  name)

;;; The asynchronous half ------------------------------------------------------------------

(defparameter +task-terminated+ "NSTaskDidTerminateNotification")

(defun run-briefly (&key (pump t) (seconds 5))
  "Run /bin/echo and wait for its termination notification.  Returns a plist.

    (run-briefly)             => (:TERMINATED T ...)
    (run-briefly :pump nil)   => (:TERMINATED NIL ...)

The two answers are the example.  NSTaskDidTerminateNotification is posted onto
the run loop of the thread that launched the task, so waiting by sleeping never
sees it however long you wait -- the child exited in milliseconds and the
notification is sitting in a source nobody is servicing.  PUMP-EVENTS is what
services it."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (let ((listener (make-listener))
          (task (objc:autorelease (objc:alloc-init-object "NSTask"))))
      (with-subscription (listener +task-terminated+)
        (objc:invoke task "setLaunchPath:" "/bin/echo")
        (objc:invoke task "setArguments:"
                     (objc:invoke "NSArray" "arrayWithObject:" "hello"))
        ;; The child's stdout is ours, and an example that scribbles on the
        ;; test suite's output is a nuisance; /bin/echo is here to exit, not
        ;; to say anything.
        (objc:invoke task "setStandardOutput:"
                     (objc:invoke "NSFileHandle" "fileHandleWithNullDevice"))
        (objc:invoke task "launch")
        (let ((deadline (+ (get-internal-real-time)
                           (* seconds internal-time-units-per-second))))
          (if pump
              (loop until (or (listener-received listener)
                              (> (get-internal-real-time) deadline))
                    do (objc.runloop:pump-events :seconds 0.02d0 :max-seconds 0.2d0))
              ;; Deliberately the wrong way: the child is long gone.
              (sleep (min seconds 0.5))))
        (list :terminated (and (listener-received listener) t)
              :pumped pump
              :notifications (notifications-received listener))))))

;;; A worked example -------------------------------------------------------------------------

(defun test-notifications ()
  "Post, filter, cross a thread, and check where the handler ran.

    (objc/examples:test-notifications)
    => (:RECEIVED ((:THREAD \"main thread\" :NAME \"ExampleNote\"
                    :INFO (\"who\" \"a value\")))
        :WRONG-SENDER-IGNORED T :RIGHT-SENDER-HEARD T
        :RETAINED-BY-CENTER NIL :HANDLER-THREAD \"poster\"
        :TASK-WITH-PUMPING T :TASK-WITH-SLEEPING NIL)

:HANDLER-THREAD is the assertion that matters and the one nothing else here
would catch.  The listener is registered on this thread and the notification is
posted from a thread named \"poster\"; the handler reports the poster's name,
because delivery is a plain message send on whichever thread called -post.

:TASK-WITH-SLEEPING is the other one.  Both halves run the same task the same
way and differ only in how they wait, and the one that sleeps never hears
anything at all."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (let ((listener (make-listener))
          (received nil)
          (wrong nil)
          (right nil)
          (retained nil)
          (handler-thread nil))
      ;; The plain case, with a userInfo.
      (with-subscription (listener "ExampleNote")
        (setf retained (/= 1 (objc:retain-count listener)))
        (post-notification "ExampleNote" :info '(:who "a value"))
        (setf received (notifications-received listener)))
      ;; Filtering on the sender.
      (forget-notifications listener)
      (let ((mine (objc:autorelease (objc:alloc-init-object "NSObject")))
            (theirs (objc:autorelease (objc:alloc-init-object "NSObject"))))
        (with-subscription (listener "FilteredNote" :object mine)
          (post-notification "FilteredNote" :object theirs)
          (setf wrong (null (listener-received listener)))
          (post-notification "FilteredNote" :object mine)
          (setf right (and (listener-received listener) t))))
      ;; Which thread the handler runs on.  Posted from "poster"; the handler
      ;; records its own thread, so the answer is Foundation's, not ours.
      (forget-notifications listener)
      (with-subscription (listener "ThreadedNote")
        (sb-thread:join-thread
         (sb-thread:make-thread
          (lambda () (objc:with-autorelease-pool () (post-notification "ThreadedNote")))
          :name "poster"))
        (setf handler-thread
              (getf (first (notifications-received listener)) :thread)))
      (list :received received
            :wrong-sender-ignored wrong
            :right-sender-heard right
            :retained-by-center retained
            :handler-thread handler-thread
            :task-with-pumping (getf (run-briefly) :terminated)
            :task-with-sleeping (getf (run-briefly :pump nil) :terminated)))))

(defun report-notifications ()
  "Print the same walk, as you would read it at a REPL."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (let ((listener (make-listener)))
      (with-subscription (listener "ExampleNote")
        (format t "~&retain count while observed: ~D (the center does not retain)~%"
                (objc:retain-count listener))
        (post-notification "ExampleNote" :info '(:who "a value" :when "now"))
        (dolist (note (notifications-received listener))
          (format t "  ~A  ~S~%" (getf note :name) (getf note :info)))))
    (format t "~&/bin/echo, waited on two ways:~%")
    (dolist (pump '(t nil))
      (let ((result (run-briefly :pump pump)))
        (format t "  ~10A terminated ~A~%"
                (if pump "pumping" "sleeping")
                (getf result :terminated))))))
