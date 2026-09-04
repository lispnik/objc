;;;; src/protocol.lisp -- DEFINE-OBJC-PROTOCOL.
;;;;
;;;; Declaring only, never creating, which follows the manual: "It is not
;;;; possible to define new protocols entirely in Lisp on macOS 10.5 and later,
;;;; but define-objc-protocol can be used to declare existing protocols."  The
;;;; declaration exists so that the :OBJC-PROTOCOLS class option has a name to
;;;; refer to; the protocol object itself comes from objc_getProtocol at class
;;;; definition time.
;;;;
;;;; The manual's reason is stale, though the behaviour it describes is still
;;;; the right one.  objc_allocateProtocol, protocol_addMethodDescription and
;;;; objc_registerProtocol arrived in macOS 10.7 and do create a protocol at run
;;;; time -- verified here: allocated, registered, and found again by
;;;; objc_getProtocol under its own name.
;;;;
;;;; What such a protocol cannot do is carry the EXTENDED method signatures
;;;; clang emits alongside the ordinary ones, because no runtime function
;;;; records them.  Anything that needs those rejects it, and NSXPCInterface
;;;; says so in as many words: "Unable to get extended method signature from
;;;; Protocol data ... Use of clang is required for NSXPCInterface."  So XPC is
;;;; out of reach from here for the same reason there is no cffi-grovel in the
;;;; build -- it wants a C compiler -- and creating protocols remains a thing
;;;; this library declines to expose rather than a thing the system forbids.

(in-package #:objc)

(defvar *declared-protocols* (make-hash-table :test 'equal)
  "Protocol name -> its declaration, for documentation and error checking.")

(defstruct (objc-protocol (:constructor make-objc-protocol
                              (name incorporated instance-methods class-methods)))
  name incorporated instance-methods class-methods)

(defmacro define-objc-protocol (name &key incorporated-protocols
                                          instance-methods
                                          class-methods)
  "Declare the existing Objective-C protocol NAME.

INSTANCE-METHODS and CLASS-METHODS are lists of (name result-type arg-type*),
where the receiver and selector arguments are NOT written out.

This records a declaration; it does not create a protocol, which the runtime
has not permitted since macOS 10.5.  The standard Foundation and AppKit
protocols already exist and can be named in :OBJC-PROTOCOLS without being
declared here at all."
  `(progn
     (setf (gethash ,name *declared-protocols*)
           (make-objc-protocol ,name ',incorporated-protocols
                               ',instance-methods ',class-methods))
     ,name))

(defun find-objc-protocol (name)
  "The runtime Protocol object named NAME, or NIL."
  (let ((protocol (%objc-get-protocol name)))
    (and (objc-pointer-p protocol) protocol)))
