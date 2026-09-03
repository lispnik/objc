;;;; examples/gcd.lisp -- Grand Central Dispatch, driven from Lisp.
;;;;
;;;; LispWorks ships this example too, at examples/fli/grand-central-dispatch.lisp,
;;;; and what it shows is that GCD needs no Objective-C support at all: its entry
;;;; points are plain C functions, and the LispWorks version declares each one
;;;; with fli:define-foreign-function.  Every one of them takes a BLOCK, which is
;;;; why that example lives under the FLI rather than under OBJC --
;;;; fli:allocate-foreign-block is the whole of what makes it possible.
;;;;
;;;; So this file is the shortest honest answer to "what did block creation
;;;; buy".  The dispatch functions below are three lines of CFFI each; the
;;;; interesting part is that the work they run is an ordinary Lisp closure,
;;;; scheduled by the same queues Cocoa schedules its own work on.
;;;;
;;;; ONE LIBDISPATCH THREAD IN LISP AT A TIME.  This is the limit that shapes
;;;; everything below, and it is SBCL's rather than GCD's.  A block runs on a
;;;; thread SBCL did not create; SBCL adopts it for the duration of the
;;;; callback, and stopping the world for a garbage collection means sending
;;;; every other thread in Lisp a signal.  Darwin refuses to signal a
;;;; libdispatch worker thread at all -- pthread_kill returns ENOTSUP on one
;;;; even for signal 0, where an ordinary SBCL thread returns 0 -- and a single
;;;; block gets away with it only because the collector skips the thread that
;;;; triggered the collection.  With two, the second has to be signalled and
;;;; cannot be:
;;;;
;;;;     fatal error encountered in SBCL: cannot suspend thread ...:
;;;;     45, Operation not supported
;;;;
;;;; -- the process, immediately, with no condition and no Lisp backtrace.
;;;; Measured, not inferred: eight concurrent allocating blocks kill it every
;;;; time, and so does dispatch_apply.  Nor does serialising Lisp entry with a
;;;; lock help: a worker parked on a Lisp lock has already been adopted, and
;;;; still has to be signalled.
;;;;
;;;; What IS safe on a stock build: dispatch_sync; any number of blocks on a
;;;; SERIAL queue, which by construction runs one at a time; and the main Lisp
;;;; thread working away while a queue thread is inside a callback.  So
;;;; GROUP-ASYNC defaults to a serial queue, and the concurrent global queues
;;;; are here for DISPATCH-SYNC.
;;;;
;;;; AND THE LIMIT LIFTS IF YOU BUILD SBCL --with-sb-safepoint, which stops the
;;;; world by polling rather than signalling.  Verified, not hoped for: the same
;;;; source built that way runs the eight-way barrier, dispatch_apply and
;;;; PARALLEL-MAP below, five runs out of five, and the whole suite
;;;; passes on it.  The worker thread is still unsignallable there -- ENOTSUP,
;;;; exactly as before -- which is the point: safepoint does not make signalling
;;;; work, it makes it unnecessary.  So DISPATCH-APPLY and PARALLEL-MAP are
;;;; here, and they refuse with an explanation rather than killing the process
;;;; when the build cannot take them.
;;;;
;;;; Lifetime, by contrast, needs no care here at all, and it is worth saying
;;;; why because it did until recently.  dispatch_group_async copies the block
;;;; before it returns; the copy takes its own reference to the Lisp closure
;;;; through the descriptor's copy helper, and gives it up through the dispose
;;;; helper when libclosure finally destroys it.  So WITH-OBJC-BLOCK is right
;;;; even for work that has not started yet: what it frees is the storage and
;;;; one reference, not the closure.  An earlier draft of this file carried every
;;;; queued block on the group and freed them after the wait, which is what the
;;;; job takes without those helpers.

(in-package #:objc/examples)

;;; The C entry points --------------------------------------------------------
;;;
;;; libdispatch is inside libSystem, so it is already loaded and these resolve
;;; against the running process.  A queue and a group are opaque pointers --
;;; and, on every macOS this library supports, Objective-C objects, so they are
;;; released with OBJC:RELEASE rather than dispatch_release.

(cffi:defcfun ("dispatch_get_global_queue" %dispatch-get-global-queue) :pointer
  (identifier :long)
  (flags :unsigned-long))

(cffi:defcfun ("dispatch_queue_create" %dispatch-queue-create) :pointer
  (label :string)
  (attr :pointer))

(cffi:defcfun ("dispatch_sync" %dispatch-sync) :void
  (queue :pointer)
  (block :pointer))

(cffi:defcfun ("dispatch_apply" %dispatch-apply) :void
  (iterations :unsigned-long)
  (queue :pointer)
  (block :pointer))

(cffi:defcfun ("dispatch_group_create" %dispatch-group-create) :pointer)

(cffi:defcfun ("dispatch_group_async" %dispatch-group-async) :void
  (group :pointer)
  (queue :pointer)
  (block :pointer))

(cffi:defcfun ("dispatch_group_wait" %dispatch-group-wait) :long
  (group :pointer)
  (timeout :unsigned-long-long))

(defconstant +dispatch-time-forever+ (1- (ash 1 64)))

(defun global-queue (&optional (priority 0))
  "The process-wide CONCURRENT queue.  PRIORITY is -2 background through 2 high.

Safe for DISPATCH-SYNC, which runs one block and waits for it.  Queueing several
asynchronous blocks here runs them at once, which is the thing SBCL cannot
survive; see the note at the top of this file, and use SERIAL-QUEUE instead.

Nothing needs releasing: the global queues are singletons that outlive us."
  (%dispatch-get-global-queue priority 0))

(defun serial-queue (&optional (label "lisp.serial"))
  "A new serial queue, which runs the blocks given to it one at a time.

The safe way to run Lisp asynchronously on GCD, and not a workaround for a bug
so much as the shape the constraint leaves: one worker thread inside Lisp at a
time is exactly what a serial queue guarantees.  Release it with OBJC:RELEASE
when done, or let WITH-SERIAL-QUEUE do it."
  (%dispatch-queue-create label (cffi:null-pointer)))

(defmacro with-serial-queue ((queue &optional (label "lisp.serial")) &body body)
  `(let ((,queue (serial-queue ,label)))
     (unwind-protect (progn ,@body)
       (objc:release ,queue))))

;;; The block type ------------------------------------------------------------
;;;
;;; Declared rather than written inline at each call, because naming a signature
;;; is how the C prototype stays legible from Lisp.  It is checked when this file
;;; loads rather than when a block is first made.

(objc:define-objc-block-type dispatch-work :void ())

(objc:define-objc-block-type dispatch-indexed-work :void ((:unsigned :long-long)))

;;; Is running Lisp on several queue threads at once survivable? -------------

(defun concurrent-blocks-supported-p ()
  "True on an SBCL that stops the world by polling rather than by signalling.

The whole of the concurrency question above reduces to this.  Verified by
building the same source --with-sb-safepoint: eight workers held inside Lisp by
a barrier and all allocating, dispatch_apply, and a parallel map all come
through, five runs out of five, where a stock build dies on the first."
  (and (member :sb-safepoint *features*) t))

(defun check-concurrent-blocks (operation)
  (unless (concurrent-blocks-supported-p)
    (error "~A runs a Lisp closure on several libdispatch threads at once, ~
            which this SBCL cannot survive.~%~
            A garbage collection stops the world by signalling every other ~
            thread in Lisp, and Darwin refuses to signal a libdispatch worker ~
            at all -- so the process dies with \"cannot suspend thread: 45, ~
            Operation not supported\", no condition and no backtrace.~%~
            Build SBCL --with-sb-safepoint, which stops the world by polling ~
            instead, and this works.  Otherwise use a serial queue: ~
            GROUP-ASYNC defaults to one." operation)))

;;; Synchronous ---------------------------------------------------------------

(defun dispatch-sync (function &key (queue (global-queue)))
  "Run FUNCTION on QUEUE and return when it has finished.

The block has not escaped by the time this returns -- dispatch_sync is done with
it -- so WITH-OBJC-BLOCK is exactly right, and the block is freed on the way out
even if FUNCTION signals."
  (objc:with-objc-block (block 'dispatch-work function)
    (%dispatch-sync queue (objc:objc-block-pointer block))))

(defun dispatch-apply (count function &key (queue (global-queue)))
  "Call FUNCTION with each index below COUNT, concurrently, and return when all
have finished.

GCD's parallel for loop: it runs as many iterations at once as the machine has
cores to spare, on threads SBCL did not create, and does not return until the
last is done.  FUNCTION must be safe to run on several threads at once --
writing to distinct elements of a vector is fine, pushing onto a shared list is
not -- and this needs a safepoint build; see CHECK-CONCURRENT-BLOCKS."
  (check-concurrent-blocks "DISPATCH-APPLY")
  (objc:with-objc-block (block 'dispatch-indexed-work function)
    (%dispatch-apply count queue (objc:objc-block-pointer block))))

(defun parallel-map (function sequence)
  "Map FUNCTION over SEQUENCE in parallel, and return the results as a vector.

A Lisp function applied across every core the machine has, scheduled by the same
queues Cocoa schedules its own work on.  Each index is written by exactly one
iteration, which is what makes the shared result vector safe without a lock."
  (let* ((input (coerce sequence 'vector))
         (results (make-array (length input))))
    (dispatch-apply (length input)
                    (lambda (index)
                      (setf (aref results index) (funcall function (aref input index)))))
    results))

;;; Asynchronous --------------------------------------------------------------
;;;
;;; A group is how you wait for work you have already queued.  It also solves
;;; this file's lifetime problem: the group knows when its work is finished, so
;;; it is the natural owner of the blocks that work runs in.

(defstruct (dispatch-group (:constructor %make-dispatch-group))
  "A GCD dispatch group and the serial queue it runs its work on."
  handle
  (queue nil))

(defun make-dispatch-group ()
  "A new dispatch group.  Release its handle when done, or use WITH-DISPATCH-GROUP."
  (%make-dispatch-group :handle (%dispatch-group-create)))

(defun group-async (group function &key queue)
  "Queue FUNCTION as part of GROUP and return immediately.

QUEUE defaults to a serial queue the group owns, so that blocks queued on one
group never run concurrently -- see the note at the top of this file for why
that default is not merely conservative.  Passing a concurrent queue is allowed
and is how you would find out.

WITH-OBJC-BLOCK, even though the work outlives this call: dispatch_group_async
copies the block before it returns, the copy holds the closure, and freeing this
one releases only our own reference.  An earlier version of this file kept every
block on the group and freed them after the wait, which is what you have to do
without copy and dispose helpers; the five lines that went are the whole benefit
of having them."
  (objc:with-objc-block (block 'dispatch-work function)
    (%dispatch-group-async (dispatch-group-handle group)
                           (or queue (ensure-group-queue group))
                           (objc:objc-block-pointer block)))
  group)

(defun ensure-group-queue (group)
  "The serial queue GROUP runs its work on, made on first use."
  (or (dispatch-group-queue group)
      (setf (dispatch-group-queue group) (serial-queue "lisp.group"))))

(defun group-wait (group &optional (timeout +dispatch-time-forever+))
  "Wait for every block queued on GROUP.  True if they all finished in time."
  (zerop (%dispatch-group-wait (dispatch-group-handle group) timeout)))

(defmacro with-dispatch-group ((group) &body body)
  "Bind GROUP, run BODY, then wait for everything BODY queued on it.

Only the GCD objects need releasing here: the blocks look after themselves, so
what is left is the ordinary Objective-C ownership this library has always had."
  `(let ((,group (make-dispatch-group)))
     (unwind-protect (progn ,@body (group-wait ,group))
       (when (dispatch-group-queue ,group)
         (objc:release (dispatch-group-queue ,group))
         (setf (dispatch-group-queue ,group) nil))
       (objc:release (dispatch-group-handle ,group)))))

;;; A worked example ----------------------------------------------------------

(defun test-gcd ()
  "Run each shape and return a plist of what happened.  Needs no window server.

    (objc/examples:test-gcd)
    => (:SYNC 42 :ASYNC-THREAD :OTHER :GROUP T :TOTAL 4950 :OVERLAPPED T)

:ASYNC-THREAD is :OTHER when the queued blocks ran on a thread SBCL did not
create, which is the whole point -- Cocoa's scheduler, Lisp's closure.  It is
read from the asynchronous path and not from DISPATCH-SYNC, because dispatch_sync
is entitled to run its block on the calling thread and normally does; that is an
optimisation rather than a fallback, and it means DISPATCH-SYNC proves nothing
about threads either way.

:OVERLAPPED is true when the main thread got work done while the queue was still
running blocks."
  (objc:ensure-objc-initialized)
  (let ((sync nil)
        (async-thread nil)
        (main (bt:current-thread))
        (total 0)
        (spun 0)
        (lock (bt:make-lock "gcd example"))
        (inside (bt:make-semaphore))
        (release (bt:make-semaphore)))
    (dispatch-sync (lambda () (setf sync 42)))
    (let ((finished
            (with-dispatch-group (group)
              ;; Queued first, so on a serial queue it runs first and holds the
              ;; queue: it tells the main thread it is inside Lisp, then waits.
              ;; The overlap below is therefore arranged rather than hoped for --
              ;; a plain "has anything finished yet?" loop is a race that usually
              ;; loses, because the first block is done before it is reached.
              (group-async group
                           (lambda ()
                             (setf async-thread
                                   (if (eq (bt:current-thread) main) :main :other))
                             (bt:signal-semaphore inside)
                             (bt:wait-on-semaphore release :timeout 10)))
              (dotimes (i 100)
                (let ((i i))
                  (group-async group
                               (lambda ()
                                 (objc:with-autorelease-pool ()
                                   (bt:with-lock-held (lock) (incf total i)))))))
              ;; One queue thread inside a callback plus SBCL's own thread is the
              ;; safe side of the line drawn at the top of this file, and this is
              ;; the point where the process is standing on it.
              (when (bt:wait-on-semaphore inside :timeout 10)
                (dotimes (i 10000) (incf spun)))
              (bt:signal-semaphore release))))
      (list :sync sync
            :async-thread async-thread
            :group finished
            :total total
            :overlapped (plusp spun)))))

(defun report-gcd ()
  "Print what TEST-GCD found."
  (let ((result (test-gcd)))
    (format t "~&dispatch_sync returned ~A~%" (getf result :sync))
    (format t "a dispatch group of 100 blocks on a serial queue ~
               ~:[did not finish~;finished~], summing to ~D, on ~
               ~:[the main~;a libdispatch~] thread~%"
            (getf result :group) (getf result :total)
            (eq :other (getf result :async-thread)))
    (format t "the main thread kept running while they did: ~A~%"
            (getf result :overlapped))
    result))
