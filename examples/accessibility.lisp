;;;; examples/accessibility.lisp -- the Accessibility API: any app's interface, as data.
;;;;
;;;; Every window, button, menu and text field on the Mac is an AXUIElement
;;;; to a process the user has trusted, and the Accessibility API lets that
;;;; process read them and press them.  It is how screen readers work, and
;;;; how automation that does not have a scripting dictionary to lean on
;;;; works.  From a REPL it is the desktop as a tree of plists.
;;;;
;;;; The API is C, in HIServices: AXUIElementCreateApplication, then
;;;; AXUIElementCopyAttributeValue for an attribute named by a string, over
;;;; and over.  Values come back as CFTypes -- strings, arrays of elements,
;;;; more elements -- which are Foundation objects and read as such.
;;;;
;;;; TRUST IS THE GATE.  AXIsProcessTrusted says whether this process may
;;;; look; when it may not, every attribute read fails with kAXErrorAPIDisabled,
;;;; and the fix is System Settings, not code.  The test skips when untrusted,
;;;; because a suite that fails on a permission the machine's owner has not
;;;; given is measuring the owner.  FRONTMOST-INTERFACE returns a plist that
;;;; says :TRUSTED NIL in that case rather than signalling, so a REPL sees why.

(in-package #:objc/examples)

(defun ensure-accessibility ()
  (objc:ensure-objc-initialized
   :modules '("/System/Library/Frameworks/AppKit.framework/AppKit"
              "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")))

;;; The C entry points, through CFFI: no libffi, so each has a fixed signature.

(cffi:defcfun ("AXIsProcessTrusted" %ax-is-process-trusted) :bool)
(cffi:defcfun ("AXUIElementCreateApplication" %ax-application) :pointer (pid :int))
(cffi:defcfun ("AXUIElementCopyAttributeValue" %ax-copy-attribute) :int
  (element :pointer) (attribute :pointer) (value :pointer))
(cffi:defcfun ("AXUIElementPerformAction" %ax-perform) :int (element :pointer) (action :pointer))
(cffi:defcfun ("CFRelease" %cf-release) :void (object :pointer))

(defun accessibility-trusted-p ()
  "Whether this process may read other applications' interfaces."
  (ensure-accessibility)
  (%ax-is-process-trusted))

(defun ax-attribute (element name)
  "The value of attribute NAME on ELEMENT as a Foundation object, or NIL.
The caller owns a reference; RELEASE-ELEMENT it when done with an element."
  (cffi:with-foreign-object (value :pointer)
    (setf (cffi:mem-ref value :pointer) (cffi:null-pointer))
    (let ((status (%ax-copy-attribute element (objc:invoke "NSString" "stringWithString:" name) value)))
      (if (and (zerop status) (not (cffi:null-pointer-p (cffi:mem-ref value :pointer))))
          (cffi:mem-ref value :pointer)
          nil))))

(defun ax-string (element name)
  (let ((value (ax-attribute element name)))
    (when value
      (prog1 (if (objc:invoke-bool value "isKindOfClass:" (objc:invoke "NSString" "class"))
                 (objc:ns-string-to-string value)
                 (objc:ns-string-to-string (objc:invoke value "description")))
        (%cf-release value)))))

(defun ax-children (element)
  "ELEMENT's AXChildren as a list; the caller releases the array's elements
by releasing the array, so they are copied out as retained references."
  (let ((array (ax-attribute element "AXChildren")))
    (when array
      (prog1 (loop for i below (objc:invoke array "count")
                   collect (objc:invoke (objc:invoke array "objectAtIndex:" i) "retain"))
        (%cf-release array)))))

(defun element-plist (element &key (depth 2))
  "ELEMENT as (:role ... :title ... :children (...)), to DEPTH."
  (let ((plist (list :role (ax-string element "AXRole")
                     :subrole (ax-string element "AXSubrole")
                     :title (ax-string element "AXTitle")
                     :value (let ((v (ax-string element "AXValue")))
                              (and v (subseq v 0 (min 60 (length v))))))))
    (if (plusp depth)
        (let ((children (ax-children element)))
          (prog1 (append plist (list :children (mapcar (lambda (child) (element-plist child :depth (1- depth))) children)))
            (mapc #'%cf-release children)))
        plist)))

(defun frontmost-interface (&key (depth 2))
  "The frontmost application's windows as a tree of plists, or :TRUSTED NIL.

    (frontmost-interface)
    => (:TRUSTED T :APPLICATION \"Safari\" :PID 812
        :WINDOWS ((:ROLE \"AXWindow\" :TITLE \"Apple\" :CHILDREN (...)) ...))"
  (ensure-accessibility)
  (if (not (%ax-is-process-trusted))
      (list :trusted nil :why "System Settings > Privacy & Security > Accessibility")
      (objc:with-autorelease-pool ()
        (let* ((front (objc:invoke (objc:invoke "NSWorkspace" "sharedWorkspace") "frontmostApplication"))
               (pid (objc:invoke front "processIdentifier"))
               (name (objc:ns-string-to-string (objc:invoke front "localizedName")))
               (application (%ax-application pid))
               (windows (let ((array (ax-attribute application "AXWindows")))
                          (when array
                            (prog1 (loop for i below (objc:invoke array "count")
                                         collect (element-plist (objc:invoke array "objectAtIndex:" i) :depth depth))
                              (%cf-release array))))))
          (%cf-release application)
          (list :trusted t :application name :pid pid :windows windows)))))

(defun press-first-button (&key (application-name nil))
  "Find the first AXButton in the frontmost application's first window and
press it.  The side-effectful half; nothing in the tests calls it."
  (declare (ignore application-name))
  (ensure-accessibility)
  (unless (%ax-is-process-trusted) (error "this process is not trusted for accessibility"))
  (let* ((front (objc:invoke (objc:invoke "NSWorkspace" "sharedWorkspace") "frontmostApplication"))
         (application (%ax-application (objc:invoke front "processIdentifier")))
         (windows (ax-children application)))
    (labels ((find-button (element)
               (if (equal (ax-string element "AXRole") "AXButton")
                   element
                   (some #'find-button (ax-children element)))))
      (let ((button (some #'find-button windows)))
        (when button
          (prog1 (ax-string button "AXTitle")
            (%ax-perform button (objc:invoke "NSString" "stringWithString:" "AXPress"))))))))

(defun test-accessibility ()
  "What the test reads: whether trusted, and if so the frontmost app's tree."
  (let ((result (frontmost-interface :depth 1)))
    (list :trusted (getf result :trusted)
          :application (getf result :application)
          :windows (length (getf result :windows))
          :roles (remove-duplicates
                  (loop for window in (getf result :windows)
                        append (loop for child in (getf window :children) collect (getf child :role)))
                  :test #'equal))))
