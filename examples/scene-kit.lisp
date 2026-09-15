;;;; examples/scene-kit.lisp -- a 3D scene, rendered without a window.
;;;;
;;;; SceneKit is a scene graph: nodes with geometry, cameras and lights, and a
;;;; renderer that turns the lot into pixels.  What makes it worth an example
;;;; here is SCNRenderer, which renders to an image rather than to a view -- so
;;;; a 3D scene described in Lisp forms becomes a PNG, with no window server,
;;;; on a CI runner, in a script.
;;;;
;;;; It shares the Metal device with metal.lisp, because SCNRenderer wants one
;;;; and there is no reason to have two.
;;;;
;;;; The structures are the interesting part of the bridge work.  SCNVector3 is
;;;; three CGFloats -- 24 bytes, passed BY VALUE to -setPosition: and friends --
;;;; and like MTLSize it is not one of the four Cocoa structures with a Lisp
;;;; reading, so it crosses as a pointer to a filled buffer.  Three of those in
;;;; one file makes the pattern clear: the #(x y w h) shorthand is a convenience
;;;; for NSRect, NSPoint, NSSize and NSRange, and everything else is a buffer.
;;;;
;;;; Floating point traps again: SceneKit goes through Metal and CoreGraphics,
;;;; so WITH-METAL from metal.lisp wraps the work here too.

(in-package #:objc/examples)

(defparameter +scene-kit-frameworks+
  '("/System/Library/Frameworks/AppKit.framework/AppKit"
    "/System/Library/Frameworks/SceneKit.framework/SceneKit"))

(defun ensure-scene-kit ()
  (objc:ensure-objc-initialized :modules +scene-kit-frameworks+))

;;; Structures by value ------------------------------------------------------------

(defun scn-vector3 (x y z)
  "An SCNVector3 as a foreign buffer.  Three CGFloats, so three doubles here.

The caller frees it; WITH-VECTOR3 does that for you."
  (let ((buffer (cffi:foreign-alloc :double :count 3)))
    (setf (cffi:mem-aref buffer :double 0) (float x 1d0)
          (cffi:mem-aref buffer :double 1) (float y 1d0)
          (cffi:mem-aref buffer :double 2) (float z 1d0))
    buffer))

(defmacro with-vector3 ((var x y z) &body body)
  `(let ((,var (scn-vector3 ,x ,y ,z)))
     (unwind-protect (locally ,@body)
       (cffi:foreign-free ,var))))

(defun set-position (node x y z)
  (with-vector3 (position x y z)
    (objc:invoke node "setPosition:" position))
  node)

(defun set-euler-angles (node x y z)
  "Rotation about each axis, in radians."
  (with-vector3 (angles x y z)
    (objc:invoke node "setEulerAngles:" angles))
  node)

;;; Building a scene -----------------------------------------------------------------

(defun make-scene ()
  (ensure-scene-kit)
  (objc:invoke "SCNScene" "scene"))

(defun add-geometry (scene geometry &key (position '(0 0 0)) (rotation '(0 0 0))
                                         colour)
  "Put GEOMETRY in SCENE at POSITION, and return its node.

COLOUR is (r g b) in 0..1, applied as the material's diffuse contents."
  (let ((node (objc:invoke "SCNNode" "nodeWithGeometry:" geometry)))
    (when colour
      (destructuring-bind (r g b) colour
        (objc:invoke (objc:invoke (objc:invoke geometry "firstMaterial") "diffuse")
                     "setContents:"
                     (objc:invoke "NSColor" "colorWithRed:green:blue:alpha:"
                                  (float r 1d0) (float g 1d0) (float b 1d0) 1d0))))
    (apply #'set-position node position)
    (apply #'set-euler-angles node rotation)
    (objc:invoke (objc:invoke scene "rootNode") "addChildNode:" node)
    node))

(defun add-camera (scene &key (position '(0 0 6)))
  (let ((node (objc:invoke "SCNNode" "node")))
    (objc:invoke node "setCamera:" (objc:invoke "SCNCamera" "camera"))
    (apply #'set-position node position)
    (objc:invoke (objc:invoke scene "rootNode") "addChildNode:" node)
    node))

(defun add-light (scene &key (type "omni") (position '(4 6 6)))
  "TYPE is \"omni\", \"directional\", \"spot\", \"ambient\" or \"area\"."
  (let ((node (objc:invoke "SCNNode" "node"))
        (light (objc:invoke "SCNLight" "light")))
    (objc:invoke light "setType:" type)
    (objc:invoke node "setLight:" light)
    (apply #'set-position node position)
    (objc:invoke (objc:invoke scene "rootNode") "addChildNode:" node)
    node))

;;; Rendering --------------------------------------------------------------------------

(defun render-scene (scene &key (width 480) (height 360) (time 0) path
                                (antialiasing 2))
  "Render SCENE to PNG bytes, writing them to PATH when given.

No window and no view: SCNRenderer draws into an image.  ANTIALIASING is 0 (off)
through 3 (16x); TIME is the scene time, which is what animates an SCNAction or
a keyframed material."
  (ensure-scene-kit)
  (with-metal
    (objc:with-autorelease-pool ()
      (let* ((device (or (default-device)
                         (error "SceneKit needs a Metal device and there is none.")))
             (renderer (objc:invoke "SCNRenderer" "rendererWithDevice:options:"
                                    device (cffi:null-pointer))))
        (objc:invoke renderer "setScene:" scene)
        (let ((image (objc:invoke renderer "snapshotAtTime:withSize:antialiasingMode:"
                                  (float time 1d0)
                                  (vector (float width 1d0) (float height 1d0))
                                  antialiasing)))
          (when (cffi:null-pointer-p (objc:objc-object-pointer image))
            (error "SceneKit rendered nothing."))
          (let ((bytes (ns-image-to-png image)))
            (when path
              (with-open-file (out path :direction :output
                                        :element-type '(unsigned-byte 8)
                                        :if-exists :supersede)
                (write-sequence bytes out)))
            bytes))))))

(defun ns-image-to-png (image)
  "An NSImage as PNG bytes, through its TIFF representation.

-TIFFRepresentation then NSBitmapImageRep is the shortest path that does not
need a CGImage; the thumbnail example takes the CGImage route because that is
what Quick Look hands back."
  (let* ((tiff (objc:invoke image "TIFFRepresentation"))
         (rep (objc:invoke "NSBitmapImageRep" "imageRepWithData:" tiff))
         (data (objc:invoke rep "representationUsingType:properties:"
                            4 ; NSBitmapImageFileTypePNG
                            (objc:invoke "NSDictionary" "dictionary"))))
    (when (cffi:null-pointer-p (objc:objc-object-pointer data))
      (error "Could not encode the render as a PNG."))
    (ns-data-to-bytes data)))

;;; Something to look at ------------------------------------------------------------------

(defun solar-scene (&key (time 0))
  "A small arrangement of coloured solids, rotated by TIME.

Deliberately built entirely from Lisp forms -- no scene file, no asset -- so the
example ships nothing and the picture is described where you can read it."
  (let ((scene (make-scene)))
    (add-camera scene :position '(0 2 9))
    (add-light scene :position '(6 8 8))
    (add-light scene :type "ambient" :position '(0 0 0))
    (add-geometry scene (objc:invoke "SCNSphere" "sphereWithRadius:" 1.6d0)
                  :colour '(0.95 0.75 0.2) :position '(0 0 0))
    (loop for i below 5
          for angle = (+ (* i (/ (* 2 pi) 5)) (* time 0.6))
          do (add-geometry scene
                           (objc:invoke "SCNBox"
                                        "boxWithWidth:height:length:chamferRadius:"
                                        0.7d0 0.7d0 0.7d0 0.08d0)
                           :colour (list (+ 0.3 (* 0.14 i)) 0.4 (- 0.9 (* 0.12 i)))
                           :position (list (* 4 (cos angle)) 0 (* 4 (sin angle)))
                           :rotation (list 0 angle (* 0.4 i))))
    (add-geometry scene (objc:invoke "SCNTorus"
                                     "torusWithRingRadius:pipeRadius:" 3.0d0 0.06d0)
                  :colour '(0.6 0.6 0.7) :rotation (list (/ pi 2) 0 0))
    scene))

;;; A worked example --------------------------------------------------------------------

(defun test-scene-kit ()
  "Build a scene, render it, and check a picture came out.

    (objc/examples:test-scene-kit)
    => (:AVAILABLE T :PNG T :PIXELS (480 360) :ANIMATES T :NODES 10)

:ANIMATES is the one with teeth: the same scene rendered at two different times
must differ, which is what says the time argument reached SceneKit rather than
being ignored.  Comparing two renders byte for byte is a blunt instrument and
exactly right here -- if they are identical, nothing moved."
  (ensure-scene-kit)
  (if (not (metal-available-p))
      (list :available nil)
      (let* ((first (render-scene (solar-scene :time 0)))
             (later (render-scene (solar-scene :time 2)))
             (scene (solar-scene)))
        (list :available t
              :png (png-p first)
              :pixels (png-dimensions first)
              :animates (not (equalp first later))
              :nodes (objc:invoke (objc:invoke (objc:invoke scene "rootNode")
                                               "childNodes")
                                  "count")))))

(defun report-scene-kit (&optional (path "/tmp/objc-scene.png"))
  "Render the scene and say where it went."
  (if (not (metal-available-p))
      (format t "~&no Metal device, so no SceneKit renderer.~%")
      (let ((bytes (render-scene (solar-scene :time 1.2) :path path :width 800 :height 600)))
        (format t "~&~D bytes -> ~A (~{~Dx~D~})~%"
                (length bytes) path (png-dimensions bytes))
        path)))
;;; The simd half --------------------------------------------------------------------
;;;
;;; Everything above places nodes with SCNVector3, three CGFloats in a
;;; buffer.  SceneKit's other face is simd: simdPosition is a vector_float3,
;;; simdTransform a simd_float4x4, and Clang cannot encode either, so the
;;; runtime describes those methods as taking nothing and returning nothing.
;;; Declared once, by selector, they take and return Lisp vectors: a float3
;;; as #(x y z), a 4x4 as four column vectors, simd's own column-major
;;; layout.  So a transform can be composed in Lisp -- a rotation times a
;;; translation, plain arithmetic on columns -- and handed over whole, and
;;; SceneKit's own composition read back and compared.
;;;
;;; Where the build cannot carry a sixteen-byte vector this half declines,
;;; and TEST-SCENE-KIT-SIMD says so; the rest of the file is unaffected.

(defun simd-available-p ()
  "Whether this build carries float3 and float4x4 by value: the declarations
themselves refuse where it does not."
  (ensure-scene-kit)
  (handler-case
      (progn
        (objc:declare-objc-signature "simdTransform" '() :result-type '(:matrix :float 4 4))
        (objc:declare-objc-signature "setSimdTransform:" '((:matrix :float 4 4)))
        (objc:declare-objc-signature "simdWorldTransform" '() :result-type '(:matrix :float 4 4))
        (objc:declare-objc-signature "simdPosition" '() :result-type '(:vector :float 3))
        (objc:declare-objc-signature "setSimdPosition:" '((:vector :float 3)))
        (objc:declare-objc-signature "simdScale" '() :result-type '(:vector :float 3))
        (objc:declare-objc-signature "setSimdScale:" '((:vector :float 3)))
        t)
    (error () nil)))

;;; Matrices, column-major, as SceneKit and simd keep them.

(defun matrix-identity ()
  #(#(1 0 0 0) #(0 1 0 0) #(0 0 1 0) #(0 0 0 1)))

(defun matrix-translation (x y z)
  (vector #(1 0 0 0) #(0 1 0 0) #(0 0 1 0) (vector x y z 1)))

(defun matrix-scale (x y z)
  (vector (vector x 0 0 0) (vector 0 y 0 0) (vector 0 0 z 0) #(0 0 0 1)))

(defun matrix-rotation-x (angle)
  "A rotation about the horizontal axis, ANGLE in radians: a camera tilt."
  (let ((c (cos angle)) (s (sin angle)))
    (vector #(1 0 0 0) (vector 0 c s 0) (vector 0 (- s) c 0) #(0 0 0 1))))

(defun matrix-rotation-y (angle)
  "A rotation about the vertical axis, ANGLE in radians."
  (let ((c (cos angle)) (s (sin angle)))
    (vector (vector c 0 (- s) 0) #(0 1 0 0) (vector s 0 c 0) #(0 0 0 1))))

(defun matrix-multiply (a b)
  "A times B, both vectors of columns: the product's column j is A applied to
B's column j."
  (flet ((element (i j)
           (loop for k below 4 sum (* (aref (aref a k) i) (aref (aref b j) k)))))
    (coerce (loop for j below 4
                  collect (coerce (loop for i below 4 collect (float (element i j) 1.0)) 'vector))
            'vector)))

(defun matrices-agree-p (a b &optional (tolerance 1e-4))
  (every (lambda (column-a column-b)
           (every (lambda (x y) (< (abs (- x y)) tolerance)) column-a column-b))
         a b))

;;; A scene placed by transforms

(defun simd-scene (&key (time 0))
  "The solar arrangement again, every node placed by a transform composed in
Lisp and set whole through setSimdTransform:, under an orbit node so that
SceneKit has a composition of its own to be asked for.  Returns (VALUES
SCENE ORBIT SATELLITE), the last two being the nodes the test compares."
  (let ((scene (make-scene))
        (root nil))
    (setf root (objc:invoke scene "rootNode"))
    ;; Even the camera is placed by a matrix: up and back, then tilted down
    ;; to look at the origin.
    (let ((camera (objc:invoke "SCNNode" "node")))
      (objc:invoke camera "setCamera:" (objc:invoke "SCNCamera" "camera"))
      (objc:invoke camera "setSimdTransform:"
                   (matrix-multiply (matrix-translation 0 3.5 10) (matrix-rotation-x -0.33)))
      (objc:invoke root "addChildNode:" camera))
    (add-light scene :position '(6 8 8))
    (add-light scene :type "ambient" :position '(0 0 0))
    ;; The sun, scaled rather than sized, through a float3.
    (let ((sun (objc:invoke "SCNNode" "nodeWithGeometry:"
                            (objc:invoke "SCNSphere" "sphereWithRadius:" 1d0))))
      (objc:invoke (objc:invoke (objc:invoke (objc:invoke sun "geometry") "firstMaterial") "diffuse")
                   "setContents:" (objc:invoke "NSColor" "colorWithRed:green:blue:alpha:" 0.95d0 0.75d0 0.2d0 1d0))
      (objc:invoke sun "setSimdScale:" #(1.6 1.6 1.6))
      (objc:invoke root "addChildNode:" sun))
    ;; An orbit node turned by TIME, and five satellites under it, each
    ;; placed by rotation-about-y times translation-out: composed here, set
    ;; whole.  The child's world transform is then SceneKit's product of
    ;; the orbit's and its own, which the test asks for.
    (let ((orbit (objc:invoke "SCNNode" "node"))
          (satellite nil))
      (objc:invoke orbit "setSimdTransform:" (matrix-rotation-y (* time 0.6)))
      (objc:invoke root "addChildNode:" orbit)
      (loop for i below 5
            for angle = (* i (/ (* 2 pi) 5))
            do (let ((node (objc:invoke "SCNNode" "nodeWithGeometry:"
                                        (objc:invoke "SCNBox" "boxWithWidth:height:length:chamferRadius:"
                                                     0.7d0 0.7d0 0.7d0 0.08d0))))
                 (objc:invoke (objc:invoke (objc:invoke (objc:invoke node "geometry") "firstMaterial") "diffuse")
                              "setContents:"
                              (objc:invoke "NSColor" "colorWithRed:green:blue:alpha:"
                                           (float (+ 0.3 (* 0.14 i)) 1d0) 0.4d0 (float (- 0.9 (* 0.12 i)) 1d0) 1d0))
                 (objc:invoke node "setSimdTransform:"
                              (matrix-multiply (matrix-rotation-y angle)
                                               (matrix-multiply (matrix-translation 4 0 0)
                                                                (matrix-rotation-y (* 0.4 i)))))
                 (objc:invoke orbit "addChildNode:" node)
                 (when (= i 0) (setf satellite node))))
      (let ((ring (objc:invoke "SCNNode" "nodeWithGeometry:"
                               (objc:invoke "SCNTorus" "torusWithRingRadius:pipeRadius:" 4.0d0 0.06d0))))
        (objc:invoke (objc:invoke (objc:invoke (objc:invoke ring "geometry") "firstMaterial") "diffuse")
                     "setContents:" (objc:invoke "NSColor" "colorWithRed:green:blue:alpha:" 0.6d0 0.6d0 0.7d0 1d0))
        (objc:invoke root "addChildNode:" ring))
      (values scene orbit satellite))))

(defun test-scene-kit-simd ()
  "Transforms in and out of SceneKit as matrices and vectors.

    (objc/examples:test-scene-kit-simd)
    => (:AVAILABLE T :ROUND-TRIP T :POSITION T :WORLD-AGREES T :PACK T :PNG T)

:WORLD-AGREES is the one with teeth: a satellite's world transform, which
SceneKit composes from the orbit node's and the satellite's own, must equal
the product Lisp computes from the same two matrices.  Two multiplications by
two implementations agreeing to four decimals says the columns went over in
the right order and the right registers, both ways.  :PACK is SBCL only: a
simd-pack handed over as the position itself."
  (cond
    ((not (simd-available-p)) (list :available nil))
    ((not (metal-available-p)) (list :available t :metal nil))
    (t
     (multiple-value-bind (scene orbit satellite) (simd-scene :time 1.2)
       ;; Translate after rotating -- T times R -- so the translation column
       ;; is still (1 2 3), which is what simdPosition reads.
       (let* ((set (matrix-multiply (matrix-translation 1 2 3) (matrix-rotation-y 0.3)))
              (probe (objc:invoke "SCNNode" "node")))
         (objc:invoke probe "setSimdTransform:" set)
         (list :available t
               :round-trip (matrices-agree-p set (objc:invoke probe "simdTransform"))
               ;; The translation column is what simdPosition reads.
               :position (equalp #(1.0 2.0 3.0) (map 'vector (lambda (x) (float x 1.0))
                                                     (subseq (objc:invoke probe "simdPosition") 0 3)))
               :world-agrees (matrices-agree-p
                              (matrix-multiply (objc:invoke orbit "simdTransform")
                                               (objc:invoke satellite "simdTransform"))
                              (objc:invoke satellite "simdWorldTransform"))
               :pack #+sbcl (progn
                              (objc:invoke probe "setSimdPosition:"
                                           (sb-kernel:%make-simd-pack-single 7.0 8.0 9.0 0.0))
                              (equalp #(7.0 8.0 9.0) (objc:invoke probe "simdPosition")))
                     #-sbcl :not-on-this-lisp
               :png (png-p (render-scene scene))))))))

(defun report-scene-kit-simd (&optional (path "/tmp/objc-scene-simd.png"))
  "Render the transform-placed scene and say where it went."
  (cond ((not (simd-available-p))
         (format t "~&this build does not carry float4x4 by value; see the README.~%"))
        ((not (metal-available-p))
         (format t "~&no Metal device, so no SceneKit renderer.~%"))
        (t
         (let ((bytes (render-scene (simd-scene :time 1.2) :path path :width 800 :height 600)))
           (format t "~&~D bytes -> ~A (~{~Dx~D~})~%" (length bytes) path (png-dimensions bytes))
           path))))
