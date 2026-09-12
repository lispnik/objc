;;;; notes-app.asd -- a document-based Mac application, in Lisp, as a bundle.
;;;;
;;;; Build it with asdf-macos-app:
;;;;
;;;;     (asdf:make "notes-app")        ; => examples/notes-app/build/Lisp Notes.app
;;;;
;;;; The signing identity comes from the environment so that a clone still
;;;; builds: MACOS_SIGNING_IDENTITY names a Developer ID certificate, and
;;;; unset it is signed ad hoc, which runs here and nowhere else.

(defsystem "notes-app"
  :defsystem-depends-on ("asdf-macos-app")
  :class :macos-app-system
  :build-operation "macos-app-op"
  :entry-point "notes-app:main"
  :description "An NSDocument-based text editor whose every class is Lisp."
  :version "1.0.0"
  :depends-on ("objc")
  :components ((:file "notes"))

  :bundle-identifier "org.lispnik.objc.notes"
  :bundle-name "Lisp Notes"
  :bundle-executable "notes-app"
  :bundle-principal-class "NSApplication"
  :bundle-category "public.app-category.productivity"
  :bundle-output-directory #.(merge-pathnames "build/" (uiop:pathname-directory-pathname
                                                        (or *load-truename* *default-pathname-defaults*)))
  ;; What makes it a document app to the system: Finder offers it for text
  ;; files, and NSDocumentController knows which class to make for one.
  :bundle-document-types ((:dict ("CFBundleTypeName" . "Plain Text")
                                 ("LSItemContentTypes" . (:array "public.plain-text"))
                                 ("CFBundleTypeRole" . "Editor")
                                 ("LSHandlerRank" . "Alternate")
                                 ("NSDocumentClass" . "LispNotesDocument")))
  :code-signing-identity #.(or (uiop:getenv "MACOS_SIGNING_IDENTITY") "-"))
