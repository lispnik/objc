;;;; examples/thumbnail.lisp -- Quick Look thumbnails for any file type.
;;;;
;;;; QuickLookThumbnailing renders a preview of anything the system knows how to
;;;; preview -- a PDF, a keynote, a source file, a movie -- by asking the same
;;;; machinery Finder uses.  From Lisp it is one call and a completion handler,
;;;; and it is the shortest example here of the shape url-session.lisp is about:
;;;; hand it a block, get an answer later.
;;;;
;;;; Two things measured rather than assumed, both of which look like the API
;;;; being broken:
;;;;
;;;;   -[QLThumbnailRepresentation NSImage] returns NIL unless AppKit is loaded,
;;;;   with no error and no complaint.  The selector exists either way, because
;;;;   the framework declares it; what is missing is the class it would return.
;;;;   ENSURE-THUMBNAILING loads both, and -CGImage works regardless.
;;;;
;;;;   The generator answers on a queue of its own, so the completion handler
;;;;   arrives on a thread SBCL did not create.  One at a time, which is the safe
;;;;   side of the line gcd.lisp draws; THUMBNAIL waits on a semaphore, exactly
;;;;   as FETCH does.

(in-package #:objc/examples)

(defparameter +thumbnailing-frameworks+
  '("/System/Library/Frameworks/AppKit.framework/AppKit"
    "/System/Library/Frameworks/QuickLookThumbnailing.framework/QuickLookThumbnailing"))

(defun ensure-thumbnailing ()
  (objc:ensure-objc-initialized :modules +thumbnailing-frameworks+))

(defparameter +representation-types+
  '((:icon . 1) (:low-quality . 2) (:thumbnail . 4))
  "QLThumbnailGenerationRequestRepresentationTypes.

Asking for more than one lets the generator answer with whatever it can produce
soonest, which is why the default here is all three: a file type with no
thumbnailer still has an icon.")

(defun representation-mask (types)
  (reduce #'logior types
          :key (lambda (type)
                 (or (cdr (assoc type +representation-types+))
                     (error "Unknown representation ~S; expected one of ~{~S~^, ~}."
                            type (mapcar #'car +representation-types+))))
          :initial-value 0))

;;; Thumbnailing --------------------------------------------------------------------

(defun thumbnail (path &key (size 256) (scale 1) (timeout 30)
                            (types '(:icon :low-quality :thumbnail)))
  "Render a thumbnail of the file at PATH and return it as PNG bytes.

    (thumbnail #p\"/path/to/paper.pdf\")
    (thumbnail #p\"/path/to/movie.mov\" :size 512)

Signals if the system could not produce one, with whatever reason it gave.
Works for any file type Finder can preview, which is most of them."
  (ensure-thumbnailing)
  (objc:with-autorelease-pool ()
    (let* ((file (or (uiop:truename* path) (error "No such file: ~A" path)))
           (url (objc:invoke "NSURL" "fileURLWithPath:" (namestring file)))
           (request (objc:invoke (objc:invoke "QLThumbnailGenerationRequest" "alloc")
                                 "initWithFileAtURL:size:scale:representationTypes:"
                                 url (vector (float size 1d0) (float size 1d0))
                                 (float scale 1d0) (representation-mask types)))
           (generator (objc:invoke "QLThumbnailGenerator" "sharedGenerator"))
           (done (bt:make-semaphore))
           (png nil)
           (failure nil))
      (objc:with-objc-block
          (block '(:void (objc:objc-object-pointer objc:objc-object-pointer))
                 (lambda (representation error)
                   (objc:with-autorelease-pool ()
                     (if (cffi:null-pointer-p (objc:objc-object-pointer error))
                         (setf png (cg-image-to-png
                                    (objc:invoke representation "CGImage")))
                         (setf failure (objc:ns-string-to-string
                                        (objc:invoke error "localizedDescription"))))
                     (bt:signal-semaphore done))))
        (objc:invoke generator "generateBestRepresentationForRequest:completionHandler:"
                     request block)
        (unless (bt:wait-on-semaphore done :timeout timeout)
          (error "Quick Look did not answer for ~A within ~D second~:P." path timeout)))
      (when failure
        (error "Quick Look could not thumbnail ~A: ~A" path failure))
      png)))

(defun cg-image-to-png (cg-image)
  "A CGImageRef as PNG bytes, through NSBitmapImageRep.

-CGImage rather than -NSImage because it needs nothing of AppKit but the
conversion, and because it is the representation that is always there."
  (when (cffi:null-pointer-p cg-image)
    (error "Quick Look returned no image."))
  (let* ((rep (objc:invoke (objc:invoke "NSBitmapImageRep" "alloc")
                           "initWithCGImage:" cg-image))
         ;; NSBitmapImageFileTypePNG is 4.
         (data (objc:invoke rep "representationUsingType:properties:"
                            4 (objc:invoke "NSDictionary" "dictionary"))))
    (when (cffi:null-pointer-p (objc:objc-object-pointer data))
      (error "Could not encode the thumbnail as a PNG."))
    (ns-data-to-bytes data)))

(defun write-thumbnail (path destination &rest options)
  "Thumbnail PATH and write the PNG to DESTINATION, returning DESTINATION."
  (let ((bytes (apply #'thumbnail path options)))
    (with-open-file (out destination :direction :output
                                     :element-type '(unsigned-byte 8)
                                     :if-exists :supersede)
      (write-sequence bytes out))
    destination))

;;; A worked example ------------------------------------------------------------------

(defun test-thumbnail ()
  "Thumbnail a PDF this example generates, and check what came back is an image.

    (objc/examples:test-thumbnail)
    => (:PNG T :PIXELS (185 256) :FITS-THE-BOX T :FROM-TEXT-FILE T)

The PDF is written by TEXT-PDF, so this needs nothing on disk.  :PIXELS is read
out of the PNG header rather than trusted.

Note what SIZE means, because the obvious reading is wrong: it is a bounding
BOX, not the size of the result.  A portrait page asked to fit 256 comes back
185 wide and 256 tall, aspect preserved -- so the assertion is that the larger
side is what was asked for and neither side exceeds it, which is the property
that actually holds."
  (ensure-thumbnailing)
  (uiop:with-temporary-file (:pathname pdf :type "pdf")
    (text-pdf "A page to make a picture of." pdf)
    (let* ((bytes (thumbnail pdf :size 256))
           (pixels (png-dimensions bytes))
           (text-file-worked
             (uiop:with-temporary-file (:pathname text :type "txt" :stream out)
               (write-string "plain text has a thumbnail too" out)
               :close-stream
               (png-p (thumbnail text :size 128)))))
      (list :png (png-p bytes)
            :pixels pixels
            :fits-the-box (and (= 256 (reduce #'max pixels))
                               (<= (reduce #'min pixels) 256))
            :from-text-file text-file-worked))))

(defun png-dimensions (bytes)
  "The (WIDTH HEIGHT) in a PNG's IHDR, which begins at byte 16."
  (flet ((word (at) (+ (ash (aref bytes at) 24) (ash (aref bytes (+ at 1)) 16)
                       (ash (aref bytes (+ at 2)) 8) (aref bytes (+ at 3)))))
    (list (word 16) (word 20))))

(defun report-thumbnail (path &optional (destination "/tmp/objc-thumbnail.png"))
  "Thumbnail PATH, write it, and say what happened."
  (let ((bytes (thumbnail path)))
    (with-open-file (out destination :direction :output
                                     :element-type '(unsigned-byte 8)
                                     :if-exists :supersede)
      (write-sequence bytes out))
    (format t "~&~A -> ~A (~{~Dx~D~}, ~D bytes)~%"
            path destination (png-dimensions bytes) (length bytes))
    destination))
