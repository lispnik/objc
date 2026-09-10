;;;; src/pool-ecl.lisp -- trampolines built before the image ships.
;;;;
;;;; For iOS, and not compiled into the library.  This file is NOT an ASDF
;;;; component: it uses FFI:C-INLINE, which cannot be interpreted and does not
;;;; survive a native compile on the host, so it has to be compiled for the
;;;; target and only for the target.  With asdf-ios-app that means naming it:
;;;;
;;;;     :bundle-trampolines (#.(asdf:system-relative-pathname
;;;;                             "objc" "src/pool-ecl.lisp"))
;;;;
;;;; Why it exists.  On a Mac a trampoline for any signature is compiled on
;;;; demand and this file is unnecessary.  On a phone there is no C compiler and
;;;; ECL's COMPILE yields bytecode, so a call shape the dynamic FFI cannot
;;;; express must already be in the image.  That is one shape: a structure
;;;; returned by value.  Scalars, pointers and the struct ARGUMENTS AAPCS64
;;;; passes like separate scalars all go through SI:CALL-CFUN with nothing
;;;; compiled at all.
;;;;
;;;; What is here.  A trampoline is chosen by the ABI shape of a signature, not
;;;; by the selector, so one entry serves every method that looks like it --
;;;; which is why a short list covers most of Cocoa.  Deliberately short:
;;;; every entry is code in the application whether or not it is ever called,
;;;; and OBJC:DEFINE-OBJC-TRAMPOLINE is how you add the one you need.  When a
;;;; shape is missing the error says exactly what to paste.

(in-package #:objc)

;;; No arguments but the hidden two: -bounds, -frame, -center, -contentSize.
;;; These are how you ask a view anything, and the reason this file exists.

(define-objc-trampoline
  (:result cocoa:ns-rect :arguments (objc:objc-object-pointer objc:sel)))

(define-objc-trampoline
  (:result cocoa:ns-point :arguments (objc:objc-object-pointer objc:sel)))

(define-objc-trampoline
  (:result cocoa:ns-size :arguments (objc:objc-object-pointer objc:sel)))

(define-objc-trampoline
  (:result cocoa:ns-range :arguments (objc:objc-object-pointer objc:sel)))

;;; One object argument: -rangeOfString:, -locationInView:, -convertRect:,
;;; -convertPoint:.

(define-objc-trampoline
  (:result cocoa:ns-range
   :arguments (objc:objc-object-pointer objc:sel objc:objc-object-pointer)))

(define-objc-trampoline
  (:result cocoa:ns-point
   :arguments (objc:objc-object-pointer objc:sel objc:objc-object-pointer)))

(define-objc-trampoline
  (:result cocoa:ns-rect
   :arguments (objc:objc-object-pointer objc:sel objc:objc-object-pointer)))

(define-objc-trampoline
  (:result cocoa:ns-size
   :arguments (objc:objc-object-pointer objc:sel objc:objc-object-pointer)))

;;; A structure in and the same structure out: -convertRect:toView:,
;;; -convertPoint:fromView:, -intersectionWithRect:.

(define-objc-trampoline
  (:result cocoa:ns-rect
   :arguments (objc:objc-object-pointer objc:sel cocoa:ns-rect)))

(define-objc-trampoline
  (:result cocoa:ns-rect
   :arguments (objc:objc-object-pointer objc:sel cocoa:ns-rect
               objc:objc-object-pointer)))

(define-objc-trampoline
  (:result cocoa:ns-point
   :arguments (objc:objc-object-pointer objc:sel cocoa:ns-point
               objc:objc-object-pointer)))

;;; A super send of the same three, since -drawRect: and -layoutSubviews
;;; commonly call up.

(define-objc-trampoline
  (:kind :super :result cocoa:ns-rect
   :arguments (objc:objc-object-pointer objc:sel)))
