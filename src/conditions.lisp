;;;; src/conditions.lisp -- the condition hierarchy.
;;;;
;;;; Two of these are exported, OBJC-EXCEPTION and NS-ERROR, and the rest are
;;;; not.  The LispWorks manual documents no condition types at all, and reverse
;;;; engineering the 8.1 image confirms it has none: every failure is signalled
;;;; with a plain CL:ERROR and a format string, so the conditions that reach
;;;; LispWorks code are SIMPLE-ERRORs.  Exporting a condition for one of those
;;;; failures would be inventing API the manual does not promise.
;;;;
;;;; The two exported ones are for what LispWorks does not do at all: an
;;;; Objective-C exception aborts its process and it has no NSError helper.
;;;; There is nothing to be compatible with, and a caller who catches an
;;;; exception wants its name, not a string to parse, so those two are named.
;;;;
;;;; We still want structured conditions internally -- a REPL session debugging
;;;; a bad type encoding wants the encoding and the offset, not a string -- so
;;;; they exist, they subclass ERROR, and their reports are worded to match the
;;;; LispWorks messages where LispWorks has one.  Callers should handle ERROR,
;;;; or the two named ones where they mean them.

(in-package #:objc)

(define-condition objc-error (error) ()
  (:documentation
   "Root of the errors this library signals.  Not exported itself: see the file
header."))

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

(define-condition unencodable-signature (objc-error)
  ((selector :initarg :selector :reader unencodable-signature-selector)
   (encoding :initarg :encoding :reader unencodable-signature-encoding))
  (:report
   (lambda (condition stream)
     (let ((selector (unencodable-signature-selector condition)))
       (format stream "~A has a type Objective-C cannot encode -- a SIMD vector, ~
                       most likely: the runtime records its signature as ~S.  ~
                       Spell the signature yourself, once, with ~
                       (objc:declare-objc-signature ~S '(...)) or per call with the ~
                       list form of the method name, '(~S (...) :result-type ...); ~
                       (:vector :float 2) is a vector_float2."
               selector (unencodable-signature-encoding condition)
               selector selector))))
  (:documentation
   "Signalled when a method's runtime type encoding has a hole in it -- Clang
writes nothing for a SIMD vector -- and nothing declared what belongs there."))

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
              NSRect, NSPoint, NSSize and NSRange need none of this, nor does ~
              any structure whose layout is known: INVOKE returns those as a ~
              vector or a cons."
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

;;; The two exported conditions ------------------------------------------------

(defun selector-designation (receiver selector)
  "The selector as Objective-C writes it in a report: +sel for a class method,
-sel for an instance method."
  (format nil "~:[-~;+~]~a" (stringp receiver) selector))

(defgeneric objc-exception-name (condition)
  (:documentation "The exception's name, a string: \"NSRangeException\".  The
class name of the thrown object when it is not an NSException, \"nil\" when
nil was thrown."))

(defgeneric objc-exception-reason (condition)
  (:documentation "The exception's -reason as a string, or NIL when it has none."))

(defgeneric objc-exception-object (condition)
  (:documentation "The thrown object, a pointer.  The runtime retained it when
it was thrown and that reference is never released, because the throw was
abandoned rather than completed: do not release it either."))

(define-condition objc-exception (objc-error)
  ((name :initarg :name :reader objc-exception-name)
   (reason :initarg :reason :initform nil :reader objc-exception-reason)
   (object :initarg :object :reader objc-exception-object)
   (selector :initarg :selector :initform nil :reader objc-exception-selector)
   (receiver :initarg :receiver :initform nil :reader objc-exception-receiver))
  (:report
   (lambda (condition stream)
     (format stream "~@[~A ~]raised ~A~@[: ~A~]"
             (and (objc-exception-selector condition)
                  (selector-designation (objc-exception-receiver condition)
                                        (objc-exception-selector condition)))
             (objc-exception-name condition)
             (objc-exception-reason condition))))
  (:documentation
   "An Objective-C exception raised inside a send and not caught by any
Objective-C handler.  Without this it would have terminated the process, which
is what LispWorks lets happen.

The frames between the send and the raise are discarded without their
cleanups: a lock or @synchronized held there stays held, and a pool pushed
there is drained by the enclosing one.  NSException is for programmer errors,
so the subsystem that raised is suspect afterwards; the process is not."))

(defgeneric ns-error-domain (condition)
  (:documentation "The NSError's domain, a string: \"NSCocoaErrorDomain\"."))

(defgeneric ns-error-code (condition)
  (:documentation "The NSError's code, an integer."))

(defgeneric ns-error-description (condition)
  (:documentation "The NSError's -localizedDescription, a string."))

(defgeneric ns-error-object (condition)
  (:documentation "The NSError, a pointer, retained once by the condition.
Release it if you keep neither the condition nor the object."))

(define-condition ns-error (objc-error)
  ((domain :initarg :domain :reader ns-error-domain)
   (code :initarg :code :reader ns-error-code)
   (description :initarg :description :reader ns-error-description)
   (object :initarg :object :reader ns-error-object)
   (selector :initarg :selector :initform nil :reader ns-error-selector)
   (receiver :initarg :receiver :initform nil :reader ns-error-receiver))
  (:report
   (lambda (condition stream)
     (format stream "~@[~A ~]failed: ~A (~A ~D)"
             (and (ns-error-selector condition)
                  (selector-designation (ns-error-receiver condition)
                                        (ns-error-selector condition)))
             (ns-error-description condition)
             (ns-error-domain condition)
             (ns-error-code condition))))
  (:documentation
   "A method with an NSError ** parameter reported failure through it: the
result was nil, NO or nothing and the error was written.  Signalled by
INVOKE-WITH-ERROR, which supplies the parameter."))
