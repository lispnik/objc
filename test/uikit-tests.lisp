;;;; test/uikit-tests.lisp -- what of objc/uikit can be checked without UIKit.
;;;;
;;;; Most of the file names classes that exist only on a phone.  The one piece
;;;; with logic of its own is the target/action bridge, and that is Foundation:
;;;; an NSObject subclass whose fire: calls a Lisp function.

(in-package #:objc/test)

(def-suite uikit :in all-tests
  :description "objc/uikit: the target/action bridge.")

(in-suite uikit)

(test an-action-target-fires-its-function
  "What a button, a gesture recognizer or a timer does to a target: send it
fire: with itself as the sender.  Here objc_msgSend does the sending."
  (with-runtime
    (let* ((seen nil)
           (target (uikit:action-target (lambda (sender) (setf seen sender))))
           (sender (objc:invoke "NSObject" "new")))
      (objc:invoke target "fire:" sender)
      (is-true (cffi:pointerp seen))
      (is-true (cffi:pointer-eq seen sender)))))

(test a-target-contains-its-functions-errors
  "There is no handler on the UIKit side of fire:.  The target reports and
returns rather than letting a condition unwind into the caller."
  (with-runtime
    (let ((target (uikit:action-target (lambda (sender) (declare (ignore sender))
                                         (error "deliberate"))))
          (output (make-string-output-stream)))
      (let ((*error-output* output))
        (finishes (objc:invoke target "fire:" nil)))
      (is (search "deliberate" (get-output-stream-string output))))))

(test kept-objects-stay-kept-until-unkept
  (with-runtime
    (let ((object (objc:invoke "NSObject" "new")))
      (uikit:keep object)
      (is-true (member object uikit::*kept*))
      (uikit:unkeep object)
      (is-false (member object uikit::*kept*)))))
