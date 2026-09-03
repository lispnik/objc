;;;; src/package.lisp -- the OBJC and COCOA packages.
;;;;
;;;; Both packages are created here, before any code, because the type
;;;; descriptor symbols cross between them: OBJC's dispatch and type machinery
;;;; refers to COCOA:NS-RECT and friends, while COCOA is implemented in terms of
;;;; OBJC:INVOKE.  Creating both up front is what keeps that from being a load
;;;; order problem.
;;;;
;;;; The export lists are exactly the symbols documented in the LispWorks 8.1
;;;; Objective-C and Cocoa manual -- 42 in OBJC and 11 in COCOA -- and nothing
;;;; else.  Anything not on these lists is an implementation detail even when it
;;;; is useful, because a symbol exported here is a promise to LispWorks source
;;;; compatibility that the manual does not make.
;;;;
;;;; The manual has 43 OBJC reference pages, not 42: OBJC-OBJECT-POINTER gets
;;;; two, one for the reader function and one for the FLI type descriptor.  It
;;;; is one symbol wearing two hats, so it is exported once.

(defpackage #:objc
  (:use #:cl #:alexandria)
  (:export
   ;; Initialization ---------------------------------------------------------
   #:ensure-objc-initialized
   ;; Invoking ---------------------------------------------------------------
   #:invoke
   #:invoke-bool
   #:invoke-into
   #:can-invoke-p
   #:current-super
   #:alloc-init-object
   #:description
   #:trace-invoke
   #:untrace-invoke
   ;; Classes and selectors --------------------------------------------------
   #:coerce-to-objc-class
   #:objc-class-name
   #:coerce-to-selector
   #:selector-name
   #:objc-class-method-signature
   ;; FLI type descriptors ---------------------------------------------------
   ;; OBJC-OBJECT-POINTER is deliberately one symbol naming both the reader and
   ;; the "id" type; see the note above.
   #:objc-object-pointer
   #:objc-class
   #:sel
   #:objc-c-string
   #:objc-bool
   #:objc-c++-bool
   #:objc-unknown
   #:objc-at-question-mark
   ;; Memory management ------------------------------------------------------
   #:retain
   #:release
   #:autorelease
   #:retain-count
   #:make-autorelease-pool
   #:with-autorelease-pool
   ;; Strings ----------------------------------------------------------------
   #:ns-string-to-string
   #:string-to-ns-string
   ;; Defining classes, methods, types ---------------------------------------
   #:standard-objc-object
   #:define-objc-class
   #:define-objc-method
   #:define-objc-class-method
   #:define-objc-protocol
   #:define-objc-struct
   #:define-objc-typedef
   ;; Object identity and instance variables ---------------------------------
   #:objc-object-from-pointer
   #:objc-object-var-value
   #:objc-object-copied
   #:objc-object-destroyed))

(defpackage #:cocoa
  (:use #:cl #:alexandria)
  (:export
   ;; Foundation structure types ---------------------------------------------
   #:ns-point
   #:ns-size
   #:ns-rect
   #:ns-range
   ;; ...and their setters ---------------------------------------------------
   #:set-ns-point*
   #:set-ns-size*
   #:set-ns-rect*
   #:set-ns-range*
   ;; Notifications ----------------------------------------------------------
   #:add-observer
   #:remove-observer
   ;; Constants --------------------------------------------------------------
   #:ns-not-found))

;;; SBCL additions, deliberately NOT in OBJC ---------------------------------
;;;
;;; Driving the Cocoa event loop is not part of the LispWorks OBJC package --
;;; there it is CAPI's job, and CAPI does not exist here.  These are ours, so
;;; they live in their own package rather than diluting the promise that every
;;; symbol in OBJC is one the LispWorks manual documents.

(defpackage #:objc.runloop
  (:use #:cl #:objc)
  (:export
   ;; The main thread ---------------------------------------------------------
   #:main-thread-p
   #:check-main-thread
   ;; The application and its event loop ---------------------------------------
   #:shared-application
   #:set-activation-policy
   #:pump-events
   #:pump-run-loop
   #:diagnose-pump
   #:*events-dispatched*
   #:run-cocoa-application
   ;; Is there anything to draw on? --------------------------------------------
   #:window-server-p
   ;; Handing the keyboard back --------------------------------------------
   #:remember-frontmost
   #:restore-frontmost))
