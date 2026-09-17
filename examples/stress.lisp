;;;; examples/stress.lisp -- every hot path, hammered, on either Lisp.
;;;;
;;;; The benchmark (bench/bench.lisp) measures one call of each shape in
;;;; isolation.  This is the other question: what happens when each shape
;;;; runs a hundred thousand times in one image, with blocks made and freed,
;;;; methods defined and redefined, exceptions caught by the thousand, and
;;;; several threads sending at once.  Every phase counts what it did, times
;;;; itself, and checks its own answers; the run as a whole watches the
;;;; process's resident size and the Lisp heap, because the failure this is
;;;; looking for is not a wrong answer but a leak, a stale cache, or a crash
;;;; that only the ten-thousandth iteration finds.
;;;;
;;;; TEST-STRESS runs it small and returns a plist the suite asserts on;
;;;; REPORT-STRESS runs it at full size and prints a table.

(in-package #:objc/examples)

;;; Measuring -------------------------------------------------------------------

(defun process-id ()
  #+sbcl (sb-unix:unix-getpid)
  #+ecl (ext:getpid)
  #-(or sbcl ecl) 0)

(defun resident-kb ()
  "The process's resident set, from ps, in KB; 0 where ps is not there."
  (or (ignore-errors
       (parse-integer (uiop:run-program (format nil "ps -o rss= -p ~d" (process-id))
                                        :output :string)
                      :junk-allowed t))
      0))

(defun heap-bytes ()
  #+sbcl (sb-kernel:dynamic-usage)
  #-sbcl 0)

(defun collect-garbage ()
  #+sbcl (sb-ext:gc :full t)
  #+ecl (si:gc t))

(defmacro timed ((count-var) &body body)
  "Run BODY, which sets COUNT-VAR to how many operations it did, and return
(VALUES COUNT NANOSECONDS-PER-OPERATION)."
  `(let ((,count-var 0)
         (start (get-internal-real-time)))
     ,@body
     (values ,count-var
             (round (* 1d9 (/ (- (get-internal-real-time) start)
                             internal-time-units-per-second
                             (max 1 ,count-var)))))))

;;; The phases ------------------------------------------------------------------
;;;
;;; Each takes a SIZE and returns (VALUES COUNT NS-PER-OP OK), where OK says
;;; the answers were right the whole way through.

(defun stress-sends (size)
  "Plain sends of every result kind: a method on the receiver's class, one
inherited from NSObject, an object out, a struct out, a string out, a Lisp
string in.  The send cache is keyed by class and selector; this is what keeps
hitting it."
  (let ((s (objc:invoke "NSString" "stringWithUTF8String:" "hello world"))
        (array (objc:invoke "NSMutableArray" "array"))
        (ok t))
    (objc:retain s)
    (dotimes (i 8) (objc:invoke array "addObject:" s))
    (multiple-value-bind (count ns)
        (timed (n)
          (dotimes (i size)
            (unless (and (= 11 (objc:invoke s "length"))
                         (cffi:pointer-eq (objc:objc-object-pointer s) (objc:invoke s "self"))
                         (= 11 (objc:invoke (objc:invoke array "objectAtIndex:" 3) "length"))
                         (equal '(6 . 5) (objc:invoke s "rangeOfString:" "world"))
                         (string= "hello world" (objc:invoke-into 'string s "self"))
                         (eql 1 (objc:invoke s "isEqualToString:" "hello world")))
              (setf ok nil))
            (incf n 6)))
      (objc:release s)
      (values count ns ok))))

(defun stress-blocks (size)
  "Blocks made and freed by the thousand, and one block called back per
element by Foundation SIZE times over a thousand-element array.  The block
registry must end where it began."
  (let ((array (objc:invoke "NSMutableArray" "array"))
        (s (objc:invoke "NSString" "stringWithUTF8String:" "x"))
        (ok t))
    (dotimes (i 1000) (objc:invoke array "addObject:" s))
    (multiple-value-bind (count ns)
        (timed (n)
          ;; Churn: a block per iteration, freed at once.
          (dotimes (i size)
            (objc:with-objc-block (b '(:long-long ((:unsigned :long-long)))
                                     (lambda (x) (* 2 x)))
              (unless (= 6 (objc:call-objc-block '(:long-long ((:unsigned :long-long))) b 3))
                (setf ok nil)))
            (incf n))
          ;; Per element: SIZE enumerations of a thousand.
          (let ((seen 0))
            (objc:with-objc-block (b '(:void (objc:objc-object-pointer (:unsigned :long-long)
                                              (:pointer :char)))
                                     (lambda (object index stop)
                                       (declare (ignore object index stop))
                                       (incf seen)))
              (dotimes (i size)
                (objc:invoke array "enumerateObjectsUsingBlock:" b)))
            (unless (= seen (* 1000 size)) (setf ok nil))
            (incf n (* 1000 size))))
      (values count ns ok))))

(objc:define-objc-class stress-object ()
  ((ticks :initform 0 :accessor stress-object-ticks))
  (:objc-class-name "LispStressObject"))

(objc:define-objc-method ("tick" :void) ((self stress-object))
  (incf (stress-object-ticks self)))

(objc:define-objc-method ("twice:" :int) ((self stress-object) (x :int))
  (declare (ignore self))
  (* 2 x))

(defun stress-methods (size)
  "Lisp methods called from Lisp SIZE times and called per element by
Foundation as many times again: the IMP path, whichever the seam makes it."
  (let* ((object (make-instance 'stress-object))
         (pointer (objc:objc-object-pointer object))
         (array (objc:invoke "NSMutableArray" "array"))
         (ok t))
    (dotimes (i 100) (objc:invoke array "addObject:" pointer))
    (multiple-value-bind (count ns)
        (timed (n)
          (dotimes (i size)
            (unless (= 84 (objc:invoke pointer "twice:" 42)) (setf ok nil))
            (incf n))
          (dotimes (i (max 1 (floor size 100)))
            (objc:invoke array "makeObjectsPerformSelector:" (objc:coerce-to-selector "tick"))
            (incf n 100))
          (unless (= (stress-object-ticks object) (* 100 (max 1 (floor size 100)))) (setf ok nil)))
      (values count ns ok))))

(defun stress-churn (size)
  "A method defined and redefined SIZE times, and called after each.  On
SBCL a method is a block over one callable per signature, so this must cost
the fixed static code space nothing; on ECL each is a heap closure.  Either
way the count of live IMPs must not grow with the churn.  Each op is a
compile, so the rate is milliseconds, not nanoseconds."
  (let ((ok t))
    (eval '(objc:define-objc-class stress-churn () () (:objc-class-name "LispStressChurn")))
    (multiple-value-bind (count ns)
        (timed (n)
          (let ((churn (objc:alloc-init-object "LispStressChurn")))
            (dotimes (i size)
              (eval `(objc:define-objc-method ("churned:" :int) ((self stress-churn) (x :int))
                       (+ x ,i)))
              (unless (= (+ 1 i) (objc:invoke churn "churned:" 1)) (setf ok nil))
              (incf n))))
      (values count ns ok))))

(defun stress-exceptions (size)
  "SIZE exceptions caught, and SIZE NSErrors signalled, in a loop.  Each
caught exception abandons the runtime's frames and keeps the NSException;
this is where that shows up as growth, and the growth must be bounded."
  (let ((empty (objc:invoke "NSArray" "array"))
        (ok t))
    (multiple-value-bind (count ns)
        (timed (n)
          (dotimes (i size)
            (unless (handler-case (progn (objc:invoke empty "objectAtIndex:" 0) nil)
                      (objc:objc-exception (e) (string= "NSRangeException" (objc:objc-exception-name e))))
              (setf ok nil))
            (incf n))
          (dotimes (i size)
            (unless (handler-case (progn (objc:invoke-with-error "NSString" "stringWithContentsOfFile:encoding:error:"
                                                                 "/nonexistent/objc-stress" 4)
                                         nil)
                      (objc:ns-error (e) (= 260 (objc:ns-error-code e))))
              (setf ok nil))
            (incf n)))
      (values count ns ok))))

(defun stress-pools (size)
  "SIZE autorelease pools, each holding a few autoreleased strings.  The
resident size afterwards is the assertion."
  (multiple-value-bind (count ns)
      (timed (n)
        (dotimes (i size)
          (objc:with-autorelease-pool ()
            (dotimes (j 4)
              (objc:invoke (objc:invoke "NSString" "stringWithUTF8String:" "autoreleased")
                           "uppercaseString"))
            (incf n 4))))
    (values count ns t)))

(defun stress-threads (size &key (threads 4))
  "THREADS threads sending SIZE times each, at once: the send caches, the
selector entries and the exception catch are shared or per thread, and this
is what says which held."
  (let ((results (make-array threads :initial-element nil))
        (empty (objc:invoke "NSArray" "array")))
    (objc:retain empty)
    (multiple-value-bind (count ns)
        (timed (n)
          (let ((workers
                  (loop for k below threads
                        collect (let ((k k))
                                  (bt:make-thread
                                   (lambda ()
                                     (objc:with-autorelease-pool ()
                                       (let ((s (objc:invoke "NSString" "stringWithUTF8String:" "thread"))
                                             (good t))
                                         (dotimes (i size)
                                           (unless (and (= 6 (objc:invoke s "length"))
                                                        ;; One exception in fifty: each caught
                                                        ;; one keeps its NSException.
                                                        (or (plusp (mod i 50))
                                                            (handler-case (progn (objc:invoke empty "objectAtIndex:" 0) nil)
                                                              (objc:objc-exception () t))))
                                             (setf good nil)))
                                         (setf (aref results k) good))))
                                   :name (format nil "stress ~d" k))))))
            (mapc #'bt:join-thread workers))
          (setf n (* 2 size threads)))
      (values count ns (every #'identity results)))))

;;; The run ---------------------------------------------------------------------

(defparameter +phases+
  '((:sends stress-sends 50000)
    (:blocks stress-blocks 200)
    (:methods stress-methods 20000)
    (:churn stress-churn 200)
    (:exceptions stress-exceptions 1000)
    (:pools stress-pools 20000)
    (:threads stress-threads 20000))
  "Phase name, function, and the SIZE REPORT-STRESS passes; TEST-STRESS
passes a tenth of it.")

(defun run-stress (&key (scale 1) (stream nil))
  "Run every phase at SCALE times its full size, printing a line per phase to
STREAM when given, and return a plist: each phase's (COUNT NS-PER-OP OK
RESIDENT-GROWTH-KB),
:RSS-GROWTH-KB and :HEAP-GROWTH-BYTES across the whole run after a
collection, and :OK for the lot."
  (objc:ensure-objc-initialized)
  (collect-garbage)
  (let ((rss0 (resident-kb))
        (heap0 (heap-bytes))
        (result '())
        (all-ok t))
    (dolist (phase +phases+)
      (destructuring-bind (name function size) phase
        (let ((rss-before (resident-kb)))
          (multiple-value-bind (count ns ok) (funcall function (max 1 (round (* scale size))))
            (let ((grew (- (resident-kb) rss-before)))
              (unless ok (setf all-ok nil))
              (when stream
                (format stream "~&~12a ~9:d ops ~10:d ns/op  resident ~@:d KB  ~a~%"
                        name count ns grew (if ok "ok" "WRONG"))
                (finish-output stream))
              (setf result (append result (list name (list count ns ok grew)))))))))
    (collect-garbage)
    (let ((rss (- (resident-kb) rss0))
          (heap (- (heap-bytes) heap0)))
      (when stream
        (format stream "~&resident +~:d KB, Lisp heap ~@d bytes after a full collection~%" rss heap))
      (list* :ok all-ok :rss-growth-kb rss :heap-growth-bytes heap result))))

(defun test-stress ()
  "The run at a tenth of its size, for the suite: a few seconds on SBCL."
  (run-stress :scale 1/10))

(defun report-stress ()
  "The run at full size, a line per phase, and the memory verdict."
  (run-stress :scale 1 :stream *standard-output*))
