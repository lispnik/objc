;;;; test/block-tests.lisp -- creating and calling Objective-C blocks.
;;;;
;;;; Foundation only: no window server, so these run wherever the runtime does.
;;;; The interesting assertions are the ones a wrong implementation would still
;;;; pass halfway -- a block whose invoke pointer is right but whose closure
;;;; lookup is wrong dispatches to the previous block, and a descriptor that
;;;; disagrees with the flags reads past its allocation without complaining.

(in-package #:objc/test)

(def-suite blocks :in all-tests
  :description "Blocks: Lisp closures called by Cocoa, and blocks called from Lisp.")

(in-suite blocks)

(defun global-queue ()
  (cffi:foreign-funcall "dispatch_get_global_queue" :long 0 :unsigned-long 0 :pointer))

(defun dispatch-sync-block (block)
  (cffi:foreign-funcall "dispatch_sync"
                        :pointer (global-queue)
                        :pointer (objc:objc-block-pointer block)
                        :void))

;;; Layout -------------------------------------------------------------------

(test the-block-literal-matches-the-published-abi
  "Everything else rests on these offsets, so they are asserted rather than
trusted.  The Block ABI has been stable since 2009 and the fields are not
reorderable: libclosure reads INVOKE and DESCRIPTOR out of memory it did not
allocate."
  (is (= 40 (objc::block-literal-size)))
  (is (= 0  (cffi:foreign-slot-offset '(:struct objc::block-literal) 'objc::isa)))
  (is (= 8  (cffi:foreign-slot-offset '(:struct objc::block-literal) 'objc::flags)))
  (is (= 12 (cffi:foreign-slot-offset '(:struct objc::block-literal) 'objc::reserved)))
  (is (= 16 (cffi:foreign-slot-offset '(:struct objc::block-literal) 'objc::invoke-ptr)))
  (is (= 24 (cffi:foreign-slot-offset '(:struct objc::block-literal) 'objc::descriptor)))
  (is (= 32 (cffi:foreign-slot-offset '(:struct objc::block-literal) 'objc::block-id)))
  ;; The descriptor is allocated in full whatever the flags say, so that
  ;; declaring BLOCK_HAS_SIGNATURE can never make _Block_signature read past it.
  (is (= 32 (cffi:foreign-type-size '(:struct objc::block-descriptor))))
  (is (= 16 (cffi:foreign-slot-offset '(:struct objc::block-descriptor) 'objc::signature))))

;;; Signatures ---------------------------------------------------------------

(defun block-encoding (result-type arg-types)
  (objc::block-type-encoding (objc::node-for-fli-type result-type)
                             (mapcar #'objc::node-for-fli-type arg-types)))

(test the-block-signature-is-the-method-encoding-with-the-block-in-place
  "A method is \"v@:@\"; the same block is \"v@?@\" -- the receiver and selector
replaced by the block itself."
  (is (string= "v@?" (block-encoding :void '())))
  (is (string= "v@?@" (block-encoding :void '(objc:objc-object-pointer))))
  (is (string= "q@?@@" (block-encoding :long-long '(objc:objc-object-pointer
                                                   objc:objc-object-pointer)))))

(test the-descriptor-and-the-flags-agree
  "The one test that proves the descriptor layout is right.  BLOCK_HAS_SIGNATURE
tells libclosure where to find the signature by computing an offset from the
flags, so if the flags and the descriptor disagree this reads rubbish or
crashes.  Asking _Block_signature and getting the string back is the only
end-to-end check of that agreement."
  (with-runtime
    (objc:with-objc-block (b '(:long-long (objc:objc-object-pointer
                                           objc:objc-object-pointer))
                             (lambda (a b) (declare (ignore a b)) 0))
      (let ((signature (objc::%block-signature (objc:objc-block-pointer b))))
        (is (not (cffi:null-pointer-p signature)))
        (is (string= "q@?@@" (cffi:foreign-string-to-lisp signature)))))))

;;; Cocoa calling a Lisp closure ---------------------------------------------

(test gcd-invokes-a-block-made-from-a-lisp-closure
  "dispatch_sync on a global queue: the smallest possible block, void (^)(void),
and the shape LispWorks' own GCD example uses."
  (with-runtime
    (let ((hits 0))
      (objc:with-objc-block (b '(:void ()) (lambda () (incf hits)))
        (dispatch-sync-block b)
        (dispatch-sync-block b))
      (is (= 2 hits) "the closure ran once per dispatch"))))

(test foundation-enumerates-through-a-lisp-closure
  "-[NSArray enumerateObjectsUsingBlock:] passes an object and an index, so this
covers a multi-argument block and the id-to-string conversion on the way in."
  (with-runtime
    (let ((array (objc:invoke "NSArray" "arrayWithArray:" #("alpha" "beta" "gamma")))
          (seen '()))
      (objc:with-objc-block
          (b '(:void (objc:objc-object-pointer (:unsigned :long-long)
                      (:pointer objc:objc-bool)))
             (lambda (object index stop)
               (declare (ignore stop))
               (push (cons index (objc:ns-string-to-string object)) seen)))
        (objc:invoke array "enumerateObjectsUsingBlock:" b))
      (is (equal '((0 . "alpha") (1 . "beta") (2 . "gamma")) (reverse seen))))))

(test writing-through-the-stop-out-parameter-halts-the-enumeration
  "The third argument is BOOL *stop, and Foundation reads it after every element.
An out-parameter is the case a conversion layer gets wrong in the quiet
direction: enumerating all four elements is what a dropped write looks like."
  (with-runtime
    (let ((array (objc:invoke "NSArray" "arrayWithArray:" #("a" "b" "c" "d")))
          (seen '()))
      (objc:with-objc-block
          (b '(:void (objc:objc-object-pointer (:unsigned :long-long)
                      (:pointer objc:objc-bool)))
             (lambda (object index stop)
               (push (objc:ns-string-to-string object) seen)
               (when (= index 1)
                 (setf (cffi:mem-ref stop :char) 1))))
        (objc:invoke array "enumerateObjectsUsingBlock:" b))
      (is (equal '("a" "b") (reverse seen))
          "Foundation stopped where the closure asked it to"))))

(test a-block-returning-bool-drives-a-foundation-predicate
  "-[NSArray indexOfObjectPassingTest:] wants BOOL back.  BOOL is a signed char
on arm64 while the runtime widens a return to a register, so this is the
caller-side conversion that has bitten this library before; a truncating or
sign-confused path finds the wrong element or none."
  (with-runtime
    (let ((array (objc:invoke "NSArray" "arrayWithArray:" #("pear" "apple" "fig"))))
      (flet ((index-of (predicate)
               (objc:with-objc-block
                   (b '(objc:objc-bool (objc:objc-object-pointer (:unsigned :long-long)
                                        (:pointer objc:objc-bool)))
                      (lambda (object index stop)
                        (declare (ignore index stop))
                        (funcall predicate (objc:ns-string-to-string object))))
                 (objc:invoke array "indexOfObjectPassingTest:" b))))
        (is (= 2 (index-of (lambda (s) (string= "fig" s)))))
        (is (= 0 (index-of (lambda (s) (= 4 (length s))))) "the first match, not the last")
        (is (= cocoa:ns-not-found (index-of (constantly nil)))
            "a closure that never returns true is NSNotFound, not zero")))))

(test foundation-sorts-using-a-lisp-comparator
  "-[NSArray sortedArrayUsingComparator:] is the one that proves a block's
RETURN value crosses correctly: Foundation decides the order from what the Lisp
closure returns, so a broken return gives a wrong permutation rather than an
error."
  (with-runtime
    (let ((array (objc:invoke "NSArray" "arrayWithArray:" #("pear" "apple" "fig"))))
      (objc:with-objc-block
          (b '(:long-long (objc:objc-object-pointer objc:objc-object-pointer))
             (lambda (x y)
               (let ((a (objc:ns-string-to-string x))
                     (c (objc:ns-string-to-string y)))
                 (cond ((string< a c) -1) ((string> a c) 1) (t 0)))))
        (let ((sorted (objc:invoke array "sortedArrayUsingComparator:" b)))
          (is (equal '("apple" "fig" "pear")
                     (loop for i below (objc:invoke sorted "count")
                           collect (objc:ns-string-to-string
                                    (objc:invoke sorted "objectAtIndex:" i))))))))))

(test a-block-can-be-invoked-on-a-foreign-thread
  "dispatch_async runs the block on a libdispatch worker -- a thread SBCL never
created.  Entering Lisp there is the thing that makes completion handlers
usable at all, and it is not something the synchronous tests cover."
  (with-runtime
    (let ((done (bt:make-semaphore))
          (main (bt:current-thread))
          (where nil))
      (let ((b (objc:make-objc-block '(:void ())
                                     (lambda ()
                                       (objc:with-autorelease-pool ()
                                         (setf where (bt:current-thread))
                                         (bt:signal-semaphore done))))))
        ;; Not WITH-OBJC-BLOCK: the block outlives this form, so it is freed
        ;; after the callback has certainly run.
        (unwind-protect
             (progn
               (cffi:foreign-funcall "dispatch_async"
                                     :pointer (global-queue)
                                     :pointer (objc:objc-block-pointer b)
                                     :void)
               (if (bt:wait-on-semaphore done :timeout 10)
                   (progn
                     (is-true where "the block ran")
                     (is (not (eq where main))
                         "and it ran on a thread SBCL did not create"))
                   (skip "the asynchronous block never ran on this machine")))
          (objc:free-objc-block b))))))

;;; Calling a block from Lisp ------------------------------------------------

(test a-block-can-be-called-from-lisp
  "The other direction: read the invoke pointer out of the literal and call it.
Works on any block, whoever built it -- this one is ours because Foundation
hands blocks out rarely, but the code path does not know the difference."
  (with-runtime
    (objc:with-objc-block (b '(:long-long (:long-long)) (lambda (n) (* 3 n)))
      (is (= 42 (objc:call-objc-block '(:long-long (:long-long)) b 14)))
      (is (= 0 (objc:call-objc-block '(:long-long (:long-long)) b 0))))))

(test calling-a-block-checks-its-argument-count
  (with-runtime
    (objc:with-objc-block (b '(:long-long (:long-long)) (lambda (n) n))
      (signals error (objc:call-objc-block '(:long-long (:long-long)) b))
      (signals error (objc:call-objc-block '(:long-long (:long-long)) b 1 2)))))

;;; Machinery --------------------------------------------------------------

(test one-signature-compiles-one-invoke-function
  "Building the invoke function calls the compiler, so it must happen once per
signature rather than once per block -- the reason LispWorks splits its API into
a load-time type definition and a run-time allocation.  Sharing the pointer is a
stronger claim than a stable table count, and the closures must still be
distinct or every block of a shape would run the first one's code."
  (with-runtime
    (objc:define-objc-block-type test-tripler :long-long (:long-long))
    ;; Warm the signature so the assertions are about the second block onward.
    (objc:with-objc-block (warm 'test-tripler (lambda (n) n))
      (is (= 7 (objc:call-objc-block 'test-tripler warm 7))))
    (let ((before (hash-table-count objc::*block-machinery*)))
      (objc:with-objc-block (b1 'test-tripler (lambda (n) (* 3 n)))
        (objc:with-objc-block (b2 'test-tripler (lambda (n) (* 5 n)))
          (is (= before (hash-table-count objc::*block-machinery*))
              "a known signature does not rebuild its machinery")
          (is (cffi:pointer-eq
               (cffi:foreign-slot-value (objc:objc-block-pointer b1)
                                        '(:struct objc::block-literal) 'objc::invoke-ptr)
               (cffi:foreign-slot-value (objc:objc-block-pointer b2)
                                        '(:struct objc::block-literal) 'objc::invoke-ptr))
              "and both blocks share the one invoke function")
          (is (= 30 (objc:call-objc-block 'test-tripler b1 10)))
          (is (= 50 (objc:call-objc-block 'test-tripler b2 10))
              "while still reaching their own closures"))))))

(test the-closure-is-found-through-the-id-not-the-address
  "_Block_copy relocates a block -- which is what every asynchronous API does to
one it keeps -- so the copy has a different address and must still reach the
same closure.  Keying the registry on the pointer would pass every other test
here and fail exactly when a block escapes."
  (with-runtime
    (let ((hits 0))
      (objc:with-objc-block (b '(:void ()) (lambda () (incf hits)))
        (let ((copy (objc::%block-copy (objc:objc-block-pointer b))))
          (is (not (cffi:pointer-eq copy (objc:objc-block-pointer b)))
              "the copy is at a different address")
          (dispatch-sync-block b)
          (cffi:foreign-funcall "dispatch_sync"
                                :pointer (global-queue) :pointer copy :void)
          (is (= 2 hits) "the original and the copy reached the same closure")
          (objc::%block-release copy))))))

;;; Lifetime and containment -------------------------------------------------

(test a-lisp-error-does-not-escape-a-block
  "There is no handler on the Objective-C side, exactly as for an IMP: an unwind
past the invoke frame aborts the process."
  (with-runtime
    (let ((output (make-string-output-stream)))
      (let ((*error-output* output))
        (objc:with-objc-block (b '(:long-long (:long-long))
                                 (lambda (n) (declare (ignore n))
                                   (error "deliberate block failure")))
          (is (eql 0 (objc:call-objc-block '(:long-long (:long-long)) b 1))
              "the zero value for the result type is returned instead")))
      (is (search "deliberate" (get-output-stream-string output))
          "and the condition is reported"))))

(test freeing-a-block-is-idempotent-and-answerable
  (with-runtime
    (let ((b (objc:make-objc-block '(:void ()) (lambda () nil))))
      (is-true (objc:objc-block-live-p b))
      (objc:free-objc-block b)
      (is-false (objc:objc-block-live-p b))
      (finishes (objc:free-objc-block b))
      (signals error (objc:objc-object-pointer b)))))

(test invoking-a-freed-blocks-copy-is-reported-not-fatal
  "The hazard this design exists to soften.  A copy Cocoa made lives in Cocoa's
memory, so invoking it after the original was freed finds a live invoke function
and a missing registry entry: a diagnostic, not a jump through freed memory.
Ids are never reused, which is what stops it reaching some later block instead."
  (with-runtime
    (let* ((b (objc:make-objc-block '(:void ()) (lambda () nil)))
           (copy (objc::%block-copy (objc:objc-block-pointer b)))
           (output (make-string-output-stream)))
      (objc:free-objc-block b)
      (let ((*error-output* output))
        (finishes (cffi:foreign-funcall "dispatch_sync"
                                        :pointer (global-queue) :pointer copy :void)))
      (is (search "freed" (get-output-stream-string output))
          "the invocation reported a freed block")
      (objc::%block-release copy))))

(test the-registry-does-not-leak-and-does-not-reuse-ids
  (with-runtime
    (let ((before-records (hash-table-count objc::*block-records*))
          (before-counter objc::*block-id-counter*))
      (dotimes (i 5)
        (objc:with-objc-block (b '(:void ()) (lambda () nil))
          (is-true (objc:objc-block-live-p b))))
      (is (= before-records (hash-table-count objc::*block-records*))
          "every block was unregistered")
      (is (= (+ 5 before-counter) objc::*block-id-counter*)
          "and each got its own id, none reused"))))

(test with-objc-block-frees-on-a-non-local-exit
  (with-runtime
    (let ((escaped nil))
      (ignore-errors
       (objc:with-objc-block (b '(:void ()) (lambda () nil))
         (setf escaped b)
         (error "unwind")))
      (is-false (objc:objc-block-live-p escaped)))))
