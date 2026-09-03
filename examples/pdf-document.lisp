;;;; examples/pdf-document.lisp -- making and reading PDFs, headless.
;;;;
;;;; pdf-view.lisp is the manual's PDFKit example: a PDFView in a window.  This
;;;; is the other half of the framework, the half with no window in it --
;;;; PDFDocument reads a file, counts its pages and hands back their text, and
;;;; none of that needs a display.  Extracting the text of a PDF from a REPL is a
;;;; small thing to be able to do and a tedious thing to write yourself.
;;;;
;;;; It is self-contained, which for a document format took some arranging: the
;;;; example WRITES the PDF it then reads.  Any NSView can render itself to PDF
;;;; data with -dataWithPDFInsideRect:, so an offscreen NSTextView holding a
;;;; string is a PDF with real text in it -- not an image of text, which is why
;;;; PDFDocument's -string gets the words back rather than nothing.  Measured
;;;; round trip, no window server, no assets.

(in-package #:objc/examples)

(defparameter +pdfkit-frameworks+
  '("/System/Library/Frameworks/AppKit.framework/AppKit"
    "/System/Library/Frameworks/PDFKit.framework/PDFKit"))

(defun ensure-pdfkit ()
  (objc:ensure-objc-initialized :modules +pdfkit-frameworks+))

;;; Writing ----------------------------------------------------------------------

(defun text-pdf (string path &key (width 468) (height 648) (font-size 14))
  "Render STRING to a PDF at PATH, and return PATH.

An offscreen NSTextView rendered with -dataWithPDFInsideRect:.  Every NSView can
do this, which makes it the shortest route from anything drawable to a PDF --
and unlike drawing an image of the text, what comes out has selectable,
searchable text in it."
  (ensure-pdfkit)
  (objc:with-autorelease-pool ()
    (let* ((frame (vector 0d0 0d0 (float width 1d0) (float height 1d0)))
           (view (objc:invoke (objc:invoke "NSTextView" "alloc")
                              "initWithFrame:" frame)))
      (objc:invoke view "setString:" string)
      (objc:invoke view "setFont:" (objc:invoke "NSFont" "systemFontOfSize:"
                                                (float font-size 1d0)))
      (let ((data (objc:invoke view "dataWithPDFInsideRect:" frame)))
        (unless (objc:invoke-bool data "writeToFile:atomically:" (namestring path) 1)
          (error "Could not write a PDF to ~A." path))
        path))))

;;; Reading ----------------------------------------------------------------------

(defun pdf-document (source)
  "A PDFDocument from a pathname, a namestring, or a vector of PDF bytes."
  (ensure-pdfkit)
  (let ((document
          (etypecase source
            ((or pathname string)
             (let ((file (or (uiop:truename* source)
                             (error "No such PDF: ~A" source))))
               (objc:invoke (objc:invoke "PDFDocument" "alloc") "initWithURL:"
                            (objc:invoke "NSURL" "fileURLWithPath:" (namestring file)))))
            (vector
             (cffi:with-foreign-object (bytes :uint8 (max 1 (length source)))
               (dotimes (i (length source))
                 (setf (cffi:mem-aref bytes :uint8 i) (aref source i)))
               (objc:invoke (objc:invoke "PDFDocument" "alloc") "initWithData:"
                            (objc:invoke "NSData" "dataWithBytes:length:"
                                         bytes (length source))))))))
    (when (cffi:null-pointer-p (objc:objc-object-pointer document))
      (error "~S is not a PDF PDFKit can open." source))
    document))

(defun pdf-text (source)
  "All of the text in a PDF, as one string.

    (pdf-text #p\"/path/to/paper.pdf\")

NIL when the PDF has no text layer at all -- a scan, for instance, which is a
picture of words rather than words.  OCR-IMAGE in vision.lisp is the answer for
those."
  (objc:with-autorelease-pool ()
    (let* ((document (pdf-document source))
           (string (objc:invoke document "string")))
      (unless (cffi:null-pointer-p (objc:objc-object-pointer string))
        (objc:ns-string-to-string string)))))

(defun pdf-page-count (source)
  (objc:with-autorelease-pool ()
    (objc:invoke (pdf-document source) "pageCount")))

(defun pdf-page-text (source index)
  "The text of one page, counting from zero."
  (objc:with-autorelease-pool ()
    (let* ((document (pdf-document source))
           (count (objc:invoke document "pageCount")))
      (unless (< -1 index count)
        (error "Page ~D is outside this ~D-page document." index count))
      (let ((string (objc:invoke (objc:invoke document "pageAtIndex:" index) "string")))
        (unless (cffi:null-pointer-p (objc:objc-object-pointer string))
          (objc:ns-string-to-string string))))))

;;; A worked example ---------------------------------------------------------------

(defun test-pdf-document ()
  "Write a PDF, read it back, and check the words survived.

    (objc/examples:test-pdf-document)
    => (:PAGES 1 :TEXT-FOUND T :PAGE-TEXT-MATCHES T :BYTES-ROUND-TRIP T)

:TEXT-FOUND is the assertion that says the PDF has a text layer rather than a
picture: an image of the same words would give a PDF of about the same size that
-string reads as nothing."
  (ensure-pdfkit)
  (let ((sentence "Ada Lovelace wrote the first algorithm in 1843."))
    (uiop:with-temporary-file (:pathname path :type "pdf")
      (text-pdf sentence path)
      (let* ((text (pdf-text path))
             (page (pdf-page-text path 0))
             (bytes (with-open-file (in path :element-type '(unsigned-byte 8))
                      (let ((buffer (make-array (file-length in)
                                                :element-type '(unsigned-byte 8))))
                        (read-sequence buffer in)
                        buffer))))
        (list :pages (pdf-page-count path)
              :text-found (and text (search "Ada Lovelace" text) t)
              :page-text-matches (and page (string= (string-trim '(#\Newline #\Space) page)
                                                    sentence))
              :bytes-round-trip (let ((from-bytes (pdf-text bytes)))
                                  (and from-bytes
                                       (search "Ada Lovelace" from-bytes) t)))))))

(defun report-pdf-document (&optional source)
  "Print what a PDF contains.  With no argument, writes one first."
  (if source
      (format t "~&~A~%  ~D page~:P~%  ~A~%" source (pdf-page-count source)
              (let ((text (pdf-text source)))
                (if text
                    (format nil "~D characters of text" (length text))
                    "no text layer -- try OCR-IMAGE")))
      (let ((result (test-pdf-document)))
        (format t "~&wrote and read back a ~D-page PDF~%" (getf result :pages))
        (format t "text layer present: ~A~%" (getf result :text-found))
        (format t "page text matched exactly: ~A~%" (getf result :page-text-matches))
        result)))
