;;;; test/thread-tests.lisp -- sending from threads other than the main one.
;;;;
;;;; Foundation is fine off the main thread; AppKit is not, and the run loop
;;;; entry points check.  What a secondary thread does need is its own
;;;; autorelease pool: Cocoa provides one on the main thread of an application
;;;; running an event loop, and nowhere else, so without one every autoreleased
;;;; object leaks and Foundation logs about it.

(in-package #:objc/test)

(def-suite threads :in all-tests
  :description "Message sends from threads other than the main one.")

(in-suite threads)

(test a-send-from-a-secondary-thread-works
  (with-runtime
    (let ((result nil))
      (bt:join-thread
       (bt:make-thread
        (lambda ()
          (objc:with-autorelease-pool ()
            (setf result (objc:invoke
                          (objc:invoke "NSString" "stringWithUTF8String:" "threaded")
                          "length"))))))
      (is (= 8 result)))))

(test the-trampoline-caches-are-shared-across-threads
  "The caches are plain hash tables read on every send, so a second thread must
find what the first compiled rather than racing to rebuild it."
  (with-runtime
    (objc:invoke (objc:invoke "NSString" "stringWithUTF8String:" "warm") "length")
    (let ((count (hash-table-count objc::*trampoline-by-method*))
          (result nil))
      (bt:join-thread
       (bt:make-thread
        (lambda ()
          (objc:with-autorelease-pool ()
            (setf result (objc:invoke
                          (objc:invoke "NSString" "stringWithUTF8String:" "again")
                          "length"))))))
      (is (= 5 result))
      (is (= count (hash-table-count objc::*trampoline-by-method*))))))

(test a-lisp-defined-class-can-be-messaged-from-another-thread
  (with-runtime
    (let ((result nil))
      (bt:join-thread
       (bt:make-thread
        (lambda ()
          (objc:with-autorelease-pool ()
            (setf result (objc:invoke (objc:alloc-init-object "MyObject")
                                      "areaOfWidth:height:" 6 7))))))
      (is (= 42 result)))))

(test the-appkit-entry-points-refuse-to-run-off-the-main-thread
  "AppKit requires thread 1 and does not check; the observed failure is a
deadlock or a half-drawn window rather than an error, so this checks instead."
  (with-runtime
    (let ((condition nil))
      (bt:join-thread
       (bt:make-thread
        (lambda ()
          (setf condition
                (handler-case (progn (objc.runloop:check-main-thread "test") nil)
                  (error (e) e))))))
      (is (typep condition 'error)))))
