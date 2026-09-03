;;;; Same idea, but instrumented: how many distinct threads actually ran the
;;;; work, and are they inside Lisp at the same time?  A reproducer that does
;;;; not reproduce is worse than none, so measure before claiming.

(in-package :cl-user)

(defvar *iterations* 64)
(defvar *threads* (make-hash-table :test 'eq :synchronized t))
(defvar *concurrent* (make-array 1 :element-type 'fixnum :initial-element 0))
(defvar *peak* (make-array 1 :element-type 'fixnum :initial-element 0))
(defvar *lock* (sb-thread:make-mutex))

(sb-alien:define-alien-callable work sb-alien:void
    ((context (sb-alien:* t)) (index sb-alien:unsigned-long))
  (declare (ignore context index))
  (sb-thread:with-mutex (*lock*)
    (setf (gethash sb-thread:*current-thread* *threads*) t)
    (incf (aref *concurrent* 0))
    (when (> (aref *concurrent* 0) (aref *peak* 0))
      (setf (aref *peak* 0) (aref *concurrent* 0))))
  ;; Allocate a lot, outside the lock, so several threads are in Lisp at once.
  (let ((acc '()))
    (dotimes (i 200000) (push (list i) acc))
    (length acc))
  (sb-thread:with-mutex (*lock*) (decf (aref *concurrent* 0))))

(defun global-queue ()
  (sb-alien:alien-funcall
   (sb-alien:extern-alien "dispatch_get_global_queue"
                          (function sb-alien:system-area-pointer
                                    sb-alien:long sb-alien:unsigned-long))
   0 0))

(format t "~&SBCL ~A, safepoint: ~A~%" (lisp-implementation-version)
        (and (member :sb-safepoint *features*) t))
(finish-output)

(sb-alien:alien-funcall
 (sb-alien:extern-alien "dispatch_apply_f"
                        (function sb-alien:void
                                  sb-alien:unsigned-long
                                  sb-alien:system-area-pointer
                                  sb-alien:system-area-pointer
                                  sb-alien:system-area-pointer))
 *iterations* (global-queue) (sb-sys:int-sap 0)
 (sb-alien:alien-sap (sb-alien:alien-callable-function 'work)))

(format t "SURVIVED: ~D distinct threads ran the work, peak ~D inside Lisp at once~%"
        (hash-table-count *threads*) (aref *peak* 0))
(finish-output)
