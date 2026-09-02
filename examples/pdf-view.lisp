;;;; examples/pdf-view.lisp
;;;;
;;;; Ported from LispWorks' examples/objc/pdf-view.lisp.  PDFKit is current, so
;;;; every objc: form below is unchanged from the original -- including the
;;;; -[NSURL fileURLWithPath:isDirectory:] chain and the AUTORELEASE around the
;;;; PDFDocument.  Only CAPI:COCOA-VIEW-PANE became an NSWindow with a PDFView
;;;; in it, and CAPI:PROMPT-FOR-FILE became NSOpenPanel.

(in-package #:objc/examples)

(defconstant +pdf-display-single-page-continuous+ 1)

(defun init-pdf-kit-test-pane (view)
  (let ((view (objc:invoke view "init")))
    (objc:invoke view "setDisplayMode:" +pdf-display-single-page-continuous+)
    (objc:invoke view "setAutoScales:" t)
    (objc:invoke view "setBackgroundColor:"
                 (objc:invoke "NSColor" "whiteColor"))
    view))

(defun set-pdf-kit-test-file (pdf-view filename)
  "Load FILENAME into PDF-VIEW.  Unchanged from the original."
  (let ((pdf-document (objc:autorelease
                       (objc:invoke (objc:invoke "PDFDocument" "alloc")
                                    "initWithURL:"
                                    (objc:invoke "NSURL" "fileURLWithPath:isDirectory:"
                                                 (namestring filename)
                                                 nil)))))
    (objc:invoke pdf-view "setDocument:" pdf-document)
    pdf-document))

(defun make-pdf-view (rect)
  (objc::register-module "/System/Library/Frameworks/Quartz.framework/Quartz"
                         :errorp nil)
  (let ((view (make-view "PDFView" rect :init-function #'init-pdf-kit-test-pane)))
    (objc:invoke view "setFrame:" rect)
    view))

(defun test-pdf-kit (&optional filename)
  "Show a PDF view, loading FILENAME if given."
  (let* ((window (make-window :title "PDF View" :rect #(240d0 240d0 700d0 560d0)))
         (view (make-pdf-view #(0d0 0d0 700d0 560d0))))
    (add-subview window view)
    (when filename
      (set-pdf-kit-test-file view filename))
    (show-window window)
    (values window view)))
