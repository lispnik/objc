;;;; src/memory.lisp -- reference counting and autorelease pools.
;;;;
;;;; There is no ARC here.  Calling through a foreign function interface puts
;;;; you in manual retain/release whatever the surrounding code does, so these
;;;; are the real thing and the ownership rules in the manual apply literally.
;;;;
;;;; No finalizers.  It is tempting to hang a RELEASE off a Lisp finalizer, but
;;;; SBCL runs finalizers on whatever thread happens to trigger the collection,
;;;; and releasing an AppKit object off the main thread is a genuine bug rather
;;;; than a style question.  Lifetime is managed by the three methods installed
;;;; on Lisp-defined classes instead; see root.lisp.

(in-package #:objc)

(defun retain (pointer)
  "Increment POINTER's reference count and return POINTER.

The manual says \"decrement\" here; that is a typo in the LispWorks
documentation, and this increments, as -retain does."
  (invoke pointer "retain")
  pointer)

(defun release (pointer)
  "Decrement POINTER's reference count."
  (invoke pointer "release")
  (values))

(defun autorelease (pointer)
  "Register POINTER with the current autorelease pool and return POINTER."
  (invoke pointer "autorelease")
  pointer)

(defun retain-count (pointer)
  "Return POINTER's reference count."
  (invoke pointer "retainCount"))

(defun make-autorelease-pool ()
  "Return a new autorelease pool for the current thread.

Cocoa provides a pool on the main thread of an application that is running an
event loop, but a plain SBCL process has none, and any thread you start has
none.  Without a pool, every autoreleased object leaks and Foundation logs about
it."
  (invoke (invoke "NSAutoreleasePool" "alloc") "init"))

(defmacro with-autorelease-pool ((&rest options) &body body)
  "Evaluate BODY with a fresh autorelease pool, draining it afterwards.

The pool is released even on a non-local exit.  OPTIONS must be empty; it
exists because the manual's lambda list has it."
  (when options
    (error "WITH-AUTORELEASE-POOL takes no options, but was given ~S." options))
  (let ((pool (gensym "POOL")))
    `(let ((,pool (make-autorelease-pool)))
       (unwind-protect (locally ,@body)
         ;; -drain rather than -release: identical without garbage collection,
         ;; and the spelling Apple documents.
         (ignore-errors (invoke ,pool "drain"))))))
