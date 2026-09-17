;;;; examples/exceptions.lisp -- an Objective-C exception, earned on purpose.
;;;;
;;;; Every other example avoids raising one, and rightly: the frames an
;;;; exception abandons leave the subsystem that raised in a state not worth
;;;; trusting.  This one earns three failures whose subsystems are disposable
;;;; -- an array past its end, a selector nothing implements, a file that is
;;;; not there -- and shows what each looks like as a condition.
;;;;
;;;; The first two are NSExceptions.  They used to end the process; now the
;;;; runtime's uncaught-exception handler hands them to the innermost send,
;;;; which signals OBJC:OBJC-EXCEPTION with the name and reason Cocoa wrote.
;;;; The third is an NSError, the failure Cocoa designs for: INVOKE-WITH-ERROR
;;;; supplies the out-parameter and signals OBJC:NS-ERROR with the domain, code
;;;; and description.  See README, "Exceptions and NSError".

(in-package #:objc/examples)

(defun out-of-range ()
  "The exception every Cocoa programmer has met: -[NSArray objectAtIndex:] past
the end.  Returns the condition, or NIL if nothing was raised."
  (handler-case (progn (objc:invoke (objc:invoke "NSArray" "array") "objectAtIndex:" 3)
                       nil)
    (objc:objc-exception (e) e)))

(defun unrecognized-selector (object)
  "A selector OBJECT does not implement, sent the way Cocoa itself would.

INVOKE resolves the Method first and refuses with a Lisp error before sending,
which is the right failure for code you wrote.  -performSelector: hands the
selector to the runtime unresolved, as a framework does, and the runtime raises
NSInvalidArgumentException from inside the send.  Returns the condition."
  (handler-case (progn (objc:invoke object "performSelector:" (objc:coerce-to-selector "fly"))
                       nil)
    (objc:objc-exception (e) e)))

(defun missing-file (path)
  "+[NSString stringWithContentsOfFile:encoding:error:] on PATH, which is not
there.  The NSError ** is INVOKE-WITH-ERROR's; the condition is NS-ERROR."
  (handler-case (progn (objc:invoke-with-error "NSString" "stringWithContentsOfFile:encoding:error:"
                                               path 4)
                       nil)
    (objc:ns-error (e) e)))

(defun test-exceptions ()
  "Earn the three failures and return a plist of what each condition carried.

    (objc/examples:test-exceptions)
    => (:RANGE-NAME \"NSRangeException\" :RANGE-REASON \"*** -[__NSArray0 objectAtIndex:]: ...\"
        :SELECTOR-NAME \"NSInvalidArgumentException\"
        :ERROR-DOMAIN \"NSCocoaErrorDomain\" :ERROR-CODE 260 :ERROR-DESCRIPTION \"...\"
        :SURVIVED T :NESTED 2)

:SURVIVED is the point: the send after the exceptions works.  :NESTED earns
the exception inside a block inside a send, where the block's own send catches
it and the enumeration completes."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (let ((range (out-of-range))
          (selector (unrecognized-selector (objc:invoke "NSString" "stringWithUTF8String:" "a string")))
          (file (missing-file "/nonexistent/objc-exceptions-example")))
      (list :range-name (and range (objc:objc-exception-name range))
            :range-reason (and range (objc:objc-exception-reason range))
            :selector-name (and selector (objc:objc-exception-name selector))
            :error-domain (and file (objc:ns-error-domain file))
            :error-code (and file (objc:ns-error-code file))
            :error-description (and file (objc:ns-error-description file))
            :survived (= 8 (objc:invoke (objc:invoke "NSString" "stringWithUTF8String:" "survived")
                                        "length"))
            :nested (let ((names '())
                          (array (objc:invoke "NSMutableArray" "array")))
                      (dotimes (i 2)
                        (objc:invoke array "addObject:" (objc:invoke "NSString" "stringWithUTF8String:" "x")))
                      (objc:with-objc-block (b '(:void (objc:objc-object-pointer (:unsigned :long-long)
                                                        (:pointer :char)))
                                               (lambda (object index stop)
                                                 (declare (ignore object index stop))
                                                 (let ((e (out-of-range)))
                                                   (when e (push (objc:objc-exception-name e) names)))))
                        (objc:invoke array "enumerateObjectsUsingBlock:" b))
                      (length names))))))

(defun report-exceptions ()
  "Print what TEST-EXCEPTIONS found."
  (let ((result (test-exceptions)))
    (format t "~&objectAtIndex: past the end raised ~A:~%  ~A~%"
            (getf result :range-name) (getf result :range-reason))
    (format t "an unrecognized selector raised ~A~%" (getf result :selector-name))
    (format t "a missing file is ~A ~D: ~A~%"
            (getf result :error-domain) (getf result :error-code) (getf result :error-description))
    (format t "the next send worked: ~A; caught inside a block ~D times~%"
            (getf result :survived) (getf result :nested))
    result))
