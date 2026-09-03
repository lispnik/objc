;;;; src/conditions.lisp -- the internal condition hierarchy.
;;;;
;;;; None of these are exported.  The LispWorks manual documents no condition
;;;; types at all, and reverse engineering the 8.1 image confirms it has none:
;;;; every failure is signalled with a plain CL:ERROR and a format string, so
;;;; the conditions that reach LispWorks code are SIMPLE-ERRORs.  Exporting a
;;;; condition class here would be inventing API the manual does not promise.
;;;;
;;;; We still want structured conditions internally -- a REPL session debugging
;;;; a bad type encoding wants the encoding and the offset, not a string -- so
;;;; they exist, they subclass ERROR, and their reports are worded to match the
;;;; LispWorks messages where LispWorks has one.  Callers should handle ERROR.

(in-package #:objc)

(define-condition objc-error (error) ()
  (:documentation
   "Root of the errors this library signals.  Not exported: see the file header."))

(define-condition library-not-found (objc-error)
  ((name :initarg :name :reader library-not-found-name)
   (candidates :initarg :candidates :reader library-not-found-candidates))
  (:report
   (lambda (condition stream)
     (format stream "Cannot load the ~A library.~@[  Tried: ~{~A~^, ~}.~]"
             (library-not-found-name condition)
             (library-not-found-candidates condition))))
  (:documentation
   "Signalled when a foreign library will not open.  CANDIDATES is the exact
list of names that were tried, in order, so the message names what to install
rather than merely reporting that something is missing."))

(define-condition no-such-class (objc-error)
  ((name :initarg :name :reader no-such-class-name))
  (:report
   (lambda (condition stream)
     ;; LispWorks: "Cannot find class ~S."
     (format stream "Cannot find class ~S." (no-such-class-name condition))))
  (:documentation "Signalled when a class name does not name a registered Objective-C class."))

(defun format-objc-pointer (object)
  "Print a pointer the way LispWorks prints one, so an error message from this
library reads like the one a porting user already knows:

  #<Pointer: OBJC:OBJC-OBJECT-POINTER = #x00000008679CF880>

CFFI pointers are system area pointers on SBCL, which otherwise print as
#.(SB-SYS:INT-SAP #X...) and make the message needlessly unfamiliar."
  (if (cffi:pointerp object)
      (format nil "#<Pointer: OBJC:OBJC-OBJECT-POINTER = #x~16,'0X>"
              (cffi:pointer-address object))
      (format nil "~S" object)))

(define-condition no-such-method (objc-error)
  ((selector :initarg :selector :reader no-such-method-selector)
   (receiver :initarg :receiver :initform nil :reader no-such-method-receiver)
   (class-name :initarg :class-name :initform nil :reader no-such-method-class-name)
   (superclass-name :initarg :superclass-name :initform nil
                    :reader no-such-method-superclass-name))
  (:report
   (lambda (condition stream)
     ;; Worded as LispWorks words it, because this is the error a porting user
     ;; is most likely to hit and most likely to grep for.
     (if (no-such-method-superclass-name condition)
         (format stream "No method ~S in superclass ~S for object ~A, class ~S."
                 (no-such-method-selector condition)
                 (no-such-method-superclass-name condition)
                 (format-objc-pointer (no-such-method-receiver condition))
                 (no-such-method-class-name condition))
         (format stream "No method ~S for object ~A, class ~S."
                 (no-such-method-selector condition)
                 (format-objc-pointer (no-such-method-receiver condition))
                 (no-such-method-class-name condition)))))
  (:documentation
   "Signalled when a selector is not implemented by the receiver's class.

This is the condition that makes the bridge survivable.  Dispatch resolves the
Method and its type encoding in order to build the call signature, so a missing
method fails here, in Lisp, before any message is sent -- which is also what
LispWorks does.  If the send happened anyway the runtime would raise an
Objective-C exception, and an NSException unwinding through Lisp frames takes
the whole process down."))

(define-condition unsupported-type-encoding (objc-error)
  ((encoding :initarg :encoding :reader unsupported-type-encoding-encoding)
   (position :initarg :position :initform nil
             :reader unsupported-type-encoding-position)
   (detail :initarg :detail :initform nil :reader unsupported-type-encoding-detail))
  (:report
   (lambda (condition stream)
     (format stream "Unsupported Objective-C type encoding ~S~@[ at position ~D~]~@[: ~A~]."
             (unsupported-type-encoding-encoding condition)
             (unsupported-type-encoding-position condition)
             (unsupported-type-encoding-detail condition))))
  (:documentation
   "Signalled when a type encoding cannot be parsed, or names a struct whose
layout the runtime elided and which is not in *STRUCT-LAYOUT-OVERRIDES*.

Signalling beats guessing here: a struct of the wrong size passed by value
corrupts the argument registers of every parameter after it, and the call
returns plausible garbage instead of failing."))

(define-condition unrepresentable-struct-result (objc-error)
  ((encoding :initarg :encoding :reader unrepresentable-struct-result-encoding)
   (selector :initarg :selector :initform nil
             :reader unrepresentable-struct-result-selector))
  (:report
   (lambda (condition stream)
     (format stream
             "~@[-~A ~]returns ~A, which has no Lisp representation.~%~
              A structure result is written into a buffer the call owns, and ~
              the only value INVOKE could return is a pointer into it -- ~
              which this call frees on its way out.  Use INVOKE-INTO with a ~
              destination you allocated:~%~
              ~2T(cffi:with-foreign-object (p :uint8 <size>)~%~
              ~4T(objc:invoke-into p receiver ~S)~%~
              ~4T...)~%~
              NSRect, NSPoint, NSSize and NSRange need none of this: INVOKE ~
              returns those as a vector or a cons."
             (unrepresentable-struct-result-selector condition)
             (unrepresentable-struct-result-encoding condition)
             (or (unrepresentable-struct-result-selector condition) "selector"))))
  (:documentation
   "Signalled when INVOKE would have to return a pointer to a structure buffer
that is already freed.

The four Cocoa structures convert to a vector or a cons and are unaffected; any
other structure has no Lisp representation here, so the result used to be a
pointer into the WITH-FOREIGN-OBJECT that INVOKE had just left.  It read as
plausible numbers -- a struct holding (7 8) came back as (4191 2) -- which is
the failure mode this library refuses everywhere else it appears.  The manual's
own struct-returning example uses INVOKE-INTO, which is why nothing caught it."))

(define-condition not-main-thread (objc-error)
  ((operation :initarg :operation :initform nil :reader not-main-thread-operation))
  (:report
   (lambda (condition stream)
     (format stream "~@[~A ~]must run on the main thread, but the current thread is ~S."
             (not-main-thread-operation condition)
             (bt:thread-name (bt:current-thread)))))
  (:documentation
   "Signalled by the AppKit entry points when called off thread 1.  AppKit
requires the main thread and does not check; the observed failure is a deadlock
or a corrupted window rather than an error, so we check instead."))
