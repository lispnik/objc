;;;; examples/workspace.lisp -- NSWorkspace: what is running, and what opens what.
;;;;
;;;; NSWorkspace is the seam between a program and the desktop around it: which
;;;; applications are running, which one would open a given file, where an
;;;; application lives, and -- the side-effectful half -- opening a URL or
;;;; revealing a file in Finder.
;;;;
;;;; The smallest example here, and included because it is the one whose answers
;;;; are immediately useful from a REPL rather than illustrative.  It needs no
;;;; window server: -runningApplications and -URLForApplicationToOpenContentType:
;;;; are queries against launch services, not the display.
;;;;
;;;; THE READ-ONLY HALF IS TESTED AND THE OTHER HALF IS NOT, deliberately.
;;;; OPEN-URL and REVEAL-IN-FINDER do something to the machine the tests are
;;;; running on -- they bring an application forward, steal focus, and on a CI
;;;; runner would do so invisibly.  They are here because they are the useful
;;;; part, and TEST-WORKSPACE does not call them, which is a distinction worth
;;;; making explicit rather than leaving to whoever reads the coverage.
;;;;
;;;; A PLAIN COMMAND-LINE PROCESS IS NOT AN APPLICATION, and finding that out
;;;; cost a bad test.  -runningApplications lists applications in launch
;;;; services' sense, and an `sbcl' started from a shell is not one: it does not
;;;; appear in its own list.  Ask Quick Look for a thumbnail first and it does --
;;;; that call registers the process on the way past.  Measured: NIL alone, T
;;;; after a THUMBNAIL, six runs each way.
;;;;
;;;; The first version of TEST-WORKSPACE asserted that this process was listed,
;;;; and passed -- because the thumbnail test happened to run earlier in the same
;;;; image.  An assertion that depends on which other test ran first is worse
;;;; than no assertion, so SELF-LISTED is now reported and not asserted, and what
;;;; is asserted is what holds whatever else has happened.

(in-package #:objc/examples)

(defun ensure-workspace ()
  (objc:ensure-objc-initialized
   :modules '("/System/Library/Frameworks/AppKit.framework/AppKit")))

(defun workspace ()
  (ensure-workspace)
  (objc:invoke "NSWorkspace" "sharedWorkspace"))

;;; What is running -------------------------------------------------------------------

(defun running-applications ()
  "Every running application, as plists.

    (running-applications)
    => ((:NAME \"Emacs\" :BUNDLE-IDENTIFIER \"org.gnu.Emacs\" :PID 4211 :ACTIVE NIL)
        ...)

Includes background and agent processes, which is most of the list -- Finder and
the window server are applications too."
  (objc:with-autorelease-pool ()
    (let ((applications (objc:invoke (workspace) "runningApplications")))
      (loop for i below (objc:invoke applications "count")
            for application = (objc:invoke applications "objectAtIndex:" i)
            collect (application-plist application)))))

(defun application-plist (application)
  (flet ((string-or-nil (selector)
           (let ((value (objc:invoke application selector)))
             (unless (cffi:null-pointer-p (objc:objc-object-pointer value))
               (objc:ns-string-to-string value)))))
    (list :name (string-or-nil "localizedName")
          :bundle-identifier (string-or-nil "bundleIdentifier")
          :pid (objc:invoke application "processIdentifier")
          :active (objc:invoke-bool application "isActive"))))

(defun frontmost-application ()
  "The application the user is in, as a plist, or NIL if there is not one."
  (objc:with-autorelease-pool ()
    (let ((application (objc:invoke (workspace) "frontmostApplication")))
      (unless (cffi:null-pointer-p (objc:objc-object-pointer application))
        (application-plist application)))))

(defun application-named (bundle-identifier)
  "Where the application with BUNDLE-IDENTIFIER lives, as a pathname, or NIL.

    (application-named \"com.apple.Safari\")   ;; => #P\"/Applications/Safari.app/\"

Asks launch services rather than looking in /Applications, so it finds an
application wherever it actually is."
  (objc:with-autorelease-pool ()
    (let ((url (objc:invoke (workspace) "URLForApplicationWithBundleIdentifier:"
                            bundle-identifier)))
      (unless (cffi:null-pointer-p (objc:objc-object-pointer url))
        (pathname (objc:invoke-into 'string url "path"))))))

(defun application-for-file (path)
  "The application that would open PATH, as a pathname, or NIL."
  (objc:with-autorelease-pool ()
    (let* ((file (or (uiop:truename* path) (error "No such file: ~A" path)))
           (url (objc:invoke (workspace) "URLForApplicationToOpenURL:"
                             (objc:invoke "NSURL" "fileURLWithPath:"
                                          (namestring file)))))
      (unless (cffi:null-pointer-p (objc:objc-object-pointer url))
        (pathname (objc:invoke-into 'string url "path"))))))

;;; Doing something ---------------------------------------------------------------------
;;;
;;; Not exercised by the tests; see the note at the top of the file.

(defun open-url (url)
  "Open URL in whatever handles it, and return true if that worked.

    (open-url \"https://sbcl.org/\")
    (open-url #p\"/etc/hosts\")

Brings another application forward, so it is a poor thing to call from a test."
  (objc:with-autorelease-pool ()
    (objc:invoke-bool (workspace) "openURL:"
                      (etypecase url
                        (pathname (objc:invoke "NSURL" "fileURLWithPath:"
                                               (namestring (truename url))))
                        (string (if (probe-file url)
                                    (objc:invoke "NSURL" "fileURLWithPath:"
                                                 (namestring (truename url)))
                                    (objc:invoke "NSURL" "URLWithString:" url)))
                        (t url)))))

(defun reveal-in-finder (&rest paths)
  "Show PATHS selected in Finder."
  (objc:with-autorelease-pool ()
    (objc:invoke (workspace) "activateFileViewerSelectingURLs:"
                 (map 'vector
                      (lambda (path)
                        (objc:invoke "NSURL" "fileURLWithPath:"
                                     (namestring (truename path))))
                      paths))))

;;; A worked example ----------------------------------------------------------------------

(defun test-workspace ()
  "Query the desktop and return a plist.  Nothing here changes anything.

    (objc/examples:test-workspace)
    => (:RUNNING 139 :WELL-FORMED T :FINDER-PATH #P\"/System/.../Finder.app\"
        :OPENS-TEXT T :SELF-LISTED NIL :FINDER-RUNNING T)

The first four are asserted.  They are launch-services questions and hold
whatever else is going on: an application registered to open a .txt exists on
every Mac, and every entry in the running list has a real process id.

The last two are REPORTED AND NOT ASSERTED, and the difference is the point.
:SELF-LISTED depends on whether this process has been registered as an
application, which a plain sbcl has not been until something does it -- see the
header.  :FINDER-RUNNING depends on there being a logged-in session at all, which
a CI runner does not have.  Both are worth printing and neither is worth
failing on."
  (ensure-workspace)
  (let* ((applications (running-applications))
         (self (objc:invoke (objc:invoke "NSProcessInfo" "processInfo")
                            "processIdentifier")))
    (list :running (length applications)
          :well-formed (every (lambda (application)
                                (let ((pid (getf application :pid)))
                                  (and (integerp pid) (plusp pid))))
                              applications)
          :finder-path (application-named "com.apple.finder")
          :opens-text (uiop:with-temporary-file (:pathname path :type "txt" :stream out)
                        (write-string "who opens me" out)
                        :close-stream
                        (and (application-for-file path) t))
          :self-listed (and (find self applications :key (lambda (a) (getf a :pid))) t)
          :finder-running (and (find "com.apple.finder" applications
                                     :key (lambda (a) (getf a :bundle-identifier))
                                     :test #'equal)
                               t))))

(defun report-workspace ()
  "Print the foreground application and a few of the running ones."
  (let ((front (frontmost-application)))
    (format t "~&frontmost: ~A~@[ (~A)~]~%"
            (getf front :name) (getf front :bundle-identifier)))
  (let ((applications (remove nil (running-applications)
                              :key (lambda (a) (getf a :bundle-identifier)))))
    (format t "~D running applications; the first ten with bundle ids:~%"
            (length applications))
    (loop for application in (subseq applications 0 (min 10 (length applications)))
          do (format t "  ~6D  ~A~%" (getf application :pid) (getf application :name)))
    applications))
