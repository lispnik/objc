;;;; examples/scripting.lisp -- driving other applications: AppleScript and Scripting Bridge.
;;;;
;;;; Two ways to send Apple events from Lisp.  NSAppleScript compiles and runs
;;;; a script, and the reply is an NSAppleEventDescriptor -- a string, a number,
;;;; a list -- read out here.  Scripting Bridge goes further: SBApplication
;;;; turns an application's scripting dictionary into Objective-C objects at
;;;; run time, so `tell application "Finder"' becomes a message send, and the
;;;; result is an element array that -- being Objective-C -- answers
;;;; objc:invoke like anything else.
;;;;
;;;; PERMISSION IS THE GATE, and it is asymmetric.  A script that targets no
;;;; application runs anywhere: it is just AppleScript.  One that targets Finder
;;;; sends an Apple event across processes, which macOS gates per pair of
;;;; applications; the first attempt prompts, and a process with no session --
;;;; a CI runner -- is refused with error -1743.  So RUN-SCRIPT is tested with a
;;;; pure script, and FINDER-STARTUP-DISK is tested only when the machine lets
;;;; it through, skipping on -1743 rather than failing on a permission.

(in-package #:objc/examples)

(defun ensure-scripting ()
  (objc:ensure-objc-initialized
   :modules '("/System/Library/Frameworks/AppKit.framework/AppKit"
              "/System/Library/Frameworks/ScriptingBridge.framework/ScriptingBridge")))

;;; NSAppleScript ---------------------------------------------------------------------

(defun descriptor-value (descriptor)
  "An NSAppleEventDescriptor's value as Lisp: a string, an integer, a list of
these, or the descriptor's own description."
  (cond ((cffi:null-pointer-p descriptor) nil)
        ((plusp (objc:invoke descriptor "numberOfItems"))
         ;; A list descriptor's items are one-based.
         (loop for i from 1 to (objc:invoke descriptor "numberOfItems")
               collect (descriptor-value (objc:invoke descriptor "descriptorAtIndex:" i))))
        (t (let ((string (objc:invoke descriptor "stringValue")))
             (if (cffi:null-pointer-p string)
                 (objc:ns-string-to-string (objc:invoke descriptor "description"))
                 (let ((text (objc:ns-string-to-string string)))
                   (or (ignore-errors (let ((*read-eval* nil)) (parse-integer text))) text)))))))

(defun run-script (source)
  "Compile and run SOURCE as AppleScript.  Returns (VALUES value error-plist):
the value on success, or NIL and a plist with the error number and message."
  (ensure-scripting)
  (objc:with-autorelease-pool ()
    (let ((script (objc:invoke (objc:invoke (objc:invoke "NSAppleScript" "alloc") "initWithSource:" source)
                               "autorelease")))
      (cffi:with-foreign-object (error :pointer)
        (setf (cffi:mem-ref error :pointer) (cffi:null-pointer))
        (let ((descriptor (objc:invoke script "executeAndReturnError:" error)))
          (if (cffi:null-pointer-p descriptor)
              (let ((info (cffi:mem-ref error :pointer)))
                (values nil
                        (list :number (let ((n (objc:invoke info "objectForKey:" "NSAppleScriptErrorNumber")))
                                        (if (cffi:null-pointer-p n) nil (objc:invoke n "intValue")))
                              :message (let ((m (objc:invoke info "objectForKey:" "NSAppleScriptErrorMessage")))
                                         (if (cffi:null-pointer-p m) nil (objc:ns-string-to-string m))))))
              (values (descriptor-value descriptor) nil)))))))

(defun finder-startup-disk ()
  "The startup disk's name, asked of Finder by Apple event.  NIL and an
error plist where the machine does not permit it."
  (run-script "tell application \"Finder\" to get name of startup disk"))

;;; Scripting Bridge ----------------------------------------------------------------

(defun scriptable-application (bundle-identifier)
  "An SBApplication for BUNDLE-IDENTIFIER, or NIL if it is not installed."
  (ensure-scripting)
  (let ((application (objc:invoke "SBApplication" "applicationWithBundleIdentifier:" bundle-identifier)))
    (if (cffi:null-pointer-p application) nil application)))

(defun finder-desktop-items ()
  "The names of the items on the desktop, through Scripting Bridge: Finder's
`desktop' is an object, its `items' an element array, each with a `name'.
Every one of those is a message send made up at run time from the dictionary."
  (let ((finder (scriptable-application "com.apple.finder")))
    (when (and finder (objc:invoke-bool finder "isRunning"))
      (objc:with-autorelease-pool ()
        (let* ((desktop (objc:invoke finder "desktop"))
               (items (objc:invoke desktop "items")))
          (loop for i below (min 20 (objc:invoke items "count"))
                collect (objc:ns-string-to-string (objc:invoke (objc:invoke items "objectAtIndex:" i) "name"))))))))

(defun test-scripting ()
  "What the test reads: a pure script's answer, and whether Finder answered."
  ;; One line: a Lisp string's \n is two characters, not a newline, and
  ;; AppleScript read the first version of this as a syntax error.
  (multiple-value-bind (pure pure-error) (run-script "6 * 7")
    (multiple-value-bind (disk disk-error) (finder-startup-disk)
      (list :pure pure :pure-error pure-error
            :disk disk :disk-error disk-error
            :permitted (and disk t)))))
