;;;; examples/shader.lisp -- a shader playground: edit it, watch it change.
;;;;
;;;; Write an expression in Metal Shading Language, get a picture.  Change the
;;;; expression, get a different one -- while the window is still open, because
;;;; the kernel is compiled at run time and the compiled one is keyed on its
;;;; source.  It is the canvas's live loop with the GPU doing the drawing, and
;;;; it is the closest thing here to a toy.
;;;;
;;;;     (shader-file "float3(uv, 0.5 + 0.5 * sin(time))" #p"/tmp/a.png")
;;;;     (run-shader "float3(fract(uv * 8.0), abs(sin(time)))")
;;;;
;;;; The expression is evaluated once per PIXEL, with `uv' running 0..1 across
;;;; the image and `time' in seconds, and it returns a float3 colour.  That is
;;;; the whole interface, and it is enough for a surprising amount.
;;;;
;;;; A COMPUTE kernel rather than a fragment shader, which is worth saying since
;;;; the shape is borrowed from fragment-shader toys.  One GPU thread per pixel,
;;;; writing RGBA bytes into a buffer, is fewer moving parts than a render
;;;; pipeline -- no vertices, no render pass, no drawable -- and the same kernel
;;;; then serves both halves of this file: the headless one that writes a PNG
;;;; and can be tested, and the windowed one that animates.
;;;;
;;;; THE TRAP HERE IS -bitmapData, and it is the only example that hits it.  It
;;;; returns `unsigned char *', which encodes as `*' -- the same encoding as a C
;;;; string -- so plain INVOKE converts it to a Lisp string, and since the buffer
;;;; begins with a zero byte you get "" rather than an error.  This is precisely
;;;; what INVOKE-INTO's :POINTER disposition exists for; the manual says so, and
;;;; nothing else in these examples needed it until now.

(in-package #:objc/examples)

(defun ensure-shader ()
  (objc:ensure-objc-initialized
   :modules '("/System/Library/Frameworks/AppKit.framework/AppKit")))

(defparameter +shader-template+
  "#include <metal_stdlib>
using namespace metal;
kernel void shade(device uchar4        *out  [[buffer(0)]],
                  constant float2      &size [[buffer(1)]],
                  constant float       &time [[buffer(2)]],
                  uint2 gid [[thread_position_in_grid]])
{
  if (gid.x >= uint(size.x) || gid.y >= uint(size.y)) return;
  float2 uv = float2(gid) / size;
  float3 colour = ~A;
  out[gid.y * uint(size.x) + gid.x] = uchar4(uchar3(saturate(colour) * 255.0), 255);
}"
  "The boilerplate around a one-expression shader.

The bounds check is not optional: -dispatchThreads: rounds the grid up to whole
threadgroups, so the last row and column get threads for pixels that do not
exist, and without the early return they write past the buffer.")

;;; Rendering ---------------------------------------------------------------------

(defun shader-pipeline (expression)
  (compile-kernel (format nil +shader-template+ expression) "shade"))

(defun shader-bytes (expression &key (width 480) (height 360) (time 0))
  "Run EXPRESSION over every pixel and return the RGBA bytes as a buffer.

Returns (VALUES MTLBUFFER WIDTH HEIGHT); the caller releases the buffer."
  (ensure-shader)
  (let ((device (or (default-device) (error "No Metal device on this machine."))))
    (with-metal
      (let ((pipeline (shader-pipeline expression))
            (out (objc:invoke device "newBufferWithLength:options:" (* width height 4) 0))
            (size (objc:invoke device "newBufferWithLength:options:" 8 0))
            (clock (objc:invoke device "newBufferWithLength:options:" 4 0)))
        (let ((p (objc:invoke size "contents")))
          (setf (cffi:mem-aref p :float 0) (float width 1.0)
                (cffi:mem-aref p :float 1) (float height 1.0)))
        (setf (cffi:mem-aref (objc:invoke clock "contents") :float 0) (float time 1.0))
        (unwind-protect
             (progn (run-kernel pipeline (list out size clock) (list width height)
                                :threads-per-group '(8 8))
                    (values out width height))
          (objc:release size)
          (objc:release clock))))))

(defun shader-png (expression &key (width 480) (height 360) (time 0))
  "Run EXPRESSION over every pixel and return a PNG."
  (ensure-shader)
  (multiple-value-bind (buffer w h) (shader-bytes expression :width width :height height
                                                             :time time)
    (unwind-protect (rgba-buffer-to-png (objc:invoke buffer "contents") w h)
      (objc:release buffer))))

(defun shader-file (expression path &rest options)
  "Render EXPRESSION and write it to PATH, which is returned."
  (let ((bytes (apply #'shader-png expression options)))
    (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                              :if-exists :supersede)
      (write-sequence bytes out))
    path))

(defun rgba-buffer-to-png (rgba width height)
  "WIDTH by HEIGHT RGBA bytes at RGBA, as PNG bytes."
  (objc:with-autorelease-pool ()
    (let ((rep (objc:invoke
                (objc:invoke "NSBitmapImageRep" "alloc")
                "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:"
                (cffi:null-pointer) width height 8 4 t nil
                "NSCalibratedRGBColorSpace" (* width 4) 32)))
      (when (cffi:null-pointer-p (objc:objc-object-pointer rep))
        (error "Could not make a bitmap of ~Dx~D." width height))
      ;; INVOKE-INTO with :POINTER, not INVOKE.  -bitmapData returns
      ;; `unsigned char *', which encodes exactly as a C string does, so plain
      ;; INVOKE hands back a Lisp string -- "" here, because the buffer starts
      ;; with a zero byte.  See the header.
      (let ((destination (objc:invoke-into :pointer rep "bitmapData")))
        (dotimes (i (* width height 4))
          (setf (cffi:mem-aref destination :uint8 i) (cffi:mem-aref rgba :uint8 i))))
      (let ((data (objc:invoke rep "representationUsingType:properties:"
                               4 (objc:invoke "NSDictionary" "dictionary"))))
        (when (cffi:null-pointer-p (objc:objc-object-pointer data))
          (error "Could not encode the shader output as a PNG."))
        (ns-data-to-bytes data)))))

;;; Live ------------------------------------------------------------------------------

(defparameter *shader* "float3(uv, 0.5 + 0.5 * sin(time))"
  "The expression RUN-SHADER draws.  SETF it and the next frame uses it.

The live loop, and the reason this file exists: the compiled kernel is cached on
its source, so changing this recompiles once and then costs nothing.")

(defun draw-shader (width height)
  "A canvas draw function that fills the view with the current shader.

Suitable for OBJC/EXAMPLES:ANIMATE-CANVAS's :DRAW argument, which is how the
window gets its frames."
  (let* ((w (max 1 (floor width)))
         (h (max 1 (floor height)))
         (time (/ (get-internal-real-time) internal-time-units-per-second))
         (png (shader-png *shader* :width w :height h :time time)))
    (objc:with-autorelease-pool ()
      (cffi:with-foreign-object (bytes :uint8 (length png))
        (dotimes (i (length png))
          (setf (cffi:mem-aref bytes :uint8 i) (aref png i)))
        (let* ((data (objc:invoke "NSData" "dataWithBytes:length:" bytes (length png)))
               (image (objc:invoke (objc:invoke "NSImage" "alloc") "initWithData:" data)))
          (objc:invoke image "drawInRect:" (vector 0d0 0d0 (float width 1d0)
                                                   (float height 1d0))))))))

(defun run-shader (&optional expression &key (seconds 20) (fps 20))
  "Open a window and animate the shader for SECONDS.  Needs a window server.

    (run-shader)                                   ; the default
    (run-shader \"float3(fract(uv * 8.0), abs(sin(time)))\")

Blocks the REPL while it runs, for the reason ANIMATE-CANVAS gives: AppKit has
this thread.  To edit live instead, SETF *SHADER* from another window and call
REFRESH, or pass a shorter :SECONDS and call this again."
  (when expression (setf *shader* expression))
  (ensure-shader)
  (unless (metal-available-p)
    (error "No Metal device, so nothing to draw with."))
  (animate-canvas :seconds (float seconds 1d0) :draw 'draw-shader :fps fps))

;;; A worked example ---------------------------------------------------------------------

(defparameter +sample-shaders+
  '(("plasma"  . "float3(0.5 + 0.5 * sin(time + uv.x * 8.0),
                         0.5 + 0.5 * sin(time * 1.3 + uv.y * 8.0),
                         0.5 + 0.5 * sin(time * 0.7 + (uv.x + uv.y) * 6.0))")
    ("checks"  . "float3(fmod(floor(uv.x * 12.0) + floor(uv.y * 12.0), 2.0))")
    ("rings"   . "float3(0.5 + 0.5 * sin(40.0 * distance(uv, float2(0.5)) - time * 3.0))")
    ("gradient". "float3(uv, 0.25)"))
  "A few expressions worth looking at, for REPORT-SHADER and the tests.")

(defun test-shader ()
  "Render each sample shader and check the pixels are what was asked for.

    (objc/examples:test-shader)
    => (:AVAILABLE T :ALL-PNG T :PIXELS (64 48) :CORNER (0 0 63) :ANIMATES T
        :BOUNDS-RESPECTED T)

:CORNER is the assertion with teeth.  \"float3(uv, 0.25)\" makes the pixel at
the origin (0, 0, 0.25), so its bytes must be 0, 0 and 63 -- a claim about a
specific pixel having a specific value, rather than about a PNG having been
produced.  A shader that ran on the wrong coordinates, or output that was
transposed or off by a row, would not land there.

:BOUNDS-RESPECTED renders a size that is not a multiple of the threadgroup, the
case the kernel's early return exists for."
  (ensure-shader)
  (if (not (metal-available-p))
      (list :available nil)
      (let* ((pngs (mapcar (lambda (entry) (shader-png (cdr entry) :width 64 :height 48))
                           +sample-shaders+))
             (corner (multiple-value-bind (buffer) (shader-bytes "float3(uv, 0.25)"
                                                                 :width 64 :height 48)
                       (unwind-protect
                            (let ((p (objc:invoke buffer "contents")))
                              (list (cffi:mem-aref p :uint8 0)
                                    (cffi:mem-aref p :uint8 1)
                                    (cffi:mem-aref p :uint8 2)))
                         (objc:release buffer)))))
        (list :available t
              :all-png (every #'png-p pngs)
              :pixels (png-dimensions (first pngs))
              :corner corner
              :animates (not (equalp (shader-png (cdr (assoc "rings" +sample-shaders+
                                                             :test #'string=))
                                                 :width 64 :height 48 :time 0)
                                     (shader-png (cdr (assoc "rings" +sample-shaders+
                                                             :test #'string=))
                                                 :width 64 :height 48 :time 1)))
              :bounds-respected (png-p (shader-png "float3(uv, 0.5)"
                                                   :width 37 :height 23))))))

(defun report-shader (&optional (directory (uiop:temporary-directory)))
  "Write each sample shader to a PNG and say where they went."
  (if (not (metal-available-p))
      (format t "~&no Metal device, so nothing to draw with.~%")
      (loop for (name . expression) in +sample-shaders+
            for path = (merge-pathnames (format nil "objc-shader-~A.png" name) directory)
            do (shader-file expression path :width 640 :height 480 :time 1.5)
               (format t "~&~10A -> ~A~%" name path)
            finally (format t "~%(run-shader) animates one in a window.~%"))))
