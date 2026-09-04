;;;; examples/metal.lisp -- GPU compute, from the REPL.
;;;;
;;;; Metal is the flagship of this set: a compute kernel written as a string,
;;;; compiled by the system at run time, and executed on the GPU over data a
;;;; Lisp function handed it.  Edit the kernel, re-evaluate, run it again -- the
;;;; same live loop the canvas has, on the other processor.
;;;;
;;;; It also exercises more of the bridge at once than anything else here:
;;;; a plain C entry point, ordinary message sends, an owned-object convention,
;;;; and a 24-byte structure passed BY VALUE.
;;;;
;;;; THE TRAP, and it is one this library already documents in a form that does
;;;; not quite cover it.  MTLCreateSystemDefaultDevice signals
;;;; FLOATING-POINT-OVERFLOW.  src/abi.lisp masks the traps Cocoa violates
;;;; around every message send and every Lisp-implemented method, which is why
;;;; nothing else here has to think about it -- but this is the first example
;;;; that calls a graphics C function DIRECTLY, and a CFFI:DEFCFUN is not a
;;;; message send.  Nothing masks it for you.  Hence WITH-METAL below, which
;;;; every entry point in this file goes through.
;;;;
;;;; MTLSize is three NSUIntegers, so 24 bytes, passed by value to
;;;; -dispatchThreads:threadsPerThreadgroup:.  It is not one of the four Cocoa
;;;; structures the bridge converts, so it crosses as a pointer to a filled
;;;; buffer -- which is exactly what MARSHAL-ARGUMENT does with any other
;;;; structure, and needs saying only because the vector shorthand that works
;;;; for NSRect does not work here.
;;;;
;;;; SKIPS RATHER THAN FAILS where there is no GPU: a virtualised CI runner may
;;;; have no Metal device at all, and that is a fact about the machine.

(in-package #:objc/examples)

(defun ensure-metal ()
  (objc:ensure-objc-initialized
   :modules '("/System/Library/Frameworks/Metal.framework/Metal")))

(cffi:defcfun ("MTLCreateSystemDefaultDevice" %create-system-default-device) :pointer)

(defmacro with-metal (&body body)
  "Run BODY with the floating point traps Metal violates masked.

Not defensive.  MTLCreateSystemDefaultDevice signals FLOATING-POINT-OVERFLOW on
the way to answering, and SBCL runs with that trap enabled; the bridge masks
traps around message sends, and this is not one."
  `(float-features:with-float-traps-masked (:invalid :divide-by-zero :overflow)
     ,@body))

;;; The device ---------------------------------------------------------------------

(defvar *device* nil)

(defun default-device ()
  "The system's default Metal device, or NIL where there is not one."
  (ensure-metal)
  (or *device*
      (setf *device*
            (with-metal
              (let ((device (%create-system-default-device)))
                (unless (cffi:null-pointer-p device) device))))))

(defun metal-available-p ()
  "True when this machine has a GPU Metal will talk to.

A virtualised runner may not, and that is not a fact about this library, so the
tests skip on it -- the same discipline THUMBNAILING-AVAILABLE-P follows."
  (handler-case (and (default-device) t)
    (error () nil)))

(defun device-name ()
  (let ((device (default-device)))
    (when device
      (with-metal (objc:invoke-into 'string device "name")))))

;;; Compiling a kernel ----------------------------------------------------------------

(defvar *pipelines* (make-hash-table :test 'equal)
  "(SOURCE . FUNCTION-NAME) -> MTLComputePipelineState.

Compiling Metal Shading Language is slow enough to notice -- tens of
milliseconds -- and the same kernel is usually run more than once, so pipelines
are memoized on the source that produced them.  The same reason the bridge
memoizes trampolines, at a coarser grain.")

(defun compile-kernel (source &optional (function-name "kernel_main"))
  "Compile SOURCE, a Metal Shading Language program, and return a pipeline state.

    (compile-kernel \"#include <metal_stdlib>
                      using namespace metal;
                      kernel void twice(device float *x [[buffer(0)]],
                                        uint i [[thread_position_in_grid]])
                      { x[i] *= 2; }\"
                    \"twice\")

Compiled by the system compiler at run time, so a kernel can be built from a
string a Lisp function assembled -- which is what GPU-MAP does."
  (let ((key (cons source function-name)))
    (or (gethash key *pipelines*)
        (setf (gethash key *pipelines*)
              (build-pipeline source function-name)))))

(defun build-pipeline (source function-name)
  (let ((device (or (default-device) (error "No Metal device on this machine."))))
    (with-metal
      (cffi:with-foreign-object (error-out :pointer)
        (setf (cffi:mem-ref error-out :pointer) (cffi:null-pointer))
        (let ((library (objc:invoke device "newLibraryWithSource:options:error:"
                                    source (cffi:null-pointer) error-out)))
          (when (cffi:null-pointer-p (objc:objc-object-pointer library))
            (error "Metal could not compile the kernel:~%~A"
                   (compiler-message (cffi:mem-ref error-out :pointer))))
          (let ((function (objc:invoke library "newFunctionWithName:" function-name)))
            (when (cffi:null-pointer-p (objc:objc-object-pointer function))
              (objc:release library)
              (error "The kernel compiled but has no function named ~S." function-name))
            (let ((pipeline (objc:invoke device
                                         "newComputePipelineStateWithFunction:error:"
                                         function error-out)))
              ;; -new... returns something owned; the pipeline holds what it needs.
              (objc:release function)
              (objc:release library)
              (when (cffi:null-pointer-p (objc:objc-object-pointer pipeline))
                (error "Metal could not build a pipeline: ~A"
                       (compiler-message (cffi:mem-ref error-out :pointer))))
              pipeline)))))))

(defun compiler-message (error-object)
  (if (cffi:null-pointer-p error-object)
      "no reason given"
      (objc:invoke-into 'string error-object "localizedDescription")))

;;; Running one ------------------------------------------------------------------------

(defun mtl-size (width &optional (height 1) (depth 1))
  "An MTLSize as a foreign buffer, for passing by value.

Three NSUIntegers, 24 bytes.  MARSHAL-ARGUMENT takes a pointer for any structure
it has no Lisp reading for, which is every structure but NSRect, NSPoint, NSSize
and NSRange -- so this is a buffer rather than the #(...) shorthand those four
accept.  The caller frees it."
  (let ((buffer (cffi:foreign-alloc :uint64 :count 3)))
    (setf (cffi:mem-aref buffer :uint64 0) width
          (cffi:mem-aref buffer :uint64 1) height
          (cffi:mem-aref buffer :uint64 2) depth)
    buffer))

(defun run-kernel (pipeline buffers count &key (threads-per-group 32))
  "Dispatch PIPELINE over COUNT elements with BUFFERS bound in order.

Blocks until the GPU has finished, which is what -waitUntilCompleted is for and
what makes this usable from a REPL at all."
  (let ((device (default-device)))
    (with-metal
      (objc:with-autorelease-pool ()
        (let* ((queue (objc:invoke device "newCommandQueue"))
               (command-buffer (objc:invoke queue "commandBuffer"))
               (encoder (objc:invoke command-buffer "computeCommandEncoder"))
               (group (min threads-per-group
                           (objc:invoke pipeline "maxTotalThreadsPerThreadgroup")))
               (grid-size (mtl-size count))
               (group-size (mtl-size group)))
          (unwind-protect
               (progn
                 (objc:invoke encoder "setComputePipelineState:" pipeline)
                 (loop for buffer in buffers
                       for index from 0
                       do (objc:invoke encoder "setBuffer:offset:atIndex:" buffer 0 index))
                 (objc:invoke encoder "dispatchThreads:threadsPerThreadgroup:"
                              grid-size group-size)
                 (objc:invoke encoder "endEncoding")
                 (objc:invoke command-buffer "commit")
                 (objc:invoke command-buffer "waitUntilCompleted"))
            (cffi:foreign-free grid-size)
            (cffi:foreign-free group-size)
            (objc:release queue)))))))

;;; Buffers ------------------------------------------------------------------------------

(defun float-buffer (floats)
  "A shared MTLBuffer holding FLOATS, a sequence of single floats."
  (let* ((floats (coerce floats 'vector))
         (device (default-device))
         (buffer (with-metal
                   (objc:invoke device "newBufferWithLength:options:"
                                (max 4 (* 4 (length floats))) 0)))
         (contents (with-metal (objc:invoke buffer "contents"))))
    (dotimes (i (length floats) buffer)
      (setf (cffi:mem-aref contents :float i) (float (aref floats i) 1.0)))))

(defun buffer-floats (buffer count)
  "COUNT single floats read out of BUFFER."
  (let ((contents (with-metal (objc:invoke buffer "contents")))
        (result (make-array count :element-type 'single-float)))
    (dotimes (i count result)
      (setf (aref result i) (cffi:mem-aref contents :float i)))))

;;; The thing you actually want ------------------------------------------------------------

(defparameter +map-template+
  "#include <metal_stdlib>
using namespace metal;
kernel void lisp_map(device const float *in  [[buffer(0)]],
                     device float       *out [[buffer(1)]],
                     uint i [[thread_position_in_grid]])
{
  out[i] = ~A;
}"
  "The boilerplate around a one-line kernel body.  ~A is filled with an MSL
expression in `in[i]'.")

(defun gpu-map (expression floats)
  "Apply an MSL EXPRESSION to every element of FLOATS on the GPU.

    (gpu-map \"in[i] * in[i]\" #(1 2 3 4))     ;; => #(1.0 4.0 9.0 16.0)
    (gpu-map \"sqrt(in[i])\" #(1 4 9 16))      ;; => #(1.0 2.0 3.0 4.0)
    (gpu-map \"sin(in[i]) + 1.0\" xs)

The whole point of the example in one function: the kernel is assembled from a
string at run time, so the GPU program is data a Lisp function wrote.  Anything
Metal's standard library provides is available in EXPRESSION.

The pipeline is cached on the source, so the same expression compiles once."
  (let* ((floats (coerce floats 'vector))
         (count (length floats)))
    (when (zerop count)
      (return-from gpu-map (make-array 0 :element-type 'single-float)))
    (let ((pipeline (compile-kernel (format nil +map-template+ expression) "lisp_map"))
          (in nil) (out nil))
      (unwind-protect
           (progn
             (setf in (float-buffer floats)
                   out (float-buffer (make-array count :initial-element 0.0)))
             (run-kernel pipeline (list in out) count)
             (buffer-floats out count))
        (when in (objc:release in))
        (when out (objc:release out))))))

;;; A worked example -----------------------------------------------------------------------

(defun test-metal ()
  "Compile kernels, run them, and check the arithmetic.

    (objc/examples:test-metal)
    => (:AVAILABLE T :DEVICE \"Apple M3\" :SQUARES T :SQUARE-ROOTS T
        :LARGE T :CACHED T :BAD-KERNEL-REPORTED T)

:LARGE runs a hundred thousand elements, which is where a GPU is doing something
a loop would not.  :BAD-KERNEL-REPORTED is the one that keeps the error path
honest: a kernel that does not compile must say so rather than crash, and the
message must come from the Metal compiler."
  (ensure-metal)
  (if (not (metal-available-p))
      (list :available nil)
      (let* ((squares (gpu-map "in[i] * in[i]" #(0 1 2 3 4 5 6 7)))
             (roots (gpu-map "sqrt(in[i])" #(1 4 9 16 25)))
             (large-input (let ((v (make-array 100000 :element-type 'single-float)))
                            (dotimes (i (length v) v) (setf (aref v i) (float i 1.0)))))
             (before (hash-table-count *pipelines*))
             (large (gpu-map "in[i] * 2.0" large-input))
             (again (gpu-map "in[i] * in[i]" #(3 4))))
        (list :available t
              :device (device-name)
              :squares (equalp squares #(0.0 1.0 4.0 9.0 16.0 25.0 36.0 49.0))
              :square-roots (equalp roots #(1.0 2.0 3.0 4.0 5.0))
              :large (and (= 100000 (length large))
                          (= 199998.0 (aref large 99999))
                          (loop for i below 1000
                                always (= (aref large i) (* 2.0 i))))
              :cached (and (equalp again #(9.0 16.0))
                           ;; One new pipeline for the "* 2.0" kernel; the
                           ;; squares kernel was already compiled.
                           (= (1+ before) (hash-table-count *pipelines*)))
              :bad-kernel-reported
              (handler-case (progn (gpu-map "this is not metal" #(1)) nil)
                (error (condition)
                  (and (search "program_source" (princ-to-string condition)) t)))))))

(defparameter +heavy-kernel+
  "#include <metal_stdlib>
using namespace metal;
kernel void heavy(device const float *in  [[buffer(0)]],
                  device float       *out [[buffer(1)]],
                  uint i [[thread_position_in_grid]])
{
  float x = in[i];
  for (int k = 0; k < 300; k++) { x = sqrt(x) * 1.5 + 0.25; }
  out[i] = x;
}"
  "Three hundred iterations per element, which is what a GPU is for.

Written out in full rather than through GPU-MAP because that one substitutes a
single EXPRESSION into `out[i] = ...', and this needs statements.  Anything
beyond an expression goes through COMPILE-KERNEL and RUN-KERNEL, which is the
whole of the difference between them.")

(defun heavy-on-cpu (x)
  (dotimes (k 300 x) (setf x (+ (* 1.5 (sqrt x)) 0.25))))

(defun report-metal (&optional (count 1000000))
  "Time the same arithmetic on the GPU and in Lisp, twice, and print both.

Not a benchmark -- one run each, on a machine doing other things -- but the
shape is stable and it is not the shape people expect, so both halves are here:

    device: Apple M3
    1000000 elements
    300 iterations each:  GPU 21ms   CPU 5501ms   262x
    one multiply each:    GPU 16ms   CPU 10ms   slower -- copying wins

THE SECOND LINE IS THE INTERESTING ONE.  For work this cheap the GPU loses, and
it loses to the copying rather than to the arithmetic: getting the floats into a
buffer and back out again is most of that time, one element at a time through
CFFI -- measured at four million elements, 36ms of a 60ms total -- and the
kernel itself is nearly free.  A GPU pays for itself when
the arithmetic per element is heavy enough to cover two copies, and not before
-- which is a fact about this bridge as much as about Metal, since a
lower-level marshalling path would move that line."
  (if (not (metal-available-p))
      (format t "~&no Metal device on this machine.~%")
      (let ((input (let ((v (make-array count :element-type 'single-float)))
                     (dotimes (i count v) (setf (aref v i) (+ 1.0 (float i 1.0))))))
            (units internal-time-units-per-second))
        (format t "~&device: ~A~%~D elements~%" (device-name) count)
        ;; Compile both kernels first, so what is timed is the work.
        (let ((pipeline (compile-kernel +heavy-kernel+ "heavy")))
          (gpu-map "sqrt(in[i]) * 2.0" #(1.0))
          (flet ((elapsed (thunk)
                   (let ((start (get-internal-real-time)))
                     (multiple-value-bind (value) (funcall thunk)
                       (values value (round (* 1000 (- (get-internal-real-time) start))
                                            units))))))
            (multiple-value-bind (heavy-gpu heavy-gpu-ms)
                (elapsed (lambda ()
                           (let ((in (float-buffer input))
                                 (out (float-buffer (make-array count
                                                                :initial-element 0.0))))
                             (unwind-protect
                                  (progn (run-kernel pipeline (list in out) count)
                                         (buffer-floats out count))
                               (objc:release in)
                               (objc:release out)))))
              (multiple-value-bind (heavy-cpu heavy-cpu-ms)
                  (elapsed (lambda () (map 'vector #'heavy-on-cpu input)))
                (format t "300 iterations each:  GPU ~Dms   CPU ~Dms~@[   ~Dx~]~%"
                        heavy-gpu-ms heavy-cpu-ms
                        (when (plusp heavy-gpu-ms) (round heavy-cpu-ms heavy-gpu-ms)))
                (format t "  agree: ~A~%"
                        (loop for i below (min count 1000)
                              always (< (abs (- (aref heavy-gpu i) (aref heavy-cpu i)))
                                        0.01)))))
            (multiple-value-bind (light-gpu light-gpu-ms)
                (elapsed (lambda () (gpu-map "sqrt(in[i]) * 2.0" input)))
              (multiple-value-bind (light-cpu light-cpu-ms)
                  (elapsed (lambda () (map 'vector (lambda (x) (* 2.0 (sqrt x))) input)))
                (format t "one multiply each:    GPU ~Dms   CPU ~Dms   ~A~%"
                        light-gpu-ms light-cpu-ms
                        (if (< light-gpu-ms light-cpu-ms) "faster" "slower -- copying wins")
                        )
                (format t "  agree: ~A~%"
                        (loop for i below (min count 1000)
                              always (< (abs (- (aref light-gpu i) (aref light-cpu i)))
                                        0.01))))))))))
