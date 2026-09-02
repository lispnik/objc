;;;; examples/area-calculator.lisp
;;;;
;;;; Ported from LispWorks' examples/objc/area-calculator/.
;;;;
;;;; The AREA-CONTROLLER class and its compute: method are unchanged from the
;;;; original -- they are the interesting half, and they are the manual's
;;;; worked example of :OBJC-INSTANCE-VARS and OBJC-OBJECT-VAR-VALUE.
;;;;
;;;; What could not be ported is the nib.  The original loads one with
;;;; -[NSWindowController initWithWindowNibPath:owner:], and the shipped nib is
;;;; a decade-old keyed archive.  BUILD-AREA-CALCULATOR constructs the same
;;;; interface in code and then does the one thing the nib was there to do:
;;;; write the three text fields into the controller's instance variables and
;;;; point the button's action at the Lisp method.  That exercises exactly what
;;;; the example is about.

(in-package #:objc/examples)

(objc:define-objc-class area-controller ()
  ()
  (:objc-class-name "AreaController")
  (:objc-instance-vars
   ("widthField" objc:objc-object-pointer)
   ("heightField" objc:objc-object-pointer)
   ("areaField" objc:objc-object-pointer)))

(defun compute-area (width height)
  (* width height))

(objc:define-objc-method ("compute:" :void)
    ((this area-controller)
     (sender objc:objc-object-pointer))
  (declare (ignore sender))
  (let* ((width
          (objc:invoke (objc:objc-object-var-value this "widthField")
                       "floatValue"))
         (height
          (objc:invoke (objc:objc-object-var-value this "heightField")
                       "floatValue"))
         (total (compute-area width height)))
    (objc:invoke (objc:objc-object-var-value this "areaField")
                 "setFloatValue:"
                 total)))

(defun build-area-calculator ()
  "Build the controller and its window.  Returns (VALUES CONTROLLER WINDOW).

The nib's job, done in code: make the fields, store them in the controller's
instance variables, and wire the button to -compute:."
  (let* ((controller (make-instance 'area-controller))
         (window (make-window :title "Area Calculator"
                              :rect #(300d0 300d0 320d0 160d0)))
         (width (make-text-field #(110d0 110d0 180d0 24d0) :text "6"))
         (height (make-text-field #(110d0 78d0 180d0 24d0) :text "7"))
         (area (make-text-field #(110d0 46d0 180d0 24d0) :text "0")))
    (add-subview window (make-label "Width:" #(20d0 112d0 80d0 20d0)))
    (add-subview window (make-label "Height:" #(20d0 80d0 80d0 20d0)))
    (add-subview window (make-label "Area:" #(20d0 48d0 80d0 20d0)))
    (add-subview window width)
    (add-subview window height)
    (add-subview window area)
    (setf (objc:objc-object-var-value controller "widthField") width
          (objc:objc-object-var-value controller "heightField") height
          (objc:objc-object-var-value controller "areaField") area)
    (add-subview window
                 (make-button "Compute" #(110d0 10d0 100d0 28d0)
                              :target (objc:objc-object-pointer controller)
                              :action "compute:"))
    (values controller window)))

(defun test-area-calculator ()
  "Show the area calculator.  Returns (VALUES WINDOW CONTROLLER).

The window comes first in every demo here so that RUN-UNTIL-CLOSED can be
wrapped straight around the call."
  (multiple-value-bind (controller window) (build-area-calculator)
    (show-window window)
    (values window controller)))
