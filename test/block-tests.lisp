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
  ;; Its size and the signature's offset both depend on BLOCK_HAS_COPY_DISPOSE:
  ;; libclosure steps over the copy and dispose pointers only when that flag is
  ;; set, so these two numbers and the flags have to agree or the signature is
  ;; read from the wrong place.
  (is (= 48 (cffi:foreign-type-size '(:struct objc::block-descriptor))))
  (is (= 16 (cffi:foreign-slot-offset '(:struct objc::block-descriptor) 'objc::copy)))
  (is (= 24 (cffi:foreign-slot-offset '(:struct objc::block-descriptor) 'objc::dispose)))
  (is (= 32 (cffi:foreign-slot-offset '(:struct objc::block-descriptor) 'objc::signature))))

(test the-flags-say-what-the-descriptor-provides
  (with-runtime
    (objc:with-objc-block (b '(:void ()) (lambda () nil))
      (let ((flags (cffi:foreign-slot-value (objc:objc-block-pointer b)
                                            '(:struct objc::block-literal) 'objc::flags)))
        (is (logtest flags objc::+block-has-signature+))
        (is (logtest flags objc::+block-has-copy-dispose+))
        (is (not (logtest flags objc::+block-is-global+))
            "a global block would make _Block_copy return the same pointer")
        (is (not (logtest flags objc::+block-use-stret+)))))))

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

;;; Structures by value ------------------------------------------------------

(test foundation-passes-structures-to-a-block-by-value
  "-[NSString enumerateSubstringsInRange:options:usingBlock:] passes two NSRanges
BY VALUE, which is the case a block ABI gets wrong quietly: a struct argument
occupies its own registers, so misreading one shifts every argument after it.
The ranges arriving right is what says the block's invoke function has the
signature Foundation thinks it has."
  (with-runtime
    (let ((string (objc:invoke "NSString" "stringWithUTF8String:" "alpha beta gamma"))
          (seen '()))
      (objc:with-objc-block
          (b '(:void (objc:objc-object-pointer cocoa:ns-range cocoa:ns-range
                      (:pointer objc:objc-bool)))
             (lambda (substring range enclosing stop)
               (declare (ignore enclosing stop))
               (push (cons (objc:ns-string-to-string substring) range) seen)))
        (objc:invoke string "enumerateSubstringsInRange:options:usingBlock:"
                     (cons 0 (objc:invoke string "length"))
                     3                          ; NSStringEnumerationByWords
                     b))
      (is (equal '(("alpha" . (0 . 5)) ("beta" . (6 . 4)) ("gamma" . (11 . 5)))
                 (reverse seen))
          "each word, with the NSRange Foundation passed by value"))))

(test a-block-can-return-a-structure-by-value
  "The other side of the same ABI question, and the one with a wrinkle: an
NSRect is four doubles, so arm64 returns it in v0-v3 rather than through a
hidden pointer despite being 32 bytes.  Whether that is right is sb-alien's
business; that it is exercised is this test's."
  (with-runtime
    (objc:with-objc-block (b '(cocoa:ns-rect (:double))
                             (lambda (n) (vector n (* 2 n) (* 3 n) (* 4 n))))
      (is (equalp #(1.5d0 3.0d0 4.5d0 6.0d0)
                  (objc:call-objc-block '(cocoa:ns-rect (:double)) b 1.5d0))))))

(test structures-cross-in-both-directions-in-one-call
  (with-runtime
    (let ((type '(cocoa:ns-rect (cocoa:ns-rect cocoa:ns-point))))
      (objc:with-objc-block (b type
                               (lambda (rect point)
                                 (vector (+ (aref rect 0) (aref point 0))
                                         (+ (aref rect 1) (aref point 1))
                                         (aref rect 2) (aref rect 3))))
        (is (equalp #(11d0 22d0 30d0 40d0)
                    (objc:call-objc-block type b #(1d0 2d0 30d0 40d0) #(10d0 20d0))))))))

(test the-signature-names-the-structures
  (with-runtime
    (objc:with-objc-block (b '(cocoa:ns-rect (cocoa:ns-point))
                             (lambda (p) (declare (ignore p)) #(0d0 0d0 0d0 0d0)))
      (is (string= "{CGRect={CGPoint=dd}{CGSize=dd}}@?{CGPoint=dd}"
                   (cffi:foreign-string-to-lisp
                    (objc::%block-signature (objc:objc-block-pointer b))))))))

(test a-structure-result-with-no-lisp-representation-is-refused-not-dangled
  "A block may RETURN any structure -- Cocoa gets it by value and is happy --
but CALL-OBJC-BLOCK has to hand Lisp something, and for a structure with no
Lisp representation the only candidate is a pointer into the buffer this call
frees on its way out.  Refusing beats returning one: a dangling pointer reads
as plausible numbers."
  (with-runtime
    (objc:define-objc-struct (block-test-quad (:foreign-name "BlockTestQuad"))
      (a :long-long) (b :long-long) (c :long-long) (d :long-long))
    ;; Creating it is fine -- this is only about the direction back into Lisp.
    (objc:with-objc-block (b '(block-test-quad (:long-long))
                             (lambda (n) (declare (ignore n)) nil))
      (signals error (objc:call-objc-block '(block-test-quad (:long-long)) b 1)))))

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

(test a-block-freed-while-cocoa-holds-a-copy-still-runs
  "The hazard the copy and dispose helpers exist to remove, and the one thing
that makes the lifetime rule ordinary.  A copy libclosure made took its own
reference to the closure on the way, so freeing the original releases only the
reference this OBJC-BLOCK held -- and the copy still runs.

Before the helpers this was a diagnostic at best: the block was gone and the
invocation reported a missing registry entry."
  (with-runtime
    (let ((hits 0))
      (let* ((b (objc:make-objc-block '(:void ()) (lambda () (incf hits))))
             (copy (objc::%block-copy (objc:objc-block-pointer b))))
        (objc:free-objc-block b)
        (is-false (objc:objc-block-live-p b) "the original's storage is gone")
        (cffi:foreign-funcall "dispatch_sync"
                              :pointer (global-queue) :pointer copy :void)
        (is (= 1 hits) "and the copy reached the closure anyway")
        (objc::%block-release copy)))))

(test the-refcount-follows-libclosure-not-our-guesses
  "What the helpers actually count is ALLOCATIONS, one dispose per copy-helper
call -- not retains.  _Block_copy on a block already on the heap bumps
libclosure's own count and returns the same pointer without calling the copy
helper, so the two schemes nest instead of double-counting.  Asserted because
getting it wrong leaks every escaped closure, silently and forever."
  (with-runtime
    (let* ((b (objc:make-objc-block '(:void ()) (lambda () nil)))
           (id (objc::objc-block-id b)))
      (flet ((refcount ()
               (let ((record (gethash id objc::*block-records*)))
                 (and record (objc::block-record-refcount record)))))
        (is (= 1 (refcount)) "the OBJC-BLOCK itself")
        (let ((copy (objc::%block-copy (objc:objc-block-pointer b))))
          (is (= 2 (refcount)) "the first copy called the copy helper")
          (let ((again (objc::%block-copy copy)))
            (is (cffi:pointer-eq copy again)
                "a copy of a heap block is the same pointer")
            (is (= 2 (refcount)) "and did not call the helper again")
            (objc::%block-release again)
            (is (= 2 (refcount)) "nor did releasing it call dispose"))
          (objc:free-objc-block b)
          (is (= 1 (refcount)) "freeing the original dropped only its own")
          (objc::%block-release copy)
          (is (null (refcount)) "and the last release retired the entry"))))))

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

(test concurrent-blocks-work-or-refuse-according-to-the-build
  "Running a Lisp closure on several libdispatch threads at once is fatal on a
stock SBCL -- a GC stops the world by signalling every other thread in Lisp, and
Darwin will not signal a libdispatch worker -- and works on one built
--with-sb-safepoint, which stops the world by polling instead.

So this asserts two different things depending on the Lisp running it, and the
one it must never do is take the process down.  On a stock build the refusal is
the feature."
  (with-runtime
    (if (objc/examples:concurrent-blocks-supported-p)
        (let ((squares (objc/examples:parallel-map
                        (lambda (n) (* n n))
                        (coerce (loop for i below 32 collect i) 'vector))))
          (is (equalp (map 'vector (lambda (n) (* n n))
                           (coerce (loop for i below 32 collect i) 'vector))
                      squares)
              "every index was computed exactly once, in parallel"))
        (progn
          (signals error (objc/examples:parallel-map #'identity #(1 2 3)))
          (is (search "sb-safepoint"
                      (princ-to-string
                       (handler-case (objc/examples:parallel-map #'identity #(1 2 3))
                         (error (c) c))))
              "and the refusal names the build that would work")))))

(test with-objc-block-frees-on-a-non-local-exit
  (with-runtime
    (let ((escaped nil))
      (ignore-errors
       (objc:with-objc-block (b '(:void ()) (lambda () nil))
         (setf escaped b)
         (error "unwind")))
      (is-false (objc:objc-block-live-p escaped)))))
