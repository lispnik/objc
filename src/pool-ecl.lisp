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

;;; Inbound: IMPs for classes defined in Lisp ---------------------------------
;;;
;;; A trampoline is looked up and called, so one serves every method that looks
;;; like it.  An IMP is a bare function pointer handed to class_addMethod and
;;; carries nothing saying which Lisp function it stands for, so one address is
;;; one method and these have to be counted rather than shared.
;;;
;;; :COUNT is how many methods of that shape an application may define.
;;; Redefining one does not spend another -- the body is reached through an
;;; index and rebinding it is the whole of a redefinition -- so these numbers
;;; bound the size of a program, not the length of a session.

;;; The three root methods DEFINE-OBJC-CLASS installs on every class it makes:
;;; +allocWithZone:, -dealloc and -copyWithZone:.  Without these no Lisp class
;;; can exist at all, so they are sized for several classes rather than one.

(define-objc-callable-pool                          ; +allocWithZone:, -copyWithZone:
  (:result objc:objc-object-pointer
   :arguments (objc:objc-object-pointer objc:sel objc:objc-object-pointer)
   :count 12))

(define-objc-callable-pool                          ; -dealloc
  (:result :void
   :arguments (objc:objc-object-pointer objc:sel)
   :count 8))

;;; Ordinary methods, by shape.

(define-objc-callable-pool                          ; -doSomething
  (:result :void :arguments (objc:objc-object-pointer objc:sel) :count 8))

(define-objc-callable-pool                          ; -handle: -observe: -fire:
  (:result :void
   :arguments (objc:objc-object-pointer objc:sel objc:objc-object-pointer)
   :count 12))

(define-objc-callable-pool                          ; -drawRect:
  (:result :void
   :arguments (objc:objc-object-pointer objc:sel cocoa:ns-rect)
   :count 4))

(define-objc-callable-pool                          ; -numberOfRowsInSection:
  (:result (:signed :long-long)
   :arguments (objc:objc-object-pointer objc:sel objc:objc-object-pointer
               (:signed :long-long))
   :count 6))

(define-objc-callable-pool                          ; -cellForRowAtIndexPath:
  (:result objc:objc-object-pointer
   :arguments (objc:objc-object-pointer objc:sel objc:objc-object-pointer
               objc:objc-object-pointer)
   :count 6))

(define-objc-callable-pool                          ; -textFieldShouldReturn:
  (:result objc:objc-bool
   :arguments (objc:objc-object-pointer objc:sel objc:objc-object-pointer)
   :count 6))

;;; Blocks. One hidden argument -- the block itself -- rather than two, which is
;;; the whole of the difference from a method.

(define-objc-callable-pool                          ; (:void ())
  (:result :void :arguments (objc:objc-object-pointer) :hidden 1 :count 6))

(define-objc-callable-pool                          ; (:void (id))
  (:result :void
   :arguments (objc:objc-object-pointer objc:objc-object-pointer)
   :hidden 1 :count 6))

;;; libclosure's copy and dispose helpers: exactly two per process, whatever
;;; block types exist, and no signature to vary.

(define-objc-callable-pool
  (:result :void
   :arguments (objc:objc-object-pointer objc:objc-object-pointer)
   :hidden 0 :count 2))

(define-objc-callable-pool
  (:result :void :arguments (objc:objc-object-pointer) :hidden 0 :count 2))
