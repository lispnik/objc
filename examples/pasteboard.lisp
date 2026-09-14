;;;; examples/pasteboard.lisp -- the pasteboard, and drag and drop, with a Lisp type.
;;;;
;;;; NSPasteboard is how applications hand each other data: copy and paste,
;;;; and drag and drop, which is the same object with a gesture in front.  A
;;;; pasteboard carries items, each with values under types named by UTI, and
;;;; an application may define its own.  This one does: org.lispnik.objc.form,
;;;; a printed Lisp form, put alongside the plain text so that other
;;;; applications see a string and this one sees a form.
;;;;
;;;; The read-write half is tested.  The drag-and-drop half is an NSView
;;;; subclass in Lisp -- registerForDraggedTypes, draggingEntered: answering
;;;; with an operation, performDragOperation: reading the drop -- and is shown
;;;; in a window by SHOW-DROP-TARGET, which nothing in the tests opens.

(in-package #:objc/examples)

(defparameter +form-type+ "org.lispnik.objc.form"
  "Our own pasteboard type: a Lisp form, printed readably.")

(defun ensure-pasteboard ()
  (objc:ensure-objc-initialized
   :modules '("/System/Library/Frameworks/AppKit.framework/AppKit")))

(defun general-pasteboard ()
  (ensure-pasteboard)
  (objc:invoke "NSPasteboard" "generalPasteboard"))

;;; Writing and reading -------------------------------------------------------------

(defun put-form (form &key (pasteboard (general-pasteboard)))
  "FORM onto PASTEBOARD twice: as our type, readable back, and as plain text
for everyone else.  Returns the pasteboard's new change count."
  (let ((printed (let ((*print-readably* t) (*package* (find-package :cl-user)))
                   (prin1-to-string form))))
    (objc:invoke pasteboard "clearContents")
    (objc:invoke pasteboard "setString:forType:" printed +form-type+)
    (objc:invoke pasteboard "setString:forType:" printed "public.utf8-plain-text")
    (objc:invoke pasteboard "changeCount")))

(defun get-form (&key (pasteboard (general-pasteboard)))
  "The form on PASTEBOARD if it carries our type, else NIL."
  (let ((string (objc:invoke pasteboard "stringForType:" +form-type+)))
    (unless (cffi:null-pointer-p string)
      (let ((*read-eval* nil) (*package* (find-package :cl-user)))
        (read-from-string (objc:ns-string-to-string string))))))

(defun pasteboard-types (&key (pasteboard (general-pasteboard)))
  "The types the pasteboard carries now, as strings."
  (let ((types (objc:invoke pasteboard "types")))
    (if (cffi:null-pointer-p types)
        '()
        (loop for i below (objc:invoke types "count")
              collect (objc:ns-string-to-string (objc:invoke types "objectAtIndex:" i))))))

;;; Drag and drop: a view in Lisp that accepts drops -----------------------------------

(defvar *last-drop* nil "What the drop target last received.")

(objc:define-objc-class drop-target ()
  ()
  (:objc-class-name "LispDropTarget")
  (:objc-superclass-name "NSView"))

(defconstant +drag-operation-copy+ 1)
(defconstant +drag-operation-none+ 0)

(objc:define-objc-method ("draggingEntered:" (:unsigned :long-long))
    ((self drop-target) (info objc:objc-object-pointer))
  ;; Copy if the drag carries something we read; otherwise nothing.
  (let ((types (pasteboard-types :pasteboard (objc:invoke info "draggingPasteboard"))))
    (if (or (member +form-type+ types :test #'string=)
            (member "public.utf8-plain-text" types :test #'string=))
        +drag-operation-copy+
        +drag-operation-none+)))

(objc:define-objc-method ("performDragOperation:" objc:objc-bool)
    ((self drop-target) (info objc:objc-object-pointer))
  (let* ((pasteboard (objc:invoke info "draggingPasteboard"))
         (form (get-form :pasteboard pasteboard))
         (text (let ((s (objc:invoke pasteboard "stringForType:" "public.utf8-plain-text")))
                 (if (cffi:null-pointer-p s) nil (objc:ns-string-to-string s)))))
    (setf *last-drop* (or form text))
    (format t "~&dropped: ~s~%" *last-drop*)
    t))

(objc:define-objc-method ("drawRect:" :void)
    ((self drop-target) (rect cocoa:ns-rect))
  (declare (ignore rect))
  (objc:invoke (objc:invoke "NSColor" "colorWithCalibratedRed:green:blue:alpha:" 0.93 0.95 1.0 1.0) "setFill")
  (objc:invoke "NSBezierPath" "fillRect:" (objc:invoke self "bounds")))

(defun show-drop-target (&key (seconds 20))
  "A window whose view accepts drops of text or of our form type, for
SECONDS.  Drag some text from anywhere onto it and *LAST-DROP* is set.
Not called by the tests: it opens a window and waits."
  (ensure-pasteboard)
  (let* ((view (make-instance 'drop-target))
         (pointer (objc:objc-object-pointer view))
         (window (make-window :title "Drop a form here" :rect #(300 300 320 200))))
    (objc:invoke pointer "registerForDraggedTypes:" (vector +form-type+ "public.utf8-plain-text"))
    (objc:invoke pointer "setFrame:" (objc:invoke (objc:invoke window "contentView") "bounds"))
    (objc:invoke pointer "setAutoresizingMask:" 18)
    (add-subview window pointer)
    (show-window window :seconds seconds)
    (objc:invoke window "close")
    *last-drop*))

(defun test-pasteboard ()
  "Round trips through the general pasteboard, restoring what was there."
  (let* ((pasteboard (general-pasteboard))
         (before (let ((s (objc:invoke pasteboard "stringForType:" "public.utf8-plain-text")))
                   (if (cffi:null-pointer-p s) nil (objc:ns-string-to-string s))))
         (form '(defun answer () (* 6 7)))
         (count-before (objc:invoke pasteboard "changeCount"))
         (count-after (put-form form))
         (back (get-form))
         (types (pasteboard-types)))
    ;; Put back whatever the user had, if it was text.
    (objc:invoke pasteboard "clearContents")
    (when before (objc:invoke pasteboard "setString:forType:" before "public.utf8-plain-text"))
    (list :round-trip (equal form back)
          :counted (> count-after count-before)
          :own-type (and (member +form-type+ types :test #'string=) t)
          :plain-text (and (member "public.utf8-plain-text" types :test #'string=) t))))
