;;;; examples/file-coordinator.lisp -- the other way to watch a file.
;;;;
;;;; file-watcher.lisp watches with a dispatch source; this one registers an
;;;; NSFilePresenter with NSFileCoordinator.  Both tell you a file changed, and
;;;; the difference between them is worth an example on its own.
;;;;
;;;; A VNODE SOURCE WATCHES AN INODE; A PRESENTER WATCHES A PATH.  That is the
;;;; whole of it, and everything else follows.  An editor saving by writing a
;;;; temporary and renaming it over the original leaves the dispatch source
;;;; holding a descriptor for a file that no longer has that name -- which is
;;;; why file-watcher.lisp has re-arming machinery, and why it goes silent
;;;; without it.  A presenter is not holding a descriptor, so the same save
;;;; needs nothing: measured, a write to the replacing file still arrives.
;;;;
;;;; It is also a Lisp class adopting a framework PROTOCOL, which nothing else
;;;; here does.  -presentedItemURL and -presentedItemOperationQueue are required
;;;; and answered from the instance's own slots, so the object really is the
;;;; presenter rather than a shim around a global.
;;;;
;;;; What a presenter can do that a dispatch source cannot: be told where the
;;;; file WENT (-presentedItemDidMoveToURL:), be asked to accommodate a deletion
;;;; before it happens, and make a coordinated writer WAIT.  What it costs: only
;;;; coordinated writers wait for you, and most writers are not coordinated.
;;;;
;;;; Uncoordinated changes are still reported, which surprised me -- I expected a
;;;; presenter to see only coordinated access.  Both a plain write and a
;;;; coordinated one notify.

(in-package #:objc/examples)

(defun ensure-file-coordination ()
  (objc:ensure-objc-initialized
   :modules '("/System/Library/Frameworks/AppKit.framework/AppKit")))

;;; The presenter -----------------------------------------------------------------
;;;
;;; A Lisp class adopting NSFilePresenter.  The protocol's two required members
;;; are properties, so they are methods here, answered from CLOS slots -- which
;;; is the point of STANDARD-OBJC-OBJECT: SELF in a method body is the Lisp
;;; instance, so an instance can carry Lisp state a C object could not.

(objc:define-objc-class file-presenter ()
  ((url :initarg :url :accessor presenter-url)
   (queue :initarg :queue :reader presenter-queue)
   (function :initarg :function :reader presenter-function)
   (live :initform t :accessor presenter-live))
  (:objc-class-name "LispFilePresenter")
  (:objc-protocols "NSFilePresenter"))

(objc:define-objc-method ("presentedItemURL" objc:objc-object-pointer)
    ((self file-presenter))
  (presenter-url self))

(objc:define-objc-method ("presentedItemOperationQueue" objc:objc-object-pointer)
    ((self file-presenter))
  (presenter-queue self))

(objc:define-objc-method ("presentedItemDidChange" :void) ((self file-presenter))
  (report-presenter-event self :changed nil))

(objc:define-objc-method ("presentedItemDidMoveToURL:" :void)
    ((self file-presenter) (url objc:objc-object-pointer))
  ;; The presenter is TOLD where the file went and updates itself.  A dispatch
  ;; source gets no such courtesy: it holds a descriptor and has to notice.
  (setf (presenter-url self) (objc:invoke url "retain"))
  (report-presenter-event self :moved (objc:invoke-into 'string url "path")))

(objc:define-objc-method ("accommodatePresentedItemDeletionWithCompletionHandler:" :void)
    ((self file-presenter) (completion objc:objc-object-pointer))
  ;; The deletion has not happened yet; it waits for the completion block.  This
  ;; is the cooperative half of coordination and a dispatch source has no
  ;; equivalent -- it learns about a deletion afterwards.
  (report-presenter-event self :deleted nil)
  (objc:call-objc-block '(:void (objc:objc-object-pointer)) completion
                        (cffi:null-pointer)))

(defun report-presenter-event (presenter event argument)
  (when (presenter-live presenter)
    (ignore-errors (funcall (presenter-function presenter) event argument))))

;;; Watching --------------------------------------------------------------------------

(defun watch-coordinated (path function)
  "Call FUNCTION when the file at PATH changes, and return the presenter.

FUNCTION is called as (EVENT ARGUMENT): (:CHANGED NIL), (:MOVED \"/new/path\")
or (:DELETED NIL).  It runs on the presenter's own serial operation queue.

Unlike WATCH, this needs no re-arming across an editor's save: the presenter
follows the path rather than the descriptor."
  (ensure-file-coordination)
  (let* ((file (or (uiop:truename* path) (error "No such file: ~A" path)))
         (url (objc:invoke (objc:invoke "NSURL" "fileURLWithPath:" (namestring file))
                           "retain"))
         (queue (objc:alloc-init-object "NSOperationQueue"))
         (presenter (make-instance 'file-presenter :url url :queue queue
                                                   :function function)))
    (objc:invoke queue "setMaxConcurrentOperationCount:" 1)
    (objc:invoke queue "setName:" "lisp.file-presenter")
    (objc:invoke "NSFileCoordinator" "addFilePresenter:" presenter)
    presenter))

(defun unwatch-coordinated (presenter)
  "Deregister PRESENTER.  Idempotent.

Leaving one registered is worse than leaving a dispatch source running: a
coordinated writer will wait on a presenter that no longer answers."
  (when (presenter-live presenter)
    (setf (presenter-live presenter) nil)
    (objc:invoke "NSFileCoordinator" "removeFilePresenter:" presenter))
  nil)

(defmacro with-coordinated-watch ((var path function) &body body)
  `(let ((,var (watch-coordinated ,path ,function)))
     (unwind-protect (locally ,@body)
       (unwatch-coordinated ,var))))

(defun pump-for (seconds)
  "Service the run loop for SECONDS, so callbacks can arrive.

The presenter's queue delivers, but the coordination machinery wants the run
loop turning; a REPL that only sleeps sees nothing.  Same lesson as
speech.lisp."
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second))))
    (loop while (< (get-internal-real-time) deadline)
          do (objc.runloop:pump-events :seconds 0.02d0 :max-seconds 0.1d0))))

;;; Coordinated access -------------------------------------------------------------------

(defun coordinated-write (path function)
  "Call FUNCTION to write PATH, with every other presenter held off meanwhile.

    (coordinated-write #p\"/tmp/notes.txt\"
                       (lambda (path)
                         (with-open-file (out path :direction :output
                                                   :if-exists :append)
                           (write-line \"appended\" out))))

This is the half of coordination that a dispatch source cannot participate in
at all: another process's presenter is asked to relinquish before FUNCTION runs
and told about the change afterwards."
  (ensure-file-coordination)
  (objc:with-autorelease-pool ()
    (let ((coordinator (objc:invoke (objc:invoke "NSFileCoordinator" "alloc")
                                    "initWithFilePresenter:" (cffi:null-pointer)))
          (url (objc:invoke "NSURL" "fileURLWithPath:"
                            (namestring (or (uiop:truename* path) path)))))
      (objc:with-objc-block
          (block '(:void (objc:objc-object-pointer))
                 (lambda (actual)
                   (funcall function (pathname (objc:invoke-into 'string actual
                                                                 "path")))))
        (objc:invoke coordinator "coordinateWritingItemAtURL:options:error:byAccessor:"
                     url 0 (cffi:null-pointer) block)))
    path))

;;; A worked example -----------------------------------------------------------------------

(defun test-file-coordinator (&key (settle 1.5))
  "Watch a file with a presenter, save over it atomically, and keep watching.

    (objc/examples:test-file-coordinator)
    => (:SAW-CHANGE T :SURVIVED-ATOMIC-SAVE T :COORDINATED-WRITE-SEEN T)

:SURVIVED-ATOMIC-SAVE is the whole point, and the direct contrast with
file-watcher.lisp.  A dispatch source holds a descriptor, so after an editor's
write-temporary-and-rename it is watching a file that no longer has that name
and must be re-armed.  A presenter holds the path, so the same save needs
nothing at all -- and this asserts the case that matters, a write to the file
that REPLACED the original."
  (ensure-file-coordination)
  (let* ((directory (uiop:ensure-directory-pathname
                     (format nil "~Aobjc-presenter-~D"
                             (uiop:temporary-directory) (get-universal-time))))
         (file (merge-pathnames "watched.txt" directory))
         (temporary (merge-pathnames "watched.new" directory))
         (events '())
         (lock (bt:make-lock "presenter")))
    (ensure-directories-exist directory)
    (with-open-file (out file :direction :output :if-exists :supersede)
      (write-string "one" out))
    (labels ((note (event argument)
               (declare (ignore argument))
               (bt:with-lock-held (lock) (push event events)))
             (saw-change-p ()
               "Wait, then report whether a change arrived, and reset."
               (pump-for settle)
               (bt:with-lock-held (lock)
                 (prog1 (and (member :changed events) t)
                   (setf events '()))))
             (append-to (path text)
               (with-open-file (out path :direction :output :if-exists :append)
                 (write-string text out)
                 (finish-output out))))
      (unwind-protect
           (with-coordinated-watch (presenter file #'note)
             (declare (ignorable presenter))
             (saw-change-p)                     ; settle, and discard whatever
             ;; 1: an ordinary write
             (append-to file " two")
             (let ((saw-change (saw-change-p)))
               ;; 2: an atomic save, then a write to the file that replaced it
               (with-open-file (out temporary :direction :output :if-exists :supersede)
                 (write-string "replaced" out))
               (rename-file temporary file)
               (saw-change-p)                   ; the save itself; not asserted
               (append-to file " three")
               (let ((survived (saw-change-p)))
                 ;; 3: a coordinated write
                 (coordinated-write file (lambda (actual) (append-to actual " four")))
                 (list :saw-change saw-change
                       :survived-atomic-save survived
                       :coordinated-write-seen (saw-change-p)))))
        (ignore-errors (uiop:delete-directory-tree directory :validate t))))))

(defun report-file-coordinator ()
  "Print what TEST-FILE-COORDINATOR found, with the contrast spelled out."
  (let ((result (test-file-coordinator)))
    (format t "~&an ordinary write was reported:        ~A~%" (getf result :saw-change))
    (format t "the watch survived an atomic save:     ~A  (no re-arming)~%"
            (getf result :survived-atomic-save))
    (format t "a coordinated write was reported:      ~A~%"
            (getf result :coordinated-write-seen))
    (format t "~%file-watcher.lisp needs :REARM for the second of those, because a~%~
                dispatch source holds a descriptor and a presenter holds a path.~%")
    result))
