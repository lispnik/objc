;;;; examples/map.lisp -- a map of anywhere, rendered without a window.
;;;;
;;;; MKMapSnapshotter fetches map tiles and draws them into an image, so a pair
;;;; of coordinates becomes a PNG: no window, no MKMapView, no interface.  It is
;;;; the only example here whose output is a picture of somewhere real.
;;;;
;;;; THE DEADLOCK IS THE LESSON, and it is a new one -- none of the other
;;;; completion-handler examples can hit it.  -startWithCompletionHandler:
;;;; delivers on the MAIN queue.  Waiting for it on the main thread, which is
;;;; what a REPL call does, means the thread that would run the handler is the
;;;; thread blocked waiting for it: the snapshot completes, the block is queued
;;;; behind you, and you wait for ever.  Measured: thirty seconds, no callback,
;;;; no error.
;;;;
;;;; -startWithQueue:completionHandler: takes the queue to answer on, so handing
;;;; it a serial queue puts the handler somewhere that is not blocked.  That is
;;;; the fix here, and it is the same one-line move url-session.lisp makes for
;;;; the same underlying reason -- a callback needs a thread that is free to run
;;;; it.  NSURLSession lets you configure that on the session; Quick Look picks
;;;; its own; MapKit defaults to the worst choice for a REPL and offers a better
;;;; one in a second selector.
;;;;
;;;; MKCoordinateRegion is four doubles -- centre latitude and longitude, then
;;;; the span in degrees -- 32 bytes, passed BY VALUE, and a buffer like every
;;;; other structure that is not one of the four Cocoa ones.
;;;;
;;;; NEEDS THE NETWORK, so the test skips rather than fails when the tiles do
;;;; not arrive.  A red build should mean the library broke.

(in-package #:objc/examples)

(defparameter +map-frameworks+
  '("/System/Library/Frameworks/AppKit.framework/AppKit"
    "/System/Library/Frameworks/MapKit.framework/MapKit"))

(defun ensure-map-kit ()
  (objc:ensure-objc-initialized :modules +map-frameworks+))

(defparameter +map-types+
  '((:standard . 0) (:satellite . 1) (:hybrid . 2)
    (:satellite-flyover . 3) (:hybrid-flyover . 4) (:muted . 5))
  "MKMapType.  :MUTED is the standard map with the colour taken out of it, which
is what you want behind your own drawing.")

(defun map-type-value (type)
  (or (cdr (assoc type +map-types+))
      (error "Unknown map type ~S; expected one of ~{~S~^, ~}."
             type (mapcar #'car +map-types+))))

;;; Structures by value ------------------------------------------------------------

(defun coordinate-region (latitude longitude latitude-span longitude-span)
  "An MKCoordinateRegion as a foreign buffer: centre, then span, in degrees.

Four doubles.  A degree of latitude is about 111km everywhere; a degree of
longitude is that at the equator and shrinks to nothing at the poles, which is
why the two spans are given separately rather than as one radius.  The caller
frees it."
  (let ((buffer (cffi:foreign-alloc :double :count 4)))
    (setf (cffi:mem-aref buffer :double 0) (float latitude 1d0)
          (cffi:mem-aref buffer :double 1) (float longitude 1d0)
          (cffi:mem-aref buffer :double 2) (float latitude-span 1d0)
          (cffi:mem-aref buffer :double 3) (float longitude-span 1d0))
    buffer))

;;; Snapshots ------------------------------------------------------------------------

(defun map-snapshot (latitude longitude
                     &key (span 0.02) (longitude-span nil) (width 600) (height 400)
                          (type :standard) (timeout 30) (buildings t)
                          (points-of-interest t))
  "Render a map centred on LATITUDE and LONGITUDE and return PNG bytes.

    (map-snapshot 51.5007 -0.1246)                     ; Westminster
    (map-snapshot 37.8199 -122.4783 :span 0.01 :type :satellite)

SPAN is the height of the view in degrees of latitude; LONGITUDE-SPAN defaults
to the same number, which is wider on the ground the nearer the equator you are.

No :SCALE, though the obvious guess is that there should be: MKMapSnapshotOptions
has -setScale: on iOS and not on macOS, where the size is in points and the
backing scale is the display's.  Asking the runtime is how that was settled --
writing it got a Lisp error naming the selector, which beats the alternative.

Signals if the tiles do not arrive within TIMEOUT, which on a machine with no
network is what happens.  MAP-AVAILABLE-P is the polite way to ask first."
  (ensure-map-kit)
  (objc:with-autorelease-pool ()
    (let ((options (objc:alloc-init-object "MKMapSnapshotOptions"))
          (region (coordinate-region latitude longitude span
                                     (or longitude-span span))))
      (unwind-protect
           (objc:invoke options "setRegion:" region)
        (cffi:foreign-free region))
      (objc:invoke options "setSize:" (vector (float width 1d0) (float height 1d0)))
      (objc:invoke options "setMapType:" (map-type-value type))
      (objc:invoke options "setShowsBuildings:" buildings)
      (objc:invoke options "setShowsPointsOfInterest:" points-of-interest)
      (let ((snapshotter (objc:invoke (objc:invoke "MKMapSnapshotter" "alloc")
                                      "initWithOptions:" options))
            (queue (serial-queue "lisp.map"))
            (done (bt:make-semaphore))
            (png nil)
            (failure nil))
        (unwind-protect
             (progn
               (objc:with-objc-block
                   (block '(:void (objc:objc-object-pointer objc:objc-object-pointer))
                          (lambda (snapshot error)
                            (objc:with-autorelease-pool ()
                              (if (cffi:null-pointer-p (objc:objc-object-pointer error))
                                  (setf png (ns-image-to-png
                                             (objc:invoke snapshot "image")))
                                  (setf failure (objc:ns-string-to-string
                                                 (objc:invoke error
                                                              "localizedDescription"))))
                              (bt:signal-semaphore done))))
                 ;; -startWithQueue:, never -startWithCompletionHandler:.  See the
                 ;; header: the latter answers on the main queue, which is this
                 ;; thread, which is about to block.
                 (objc:invoke snapshotter "startWithQueue:completionHandler:" queue block)
                 (unless (bt:wait-on-semaphore done :timeout timeout)
                   (objc:invoke snapshotter "cancel")
                   (error "The map did not arrive within ~D second~:P.  ~
                           MKMapSnapshotter needs the network." timeout))))
          (objc:release queue))
        (when failure
          (error "MapKit could not render that map: ~A" failure))
        png))))

(defun map-file (latitude longitude path &rest options)
  "Render a map and write it to PATH, which is returned."
  (let ((bytes (apply #'map-snapshot latitude longitude options)))
    (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                              :if-exists :supersede)
      (write-sequence bytes out))
    path))

(defun map-available-p (&key (timeout 15))
  "True when a map can actually be fetched -- which is a question about the
network, not about this library, so the tests skip on it."
  (handler-case (and (map-snapshot 51.5007 -0.1246 :width 64 :height 64
                                                   :timeout timeout)
                     t)
    (error () nil)))

;;; A worked example --------------------------------------------------------------------

(defparameter +places+
  '(("westminster" 51.5007 -0.1246 :standard)
    ("golden-gate" 37.8199 -122.4783 :satellite)
    ("manhattan"   40.7580  -73.9855 :muted))
  "Somewhere recognisable in each map type.")

(defun test-map ()
  "Fetch a couple of maps and check they are pictures of the right shape.

    (objc/examples:test-map)
    => (:AVAILABLE T :PNG T :PIXELS (600 400) :DIFFERENT-PLACES T :TYPES-DIFFER T)

:DIFFERENT-PLACES is the assertion worth having: two different coordinates must
give different images.  A snapshotter that ignored the region -- which is the
plausible failure, since the region crosses as a structure by value -- would
return the same picture twice and satisfy everything else here."
  (ensure-map-kit)
  (if (not (map-available-p))
      (list :available nil)
      (let ((london (map-snapshot 51.5007 -0.1246 :width 600 :height 400))
            (paris (map-snapshot 48.8584 2.2945 :width 600 :height 400)))
        (list :available t
              :png (and (png-p london) (png-p paris))
              :pixels (png-dimensions london)
              :different-places (not (equalp london paris))
              :types-differ (not (equalp london
                                         (map-snapshot 51.5007 -0.1246
                                                       :width 600 :height 400
                                                       :type :satellite)))))))

(defun report-map (&optional (directory (uiop:temporary-directory)))
  "Write one map per place and say where they went."
  (ensure-map-kit)
  (if (not (map-available-p))
      (format t "~&no network, so no map tiles.~%")
      (loop for (name latitude longitude type) in +places+
            for path = (merge-pathnames (format nil "objc-map-~A.png" name) directory)
            do (map-file latitude longitude path :type type :width 800 :height 600)
               (format t "~&~14A ~8,4F ~9,4F  ~10A -> ~A~%"
                       name latitude longitude type path))))
