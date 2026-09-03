;;;; examples/file-watcher.lisp -- watching the filesystem with dispatch sources.
;;;;
;;;; A dispatch source turns something the kernel notices -- a file changing, a
;;;; timer expiring, a signal arriving -- into a block on a queue.  This is the
;;;; one example here you might actually keep: watch a directory, recompile when
;;;; it changes, from a REPL that stays live throughout.
;;;;
;;;; It needs nothing from Objective-C.  dispatch_source_create and friends are C
;;;; functions, and what they want is a BLOCK -- so, exactly as with GCD, block
;;;; creation is the whole of what makes this reachable.  A dozen defcfuns and
;;;; the work is an ordinary Lisp closure.
;;;;
;;;; THE TRAP, and it is the reason most hand-rolled file watchers quietly stop
;;;; working.  A vnode source watches a FILE DESCRIPTOR, not a path.  Almost
;;;; every editor saves by writing a temporary file and renaming it over the
;;;; original -- Emacs and vim both do -- so after one save the descriptor refers
;;;; to a file that no longer has that name, and the watcher goes silent while
;;;; looking perfectly healthy.  Two answers, and this file offers both:
;;;;
;;;;   :REARM (the default) reopens the path when the source reports a delete or
;;;;   a rename, so the watch follows the name rather than the descriptor.
;;;;
;;;;   Watching the containing DIRECTORY instead is the more robust shape: a
;;;;   directory's descriptor survives whatever happens to the files in it, and
;;;;   its :WRITE fires when entries are added, removed or renamed.
;;;;
;;;; The queue is serial, so only one handler is ever inside Lisp at a time and
;;;; this is safe on a stock SBCL.  See the header of gcd.lisp for why that
;;;; matters.

(in-package #:objc/examples)

;;; The C entry points ---------------------------------------------------------

(cffi:defcfun ("open" %open) :int (path :string) (flags :int))
(cffi:defcfun ("close" %close) :int (fd :int))

(cffi:defcfun ("dispatch_source_create" %dispatch-source-create) :pointer
  (type :pointer) (handle :unsigned-long) (mask :unsigned-long) (queue :pointer))
(cffi:defcfun ("dispatch_source_set_event_handler" %dispatch-source-set-event-handler)
    :void (source :pointer) (handler :pointer))
(cffi:defcfun ("dispatch_source_set_cancel_handler" %dispatch-source-set-cancel-handler)
    :void (source :pointer) (handler :pointer))
(cffi:defcfun ("dispatch_source_get_data" %dispatch-source-get-data) :unsigned-long
  (source :pointer))
(cffi:defcfun ("dispatch_source_set_timer" %dispatch-source-set-timer) :void
  (source :pointer) (start :uint64) (interval :uint64) (leeway :uint64))
(cffi:defcfun ("dispatch_resume" %dispatch-resume) :void (object :pointer))
(cffi:defcfun ("dispatch_source_cancel" %dispatch-source-cancel) :void (source :pointer))

(defconstant +o-evtonly+ #x8000
  "Open for event notification only: no read, no write, and it does not stop the
volume being unmounted.")

;;; Events ---------------------------------------------------------------------

(defparameter +vnode-events+
  '((:delete . 1) (:write . 2) (:extend . 4) (:attrib . 8)
    (:link . #x10) (:rename . #x20) (:revoke . #x40))
  "The DISPATCH_VNODE_* flags, as keywords.")

(defun events-mask (events)
  (reduce #'logior events
          :key (lambda (event)
                 (or (cdr (assoc event +vnode-events+))
                     (error "Unknown file event ~S; expected one of ~{~S~^, ~}."
                            event (mapcar #'car +vnode-events+))))
          :initial-value 0))

(defun mask-events (mask)
  "MASK as the list of keywords it stands for, which is what a handler is given."
  (loop for (event . bit) in +vnode-events+
        when (logtest mask bit) collect event))

;;; Watching -------------------------------------------------------------------

(defstruct (watcher (:constructor %make-watcher) (:print-object print-watcher))
  "A live filesystem watch.  Stop it with UNWATCH."
  path source fd queue function events rearm (live t))

(defun print-watcher (watcher stream)
  (print-unreadable-object (watcher stream :type t :identity nil)
    (format stream "~A ~A" (watcher-path watcher)
            (if (watcher-live watcher) "live" "stopped"))))

(defun watch (path function &key (events '(:write :extend :delete :rename :attrib))
                                 (rearm t) queue)
  "Call FUNCTION when PATH changes, and return a WATCHER.

FUNCTION is called with one argument, the list of events that fired -- (:WRITE
:EXTEND) for an ordinary append.  It runs on a serial queue, on a thread SBCL did
not create, so it needs its own autorelease pool if it touches Cocoa.

PATH may be a directory, and that is the more robust thing to watch; see the
header.  With REARM true a file watch reopens the path after a delete or rename,
which is what keeps it working across an editor's save.

    (defvar *w* (watch #p\"/tmp/notes.txt\"
                       (lambda (events) (format t \"~&changed: ~S~%\" events))))
    (unwatch *w*)"
  (objc:ensure-objc-initialized)
  (let* ((namestring (namestring (if (pathnamep path) path (pathname path))))
         (fd (%open namestring +o-evtonly+)))
    (when (minusp fd)
      (error "Cannot watch ~A: it could not be opened." namestring))
    (let* ((queue (or queue (serial-queue "lisp.file-watcher")))
           (watcher (%make-watcher :path namestring :fd fd :queue queue
                                   :function function :events events :rearm rearm)))
      (arm-watcher watcher)
      watcher)))

(defun arm-watcher (watcher)
  "Create and start the dispatch source for WATCHER's current descriptor.

Separate from WATCH because re-arming after a rename does exactly this again with
a fresh descriptor."
  (let ((source (%dispatch-source-create
                 (or (cffi:foreign-symbol-pointer "_dispatch_source_type_vnode")
                     (error "libdispatch has no vnode source type."))
                 (watcher-fd watcher)
                 (events-mask (watcher-events watcher))
                 (watcher-queue watcher))))
    (when (cffi:null-pointer-p source)
      (error "Could not create a dispatch source for ~A." (watcher-path watcher)))
    (setf (watcher-source watcher) source)
    ;; The handler and the cancel handler are both blocks, and both are copied
    ;; by libdispatch here, so WITH-OBJC-BLOCK is right for each: what it frees
    ;; is our storage and our reference, not the closure.
    (objc:with-objc-block (handler '(:void ())
                                   (lambda () (handle-watch-event watcher)))
      (%dispatch-source-set-event-handler source (objc:objc-block-pointer handler)))
    (let ((fd (watcher-fd watcher)))
      ;; Closing the descriptor belongs in the cancel handler and nowhere else:
      ;; cancellation is asynchronous, and this runs after the source has stopped
      ;; and no handler is still using it.  Closing it at UNWATCH would race.
      (objc:with-objc-block (cancel '(:void ()) (lambda () (%close fd)))
        (%dispatch-source-set-cancel-handler source (objc:objc-block-pointer cancel))))
    (%dispatch-resume source)
    source))

(defun handle-watch-event (watcher)
  (let* ((mask (%dispatch-source-get-data (watcher-source watcher)))
         (events (mask-events mask)))
    ;; Re-arm BEFORE running the handler, not after.  The order looked arbitrary
    ;; and is not: a caller that reacts to the rename by writing to the file --
    ;; or merely by returning, after which anything may write -- would land in
    ;; the gap between the old descriptor going stale and the new one being
    ;; armed, and that write would be missed.  Which is exactly the failure
    ;; re-arming exists to prevent.  Measured: with the handler first, a write
    ;; issued the moment the rename was reported was lost every run.
    (when (and (watcher-rearm watcher)
               (or (member :delete events) (member :rename events))
               (watcher-live watcher))
      (rearm-watcher watcher))
    (funcall (watcher-function watcher) events)))

(defun rearm-watcher (watcher)
  "Follow the path to its new descriptor after a delete or a rename.

The old source is cancelled -- which closes the old descriptor through its cancel
handler -- and a new one is armed on a freshly opened path.  If the path is gone
for good, the watch stops and says so."
  (%dispatch-source-cancel (watcher-source watcher))
  (let ((fd (%open (watcher-path watcher) +o-evtonly+)))
    (cond ((minusp fd)
           (setf (watcher-live watcher) nil))
          (t
           (setf (watcher-fd watcher) fd)
           (arm-watcher watcher)))))

(defun unwatch (watcher)
  "Stop WATCHER.  Idempotent.

The descriptor is closed by the source's cancel handler rather than here; see
ARM-WATCHER."
  (check-type watcher watcher)
  (when (watcher-live watcher)
    (setf (watcher-live watcher) nil)
    (%dispatch-source-cancel (watcher-source watcher))
    (when (watcher-queue watcher)
      (objc:release (watcher-queue watcher))
      (setf (watcher-queue watcher) nil)))
  nil)

(defmacro with-watch ((watcher path function &rest options) &body body)
  "Watch PATH for the extent of BODY."
  `(let ((,watcher (watch ,path ,function ,@options)))
     (unwind-protect (progn ,@body)
       (unwatch ,watcher))))

;;; Timers, the other source everyone wants ------------------------------------

(defstruct (repeater (:constructor %make-repeater))
  "A periodic timer.  Stop it with STOP-REPEATING."
  source queue (live t))

(defun every-seconds (seconds function &key (leeway 0.1))
  "Call FUNCTION every SECONDS on a serial queue, and return a REPEATER.

LEEWAY is how much the system may drift the timer to coalesce wakeups, in
seconds; being generous with it is being kind to the battery."
  (objc:ensure-objc-initialized)
  (let* ((queue (serial-queue "lisp.repeater"))
         (source (%dispatch-source-create
                  (or (cffi:foreign-symbol-pointer "_dispatch_source_type_timer")
                      (error "libdispatch has no timer source type."))
                  0 0 queue))
         (nanoseconds (round (* seconds 1000000000))))
    (objc:with-objc-block (handler '(:void ()) function)
      (%dispatch-source-set-event-handler source (objc:objc-block-pointer handler)))
    ;; DISPATCH_TIME_NOW is 0, so the first firing is one interval away.
    (%dispatch-source-set-timer source nanoseconds nanoseconds
                                (round (* leeway 1000000000)))
    (%dispatch-resume source)
    (%make-repeater :source source :queue queue)))

(defun stop-repeating (repeater)
  "Stop REPEATER.  Idempotent."
  (check-type repeater repeater)
  (when (repeater-live repeater)
    (setf (repeater-live repeater) nil)
    (%dispatch-source-cancel (repeater-source repeater))
    (objc:release (repeater-queue repeater))
    (setf (repeater-queue repeater) nil))
  nil)

;;; A worked example -----------------------------------------------------------

(defun test-file-watcher (&key (timeout 10))
  "Exercise a file watch, an atomic save, a directory watch and a timer.

    (objc/examples:test-file-watcher)
    => (:WRITE (:WRITE :EXTEND) :SURVIVED-ATOMIC-SAVE T :DIRECTORY T :TIMER 3)

:SURVIVED-ATOMIC-SAVE is the one that matters, and it has to be asked carefully.
The file is replaced the way an editor replaces it, by renaming a temporary over
it; a watcher keyed on the descriptor still reports THAT, because the rename is
what its descriptor sees happening.  What it cannot see is the next write, to
the file now holding the name.  So this writes again afterwards and requires an
event -- which is the difference between a watch that works and one that has
gone silent while still answering WATCHER-LIVE with true.  Measured with
:REARM NIL, the second write produces nothing at all."
  (objc:ensure-objc-initialized)
  (let* ((directory (uiop:ensure-directory-pathname
                     (format nil "~Aobjc-watch-~D"
                             (uiop:temporary-directory) (get-universal-time))))
         (file (merge-pathnames "watched.txt" directory))
         (temporary (merge-pathnames "watched.new" directory)))
    (ensure-directories-exist directory)
    (with-open-file (out file :direction :output :if-exists :supersede)
      (write-string "one" out))
    (unwind-protect
         (let ((first-events nil)
               (after-save nil)
               (replaced nil)
               (directory-saw nil)
               (ticks 0)
               (wrote (bt:make-semaphore))
               (saved (bt:make-semaphore))
               (rewrote (bt:make-semaphore))
               (dir-event (bt:make-semaphore))
               (ticked (bt:make-semaphore)))
           ;; 1 and 2: a file watch, then the same watch across an atomic save
           ;; AND a write to the file that replaced it.
           (with-watch (watcher file
                                (lambda (events)
                                  (cond ((not replaced)
                                         (unless first-events
                                           (setf first-events events)
                                           (bt:signal-semaphore wrote))
                                         (when (or (member :delete events)
                                                   (member :rename events))
                                           (bt:signal-semaphore saved)))
                                        ((member :write events)
                                         (unless after-save
                                           (setf after-save events)
                                           (bt:signal-semaphore rewrote))))))
             (with-open-file (out file :direction :output :if-exists :append)
               (write-string " two" out)
               (finish-output out))
             (bt:wait-on-semaphore wrote :timeout timeout)
             ;; Exactly what an editor does: write elsewhere, rename over.
             (with-open-file (out temporary :direction :output :if-exists :supersede)
               (write-string "replaced" out))
             (rename-file temporary file)
             (bt:wait-on-semaphore saved :timeout timeout)
             (setf replaced t)
             ;; The write only a re-armed watch can see.
             (with-open-file (out file :direction :output :if-exists :append)
               (write-string " three" out)
               (finish-output out))
             (bt:wait-on-semaphore rewrote :timeout timeout)
             (setf after-save (and after-save (watcher-live watcher) t)))
           ;; 3: watching the directory, which survives all of that by nature.
           (with-watch (directory-watcher directory
                                          (lambda (events)
                                            (unless directory-saw
                                              (setf directory-saw events)
                                              (bt:signal-semaphore dir-event)))
                                          :events '(:write))
             (with-open-file (out (merge-pathnames "appeared.txt" directory)
                                  :direction :output :if-exists :supersede)
               (write-string "new file" out))
             (bt:wait-on-semaphore dir-event :timeout timeout)
             (setf directory-saw (and directory-saw
                                      (watcher-live directory-watcher))))
           ;; 4: a timer.
           (let ((repeater (every-seconds 0.05 (lambda ()
                                                 (when (<= (incf ticks) 3)
                                                   (when (= ticks 3)
                                                     (bt:signal-semaphore ticked)))))))
             (unwind-protect (bt:wait-on-semaphore ticked :timeout timeout)
               (stop-repeating repeater)))
           (list :write first-events
                 :survived-atomic-save (and after-save t)
                 :directory (and directory-saw t)
                 :timer (min ticks 3)))
      (ignore-errors (uiop:delete-directory-tree directory :validate t)))))

(defun report-file-watcher ()
  "Print what TEST-FILE-WATCHER found."
  (let ((result (test-file-watcher)))
    (format t "~&a write reported ~S~%" (getf result :write))
    (format t "the watch survived an atomic save: ~A~%"
            (getf result :survived-atomic-save))
    (format t "a directory watch saw a new file: ~A~%" (getf result :directory))
    (format t "a timer fired ~D times~%" (getf result :timer))
    result))
