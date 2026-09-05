;;;; examples/plugin.lisp -- protocols and typedefs, and what each one is not.
;;;;
;;;; The last two defining macros without an example: DEFINE-OBJC-PROTOCOL and
;;;; DEFINE-OBJC-TYPEDEF.  Both are worth using and neither does what its name
;;;; suggests, which is the reason this file exists.
;;;;
;;;; DEFINE-OBJC-PROTOCOL DOES NOT CREATE A PROTOCOL.  The runtime has not
;;;; allowed that since macOS 10.5, and this library says so in the docstring.
;;;; What it records is a DECLARATION -- the methods you expect a protocol to
;;;; have -- for protocols that already exist.  Measured, so the distinction is
;;;; not theoretical: after declaring "LispOnlyProtocol", objc_getProtocol still
;;;; returns null for it, and no class can be made to conform.
;;;;
;;;; So conformance goes the other way.  A class adopts an EXISTING protocol
;;;; through DEFINE-OBJC-CLASS's :OBJC-PROTOCOLS option, and that registration is
;;;; real: -conformsToProtocol: answers YES for NSCopying and NO for NSCoding on
;;;; the class below, which is Cocoa's own answer and not our bookkeeping.
;;;;
;;;; DEFINE-OBJC-TYPEDEF IS FOR THE READER, NOT THE RUNTIME.  A method declared
;;;; to return TIME-INTERVAL has the encoding "d@:d" and its signature reads back
;;;; as :DOUBLE -- the name is erased at the boundary, exactly as a C typedef is.
;;;; That is not a defect; it is what a typedef means.  Worth knowing because it
;;;; sets what the macro can do for you: code that reads like the headers, and no
;;;; type checking whatsoever.  NSTimeInterval and CGFloat are both doubles, and
;;;; nothing will stop you passing one where the other belongs.
;;;;
;;;; Together they are the plugin-shaped part of the interface: an object that
;;;; announces what it can do, checked by the runtime rather than by convention.

(in-package #:objc/examples)

(cffi:defcfun ("objc_getProtocol" %objc-get-protocol) :pointer (name :string))

;;; Names for what the headers call things -------------------------------------------

(objc:define-objc-typedef (time-interval (:foreign-name "NSTimeInterval")) :double)

(objc:define-objc-typedef (screen-coordinate (:foreign-name "CGFloat")) :double)

;;; A class that adopts a real protocol ------------------------------------------------
;;;
;;; NSCopying is Foundation's, so it exists and can be adopted.  The library
;;; installs -copyWithZone: on every Lisp-defined class already, which is what
;;; makes the conformance honest rather than a claim: an NSDictionary will copy
;;; one of these as a key and get a working copy.  See collections.lisp.

(objc:define-objc-class plugin ()
  ((name :initarg :name :initform "unnamed" :accessor plugin-name)
   (started :initform nil :accessor plugin-started-p))
  (:objc-class-name "LispPlugin")
  (:objc-protocols "NSCopying"))

(objc:define-objc-method ("startupTime" time-interval) ((self plugin))
  (if (plugin-started-p self) 0.25d0 -1d0))

(objc:define-objc-method ("start" :void) ((self plugin))
  (setf (plugin-started-p self) t))

(objc:define-objc-method ("scaleFor:" screen-coordinate)
    ((self plugin) (points screen-coordinate))
  (* points 2))

(defun make-plugin (name)
  "A plugin object conforming to NSCopying."
  (objc:ensure-objc-initialized)
  (make-instance 'plugin :name name))

;;; Asking what something conforms to ----------------------------------------------------

(defun find-protocol (name)
  "The runtime's Protocol object called NAME, or NIL if there is none.

objc_getProtocol rather than anything in OBJC, for the reason browser.lisp gives
about class_copyMethodList: the LispWorks manual does not provide it, so this
library does not export it, so an example is where the raw call belongs."
  (objc:ensure-objc-initialized)
  (let ((pointer (%objc-get-protocol name)))
    (unless (cffi:null-pointer-p pointer)
      pointer)))

(defun conforms-p (object protocol-name)
  "Whether OBJECT conforms to the protocol called PROTOCOL-NAME.

NIL when the protocol does not exist at all, which is a different thing from a
NO and is worth not conflating: a typo in the name gives the same answer as a
class that does not adopt it."
  (objc:ensure-objc-initialized)
  (let ((protocol (find-protocol protocol-name)))
    (and protocol (objc:invoke-bool object "conformsToProtocol:" protocol))))

;;; A declaration, which is all DEFINE-OBJC-PROTOCOL makes -------------------------------
;;;
;;; Declared so the file can show what a declaration does and does not buy.  It
;;; records the shape for the reader and for anything that wants to look it up;
;;; it does not put a protocol into the runtime, and DECLARED-PROTOCOL-IS-NOT-REAL
;;; below is the measurement.

(objc:define-objc-protocol "LispPluginProtocol"
  :instance-methods (("start" :void)
                     ("startupTime" time-interval)))

(defun declared-protocol-is-real-p (name)
  "Whether declaring NAME put an actual protocol into the runtime.  It does not."
  (and (find-protocol name) t))

;;; A worked example -------------------------------------------------------------------------

(defun test-plugin ()
  "Adopt a protocol, check conformance, and see a typedef erased.

    (objc/examples:test-plugin)
    => (:CONFORMS-TO-NSCOPYING T :CONFORMS-TO-NSCODING NIL
        :UNKNOWN-PROTOCOL NIL :DECLARED-PROTOCOL-IS-REAL NIL
        :BEFORE-START -1.0d0 :AFTER-START 0.25d0 :SCALED 21.0d0
        :SIGNATURE ((OBJC-OBJECT-POINTER SEL) :DOUBLE \"d@:\")
        :COPY-WORKS T)

:CONFORMS-TO-NSCOPYING is Cocoa's answer, not ours -- :OBJC-PROTOCOLS registers
the conformance with the runtime, and -conformsToProtocol: reads it back.
:CONFORMS-TO-NSCODING is the control: the same object, a protocol it did not
adopt.

:DECLARED-PROTOCOL-IS-REAL is the one that matters.  DEFINE-OBJC-PROTOCOL
records a declaration and the runtime still has no such protocol, so nothing can
conform to it and nothing can be checked against it.  It is a declaration, as
the docstring says, and this is what that costs.

:SIGNATURE shows the typedef erased: -startupTime is declared TIME-INTERVAL and
reads back as :DOUBLE with the encoding \"d@:\"."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (let ((plugin (make-plugin "example")))
      (list :conforms-to-nscopying (conforms-p plugin "NSCopying")
            :conforms-to-nscoding (conforms-p plugin "NSCoding")
            :unknown-protocol (conforms-p plugin "NoSuchProtocolAnywhere")
            :declared-protocol-is-real (declared-protocol-is-real-p "LispPluginProtocol")
            :before-start (objc:invoke plugin "startupTime")
            :after-start (progn (objc:invoke plugin "start")
                                (objc:invoke plugin "startupTime"))
            :scaled (objc:invoke plugin "scaleFor:" 10.5d0)
            :signature (multiple-value-list
                        (objc:objc-class-method-signature "LispPlugin" "startupTime"))
            :copy-works
            (let ((copy (objc:invoke plugin "copy")))
              (and (string= "example" (plugin-name (objc:objc-object-from-pointer copy)))
                   t))))))

(defun report-plugin ()
  "Print what the object claims and what the runtime confirms."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (let ((plugin (make-plugin "example")))
      (format t "~&LispPlugin conformance:~%")
      (dolist (name '("NSCopying" "NSCoding" "LispPluginProtocol" "NoSuchProtocol"))
        (format t "  ~20A exists ~3A  conforms ~A~%" name
                (if (find-protocol name) "yes" "no")
                (if (conforms-p plugin name) "yes" "no")))
      (format t "~&-startupTime is declared TIME-INTERVAL and reads back as ~S~%"
              (nth-value 1 (objc:objc-class-method-signature "LispPlugin" "startupTime")))
      (format t "encoding: ~S~%"
              (nth-value 2 (objc:objc-class-method-signature "LispPlugin" "startupTime"))))))
