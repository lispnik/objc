;;;; examples/scene-view.lisp -- the 3D scene, animated in a window.
;;;;
;;;; scene-kit.lisp renders a scene to a PNG with no window.  This is the same
;;;; kind of scene in an SCNView in an NSWindow, moving.  Two ways:
;;;;
;;;;   ANIMATE-SCENE-VIEW turns the orbit from Lisp, one transform per frame,
;;;;   with the run loop pumped between frames the way ANIMATE-CANVAS does, so
;;;;   every frame SceneKit draws was placed by a form here.
;;;;
;;;;   RUN-SCENE-VIEW hands SceneKit an SCNAction and waits for the window to
;;;;   close.  SceneKit animates on its own thread; Lisp idles in AppKit's
;;;;   modal loop at no CPU.
;;;;
;;;; The per-frame placement is a float4x4 composed in Lisp and set whole
;;;; through setSimdTransform: where the build carries one (see the simd half
;;;; of scene-kit.lisp), and an Euler angle through an SCNVector3 where it does
;;;; not, so the example runs on every build the library does.

(in-package #:objc/examples)

(defvar *scene-window* nil "The window the last MAKE-SCENE-WINDOW made.")
(defvar *scene-view* nil "Its SCNView.")
(defvar *scene-orbit* nil "The node whose rotation carries the satellites.")

(defun coloured-node (geometry r g b)
  "A node showing GEOMETRY with an (r g b) diffuse colour."
  (let ((node (objc:invoke "SCNNode" "nodeWithGeometry:" geometry)))
    (objc:invoke (objc:invoke (objc:invoke geometry "firstMaterial") "diffuse")
                 "setContents:"
                 (objc:invoke "NSColor" "colorWithRed:green:blue:alpha:"
                              (float r 1d0) (float g 1d0) (float b 1d0) 1d0))
    node))

(defun orbit-scene ()
  "The solar arrangement of scene-kit.lisp with its satellites under one
orbit node, so that turning one node moves them all.  Returns (VALUES SCENE
ORBIT SUN)."
  (let* ((scene (make-scene))
         (root (objc:invoke scene "rootNode"))
         (orbit (objc:invoke "SCNNode" "node"))
         (sun (coloured-node (objc:invoke "SCNSphere" "sphereWithRadius:" 1.6d0)
                             0.95 0.75 0.2)))
    (set-euler-angles (add-camera scene :position '(0 3.5 10)) -0.33 0 0)
    (add-light scene :position '(6 8 8))
    (add-light scene :type "ambient" :position '(0 0 0))
    (objc:invoke root "addChildNode:" sun)
    (loop for i below 5
          for angle = (* i (/ (* 2 pi) 5))
          do (let ((node (coloured-node
                          (objc:invoke "SCNBox" "boxWithWidth:height:length:chamferRadius:"
                                       0.7d0 0.7d0 0.7d0 0.08d0)
                          (+ 0.3 (* 0.14 i)) 0.4 (- 0.9 (* 0.12 i)))))
               (set-position node (* 4 (cos angle)) 0 (* 4 (sin angle)))
               (set-euler-angles node 0 angle (* 0.4 i))
               (objc:invoke orbit "addChildNode:" node)))
    (objc:invoke root "addChildNode:" orbit)
    (let ((ring (coloured-node (objc:invoke "SCNTorus" "torusWithRingRadius:pipeRadius:" 4.0d0 0.06d0)
                               0.6 0.6 0.7)))
      (set-euler-angles ring (/ pi 2) 0 0)
      (objc:invoke root "addChildNode:" ring))
    (values scene orbit sun)))

(defun turn-orbit (orbit angle)
  "Set ORBIT's rotation about y to ANGLE: a matrix set whole where the build
carries a float4x4, an Euler angle through a struct where it does not."
  (if (simd-available-p)
      (objc:invoke orbit "setSimdTransform:" (matrix-rotation-y angle))
      (set-euler-angles orbit 0 angle 0)))

(defun make-scene-window (&key (title "Lisp SceneKit") (rect #(200 200 640 480)))
  "A window whose content view is an SCNView showing ORBIT-SCENE.
Returns (VALUES WINDOW VIEW ORBIT).  Drag in the view to move the camera:
that is SceneKit's own camera control, switched on, not anything here."
  (ensure-scene-kit)
  (multiple-value-bind (scene orbit) (orbit-scene)
    (let* ((window (make-window :title title :rect rect))
           (view (make-view "SCNView" (vector 0 0 (aref rect 2) (aref rect 3)))))
      (objc:invoke view "setScene:" scene)
      (objc:invoke view "setBackgroundColor:"
                   (objc:invoke "NSColor" "colorWithRed:green:blue:alpha:" 0.06d0 0.06d0 0.09d0 1d0))
      (objc:invoke view "setAllowsCameraControl:" t)
      (objc:invoke view "setAutoresizingMask:" 18) ; width and height follow the window
      (objc:invoke window "setContentView:" view)
      (setf *scene-window* window *scene-view* view *scene-orbit* orbit)
      (values window view orbit))))

(defun animate-scene-view (&key (seconds 12d0) (fps 60) (turns-per-second 0.12d0))
  "Open the window and turn the orbit from Lisp for SECONDS: one transform a
frame, the run loop pumped between frames so SceneKit draws each one.

Blocks the REPL for the duration, as ANIMATE-CANVAS does: AppKit runs on this
thread.  Returns the window, still open, and the number of frames placed."
  (multiple-value-bind (window view orbit) (make-scene-window)
    (declare (ignore view))
    (show-window window)
    (let ((frame (/ 1d0 fps))
          (start (get-internal-real-time))
          (frames 0))
      (loop for elapsed = (/ (- (get-internal-real-time) start)
                             internal-time-units-per-second)
            while (< elapsed seconds)
            do (turn-orbit orbit (* 2 pi turns-per-second elapsed))
               (incf frames)
               (objc.runloop:pump-events :seconds frame :max-seconds frame
                                         :until (constantly nil)))
      (objc.runloop:restore-frontmost)
      (values window frames))))

(defun run-scene-view ()
  "Open the window with SceneKit turning the orbit itself, an SCNAction
repeated forever, and block until the window is closed.  Lisp does nothing
per frame; AppKit's modal loop idles.  Returns the window."
  (multiple-value-bind (window view orbit) (make-scene-window)
    (objc:invoke orbit "runAction:"
                 (objc:invoke "SCNAction" "repeatActionForever:"
                              (objc:invoke "SCNAction" "rotateByX:y:z:duration:"
                                           0d0 (* 2 pi) 0d0 8d0)))
    (objc:invoke view "setPlaying:" t)
    (show-window window)
    (run-until-closed window)
    (objc.runloop:restore-frontmost)
    window))

(defun snapshot-scene-view (view &optional path)
  "The frame VIEW is showing, as PNG bytes -- SCNView's own -snapshot -- and
written to PATH when one is given."
  (let ((bytes (ns-image-to-png (objc:invoke view "snapshot"))))
    (when path
      (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                                :if-exists :supersede)
        (write-sequence bytes out)))
    bytes))

(defun test-scene-view ()
  "Open the window, place twenty frames from Lisp, and report a plist:
:VISIBLE, :FRAMES, :ANIMATES (the view's first and last snapshots differ),
:PNG (a snapshot came out).  Closes the window."
  (ensure-scene-kit)
  (multiple-value-bind (window view orbit) (make-scene-window :rect #(200 200 480 360))
    (unwind-protect
         (progn
           (show-window window :seconds 0.3d0)
           (let ((before (snapshot-scene-view view))
                 (frames 0))
             (dotimes (i 20)
               (turn-orbit orbit (* i 0.15))
               (incf frames)
               (objc.runloop:pump-events :seconds (/ 1d0 30) :max-seconds (/ 1d0 30)
                                         :until (constantly nil)))
             (let ((after (snapshot-scene-view view)))
               (list :visible (objc:invoke-bool window "isVisible")
                     :frames frames
                     :animates (not (equalp before after))
                     :png (plusp (length after))))))
      (objc:invoke window "close")
      (objc.runloop:restore-frontmost))))

(defun report-scene-view (&optional (path "/tmp/objc-scene-view.png"))
  "Animate for two seconds, write the frame the view ends on to PATH, close."
  (multiple-value-bind (window frames) (animate-scene-view :seconds 2d0)
    (snapshot-scene-view *scene-view* path)
    (objc:invoke window "close")
    (format t "~&~d frames placed from Lisp; the last one written to ~a~%" frames path)
    path))
