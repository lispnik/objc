;;;; src/protocol.lisp -- DEFINE-OBJC-PROTOCOL.
;;;;
;;;; Declaring only, never creating.  The manual says so itself: "It is not
;;;; possible to define new protocols entirely in Lisp on macOS 10.5 and later,
;;;; but define-objc-protocol can be used to declare existing protocols."  The
;;;; declaration exists so that the :OBJC-PROTOCOLS class option has a name to
;;;; refer to; the protocol object itself comes from objc_getProtocol at class
;;;; definition time.

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
