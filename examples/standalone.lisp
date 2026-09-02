;;;; examples/standalone.lisp
;;;;
;;;; Ported from section 3.4.1 of the manual, "Running Cocoa standalone".
;;;;
;;;; The original wraps everything in MP:INITIALIZE-MULTIPROCESSING.  There is
;;;; no equivalent here and none is needed: that call exists in LispWorks to
;;;; hand thread 1 over to Cocoa, and on SBCL the initial thread already IS
;;;; thread 1, which is where the REPL and this code run.

(in-package #:objc/examples)

(objc:define-objc-class application-delegate ()
  ((launched :initform nil :accessor application-delegate-launched-p))
  (:objc-class-name "LispApplicationDelegate"))

(objc:define-objc-method ("applicationDidFinishLaunching:" :void)
    ((self application-delegate)
     (notification objc:objc-object-pointer))
  (declare (ignore notification))
  (setf (application-delegate-launched-p self) t))

(objc:define-objc-method ("applicationShouldTerminateAfterLastWindowClosed:"
                          objc:objc-bool)
    ((self application-delegate)
     (application objc:objc-object-pointer))
  (declare (ignore application))
  t)

(defun init-function ()
  "The manual's INIT-FUNCTION, minus the multiprocessing dance."
  (objc:ensure-objc-initialized
   :modules
   '("/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"
     "/System/Library/Frameworks/Cocoa.framework/Versions/A/Cocoa"))
  (objc:with-autorelease-pool ()
    (let ((app (objc.runloop:shared-application))
          (delegate (make-instance 'application-delegate)))
      (objc:invoke app "setDelegate:" (objc:objc-object-pointer delegate))
      ;; The manual's example ends with (objc:invoke app "run"), which never
      ;; returns.  RUN-COCOA-APPLICATION is that, named so the blocking is
      ;; obvious at the call site.
      (objc.runloop:run-cocoa-application))))
