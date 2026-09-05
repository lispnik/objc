;;;; examples/geometry.lisp -- the COCOA package's four structure types.
;;;;
;;;; NS-POINT, NS-SIZE, NS-RECT and NS-RANGE, and the four SET-NS-*` writers
;;;; that fill one in foreign memory.  Six of the eleven symbols COCOA exports
;;;; are here, and none of them had an example: canvas.lisp names NS-RECT as a
;;;; method argument type and that was the whole of the coverage.
;;;;
;;;; A structure crosses in one of two shapes and it is worth knowing which:
;;;;
;;;;   AS A LISP VALUE.  #(x y), #(width height), #(x y width height) -- and
;;;;   NS-RANGE as a CONS, (location . length), not a vector.  That asymmetry is
;;;;   the manual's, not ours, and it catches people: a range written #(5 7)
;;;;   is not a range.
;;;;
;;;;   AS A POINTER to memory you filled.  That is what SET-NS-RECT* and its
;;;;   siblings are for, and a filled buffer is accepted anywhere the vector is.
;;;;   Measured both directions: fill with SET-NS-RECT*, pass it as an argument,
;;;;   read the result back into another buffer with INVOKE-INTO.
;;;;
;;;; A VECTOR OF THE WRONG LENGTH IS NOT CHECKED, and the two errors are not
;;;; symmetric.  Too few components signals from inside the conversion --
;;;; INDEX-TOO-LARGE-ERROR, naming an index rather than the call you got wrong.
;;;; Too many are SILENTLY DROPPED: pass #(1 2 3 4 5) where an NSSize is wanted
;;;; and Cocoa is handed (1 2) with no complaint from anyone.
;;;;
;;;; FOUNDATION'S OWN GEOMETRY FUNCTIONS ARE OUT OF REACH, and this is the one
;;;; place in the library where that bites.  NSUnionRect, NSIntersectionRect and
;;;; NSPointInRect are plain C functions taking structures BY VALUE, not
;;;; messages -- so there is no encoding to read and no trampoline to build.
;;;; CFFI cannot express the call without libffi: measured, the attempt signals
;;;; COMPILED-PROGRAM-ERROR at the call site.  Anything reachable by MESSAGE is
;;;; fine, which is why the boxing route below works; the arithmetic is done in
;;;; Lisp because there is no alternative, not because it is tidier.

(in-package #:objc/examples)

;;; Boxing, which is the message-based route -----------------------------------------
;;;
;;; NSValue is how Cocoa itself carries geometry through anything that wants an
;;; object -- an array, a dictionary, a notification's userInfo.  It is also the
;;; cleanest proof that a conversion is right in both directions, because the
;;; value goes into Foundation as a structure and comes back out as one.

(defun box-point (x y)
  "An NSValue holding the point (X, Y)."
  (objc:ensure-objc-initialized)
  (objc:invoke "NSValue" "valueWithPoint:" (vector x y)))

(defun box-size (width height)
  "An NSValue holding the size WIDTH by HEIGHT."
  (objc:ensure-objc-initialized)
  (objc:invoke "NSValue" "valueWithSize:" (vector width height)))

(defun box-rect (x y width height)
  "An NSValue holding the rectangle (X, Y, WIDTH, HEIGHT)."
  (objc:ensure-objc-initialized)
  (objc:invoke "NSValue" "valueWithRect:" (vector x y width height)))

(defun box-range (location length)
  "An NSValue holding the range (LOCATION . LENGTH).

A CONS, because that is what the manual says an NS-RANGE converts to and from.
The other three are vectors; this one is not, and passing #(5 7) here gets you
something that is not a range."
  (objc:ensure-objc-initialized)
  (objc:invoke "NSValue" "valueWithRange:" (cons location length)))

(defun unbox (value kind)
  "The structure inside an NSValue.  KIND is :POINT, :SIZE, :RECT or :RANGE.

    (unbox (box-rect 1 2 3 4) :rect)   => #(1.0d0 2.0d0 3.0d0 4.0d0)
    (unbox (box-range 5 7) :range)     => (5 . 7)"
  (objc:invoke value (ecase kind
                       (:point "pointValue")
                       (:size "sizeValue")
                       (:rect "rectValue")
                       (:range "rangeValue"))))

;;; The pointer route, which is what the SET-NS-* writers are for -----------------------

(defmacro with-ns-point ((var x y) &body body)
  "Bind VAR to a foreign NSPoint holding (X, Y) for the extent of BODY."
  `(cffi:with-foreign-object (,var :double 2)
     (cocoa:set-ns-point* ,var ,x ,y)
     (locally ,@body)))

(defmacro with-ns-size ((var width height) &body body)
  "Bind VAR to a foreign NSSize holding WIDTH by HEIGHT for the extent of BODY."
  `(cffi:with-foreign-object (,var :double 2)
     (cocoa:set-ns-size* ,var ,width ,height)
     (locally ,@body)))

(defmacro with-ns-rect ((var x y width height) &body body)
  "Bind VAR to a foreign NSRect for the extent of BODY.

    (with-ns-rect (r 0 0 320 200)
      (objc:invoke \"NSValue\" \"valueWithRect:\" r))

The buffer is accepted anywhere the #(x y width height) vector is -- INVOKE
takes a pointer to a filled structure as readily as it takes the Lisp value.
Which you want depends on where the numbers are coming from: a vector if you are
writing them, a buffer if something else already filled one."
  `(cffi:with-foreign-object (,var :double 4)
     (cocoa:set-ns-rect* ,var ,x ,y ,width ,height)
     (locally ,@body)))

(defmacro with-ns-range ((var location length) &body body)
  "Bind VAR to a foreign NSRange for the extent of BODY.

Two unsigned 64-bit integers, not doubles -- the manual's reference page says
(:UNSIGNED :INT), which is stale 32-bit text; see the note in src/cocoa.lisp."
  `(cffi:with-foreign-object (,var :uint64 2)
     (cocoa:set-ns-range* ,var ,location ,length)
     (locally ,@body)))

(defun rect-buffer-values (rect)
  "The four doubles in the foreign NSRect at RECT, as a list."
  (loop for i below 4 collect (cffi:mem-aref rect :double i)))

(defun range-buffer-values (range)
  "The (location . length) in the foreign NSRange at RANGE."
  (cons (cffi:mem-aref range :uint64 0) (cffi:mem-aref range :uint64 1)))

;;; The types as method types -----------------------------------------------------------
;;;
;;; The other place the descriptors appear: a Lisp method that takes and returns
;;; structures by value, which is the whole reason this library is built on
;;; sb-alien rather than CFFI.

(objc:define-objc-class placement ()
  ()
  (:objc-class-name "LispGeometryPlacement"))

(objc:define-objc-method ("sizeForOrigin:" cocoa:ns-size)
    ((self placement) (origin cocoa:ns-point))
  (vector (* 2 (aref origin 0)) (* 3 (aref origin 1))))

(objc:define-objc-method ("boundsFor:" cocoa:ns-rect)
    ((self placement) (size cocoa:ns-size))
  (vector 0 0 (aref size 0) (aref size 1)))

(defun make-placement ()
  "An object whose methods take and return geometry by value."
  (objc:ensure-objc-initialized)
  (make-instance 'placement))

;;; Arithmetic, in Lisp because Foundation's is unreachable ------------------------------

(defun union-rect (a b)
  "The smallest rectangle containing A and B, both #(x y width height).

NSUnionRect would do this, and cannot be called; see the header.  Written out
rather than hidden behind a helper because the point is that this is the part
you have to supply yourself."
  (let* ((left (min (aref a 0) (aref b 0)))
         (bottom (min (aref a 1) (aref b 1)))
         (right (max (+ (aref a 0) (aref a 2)) (+ (aref b 0) (aref b 2))))
         (top (max (+ (aref a 1) (aref a 3)) (+ (aref b 1) (aref b 3)))))
    (vector left bottom (- right left) (- top bottom))))

(defun point-in-rect-p (point rect)
  "Whether POINT #(x y) falls inside RECT #(x y width height)."
  (and (<= (aref rect 0) (aref point 0) (+ (aref rect 0) (aref rect 2)))
       (<= (aref rect 1) (aref point 1) (+ (aref rect 1) (aref rect 3)))))

;;; A worked example -------------------------------------------------------------------------

(defun test-geometry ()
  "Round-trip all four types, by value and through a foreign buffer.

    (objc/examples:test-geometry)
    => (:POINT #(3.0d0 4.0d0) :SIZE #(10.0d0 20.0d0)
        :RECT #(1.0d0 2.0d0 3.0d0 4.0d0) :RANGE (5 . 7)
        :FILLED-BUFFER (1.0d0 2.0d0 3.0d0 4.0d0)
        :BUFFER-AS-ARGUMENT #(1.0d0 2.0d0 3.0d0 4.0d0)
        :INTO-BUFFER (9.0d0 8.0d0 7.0d0 6.0d0) :RANGE-BUFFER (5 . 7)
        :METHOD-SIZE #(10.0d0 18.0d0) :METHOD-BOUNDS #(0.0d0 0.0d0 10.0d0 20.0d0)
        :LONG-VECTOR-TRUNCATED T :UNION #(0 0 30 30))

:BUFFER-AS-ARGUMENT is the one worth having.  It fills an NSRect with
SET-NS-RECT*, hands the POINTER to a method that wants a structure by value, and
gets the same four numbers back -- which is the only thing that makes those four
writers useful rather than decorative.

:LONG-VECTOR-TRUNCATED is the trap: #(1 2 3 4 5) where an NSSize is expected is
accepted, and the last three components are dropped in silence."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (let ((placement (make-placement)))
      (with-ns-rect (rect 1 2 3 4)
        (cffi:with-foreign-object (out :double 4)
          (objc:invoke-into out (box-rect 9 8 7 6) "rectValue")
          (with-ns-range (range 5 7)
            (list :point (unbox (box-point 3 4) :point)
                  :size (unbox (box-size 10 20) :size)
                  :rect (unbox (box-rect 1 2 3 4) :rect)
                  :range (unbox (box-range 5 7) :range)
                  :filled-buffer (rect-buffer-values rect)
                  :buffer-as-argument (unbox (objc:invoke "NSValue" "valueWithRect:" rect)
                                             :rect)
                  :into-buffer (rect-buffer-values out)
                  :range-buffer (range-buffer-values range)
                  :method-size (objc:invoke placement "sizeForOrigin:" #(5 6))
                  :method-bounds (objc:invoke placement "boundsFor:" #(10 20))
                  :long-vector-truncated
                  (equalp #(0d0 0d0 1d0 2d0)
                          (objc:invoke placement "boundsFor:" #(1 2 3 4 5)))
                  :union (union-rect #(0 0 10 10) #(20 20 10 10)))))))))

(defun report-geometry ()
  "Print each type going out and coming back."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (format t "~&boxed and unboxed:~%")
    (dolist (entry (list (list "NSPoint" (box-point 3 4) :point)
                         (list "NSSize" (box-size 10 20) :size)
                         (list "NSRect" (box-rect 1 2 3 4) :rect)
                         (list "NSRange" (box-range 5 7) :range)))
      (format t "  ~8A ~S~%" (first entry) (unbox (second entry) (third entry))))
    (with-ns-rect (rect 0 0 320 200)
      (format t "~&a buffer filled by SET-NS-RECT*: ~S~%" (rect-buffer-values rect))
      (format t "passed as an argument, read back:  ~S~%"
              (unbox (objc:invoke "NSValue" "valueWithRect:" rect) :rect)))
    (let ((placement (make-placement)))
      (format t "~&a Lisp method taking NS-POINT, returning NS-SIZE: ~S~%"
              (objc:invoke placement "sizeForOrigin:" #(5 6)))
      (format t "the same method given one component too many:      ~S~%"
              (objc:invoke placement "boundsFor:" #(1 2 3 4 5))))))
