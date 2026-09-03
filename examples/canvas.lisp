;;;; examples/canvas.lisp -- a native NSView you draw into from Lisp, live.
;;;;
;;;; Every other example here is a port: the point of them is that LispWorks
;;;; source runs unchanged.  This one is not in the manual, because it is the
;;;; thing the manual's interface is FOR.  It defines a real NSView subclass
;;;; whose -drawRect: calls a Lisp function you can redefine at the REPL while
;;;; the window is open; the next repaint runs the new definition.  That live
;;;; loop -- a native macOS view sculpted from a running Lisp, with the debugger
;;;; behind it -- is what an Objective-C bridge buys a Lisp that a compiled
;;;; toolchain cannot.
;;;;
;;;; It also leans on the hardest thing the library does.  -drawRect: receives
;;;; its dirty rectangle as an NSRect passed BY VALUE, and the drawing below
;;;; passes NSRect and NSPoint by value to NSBezierPath and NSColor on every
;;;; shape.  Struct-by-value in both directions is exactly what src/abi.lisp was
;;;; written for; a paint loop is where it earns its keep.

(in-package #:objc/examples)

;;; The view ------------------------------------------------------------------

(objc:define-objc-class canvas-view ()
  ()
  (:objc-class-name "LispCanvasView")
  (:objc-superclass-name "NSView"))

;; Flip the coordinate system so (0,0) is the top-left corner and y grows
;; downward.  NSView is bottom-up by default; every drawing routine below, and
;; almost everyone's intuition, assumes top-down.  A Lisp method returning a
;; BOOL, called by AppKit during layout, decides it.
(objc:define-objc-method ("isFlipped" objc:objc-bool)
    ((self canvas-view))
  t)

(defvar *canvas-draw* 'draw-default
  "The function -drawRect: calls, of (WIDTH HEIGHT) in the view's own units.

Redefine the named function, or SETF this to a fresh closure, and the next
repaint (see REFRESH) runs it.  This indirection is the whole example: the
compiled -drawRect: never changes, but what it does is ordinary Lisp you edit
live.")

(defvar *canvas* nil
  "The view currently being drawn, bound for the extent of -drawRect:.
A draw function that wants the NSView itself -- its size, a subview -- reads it
here rather than taking another argument.")

(objc:define-objc-method ("drawRect:" :void)
    ((self canvas-view) (dirty cocoa:ns-rect))
  ;; DIRTY arrives as #(x y width height): the struct came in by value and the
  ;; bridge converted it.  We repaint the whole bounds and let AppKit's clip do
  ;; the rest, so the dirty rectangle itself is only proof the value crossed.
  (declare (ignore dirty))
  (let* ((*canvas* self)
         (bounds (objc:invoke self "bounds")))     ; another NSRect, as #(x y w h)
    (handler-case
        (funcall *canvas-draw* (aref bounds 2) (aref bounds 3))
      ;; A Lisp condition must never unwind into the AppKit frame that called
      ;; us -- it would tear through Objective-C stack it cannot restart.  Catch
      ;; it, flash the view so the trouble is visible, and print it for the REPL.
      (error (condition) (draw-error condition)))))

;;; Drawing primitives --------------------------------------------------------
;;;
;;; Thin wrappers over AppKit's own drawing, so a draw function reads like one.
;;; They are valid only inside a draw function -- that is, during -drawRect: --
;;; because they paint into the current NSGraphicsContext, which AppKit only
;;; makes current for the duration of that call.

(declaim (inline df))
(defun df (x) (coerce x 'double-float))

(defun set-color (red green blue &optional (alpha 1))
  "Make (RED GREEN BLUE ALPHA), each 0..1, the current colour for fills and
strokes.  -[NSColor set] sets both."
  (objc:invoke (objc:invoke "NSColor" "colorWithCalibratedRed:green:blue:alpha:"
                            (df red) (df green) (df blue) (df alpha))
               "set")
  (values))

(defun fill-rect (x y width height)
  "Fill the rectangle in the current colour."
  (objc:invoke (objc:invoke "NSBezierPath" "bezierPathWithRect:"
                            (vector (df x) (df y) (df width) (df height)))
               "fill")
  (values))

(defun fill-oval (x y width height)
  "Fill the ellipse inscribed in the rectangle."
  (objc:invoke (objc:invoke "NSBezierPath" "bezierPathWithOvalInRect:"
                            (vector (df x) (df y) (df width) (df height)))
               "fill")
  (values))

(defun stroke-oval (x y width height &optional (line-width 1))
  "Outline the ellipse inscribed in the rectangle."
  (let ((path (objc:invoke "NSBezierPath" "bezierPathWithOvalInRect:"
                           (vector (df x) (df y) (df width) (df height)))))
    (objc:invoke path "setLineWidth:" (df line-width))
    (objc:invoke path "stroke"))
  (values))

(defun draw-line (x1 y1 x2 y2 &optional (line-width 1))
  "Stroke a line from (X1,Y1) to (X2,Y2).  Both endpoints are NSPoints passed
by value to NSBezierPath."
  (let ((path (objc:invoke "NSBezierPath" "bezierPath")))
    (objc:invoke path "setLineWidth:" (df line-width))
    (objc:invoke path "moveToPoint:" (vector (df x1) (df y1)))
    (objc:invoke path "lineToPoint:" (vector (df x2) (df y2)))
    (objc:invoke path "stroke"))
  (values))

;;; Default and demo drawings -------------------------------------------------

(defun draw-default (width height)
  "The scene the window opens on: a dark ground and a stack of rings, so there
is something to see before you have written a line, and something to replace."
  (set-color 0.09 0.10 0.13)
  (fill-rect 0 0 width height)
  (let ((cx (/ width 2)) (cy (/ height 2))
        (step (/ (min width height) 18.0)))
    (loop for i from 8 downto 1
          for r = (* i step)
          do (set-color (/ i 8.0) 0.45 (- 1.0 (/ i 8.0)) 0.9)
             (fill-oval (- cx r) (- cy r) (* 2 r) (* 2 r))))
  (set-color 0.95 0.85 0.35)
  (draw-line 0 (/ height 2) width (/ height 2) 1)
  (draw-line (/ width 2) 0 (/ width 2) height 1))

(defun draw-clock (width height)
  "A draw function of the clock: a hand sweeping once every twelve seconds.
Because it reads the time itself, repainting it -- see ANIMATE-CANVAS -- shows a
new frame each pass."
  (set-color 0.10 0.11 0.14)
  (fill-rect 0 0 width height)
  (let* ((cx (/ width 2)) (cy (/ height 2))
         (radius (* 0.42 (min width height)))
         (seconds (/ (get-internal-real-time) internal-time-units-per-second))
         (angle (* 2 pi (/ (mod seconds 12d0) 12d0))))
    (set-color 0.16 0.17 0.22)
    (fill-oval (- cx radius) (- cy radius) (* 2 radius) (* 2 radius))
    (set-color 0.30 0.33 0.42)
    (stroke-oval (- cx radius) (- cy radius) (* 2 radius) (* 2 radius) 2)
    (set-color 0.95 0.72 0.20)
    (draw-line cx cy
               (+ cx (* radius (sin angle)))
               (- cy (* radius (cos angle)))
               4)))

(defun draw-error (condition)
  "Make a drawing error visible instead of silent: a red wash, and the message
to *ERROR-OUTPUT* for the REPL."
  (ignore-errors
   (set-color 0.45 0.06 0.06)
   (fill-rect 0 0 100000 100000))          ; oversized; the view clips it
  (format *error-output* "~&[canvas] draw error: ~A~%" condition)
  (finish-output *error-output*))

;;; Building, showing, and the live loop --------------------------------------

(defvar *current-canvas* nil
  "The most recently built canvas view, so REFRESH needs no argument.")

(defun make-canvas (&key (title "Lisp Canvas") (rect #(200 200 480 480)))
  "Build a window with a canvas view filling it.  Returns (VALUES WINDOW VIEW)."
  (let* ((window (make-window :title title :rect rect))
         (view (make-view "LispCanvasView"
                          (vector 0 0 (aref rect 2) (aref rect 3)))))
    (add-subview window view)
    (setf *current-canvas* view)
    (values window view)))

(defun refresh (&optional (view *current-canvas*))
  "Repaint VIEW now: mark it dirty and pump the run loop briefly so -drawRect:
has run before this returns.  The REPL half of the live loop -- redefine your
draw function, then (refresh)."
  (when view
    (objc:invoke view "setNeedsDisplay:" t)
    (objc.runloop:pump-events :seconds 0.02d0 :max-seconds 0.2d0
                              :until (constantly nil)))
  view)

(defun test-canvas ()
  "Show the canvas with the current *CANVAS-DRAW*.  Returns (VALUES WINDOW VIEW).

The window comes first, so RUN-UNTIL-CLOSED wraps straight around the call --
the same shape as every other demo here.  Keep the values: SETF *CANVAS-DRAW*
(or redefine DRAW-DEFAULT) and (REFRESH) to redraw."
  (objc:ensure-objc-initialized)
  (multiple-value-bind (window view) (make-canvas)
    (show-window window)
    (values window view)))

(defun run-canvas ()
  "Show the canvas and stay in AppKit's event loop until the window is closed.
Self-contained -- no REPL interaction -- so it is the one to reach for when you
just want to see it.  Returns T."
  (multiple-value-bind (window view) (test-canvas)
    (declare (ignore view))
    (run-until-closed window)))

(defun animate-canvas (&key (seconds 12d0) (draw 'draw-clock) (fps 30))
  "Show the canvas and animate DRAW for SECONDS, repainting FPS times a second.

This blocks the REPL for the duration: AppKit runs on this thread, so the
animation and the listener cannot both have it.  The binding of *CANVAS-DRAW*
is seen by -drawRect: because the repaint happens, synchronously, inside this
call.  Close the window early to stop, or wait it out."
  (objc:ensure-objc-initialized)
  (multiple-value-bind (window view) (make-canvas)
    (show-window window)
    (let ((*canvas-draw* draw)
          (frame (/ 1.0d0 fps))
          (end (+ (get-internal-real-time)
                  (* seconds internal-time-units-per-second))))
      (loop while (< (get-internal-real-time) end)
            do (objc:invoke view "setNeedsDisplay:" t)
               (objc.runloop:pump-events :seconds frame :max-seconds frame
                                         :until (constantly nil))))
    ;; Hand the keyboard back: showing a window made this the frontmost app.
    (objc.runloop:restore-frontmost)
    window))
