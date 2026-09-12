;;;; notes.lisp -- a document-based application: NSDocument, NSDocumentController,
;;;; a main menu, and a window per document, all defined here.
;;;;
;;;; What the document architecture gives for free, once a document class
;;;; exists: New and Open, Save and Save As with the standard panels, the
;;;; dirty dot in the close button, Autosave and Versions, Revert, the
;;;; window title with its proxy icon, Undo shared between the text view and
;;;; the document, and the file's own permission to be edited.  None of it is
;;;; written below; it is inherited.
;;;;
;;;; What has to be written: the four methods a document needs, a controller
;;;; that knows the document type without an Info.plist (so this also runs
;;;; from a REPL), and the menu, since a program with no nib has no menu bar.

(defpackage #:notes-app
  (:use #:cl)
  (:export #:main #:document #:document-text))

(in-package #:notes-app)

(defconstant +ns-utf8-string-encoding+ 4)
(defconstant +ns-window-style-mask+ 15
  "Titled, closable, miniaturizable, resizable.")
(defconstant +ns-view-width-and-height-sizable+ 18)

(defparameter +document-type+ "public.plain-text")

;;; The document -------------------------------------------------------------

(objc:define-objc-class document ()
  ((text :accessor document-text
         :documentation "The contents, until there is a text view to hold them.")
   (text-view :accessor document-text-view))
  (:objc-class-name "LispNotesDocument")
  (:objc-superclass-name "NSDocument"))

;; AppKit makes the documents -- NSDocumentController allocates and
;; initialises them -- so the Lisp object appears when the bridge first
;; sees the pointer, with its slots unbound rather than initialised.  Each
;; method starts here.
(defun ensure-document-slots (document)
  (unless (slot-boundp document 'text)
    (setf (document-text document) ""))
  (unless (slot-boundp document 'text-view)
    (setf (document-text-view document) nil))
  document)

;; Autosave in place is what turns on Versions, and the modern save
;; behaviour: no "do you want to save" on close, the document is simply kept.
(objc:define-objc-class-method ("autosavesInPlace" objc:objc-bool)
    ((self document))
  t)

(defun text-from-data (data)
  (let ((string (objc:invoke (objc:invoke "NSString" "alloc")
                             "initWithData:encoding:" data +ns-utf8-string-encoding+)))
    (if (cffi:null-pointer-p string)
        ""
        (objc:ns-string-to-string string))))

(objc:define-objc-method ("readFromData:ofType:error:" objc:objc-bool)
    ((self document) (data objc:objc-object-pointer) (type objc:objc-object-pointer)
     (error (:pointer :void)))
  (declare (ignore type error))
  (ensure-document-slots self)
  (let ((text (text-from-data data)))
    (setf (document-text self) text)
    (when (document-text-view self)
      (objc:invoke (document-text-view self) "setString:" text))
    t))

(objc:define-objc-method ("dataOfType:error:" objc:objc-object-pointer)
    ((self document) (type objc:objc-object-pointer) (error (:pointer :void)))
  (declare (ignore type error))
  (ensure-document-slots self)
  (let ((text (if (document-text-view self)
                  (objc:ns-string-to-string (objc:invoke (document-text-view self) "string"))
                  (document-text self))))
    (objc:invoke (objc:string-to-ns-string text) "dataUsingEncoding:" +ns-utf8-string-encoding+)))

(defun make-text-view (frame)
  "A scrolling NSTextView filling FRAME, with undo on: the text view then
registers every edit with the window's undo manager, which the window
controller supplies from the document -- so the document knows it is dirty,
and Undo in the Edit menu reaches back through the same manager."
  (let ((scroll (objc:invoke (objc:invoke "NSScrollView" "alloc") "initWithFrame:" frame))
        (text-view (objc:invoke (objc:invoke "NSTextView" "alloc") "initWithFrame:" frame)))
    (objc:invoke scroll "setHasVerticalScroller:" t)
    (objc:invoke scroll "setAutoresizingMask:" +ns-view-width-and-height-sizable+)
    (objc:invoke text-view "setAutoresizingMask:" +ns-view-width-and-height-sizable+)
    (objc:invoke text-view "setAllowsUndo:" t)
    (objc:invoke text-view "setRichText:" nil)
    (objc:invoke text-view "setAutomaticQuoteSubstitutionEnabled:" nil)
    (objc:invoke text-view "setFont:" (objc:invoke "NSFont" "monospacedSystemFontOfSize:weight:" 13d0 0d0))
    (objc:invoke scroll "setDocumentView:" text-view)
    (values scroll text-view)))

(objc:define-objc-method ("makeWindowControllers" :void)
    ((self document))
  ;; A window controller per document is the architecture's unit: it owns
  ;; the window, titles it after the document, and closes with it.
  (ensure-document-slots self)
  (let* ((frame (vector 0d0 0d0 640d0 480d0))
         (window (objc:invoke (objc:invoke "NSWindow" "alloc")
                              "initWithContentRect:styleMask:backing:defer:"
                              frame +ns-window-style-mask+ 2 nil)))
    (multiple-value-bind (scroll text-view) (make-text-view frame)
      (objc:invoke window "setContentView:" scroll)
      (objc:invoke window "setInitialFirstResponder:" text-view)
      (objc:invoke text-view "setString:" (document-text self))
      (setf (document-text-view self) text-view))
    (objc:invoke window "center")
    (let ((controller (objc:invoke (objc:invoke "NSWindowController" "alloc")
                                   "initWithWindow:" window)))
      (objc:invoke (objc:objc-object-pointer self) "addWindowController:" controller))))

;;; The document controller ----------------------------------------------------
;;; NSDocumentController learns document types from Info.plist.  Answering
;;; the three questions here as well is what lets the same code run from a
;;; REPL with no bundle around it, which is where it was written.

(objc:define-objc-class document-controller ()
  ()
  (:objc-class-name "LispNotesDocumentController")
  (:objc-superclass-name "NSDocumentController"))

(objc:define-objc-method ("defaultType" objc:objc-object-pointer)
    ((self document-controller))
  (objc:string-to-ns-string +document-type+))

(objc:define-objc-method ("documentClassForType:" objc:objc-object-pointer)
    ((self document-controller) (type objc:objc-object-pointer))
  (declare (ignore type))
  (objc:coerce-to-objc-class "LispNotesDocument"))

(objc:define-objc-method ("typeForContentsOfURL:error:" objc:objc-object-pointer)
    ((self document-controller) (url objc:objc-object-pointer) (error (:pointer :void)))
  (declare (ignore url error))
  (objc:string-to-ns-string +document-type+))

;;; The menu ---------------------------------------------------------------------
;;; Every item's target is nil: the responder chain finds the text view, the
;;; document, the document controller or the application, whichever answers
;;; the selector.  That is how one menu serves every window.

(defun add-item (menu title action &optional (key ""))
  (let ((item (objc:invoke (objc:invoke "NSMenuItem" "alloc")
                           "initWithTitle:action:keyEquivalent:"
                           title (objc:coerce-to-selector action) key)))
    (objc:invoke menu "addItem:" item)
    item))

(defun add-submenu (main-menu title items)
  "A top-level menu of ITEMS, each (TITLE ACTION [KEY]) or :separator."
  (let ((menu (objc:invoke (objc:invoke "NSMenu" "alloc") "initWithTitle:" title))
        (holder (objc:invoke (objc:invoke "NSMenuItem" "alloc")
                             "initWithTitle:action:keyEquivalent:" title nil "")))
    (dolist (item items)
      (if (eq item :separator)
          (objc:invoke menu "addItem:" (objc:invoke "NSMenuItem" "separatorItem"))
          (apply #'add-item menu item)))
    (objc:invoke holder "setSubmenu:" menu)
    (objc:invoke main-menu "addItem:" holder)
    menu))

(defun install-menu ()
  (let ((main (objc:invoke (objc:invoke "NSMenu" "alloc") "initWithTitle:" "Main"))
        (app (objc.runloop:shared-application)))
    (add-submenu main "Lisp Notes"
                 '(("About Lisp Notes" "orderFrontStandardAboutPanel:")
                   :separator
                   ("Hide Lisp Notes" "hide:" "h")
                   ("Quit Lisp Notes" "terminate:" "q")))
    (add-submenu main "File"
                 '(("New" "newDocument:" "n")
                   ("Open…" "openDocument:" "o")
                   :separator
                   ("Close" "performClose:" "w")
                   ("Save…" "saveDocument:" "s")
                   ("Duplicate" "duplicateDocument:" "S")
                   ("Rename…" "renameDocument:")
                   ("Revert To Saved" "revertDocumentToSaved:")))
    (add-submenu main "Edit"
                 '(("Undo" "undo:" "z")
                   ("Redo" "redo:" "Z")
                   :separator
                   ("Cut" "cut:" "x")
                   ("Copy" "copy:" "c")
                   ("Paste" "paste:" "v")
                   ("Select All" "selectAll:" "a")))
    (let ((windows (add-submenu main "Window"
                                '(("Minimize" "performMiniaturize:" "m")
                                  ("Zoom" "performZoom:")
                                  :separator
                                  ("Bring All to Front" "arrangeInFront:")))))
      (objc:invoke app "setWindowsMenu:" windows))
    (objc:invoke app "setMainMenu:" main)))

;;; The application ----------------------------------------------------------

(objc:define-objc-class application-delegate ()
  ()
  (:objc-class-name "LispNotesApplicationDelegate"))

;; A document application stays open with no windows, as TextEdit does.
(objc:define-objc-method ("applicationShouldTerminateAfterLastWindowClosed:" objc:objc-bool)
    ((self application-delegate) (application objc:objc-object-pointer))
  (declare (ignore application))
  nil)

;; Set NOTES_SNAPSHOT to a path and the front window is written there as a
;; PNG two seconds after launch, and the application quits: how this file
;; was verified from a shell.  NOTES_OPEN names a file to open first.
(objc:define-objc-method ("snapshotAndQuit:" :void)
    ((self application-delegate) (timer objc:objc-object-pointer))
  (declare (ignore timer))
  (handler-case
      (let* ((app (objc.runloop:shared-application))
             (windows (objc:invoke app "windows"))
             (documents (objc:invoke (objc:objc-object-pointer *controller*) "documents")))
        (format t "~&snapshot: ~d document~:p, ~d window~:p, key window ~a~%"
                (objc:invoke documents "count") (objc:invoke windows "count")
                (if (cffi:null-pointer-p (objc:invoke app "keyWindow")) "none" "present"))
        (finish-output)
        (let* ((window (objc:invoke windows "firstObject"))
               (view (objc:invoke window "contentView"))
             (bounds (objc:invoke view "bounds"))
             (rep (objc:invoke view "bitmapImageRepForCachingDisplayInRect:" bounds)))
        (objc:invoke view "cacheDisplayInRect:toBitmapImageRep:" bounds rep)
        (objc:invoke (objc:invoke rep "representationUsingType:properties:" 4
                                  (objc:invoke "NSDictionary" "dictionary"))
                     "writeToFile:atomically:" (uiop:getenv "NOTES_SNAPSHOT") t)))
    (error (condition)
      (format *error-output* "~&snapshot: ~a~%" condition)))
  (objc:invoke (objc.runloop:shared-application) "terminate:" nil))

(defvar *delegate* nil "Held so the delegate is not collected.")
(defvar *controller* nil "Held so the document controller is not collected.")

(defun main ()
  "The entry point, for the bundle and for a REPL alike."
  (objc:ensure-objc-initialized
   :modules '("/System/Library/Frameworks/Cocoa.framework/Versions/A/Cocoa"))
  (let ((app (objc.runloop:shared-application)))
    ;; Made before anything asks for the shared controller, which is how a
    ;; subclass becomes it.
    (setf *controller* (make-instance 'document-controller)
          *delegate* (make-instance 'application-delegate))
    (objc:invoke app "setDelegate:" (objc:objc-object-pointer *delegate*))
    (install-menu)
    (let ((open (uiop:getenv "NOTES_OPEN")))
      (when open
        (objc:invoke (objc:objc-object-pointer *controller*)
                     "openDocumentWithContentsOfURL:display:error:"
                     (objc:invoke "NSURL" "fileURLWithPath:" open) t (cffi:null-pointer))))
    (when (uiop:getenv "NOTES_SNAPSHOT")
      (objc:invoke "NSTimer" "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"
                   2d0 (objc:objc-object-pointer *delegate*)
                   (objc:coerce-to-selector "snapshotAndQuit:") nil nil))
    (objc.runloop:run-cocoa-application)))
