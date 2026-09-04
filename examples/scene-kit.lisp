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
