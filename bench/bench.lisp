;;;; bench/bench.lisp -- the same measurements on SBCL, ECL and LispWorks.
;;;;
;;;; One file, compiled on each Lisp, so the columns in RESULTS.md come
;;;; from identical code.  Everything is written against the LispWorks API
;;;; (INVOKE, ALLOC-INIT-OBJECT, DEFINE-OBJC-METHOD, the list-form method
;;;; designator); the few places this library goes beyond LispWorks -- SIMD
;;;; vectors, WITH-OBJC-BLOCK -- are #-lispworks, and the block half is done
;;;; with LispWorks' own FLI blocks on that side.
;;;;
;;;; Method: each row is a thunk run *ITERATIONS* times per round, *ROUNDS*
;;;; rounds after one discarded warm-up round, and the median round is
;;;; reported in nanoseconds per call.  The median is what makes a run
;;;; repeatable: a GC or a scheduler hiccup lands in one round and is
;;;; discarded.  Do not compare numbers across machines; compare Lisps on one.
;;;;
;;;; Run:
;;;;   make bench            SBCL and ECL, then the comparison table
;;;;   make bench-lispworks  prints what to type into a LispWorks Listener
;;;; or from any of the three Lisps, with objc loaded:
;;;;   (load (compile-file "bench/bench.lisp"))
;;;;   (objc-bench:run)
;;;; RUN writes bench/results/<lisp>.txt; (objc-bench:compare) merges every
;;;; results file present into bench/RESULTS.md.

;;; LispWorks' IDE image on macOS already contains the OBJC package -- the IDE
;;; is built on Cocoa -- so nothing is required here; (require "objc") is an
;;; unknown module there.

(defpackage #:objc-bench
  (:use #:cl)
  (:export #:run #:compare #:*iterations* #:*rounds*))

(in-package #:objc-bench)

(defparameter *iterations* 200000
  "Calls per round.  At 200 000 the fastest rows take 60 ms on SBCL, which is
sixty ticks of LispWorks' millisecond clock -- enough for a 2% reading.")

(defparameter *rounds* 5
  "Rounds per row, after one warm-up round that is not counted.")

(defparameter *bench-directory*
  #.(directory-namestring (or *compile-file-truename* *load-truename*))
  "Where this file lives; results go in results/ beside it.")

(defparameter +modules+
  '("/System/Library/Frameworks/Foundation.framework/Foundation"
    "/System/Library/Frameworks/GameplayKit.framework/GameplayKit"))

;;; Timing ---------------------------------------------------------------------

(defun median-seconds (thunk n)
  "Run THUNK N times per round, discard the warm-up, return the median round."
  (let ((samples '()))
    (dotimes (r (1+ *rounds*))
      (let ((start (get-internal-real-time)))
        (dotimes (i n) (funcall thunk))
        (push (/ (- (get-internal-real-time) start) internal-time-units-per-second)
              samples)))
    ;; The warm-up was pushed first, so it is last.
    (let ((sorted (sort (butlast samples) #'<)))
      (nth (floor (length sorted) 2) sorted))))

(defun ns-per-call (thunk &key (n *iterations*) (per 1))
  "Nanoseconds per call of THUNK, or per one of the PER things THUNK does."
  (round (* 1d9 (/ (median-seconds thunk n) n per))))

(defvar *rows* '())

(defun report (name ns)
  (push (cons name ns) *rows*)
  (format t "~&~60a ~8d ns~%" name ns)
  (finish-output))

;;; Fixtures -------------------------------------------------------------------

(defvar *ticks* 0)

(objc:define-objc-class bench-object ()
  ()
  (:objc-class-name "BenchObject"))

(objc:define-objc-method ("twice:" :int) ((self bench-object) (x :int))
  (declare (ignore self))
  (* 2 x))

(objc:define-objc-method ("tick" :void) ((self bench-object))
  (declare (ignore self))
  (incf *ticks*))

#+lispworks
(fli:define-foreign-block-callable-type enumerate-block :void
  (objc:objc-object-pointer (:unsigned :long-long) (:pointer :char)))

#+lispworks
(fli:define-foreign-funcallable %raw-send ((receiver :pointer) (selector :pointer))
  :result-type :long)

(defun packed-float2 (x y)
  "The double whose eight bytes are the floats X and Y: how a float2 crosses
in the list-form designator, on all three Lisps."
  #+lispworks
  (fli:with-dynamic-foreign-objects ((p :float :nelems 2))
    (setf (fli:dereference p :index 0) x (fli:dereference p :index 1) y)
    (fli:dereference (fli:copy-pointer p :type :double)))
  #-lispworks
  (cffi:with-foreign-object (p :float 2)
    (setf (cffi:mem-aref p :float 0) x (cffi:mem-aref p :float 1) y)
    (cffi:mem-ref p :double)))

#-lispworks
(defun make-c-noop-block ()
  "A block literal that is all C: a global block whose invoke is getpid, which
ignores the argument it is handed.  No copy helper, no dispose helper, no
Lisp anywhere.  What a queue hop costs with nothing of ours in it."
  (let ((literal (cffi:foreign-alloc :uint8 :count 32 :initial-element 0))
        (descriptor (cffi:foreign-alloc :uint64 :count 2 :initial-element 0)))
    (setf (cffi:mem-aref descriptor :uint64 1) 32)
    (setf (cffi:mem-ref literal :pointer 0) (cffi:foreign-symbol-pointer "_NSConcreteGlobalBlock")
          (cffi:mem-ref literal :int32 8) (ash 1 28) ; BLOCK_IS_GLOBAL
          (cffi:mem-ref literal :pointer 16) (cffi:foreign-symbol-pointer "getpid")
          (cffi:mem-ref literal :pointer 24) descriptor)
    literal))

#-lispworks
(defun group-hop (group queue block)
  "dispatch_group_async BLOCK on QUEUE and wait for it: one trip through a
libdispatch worker thread and back."
  (cffi:foreign-funcall "dispatch_group_async" :pointer group :pointer queue :pointer block :void)
  (cffi:foreign-funcall "dispatch_group_wait" :pointer group :unsigned-long-long (1- (ash 1 64)) :long))

(defun msg-send-address ()
  #+lispworks (fli:make-pointer :symbol-name "objc_msgSend")
  #-lispworks (cffi:foreign-symbol-pointer "objc_msgSend"))

(defun raw-send-length (send receiver selector)
  "objc_msgSend at SEND through the FFI with no bridge at all: the floor."
  #+lispworks
  (%raw-send send receiver selector)
  #-lispworks
  (cffi:foreign-funcall-pointer send () :pointer receiver :pointer selector :long))

;;; The rows -------------------------------------------------------------------

(defun run-rows ()
  (let* ((n *iterations*)
         (s (objc:invoke "NSString" "stringWithUTF8String:" "hello world"))
         (a (objc:invoke "NSMutableArray" "array"))
         (o (objc:alloc-init-object "BenchObject"))
         (objects (objc:invoke "NSMutableArray" "array"))
         (agent (objc:alloc-init-object "GKAgent2D"))
         (packed (packed-float2 1.0 2.0))
         (sel (objc:coerce-to-selector "length"))
         (send (msg-send-address)))
    (objc:retain s) (objc:retain a) (objc:retain objects)
    (dotimes (i 1000) (objc:invoke a "addObject:" s))
    (dotimes (i 1000) (objc:invoke objects "addObject:" o))
    ;; floors
    (report "lisp: (length \"hello world\")"
            (ns-per-call (lambda () (length "hello world"))))
    (report "ffi: objc_msgSend -length, no bridge"
            (ns-per-call (lambda () (raw-send-length send s sel))))
    ;; sends
    (report "invoke: -length (method on the receiver's class)"
            (ns-per-call (lambda () (objc:invoke s "length"))))
    (report "invoke: -self (inherited from NSObject)"
            (ns-per-call (lambda () (objc:invoke s "self"))))
    (report "invoke: +class on \"NSString\" (class receiver)"
            (ns-per-call (lambda () (objc:invoke "NSString" "class"))))
    (report "invoke: -objectAtIndex: (id in, id out)"
            (ns-per-call (lambda () (objc:invoke a "objectAtIndex:" 3))))
    (report "invoke: -rangeOfString: (NSRange out)"
            (ns-per-call (lambda () (objc:invoke s "rangeOfString:" s))))
    (report "invoke: -UTF8String -> Lisp string"
            (ns-per-call (lambda () (objc:invoke s "UTF8String"))))
    (report "invoke: -isEqualToString: (Lisp string in)"
            (ns-per-call (lambda () (objc:invoke s "isEqualToString:" "hello world"))))
    (report "invoke: (invoke (invoke s uppercaseString) length)"
            (ns-per-call (lambda () (objc:invoke (objc:invoke s "uppercaseString") "length"))))
    ;; a float2 as the double that carries it, through the list form
    (report "invoke: -setPosition: float2 as double (list form)"
            (ns-per-call (lambda () (objc:invoke agent '("setPosition:" (:double)) packed))))
    (report "invoke: -position -> double (list form)"
            (ns-per-call (lambda () (objc:invoke agent '("position" () :result-type :double)))))
    ;; the same through a declared SIMD signature, as Lisp vectors
    #-lispworks
    (progn
      (objc:declare-objc-signature "setPosition:" '((:vector :float 2)))
      (objc:declare-objc-signature "position" '() :result-type '(:vector :float 2))
      (report "invoke: -setPosition: #(1.0 2.0) (declared float2)"
              (ns-per-call (lambda () (objc:invoke agent "setPosition:" #(1.0 2.0)))))
      (report "invoke: -position -> #(x y) (declared float2)"
              (ns-per-call (lambda () (objc:invoke agent "position"))))
      (when (objc::wide-vector-supported-p)
        (let ((agent3 (objc:alloc-init-object "GKAgent3D")))
          (objc:declare-objc-signature "setPosition:" '((:vector :float 3)))
          (objc:declare-objc-signature "position" '() :result-type '(:vector :float 3))
          (report "invoke: -setPosition: #(1.0 2.0 3.0) (declared float3)"
                  (ns-per-call (lambda () (objc:invoke agent3 "setPosition:" #(1.0 2.0 3.0)))))
          (report "invoke: -position -> #(x y z) (declared float3)"
                  (ns-per-call (lambda () (objc:invoke agent3 "position")))))))
    ;; Lisp called from Objective-C: a block per element, a method per element
    (let ((count 0))
      (flet ((enumerate (block)
               (ns-per-call (lambda () (objc:invoke a "enumerateObjectsUsingBlock:" block))
                            :n (floor n 1000) :per 1000)))
        #+lispworks
        (let ((block (fli:allocate-foreign-block
                      'enumerate-block
                      (lambda (object index stop)
                        (declare (ignore object index stop))
                        (incf count)))))
          (report "block: called back per element by NSArray" (enumerate block))
          (fli:free-foreign-block block))
        #-lispworks
        (objc:with-objc-block
            (block '(:void (objc:objc-object-pointer (:unsigned :long-long) (:pointer :char)))
                   (lambda (object index stop)
                     (declare (ignore object index stop))
                     (incf count)))
          (report "block: called back per element by NSArray" (enumerate block)))))
    (report "method: Lisp -twice: via invoke"
            (ns-per-call (lambda () (objc:invoke o "twice:" 21))))
    (report "method: Lisp -tick per element, makeObjectsPerformSelector:"
            (ns-per-call (lambda ()
                           (objc:invoke objects "makeObjectsPerformSelector:"
                                        (objc:coerce-to-selector "tick")))
                         :n (floor n 1000) :per 1000))
    ;; A block on a libdispatch worker: what adopting the thread costs.  The
    ;; first row is the hop itself, with nothing of ours in it.  The second
    ;; adds one Lisp entry on the worker, the invoke: the block is held as a
    ;; heap copy here, so libdispatch's copy is a count and its release is a
    ;; count, and no helper runs.  The third hands over the original literal,
    ;; so libdispatch's copy runs the copy helper on this thread and its
    ;; release runs the dispose helper on the worker: a second adoption.
    #-lispworks
    (let* ((hops (floor n 20))
           (queue (cffi:foreign-funcall "dispatch_queue_create"
                                        :string "objc.bench" :pointer (cffi:null-pointer) :pointer))
           (group (cffi:foreign-funcall "dispatch_group_create" :pointer))
           (c-block (make-c-noop-block))
           (lisp-block (objc:make-objc-block '(:void ()) (lambda () nil)))
           (held (objc::%block-copy (objc:objc-block-pointer lisp-block))))
      (unwind-protect
           (progn
             (report "worker: a C no-op block through a queue and back (the hop)"
                     (ns-per-call (lambda () (group-hop group queue c-block)) :n hops))
             (report "worker: a Lisp block held here (one adoption, the invoke)"
                     (ns-per-call (lambda () (group-hop group queue held)) :n hops))
             (report "worker: a Lisp block copied fresh (two: invoke and dispose helper)"
                     (ns-per-call (lambda () (group-hop group queue (objc:objc-block-pointer lisp-block)))
                                  :n hops)))
        (objc::%block-release held)
        (objc:free-objc-block lisp-block)
        (objc:release group)
        (objc:release queue)))))

;;; Files ----------------------------------------------------------------------

(defun lisp-name ()
  "sbcl, sbcl-safepoint, ecl or lispworks: the column name and the results
file name.  LispWorks Personal reports \"LispWorks Personal Edition\", which is
the same column.  An SBCL built --with-sb-safepoint is its own column: it
polls at every foreign-call boundary, so its numbers are not the stock ones."
  (let ((name (string-downcase (lisp-implementation-type))))
    (cond ((and (> (length name) 9) (string= "lispworks" name :end2 9))
           "lispworks")
          ((and (string= "sbcl" name) (member :sb-safepoint *features*))
           "sbcl-safepoint")
          (t (substitute #\- #\Space name)))))

(defun results-file (&optional (lisp (lisp-name)))
  (merge-pathnames (format nil "results/~a.txt" lisp) *bench-directory*))

(defun header ()
  (multiple-value-bind (sec min hour day month year) (get-decoded-time)
    (declare (ignore sec))
    (format nil "~a ~a~:[~; (safepoint)~] ~a ~a ~a ~4,'0d-~2,'0d-~2,'0d ~2,'0d:~2,'0d n=~d rounds=~d"
            (lisp-implementation-type) (lisp-implementation-version)
            (member :sb-safepoint *features*)
            (machine-type) (software-type) (software-version)
            year month day hour min *iterations* *rounds*)))

(defun run ()
  "Measure everything, print it, write bench/results/<lisp>.txt.
Returns the rows as an alist of (name . nanoseconds)."
  (objc:ensure-objc-initialized :modules +modules+)
  (setf *rows* '())
  (format t "~&~a~%" (header))
  (run-rows)
  (let ((rows (reverse *rows*)))
    (ensure-directories-exist (results-file))
    (with-open-file (out (results-file) :direction :output :if-exists :supersede)
      (format out "# ~a~%" (header))
      (dolist (row rows)
        (format out "~a~c~d~%" (car row) #\Tab (cdr row))))
    (format t "~&Wrote ~a~%" (results-file))
    rows))

;;; Comparison -----------------------------------------------------------------

(defparameter +lisps+ '("sbcl" "sbcl-safepoint" "ecl" "lispworks")
  "Column order.  A Lisp with no results file is left out.")

(defun read-results (lisp)
  "The header line and an alist of rows from results/LISP.txt, or NIL."
  (with-open-file (in (results-file lisp) :if-does-not-exist nil)
    (when in
      (let ((header (read-line in nil ""))
            (rows '()))
        (loop for line = (read-line in nil)
              while line
              do (let ((tab (position #\Tab line)))
                   (when tab
                     (push (cons (subseq line 0 tab)
                                 (parse-integer line :start (1+ tab)))
                           rows))))
        (values (string-left-trim "# " header) (nreverse rows))))))

(defun compare (&optional (stream *standard-output*))
  "Merge every results file into a markdown table, written to STREAM and to
bench/RESULTS.md."
  (let ((columns '()) (names '()))
    (dolist (lisp +lisps+)
      (multiple-value-bind (header rows) (read-results lisp)
        (when rows
          (push (list lisp header rows) columns)
          (dolist (row rows)
            (unless (member (car row) names :test #'string=)
              (push (car row) names))))))
    (setf columns (nreverse columns) names (nreverse names))
    (flet ((emit (out)
             (format out "# objc bench~%~%")
             (format out "Nanoseconds per call, median of ~d rounds of ~d after a warm-up.~%~
                          Produced by `make bench`; see bench/bench.lisp for what each row does.~%~%"
                     *rounds* *iterations*)
             (dolist (column columns)
               (format out "- **~a**: ~a~%" (first column) (second column)))
             (format out "~%| measurement |~{ ~a |~}~%" (mapcar #'first columns))
             (format out "|---|~{~*---:|~}~%" columns)
             (dolist (name names)
               (format out "| ~a |" name)
               (dolist (column columns)
                 (let ((cell (cdr (assoc name (third column) :test #'string=))))
                   (format out " ~:[n/a~;~:*~:d~] |" cell)))
               (terpri out))))
      (emit stream)
      (with-open-file (out (merge-pathnames "RESULTS.md" *bench-directory*)
                           :direction :output :if-exists :supersede)
        (emit out)))
    (length names)))
