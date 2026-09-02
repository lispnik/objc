;;;; src/cocoa.lisp -- the COCOA package.

(in-package #:cocoa)

;;; Structure types ----------------------------------------------------------
;;;
;;; NS-POINT, NS-SIZE, NS-RECT and NS-RANGE are type descriptor symbols; their
;;; encodings and layouts are registered in src/types.lisp.
;;;
;;; The manual's reference pages say ns-point and ns-size have :FLOAT slots and
;;; ns-range has (:UNSIGNED :INT) slots.  That is stale 32-bit text.  Measured
;;; in LispWorks 8.1 on Apple silicon: ns-point 16 bytes, ns-size 16, ns-rect
;;; 32, ns-range 16 -- doubles and 64-bit integers.  We follow the
;;; implementation, and so does LispWorks; only its documentation does not.

(setf (documentation 'ns-point 'type)
      "The Foundation NSPoint type.  Converts to and from #(x y).")
(setf (documentation 'ns-size 'type)
      "The Foundation NSSize type.  Converts to and from #(width height).")
(setf (documentation 'ns-rect 'type)
      "The Foundation NSRect type.  Converts to and from #(x y width height).")
(setf (documentation 'ns-range 'type)
      "The Foundation NSRange type.  Converts to and from the CONS
(location . length) -- a cons, not a vector, unlike the other three.")

;;; Setters ------------------------------------------------------------------

(defun set-ns-point* (point x y)
  "Set the slots of the foreign NSPoint at POINT and return POINT."
  (setf (cffi:mem-aref point :double 0) (coerce x 'double-float)
        (cffi:mem-aref point :double 1) (coerce y 'double-float))
  point)

(defun set-ns-size* (size width height)
  "Set the slots of the foreign NSSize at SIZE and return SIZE."
  (setf (cffi:mem-aref size :double 0) (coerce width 'double-float)
        (cffi:mem-aref size :double 1) (coerce height 'double-float))
  size)

(defun set-ns-rect* (rect x y width height)
  "Set the slots of the foreign NSRect at RECT and return RECT."
  (setf (cffi:mem-aref rect :double 0) (coerce x 'double-float)
        (cffi:mem-aref rect :double 1) (coerce y 'double-float)
        (cffi:mem-aref rect :double 2) (coerce width 'double-float)
        (cffi:mem-aref rect :double 3) (coerce height 'double-float))
  rect)

(defun set-ns-range* (range location length)
  "Set the slots of the foreign NSRange at RANGE and return RANGE."
  (check-type location (integer 0))
  (check-type length (integer 0))
  (setf (cffi:mem-aref range :uint64 0) location
        (cffi:mem-aref range :uint64 1) length)
  range)

;;; Constants ----------------------------------------------------------------

(defconstant ns-not-found (1- (expt 2 63))
  "The Foundation NSNotFound constant, which is NSIntegerMax.")

;;; Notifications ------------------------------------------------------------

(defun default-notification-center ()
  (objc:invoke "NSNotificationCenter" "defaultCenter"))

(defun add-observer (target selector &key name object center)
  "Add TARGET as an observer for SELECTOR with the given NAME and OBJECT.
CENTER defaults to the default notification center."
  (objc:invoke (or center (default-notification-center))
               "addObserver:selector:name:object:"
               target
               (objc:coerce-to-selector selector)
               (or name (cffi:null-pointer))
               (or object (cffi:null-pointer))))

(defun remove-observer (target &key name object center)
  "Remove TARGET as an observer for NAME and OBJECT.
CENTER defaults to the default notification center."
  (objc:invoke (or center (default-notification-center))
               "removeObserver:name:object:"
               target
               (or name (cffi:null-pointer))
               (or object (cffi:null-pointer))))
