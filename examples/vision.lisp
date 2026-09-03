;;;; examples/vision.lisp -- optical character recognition with the Vision
;;;; framework, driven from Lisp.
;;;;
;;;; Like the canvas, this is not in the LispWorks manual; it is here to show
;;;; the bindings reaching a modern macOS framework:
;;;;
;;;;   -[VNImageRequestHandler performRequests:error:] is SYNCHRONOUS.  It runs
;;;;   the request and the request holds its results when the call returns, so
;;;;   no Objective-C block is needed.  The completion-handler face of Vision is
;;;;   reachable too, with MAKE-OBJC-BLOCK, but a request that has already
;;;;   finished is the shorter road to the same results.
;;;;
;;;;   Each recognised line's bounding box comes back as a CGRect passed BY
;;;;   VALUE, which the bridge converts to #(x y width height) -- the same
;;;;   struct-return path as the canvas, from a framework this time rather than
;;;;   a Lisp-defined method.

(in-package #:objc/examples)

(defparameter +vision-framework+
  "/System/Library/Frameworks/Vision.framework/Versions/A/Vision"
  "Vision is not one of the frameworks ENSURE-OBJC-INITIALIZED loads by
default, so OCR-IMAGE names it explicitly.")

(defun %ns-string-constant (name)
  "The NSString* value of an exported Objective-C string constant.

Keys like NSFontAttributeName are `extern NSString * const' -- a symbol whose
value is the pointer.  CFFI:FOREIGN-SYMBOL-POINTER gives the symbol's address;
one dereference gives the NSString the rest of AppKit compares against."
  (let ((symbol (cffi:foreign-symbol-pointer name)))
    (unless symbol
      (error "Objective-C string constant ~A is not available." name))
    (cffi:mem-ref symbol :pointer)))

;;; Rendering text to an image ------------------------------------------------

(defun text-image (string path &key (font-size 56) (padding 24))
  "Draw STRING as black text on white and write it to PATH as a PNG; return the
namestring of PATH.

A small utility, mostly so OCR-IMAGE has something to read without a fixture in
the repository -- but it also shows offscreen drawing through an NSImage and
the exported-constant dance the attributed-string API needs.  The image is
sized to the text with -sizeWithAttributes:, an NSSize returned by value."
  (objc:ensure-objc-initialized)
  (let* ((font (objc:invoke "NSFont" "boldSystemFontOfSize:"
                            (coerce font-size 'double-float)))
         (attributes (objc:invoke "NSMutableDictionary" "dictionary"))
         (text (objc:invoke "NSString" "stringWithUTF8String:" string)))
    (objc:invoke attributes "setObject:forKey:" font
                 (%ns-string-constant "NSFontAttributeName"))
    (let* ((measured (objc:invoke text "sizeWithAttributes:" attributes)) ; NSSize -> #(w h)
           (width (+ (* 2 padding) (ceiling (aref measured 0))))
           (height (+ (* 2 padding) (ceiling (aref measured 1))))
           (image (objc:invoke (objc:invoke "NSImage" "alloc")
                               "initWithSize:" (vector width height))))
      (objc:invoke image "lockFocus")
      (objc:invoke (objc:invoke "NSColor" "whiteColor") "set")
      (objc:invoke (objc:invoke "NSBezierPath" "bezierPathWithRect:"
                                (vector 0 0 width height)) "fill")
      (objc:invoke text "drawAtPoint:withAttributes:" (vector padding padding) attributes)
      (objc:invoke image "unlockFocus")
      (let* ((tiff (objc:invoke image "TIFFRepresentation"))
             (rep (objc:invoke "NSBitmapImageRep" "imageRepWithData:" tiff))
             (png (objc:invoke rep "representationUsingType:properties:"
                               4 (objc:invoke "NSDictionary" "dictionary")))) ; 4 = PNG
        (objc:invoke png "writeToFile:atomically:" (namestring path) nil))
      (namestring path))))

;;; Recognising text ----------------------------------------------------------

(defun ocr-image (path &key (level :accurate) languages)
  "Recognise text in the image at PATH with the Vision framework.

Returns one plist per line found:

    (:text STRING :confidence FLOAT :bounding-box #(x y width height))

The box is normalised to 0..1 with its origin at the BOTTOM-left, Vision's
convention -- multiply by the image's width and height to place it.

LEVEL is :ACCURATE (default) or :FAST.  LANGUAGES, if given, is a list of BCP-47
codes such as (\"en-US\") to bias recognition.

No block anywhere: -performRequests:error: runs synchronously and the request
carries its -results when it returns."
  (objc:ensure-objc-initialized :modules (list +vision-framework+))
  (let* ((file (or (uiop:truename* path)
                   (error "No such file to recognise: ~A" path)))
         (url (objc:invoke "NSURL" "fileURLWithPath:" (namestring file)))
         (handler (objc:invoke (objc:invoke "VNImageRequestHandler" "alloc")
                               "initWithURL:options:" url
                               (objc:invoke "NSDictionary" "dictionary")))
         (request (objc:invoke (objc:invoke "VNRecognizeTextRequest" "alloc") "init")))
    (objc:invoke request "setRecognitionLevel:" (ecase level (:accurate 0) (:fast 1)))
    (when languages
      (objc:invoke request "setRecognitionLanguages:" (coerce languages 'vector)))
    ;; A vector of requests becomes the NSArray the parameter wants; the error
    ;; out-parameter is left NULL, and a NIL return is turned into a condition.
    (unless (objc:invoke handler "performRequests:error:"
                         (vector request) (cffi:null-pointer))
      (error "Vision could not process ~A." path))
    (let* ((results (objc:invoke request "results"))
           (count (objc:invoke results "count")))
      (loop for i below count
            for observation = (objc:invoke results "objectAtIndex:" i)
            for candidates = (objc:invoke observation "topCandidates:" 1)
            when (plusp (objc:invoke candidates "count"))
              collect (let ((candidate (objc:invoke candidates "objectAtIndex:" 0)))
                        (list :text (objc:invoke-into 'string candidate "string")
                              :confidence (objc:invoke candidate "confidence")
                              :bounding-box (objc:invoke observation "boundingBox")))))))

(defun test-ocr (&optional (string "Hello, Lisp!  42"))
  "Render STRING to a temporary image, recognise it, and return what Vision
read -- the (:text ...) plists.  The round trip in one call, for the REPL."
  (uiop:with-temporary-file (:pathname path :type "png")
    (text-image string path)
    (ocr-image path)))
