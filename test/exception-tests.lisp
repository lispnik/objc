;;;; test/exception-tests.lisp -- an Objective-C exception inside a send, and NSError.

(in-package #:objc/test)

(def-suite exceptions :in all-tests
  :description "An NSException raised inside a send is a condition; an NSError
written through an out-parameter is one too.")
(in-suite exceptions)

(defmacro with-exceptions (&body body)
  `(with-runtime
     (if (not (objc::objc-exceptions-catchable-p))
         (skip "Objective-C exceptions are not catchable on this build")
         (progn ,@body))))

(defun empty-array () (objc:invoke "NSArray" "array"))

(defparameter +enumerate-block-type+
  '(:void (objc:objc-object-pointer (:unsigned :long-long) (:pointer :char))))

;;; Exceptions -----------------------------------------------------------------

(test an-out-of-range-index-signals-objc-exception
  "The exception that used to take the process down: -[NSArray objectAtIndex:]
past the end raises NSRangeException, no Objective-C frame between here and
there catches it, and the runtime's uncaught-exception handler is ours."
  (with-exceptions
    (signals objc:objc-exception (objc:invoke (empty-array) "objectAtIndex:" 0))
    (handler-case (progn (objc:invoke (empty-array) "objectAtIndex:" 0)
                         (fail "no exception was signalled"))
      (objc:objc-exception (e)
        (is (string= "NSRangeException" (objc:objc-exception-name e)))
        (is (search "beyond bounds" (objc:objc-exception-reason e)))
        (is-false (cffi:null-pointer-p (objc:objc-exception-object e)))
        (let ((report (princ-to-string e)))
          (is (search "-objectAtIndex:" report))
          (is (search "NSRangeException" report))
          (is (search "beyond bounds" report)))))))

(test an-unrecognized-selector-sent-by-cocoa-itself-is-caught
  "MISSING-METHOD-SIGNALS-BEFORE-SENDING covers the selector INVOKE resolves
first.  -performSelector: hands the selector to the runtime unresolved, which
is how Cocoa itself reaches an unrecognized one, and that raises
NSInvalidArgumentException from inside the send."
  (with-exceptions
    (handler-case (progn (objc:invoke (ns "hello") "performSelector:"
                                      (objc:coerce-to-selector "noSuchMethodAtAll"))
                         (fail "no exception was signalled"))
      (objc:objc-exception (e)
        (is (string= "NSInvalidArgumentException" (objc:objc-exception-name e)))))))

(test the-process-survives-and-the-next-send-works
  "A hundred caught exceptions, a full collection, a thousand sends: the
abandoned C frames left nothing behind that the next send trips over."
  (with-exceptions
    (dotimes (i 100)
      (handler-case (objc:invoke (empty-array) "objectAtIndex:" 0)
        (objc:objc-exception () nil)))
    #+sbcl (sb-ext:gc :full t)
    #+ecl (si:gc t)
    (let ((s (ns "hello")))
      (dotimes (i 1000) (objc:invoke s "length"))
      (is (= 5 (objc:invoke s "length"))))))

(test the-innermost-send-catches-a-nested-exception
  "A send inside a block inside a send: the exception is caught by the send
that made it, inside the block, and the outer enumeration completes."
  (with-exceptions
    (let ((names '())
          (array (objc:invoke "NSMutableArray" "array")))
      (dotimes (i 3) (objc:invoke array "addObject:" (ns "x")))
      (objc:with-objc-block (b +enumerate-block-type+
                               (lambda (object index stop)
                                 (declare (ignore object index stop))
                                 (handler-case (objc:invoke (empty-array) "objectAtIndex:" 99)
                                   (objc:objc-exception (e)
                                     (push (objc:objc-exception-name e) names)))))
        (finishes (objc:invoke array "enumerateObjectsUsingBlock:" b)))
      (is (equal '("NSRangeException" "NSRangeException" "NSRangeException") names)))))

(test an-exception-across-a-lisp-callback-frame-unwinds-the-lisp-frames
  "Raised inside a block, with no send of its own to catch it (SEND-RAW has
none), the exception is the outer send's: the throw crosses the block's Lisp
frame, whose UNWIND-PROTECT runs, and the enumeration's C frames, which are
abandoned."
  (with-exceptions
    (let ((cleaned nil)
          (array (objc:invoke "NSArray" "arrayWithObject:" (ns "x"))))
      (objc:with-objc-block (b +enumerate-block-type+
                               (lambda (object index stop)
                                 (declare (ignore object index stop))
                                 (unwind-protect
                                      (objc::send-raw
                                       (objc:invoke "NSException" "exceptionWithName:reason:userInfo:"
                                                    "TestException" "from a block" nil)
                                       "raise")
                                   (setf cleaned t))))
        (handler-case (progn (objc:invoke array "enumerateObjectsUsingBlock:" b)
                             (fail "no exception was signalled"))
          (objc:objc-exception (e)
            (is (string= "TestException" (objc:objc-exception-name e)))
            (is (string= "from a block" (objc:objc-exception-reason e))))))
      (is-true cleaned "the block's UNWIND-PROTECT cleanup ran")
      (is (= 5 (objc:invoke (ns "hello") "length"))))))

(test a-secondary-lisp-thread-catches-its-own-exception
  "The catch is per send and the send is on this thread, whichever thread
that is."
  (with-exceptions
    (let ((name nil))
      (bt:join-thread
       (bt:make-thread
        (lambda ()
          (objc:with-autorelease-pool ()
            (handler-case (objc:invoke (empty-array) "objectAtIndex:" 0)
              (objc:objc-exception (e) (setf name (objc:objc-exception-name e))))))))
      (is (string= "NSRangeException" name)))))

(test the-handler-is-still-ours-after-appkit-loads
  "CoreFoundation installs its own uncaught-exception handler when it
initializes; ours must be the one in place after every framework this
library loads has come up."
  (with-exceptions
    (objc::ensure-appkit)
    (signals objc:objc-exception (objc:invoke (empty-array) "objectAtIndex:" 0))))

#+sbcl
(test an-exception-on-a-foreign-thread-outside-any-send-still-terminates-the-process
  "The one path that must NOT change: an exception with no send in progress on
its thread -- here a thread the runtime made -- reaches the handler that was
installed before ours and the process aborts with CoreFoundation's message.
Only safe to test in a subprocess, which is what this is; the bootstrap is
dump-tests'."
  (with-exceptions
    (let* ((program (format nil "~a(asdf:load-system :objc)
(objc:ensure-objc-initialized)
(let ((exc (objc:invoke \"NSException\" \"exceptionWithName:reason:userInfo:\"
                        \"OutsideException\" \"raised outside any send\" nil)))
  (objc:retain exc)
  (objc:invoke exc \"performSelectorInBackground:withObject:\"
               (objc:coerce-to-selector \"raise\") nil)
  (sleep 5)
  (format t \"STILL ALIVE~%\"))" (bootstrap-form)))
           (output nil) (error-output nil) (status nil))
      ;; Written to a file and loaded, as dump-tests does: --eval reads every
      ;; form of its string before evaluating the first, so asdf: is
      ;; unreadable there until (require :asdf) has run.  And the same
      ;; runtime as this test's (TEST-RUNTIME), not whatever sbcl is on PATH.
      (uiop:with-temporary-file (:pathname source :type "lisp" :keep nil)
        (with-open-file (out source :direction :output :if-exists :supersede)
          (write-string program out))
        (multiple-value-setq (output error-output status)
          (uiop:run-program (list (test-runtime) "--noinform" "--non-interactive"
                                  "--load" (namestring source))
                            :output :string :error-output :string
                            :ignore-error-status t)))
      (is (/= 0 status) "the subprocess died")
      (is (not (search "STILL ALIVE" output)) "and never printed after the raise")
      (is (search "OutsideException" error-output)
          "with CoreFoundation's uncaught-exception message: ~a" error-output))))

;;; NSError --------------------------------------------------------------------

(objc:define-objc-class error-probe ()
  ()
  (:objc-class-name "ObjcErrorProbe"))

(defun write-test-error (out)
  (unless (cffi:null-pointer-p out)
    (setf (cffi:mem-ref out :pointer)
          (objc:invoke "NSError" "errorWithDomain:code:userInfo:" "ObjcTestDomain" 42 nil))))

(objc:define-objc-method ("failWithError:" objc:objc-object-pointer)
    ((self error-probe) (out (:pointer objc:objc-object-pointer)))
  (declare (ignore self))
  (write-test-error out)
  nil)

(objc:define-objc-method ("failWithoutError:" objc:objc-object-pointer)
    ((self error-probe) (out (:pointer objc:objc-object-pointer)))
  (declare (ignore self out))
  nil)

(objc:define-objc-method ("succeedWithError:" objc:objc-bool)
    ((self error-probe) (out (:pointer objc:objc-object-pointer)))
  (declare (ignore self))
  (write-test-error out)
  t)

(objc:define-objc-method ("voidFailWithError:" :void)
    ((self error-probe) (out (:pointer objc:objc-object-pointer)))
  (declare (ignore self))
  (write-test-error out))

(test invoke-with-error-signals-when-the-method-failed-and-wrote-an-error
  (with-runtime
    (let ((probe (objc:alloc-init-object "ObjcErrorProbe")))
      (handler-case (progn (objc:invoke-with-error probe "failWithError:")
                           (fail "no NS-ERROR was signalled"))
        (objc:ns-error (e)
          (is (string= "ObjcTestDomain" (objc:ns-error-domain e)))
          (is (= 42 (objc:ns-error-code e)))
          (is (stringp (objc:ns-error-description e)))
          (is-false (cffi:null-pointer-p (objc:ns-error-object e)))
          (let ((report (princ-to-string e)))
            (is (search "-failWithError: failed:" report))
            (is (search "(ObjcTestDomain 42)" report))))))))

(test invoke-with-error-returns-a-failure-value-when-no-error-was-written
  (with-runtime
    (let ((probe (objc:alloc-init-object "ObjcErrorProbe")))
      (is (cffi:null-pointer-p (objc:invoke-with-error probe "failWithoutError:"))))))

(test invoke-with-error-returns-a-success-value-whatever-the-error-slot-holds
  "Cocoa promises the error only on failure; a method that wrote one and
answered YES answered YES.  And a BOOL comes back as INVOKE returns it, 1."
  (with-runtime
    (let ((probe (objc:alloc-init-object "ObjcErrorProbe")))
      (is (eql 1 (objc:invoke-with-error probe "succeedWithError:"))))))

(test invoke-with-error-signals-for-a-void-method-that-wrote-an-error
  (with-runtime
    (let ((probe (objc:alloc-init-object "ObjcErrorProbe")))
      (signals objc:ns-error (objc:invoke-with-error probe "voidFailWithError:")))))

(test invoke-with-error-on-a-cocoa-class-method
  "+[NSString stringWithContentsOfFile:encoding:error:] on a path that does not
exist: NSCocoaErrorDomain 260, NSFileReadNoSuchFileError.  On one that does,
the string."
  (with-runtime
    (handler-case (progn (objc:invoke-with-error "NSString" "stringWithContentsOfFile:encoding:error:"
                                                 "/nonexistent/objc-test-file" 4)
                         (fail "no NS-ERROR was signalled"))
      (objc:ns-error (e)
        (is (string= "NSCocoaErrorDomain" (objc:ns-error-domain e)))
        (is (= 260 (objc:ns-error-code e)))
        (is (search "+stringWithContentsOfFile:encoding:error: failed:" (princ-to-string e)))))
    (is-false (cffi:null-pointer-p
               (objc:invoke-with-error "NSString" "stringWithContentsOfFile:encoding:error:"
                                       "/etc/hosts" 4)))))

(test invoke-with-error-refuses-a-selector-without-an-error-parameter
  (with-runtime
    (signals error (objc:invoke-with-error (ns "x") "length"))))
