;;;; test/oracle/probe.lisp -- paste this into a LispWorks Listener.
;;;;
;;;; LispWorks Personal 8.1 cannot be scripted.  -eval is not honoured: the
;;;; process ignores it and launches the IDE, which never exits, and the heap
;;;; says why -- "Initialization files are not available in the Personal Edition
;;;; of LispWorks."  SAVE-IMAGE, DELIVER and LOAD-ALL-PATCHES are blocked the
;;;; same way, and the C launcher only recognises -lw-architecture and
;;;; -lw-verbose-mapping.  So this is gathered by hand, once, and the results
;;;; are committed to answers.lisp next door.
;;;;
;;;; Block 1 is safe.  Block 2 is at the bottom and will very likely take the
;;;; image down; run it last, in a fresh Listener.

;;; ---------------------------------------------------------------- Block 1

(progn
  (objc:ensure-objc-initialized
   :modules '("/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"
              "/System/Library/Frameworks/Cocoa.framework/Versions/A/Cocoa"))
  (let ((s (objc:invoke "NSString" "stringWithUTF8String:" "hello world"))
        (c (objc:coerce-to-objc-class "NSString")))
    (flet ((p (label thunk)
             (format t "~&~28a => ~s~%" label
                     (handler-case (funcall thunk)
                       (condition (e) (list :signalled (type-of e)
                                            (princ-to-string e)))))))
      (p "BOOL invoke true"    (lambda () (objc:invoke s "isKindOfClass:" c)))
      (p "BOOL invoke false"   (lambda () (objc:invoke s "hasPrefix:" "zzz")))
      (p "BOOL invoke-bool"    (lambda () (objc:invoke-bool s "isKindOfClass:" c)))
      (p "length"              (lambda () (objc:invoke s "length")))
      (p "rangeOfString: bare" (lambda () (objc:invoke s "rangeOfString:" "world")))
      (p "sizeof ns-point"     (lambda () (fli:size-of 'cocoa:ns-point)))
      (p "sizeof ns-size"      (lambda () (fli:size-of 'cocoa:ns-size)))
      (p "sizeof ns-rect"      (lambda () (fli:size-of 'cocoa:ns-rect)))
      (p "sizeof ns-range"     (lambda () (fli:size-of 'cocoa:ns-range)))
      (p "sig length"          (lambda () (multiple-value-list
                                           (objc:objc-class-method-signature "NSString" "length"))))
      (p "sig rangeOfString:"  (lambda () (multiple-value-list
                                           (objc:objc-class-method-signature "NSString" "rangeOfString:"))))
      (p "sig substringWithR:" (lambda () (multiple-value-list
                                           (objc:objc-class-method-signature "NSString" "substringWithRange:"))))
      (p "sig description"     (lambda () (multiple-value-list
                                           (objc:objc-class-method-signature "NSObject" "description"))))
      (p "can-invoke-p bogus"  (lambda () (objc:can-invoke-p s "noSuchMethodAtAll")))
      (p "selector-name str"   (lambda () (objc:selector-name "notAColonName")))
      (p "selector-name sel"   (lambda () (objc:selector-name (objc:coerce-to-selector "setWidth:height:"))))
      (p "retain-count new"    (lambda () (objc:retain-count (objc:invoke "NSObject" "new"))))
      (p "missing method"      (lambda () (objc:invoke s "noSuchMethodAtAll")))))
  (values))

;;; ---------------------------------------------------------------- Block 2
;;;
;;; DANGEROUS.  An out-of-range -[NSArray objectAtIndex:] raises an
;;; NSException, and LispWorks has no @try/@catch anywhere -- the 8.1 image
;;; imports no __cxa_begin_catch, no objc_exception_*, and no
;;; NSSetUncaughtExceptionHandler.  What was actually observed is that the
;;; exception reached objc_terminate, called abort(), and LispWorks' generic
;;; fatal-signal handler turned the SIGABRT into SYSTEM::EXCEPTION-ERROR with a
;;; register dump.  That is crash recovery, not exception bridging.

#|
(handler-case (objc:invoke (objc:invoke "NSArray" "array") "objectAtIndex:" 5)
  (condition (e) (list :caught (type-of e) (princ-to-string e))))
|#
