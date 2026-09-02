;;;; test/cocoa-tests.lisp -- the COCOA package.

(in-package #:objc/test)

(def-suite cocoa :in all-tests
  :description "The COCOA package: struct setters, constants, notifications.")

(in-suite cocoa)

(test ns-not-found-is-ns-integer-max
  (is (= cocoa:ns-not-found (1- (expt 2 63)))))

(test set-ns-point*
  (cffi:with-foreign-object (point :double 2)
    (is (cffi:pointer-eq point (cocoa:set-ns-point* point 3 4)))
    (is (= 3d0 (cffi:mem-aref point :double 0)))
    (is (= 4d0 (cffi:mem-aref point :double 1)))))

(test set-ns-size*
  (cffi:with-foreign-object (size :double 2)
    (is (cffi:pointer-eq size (cocoa:set-ns-size* size 100 50)))
    (is (= 100d0 (cffi:mem-aref size :double 0)))
    (is (= 50d0 (cffi:mem-aref size :double 1)))))

(test set-ns-rect*
  (cffi:with-foreign-object (rect :double 4)
    (is (cffi:pointer-eq rect (cocoa:set-ns-rect* rect 1 2 3 4)))
    (is (equalp '(1d0 2d0 3d0 4d0)
                (loop for i below 4 collect (cffi:mem-aref rect :double i))))))

(test set-ns-range*
  (cffi:with-foreign-object (range :uint64 2)
    (is (cffi:pointer-eq range (cocoa:set-ns-range* range 6 5)))
    (is (= 6 (cffi:mem-aref range :uint64 0)))
    (is (= 5 (cffi:mem-aref range :uint64 1)))))

(test set-ns-range-rejects-negative-values
  (cffi:with-foreign-object (range :uint64 2)
    (signals error (cocoa:set-ns-range* range -1 5))))

(test a-rect-set-with-set-ns-rect-can-be-passed-to-a-method
  "The setters and the automatic #(x y w h) conversion must agree."
  (with-runtime
    (cffi:with-foreign-object (rect :double 4)
      (cocoa:set-ns-rect* rect 1 2 30 40)
      (let ((value (objc:invoke "NSValue" "valueWithRect:" rect)))
        (is (equalp #(1d0 2d0 30d0 40d0) (objc:invoke value "rectValue")))))))

(test notification-center-round-trip
  (with-runtime
    (let ((center (cocoa::default-notification-center)))
      (is (cffi:pointerp center))
      (is (not (cffi:null-pointer-p center))))))
