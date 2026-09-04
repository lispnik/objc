;;;; examples/memory.lisp -- retain counts, pools, and when an object actually dies.
;;;;
;;;; There is no ARC here.  Calling Objective-C through a foreign function
;;;; interface puts you in manual retain/release whatever the surrounding code
;;;; does, so the ownership rules apply literally -- and yet almost every other
;;;; example in this directory gets away with never thinking about them, because
;;;; WITH-AUTORELEASE-POOL is doing the work.  This file is what it is doing.
;;;;
;;;; Deaths are OBSERVED rather than inferred.  A Lisp-defined class gets an
;;;; OBJC-OBJECT-DESTROYED hook, so "the object was deallocated" is a fact this
;;;; file records, not a claim about what a retain count implies.  That matters,
;;;; because the retain count is a worse witness than it looks:
;;;;
;;;; -retainCount ON A TAGGED POINTER IS NONSENSE, AND NOT EVEN CONSISTENT
;;;; NONSENSE.  A short NSString is not a heap object at all -- the characters
;;;; live in the pointer -- and asking one for its retain count gives
;;;; 18446744073709551615.  A tagged NSNumber gives 9223372036854775807.  Both
;;;; are "never deallocate me", spelled differently by different classes, and
;;;; neither is a number to compare against anything.  A short literal string is
;;;; exactly the value someone reaches for when writing a memory test.
;;;;
;;;; A COUNT OF 1 DOES NOT MEAN YOU OWN IT.  +dataWithLength: hands back an
;;;; object with a count of 1 that is already registered with the current pool,
;;;; so the pending release does not appear in the count.  Release it because
;;;; the count "looks like one you own" and it dies twice.
;;;;
;;;; The rule the count is good for is the one the manual states: you own what
;;;; you got from +alloc, -copy, -mutableCopy or a name containing "create", and
;;;; nothing else.  Ownership is a static property of the call you made, not a
;;;; runtime property you can measure.
;;;;
;;;; DRAINING A POOL ON A THREAD THAT DID NOT CREATE IT IS A MEMORY FAULT, and
;;;; that is the whole reason MAKE-AUTORELEASE-POOL is the sharp tool and
;;;; WITH-AUTORELEASE-POOL is the one to reach for.  Measured: `Memory fault at
;;;; 0x10' inside -drain, backtrace in libobjc, process gone.  Nothing checks
;;;; this for you and nothing warns.  It is not demonstrated below for that
;;;; reason -- an example that ends the image is not an example.
;;;;
;;;; And WITHOUT A POOL THERE IS NO DIAGNOSTIC AT ALL.  The autorelease simply
;;;; does not happen; nothing is logged, on stderr or anywhere else, even with
;;;; OBJC_DEBUG_MISSING_POOLS=YES.  On the main thread of a plain SBCL process
;;;; that means the object lives until the process exits.  On a thread you
;;;; started it means the object lives until the THREAD exits, which is not a
;;;; leak so much as a lifetime you did not choose.

(in-package #:objc/examples)

;;; Something whose death is observable ---------------------------------------------
;;;
;;; The library installs -dealloc on every Lisp-defined class, so an :AFTER
;;; method on OBJC-OBJECT-DESTROYED is how anything here is measured at all.

(defvar *deaths* '()
  "Tags of the TRACKED objects deallocated so far, most recent first.")

(objc:define-objc-class tracked ()
  ((tag :initarg :tag :initform nil :accessor tracked-tag))
  (:objc-class-name "LispTrackedObject"))

(defmethod objc:objc-object-destroyed :after ((self tracked))
  (push (tracked-tag self) *deaths*))

(defun make-tracked (&optional tag)
  "A TRACKED object.  Its deallocation pushes TAG onto *DEATHS*."
  (objc:ensure-objc-initialized)
  (make-instance 'tracked :tag tag))

(defun tracked-deaths ()
  "The tags recorded so far, oldest first."
  (reverse *deaths*))

(defun reset-tracked ()
  "Forget the recorded deaths."
  (setf *deaths* '()))

;;; *DEATHS* is rebound rather than reset wherever one thread is doing the
;;; work.  Where a SECOND thread is involved it cannot be: SBCL threads do not
;;; inherit dynamic bindings, and -dealloc runs on the thread that dropped the
;;; last reference, so the push lands on the global value.  LEAK-WITHOUT-A-POOL
;;; is the one place that matters, and it says so.

;;; Looking at a pointer ---------------------------------------------------------------

(defun tagged-pointer-p (object)
  "Whether OBJECT is a tagged pointer rather than a heap object.

Not an address you can dereference: the value IS the object.  Bit 63 on Apple
silicon, bit 0 on Intel -- read from the pointer rather than guessed from the
class, because which classes tag which values is Apple's business and changes.

This is the guard to put in front of RETAIN-COUNT, and the reason to put one
there is that the counts a tagged pointer reports are not merely large but
class-specific: 2^64-1 from NSTaggedPointerString, 2^63-1 from a tagged
NSNumber."
  (let ((address (cffi:pointer-address (objc:objc-object-pointer object))))
    #+arm64 (logbitp 63 address)
    #-arm64 (logbitp 0 address)))

(defun count-of (object)
  "OBJECT's retain count, or :TAGGED if the question does not apply.

    (count-of (objc:invoke \"NSString\" \"stringWithUTF8String:\" \"hi\"))
    => :TAGGED

RETAIN-COUNT is exported and answers honestly; this is the wrapper worth having
in front of it, because the honest answer for a tagged pointer is a number that
will pass any comparison you write."
  (if (tagged-pointer-p object)
      :tagged
      (objc:retain-count object)))

;;; What ownership looks like ------------------------------------------------------------

(defun ownership-walk ()
  "Take an object through +alloc, -retain, -release and -dealloc, counting.

    (ownership-walk)
    => (:FRESH 1 :RETAINED 2 :RELEASED 1 :DIED-ON-LAST-RELEASE T)

+alloc gives you a count of one and an obligation.  The last -release runs
-dealloc, which is where the DIED assertion comes from -- a count reaching zero
is not observable, since the object is gone before you could ask."
  (objc:ensure-objc-initialized)
  (let ((*deaths* '()))
    (let* ((object (make-tracked :owned))
           (fresh (count-of object))
           (retained (progn (objc:retain object) (count-of object)))
           (released (progn (objc:release object) (count-of object))))
      (objc:release object)
      (list :fresh fresh
            :retained retained
            :released released
            :died-on-last-release (equal '(:owned) (reverse *deaths*))))))

(defun autorelease-walk ()
  "Show that an autoreleased object outlives the expression that made it.

    (autorelease-walk)
    => (:DEAD-INSIDE NIL :DEAD-AFTER (:POOLED))

Which is the entire point of a pool: a function can return an object it does not
own without either leaking it or handing back something already dead."
  (objc:ensure-objc-initialized)
  (let ((inside nil)
        (after nil))
    (let ((*deaths* '()))
      (objc:with-autorelease-pool ()
        (objc:autorelease (make-tracked :pooled))
        (setf inside (reverse *deaths*)))
      (setf after (reverse *deaths*)))
    (list :dead-inside inside :dead-after after)))

;;; Why MAKE-AUTORELEASE-POOL exists -----------------------------------------------------

(defun deaths-during-loop (&key (count 200) (per-iteration nil))
  "Autorelease COUNT objects in a loop; return how many died BEFORE it ended.

    (deaths-during-loop)                      => 0
    (deaths-during-loop :per-iteration t)     => 200

This is the measurement that justifies MAKE-AUTORELEASE-POOL being exported at
all.  WITH-AUTORELEASE-POOL wraps a lexical scope, and a loop body is a scope --
but a pool around the whole loop holds every object until the loop finishes.
With one pool per iteration the objects die as you go, which for a loop over a
large directory or a long file is the difference between a working program and
one that grows until it is killed.

The inner pool is drained explicitly rather than by WITH-AUTORELEASE-POOL only
to show what the macro is doing; in real code the macro is the right answer, and
it is exception-safe where this is not."
  (objc:ensure-objc-initialized)
  (let ((*deaths* '())
        (during 0))
    (objc:with-autorelease-pool ()
      (dotimes (i count)
        (if per-iteration
            (let ((pool (objc:make-autorelease-pool)))
              (objc:autorelease (make-tracked i))
              (objc:invoke pool "drain"))
            (objc:autorelease (make-tracked i))))
      (setf during (length *deaths*)))
    during))

;;; What happens with no pool at all --------------------------------------------------------

(defun leak-without-a-pool ()
  "Autorelease with no pool, on this thread and on a fresh one.

    (leak-without-a-pool)
    => (:MAIN-THREAD NIL :SECONDARY-THREAD (:THREAD))

Nothing is logged in either case -- see the header.  On this thread the object
is simply still alive; on a thread that exits, the runtime pops the thread's
pool page as it tears down, so the object dies at an unrelated moment, which is
worse than either alternative to reason about.

Note what is NOT asserted: that the main-thread object leaks forever.  It has
not died by the time this returns, and that is all this can honestly claim."
  (objc:ensure-objc-initialized)
  (let ((main (let ((*deaths* '()))
                (objc:autorelease (make-tracked :main))
                (reverse *deaths*))))
    ;; The global value, deliberately.  The thread does not inherit a binding,
    ;; and -dealloc runs on the thread being torn down, so a LET here would
    ;; watch a variable nothing ever pushes to and report a leak that is not
    ;; happening.
    (setf *deaths* '())
    (sb-thread:join-thread
     (sb-thread:make-thread
      (lambda () (objc:autorelease (make-tracked :thread)) :done)))
    ;; The pool page is popped during teardown, which JOIN-THREAD does not wait
    ;; for; two seconds is far longer than it takes and reports honestly if not.
    (loop repeat 100 until *deaths* do (sleep 0.02))
    (list :main-thread main :secondary-thread (reverse *deaths*))))

;;; A worked example ---------------------------------------------------------------------------

(defun test-memory ()
  "Walk the ownership rules and check each one against an observed deallocation.

    (objc/examples:test-memory)
    => (:OWNERSHIP (:FRESH 1 :RETAINED 2 :RELEASED 1 :DIED-ON-LAST-RELEASE T)
        :AUTORELEASE (:DEAD-INSIDE NIL :DEAD-AFTER (:POOLED))
        :TAGGED-STRING :TAGGED :HEAP-STRING 1 :TAGGED-COUNT-IS-ABSURD T
        :DEATHS-IN-LOOP 0 :DEATHS-IN-LOOP-WITH-POOLS 200
        :NO-POOL (:MAIN-THREAD NIL :SECONDARY-THREAD (:THREAD)))

:TAGGED-COUNT-IS-ABSURD is the assertion with teeth, because it is the one that
would let a plausible test through.  A memory test written with a short literal
string measures an object that cannot be deallocated and reports a retain count
of 18446744073709551615 -- and any \"the count went up\" check passes on it,
before and after."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (let* ((tagged (objc:invoke "NSString" "stringWithUTF8String:" "hi"))
           (heap (objc:invoke "NSString" "stringWithUTF8String:"
                              "long enough to be a real heap object")))
      (list :ownership (ownership-walk)
            :autorelease (autorelease-walk)
            :tagged-string (count-of tagged)
            :heap-string (count-of heap)
            :tagged-count-is-absurd (> (objc:retain-count tagged) 1000000)
            :deaths-in-loop (deaths-during-loop)
            :deaths-in-loop-with-pools (deaths-during-loop :per-iteration t)
            :no-pool (leak-without-a-pool)))))

(defun report-memory ()
  "Print the walk, as you would read it at a REPL."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (format t "~&ownership:   ~S~%" (ownership-walk))
    (format t "autorelease: ~S~%" (autorelease-walk))
    (format t "~&counts:~%")
    (dolist (entry (list (cons "short NSString"
                               (objc:invoke "NSString" "stringWithUTF8String:" "hi"))
                         (cons "long NSString"
                               (objc:invoke "NSString" "stringWithUTF8String:"
                                            "long enough to be a real heap object"))
                         (cons "NSNumber" (objc:invoke "NSNumber" "numberWithInt:" 7))
                         (cons "NSObject"
                               (objc:invoke (objc:invoke "NSObject" "alloc") "init"))))
      (format t "  ~16A ~14A raw ~D~%"
              (car entry)
              (let ((count (count-of (cdr entry))))
                (if (eq count :tagged) "tagged pointer" count))
              (objc:retain-count (cdr entry))))
    (format t "~&deaths before the loop ends: ~D with one pool, ~D with one each~%"
            (deaths-during-loop) (deaths-during-loop :per-iteration t))
    (format t "no pool at all: ~S~%" (leak-without-a-pool))))
