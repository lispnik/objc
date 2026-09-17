;;;; src/exceptions.lisp -- an uncaught Objective-C exception becomes a condition.
;;;;
;;;; An NSException raised inside a send used to take the process down: the C++
;;;; unwinder's search for a handler walks up from the throw, reaches a Lisp
;;;; frame it has no unwind information for, and stops; __cxa_throw calls
;;;; std::terminate; the runtime's terminate handler prints "Terminating app
;;;; due to uncaught exception" and aborts.  LispWorks lets the same thing
;;;; happen (test/oracle/answers.lisp records the SIGABRT).
;;;;
;;;; The hook is objc_setUncaughtExceptionHandler, which the runtime's
;;;; terminate handler calls, on the throwing thread, with the stack intact and
;;;; the exception object in hand, before it aborts.  From there a Lisp THROW
;;;; to the innermost send's catch abandons the C frames between and lands in
;;;; %INVOKE, which signals OBJC-EXCEPTION.
;;;;
;;;; Not the exception preprocessor, which would be called for every throw:
;;;; Cocoa uses exceptions as control flow in places you cannot enumerate, and
;;;; one of them is AppKit's event loop, which catches an exception from an
;;;; action and carries on.  A preprocessor that threw to Lisp would pre-empt
;;;; that catch and end the loop.  The uncaught handler runs only when the
;;;; process was about to die, so an exception Cocoa handles itself is not
;;;; touched, and the frames this discards are frames whose cleanups were never
;;;; going to run anyway.
;;;;
;;;; What the throw skips, per caught exception: the C++ exception header
;;;; (__cxa_allocate_exception), one stale entry on libc++abi's caught-exception
;;;; list, and the runtime's own retain of the NSException, which therefore
;;;; lives for the rest of the process together with the backtrace CoreFoundation
;;;; attached to it -- about 3 KB, measured.  Any lock held by a raising frame
;;;; stays held.  NSException is for programmer errors, and this is the price
;;;; of surviving one.
;;;;
;;;; Which send catches: the innermost on this thread, because THROW finds the
;;;; innermost CATCH.  Whether any send is in progress on this thread is what
;;;; *CALL-TEMPORARIES* says -- :OUTSIDE otherwise, and on a thread the runtime
;;;; made and Lisp merely attached for the callback -- and a throw with no catch
;;;; after all signals CONTROL-ERROR before unwinding, which is caught here.
;;;; In either case the exception is handed to the handler that was installed
;;;; before ours, CoreFoundation's, which terminates the process as it always
;;;; did.
;;;;
;;;; Why the throw across foreign frames is sound: SBCL's catch block restores
;;;; the control, number and binding stacks, and the callback entry already
;;;; marked this thread as in Lisp, so nothing that the skipped alien-funcall
;;;; return would have restored is left stale; the safepoint build keeps the
;;;; same invariant.  ECL unwinds with its own frame stack and longjmp across C
;;;; frames as it does for any throw across a callback.  Both were measured
;;;; before this was written: a thousand caught exceptions, a full GC, ten
;;;; thousand sends and the whole suite in the same image.

(in-package #:objc)

(defvar *uncaught-exception-handler* nil
  "(NAME . SAP) of the installed callable: a GC root, as *IMP-REGISTRY* is for
IMPs, since a callable that becomes garbage has its trampoline recycled.")

(defvar *previous-uncaught-exception-handler* nil
  "The handler installed before ours, CoreFoundation's, given every exception
that is not ours to catch.")

(defvar *exception-handler-installed* nil)

(defun objc-exceptions-catchable-p ()
  "Whether an Objective-C exception raised inside a send becomes a condition
here.  True on every build this library runs on; the tests skip where it is
not."
  t)

(defun chain-to-previous-uncaught-handler (exception)
  (let ((previous *previous-uncaught-exception-handler*))
    (when (and previous (not (cffi:null-pointer-p previous)))
      (cffi:foreign-funcall-pointer previous () :pointer exception :void))))

(defun handle-uncaught-exception (result-sap exception)
  "The uncaught-exception handler's body.  Throw to the innermost send on this
thread when there is one; otherwise, or when there turns out to be no catch,
hand the exception on to the handler that was here before."
  (declare (ignore result-sap))
  (let ((exception (pointer-of exception)))
    (unless (eq *call-temporaries* :outside)
      (handler-case (throw 'objc-exception exception)
        (control-error () nil)))
    (chain-to-previous-uncaught-handler exception)
    nil))

(defun ensure-exception-handler ()
  "Install the handler, once per process.  Called by ENSURE-OBJC-INITIALIZED."
  (when (and (objc-exceptions-catchable-p) (not *exception-handler-installed*))
    (multiple-value-bind (sap name)
        (build-callable 'objc-uncaught-exception-handler :void '(:id) 0
                        #'handle-uncaught-exception "uncaught exception handler")
      (setf *uncaught-exception-handler* (cons name sap)
            *previous-uncaught-exception-handler*
            (%objc-set-uncaught-exception-handler (pointer-of sap))
            *exception-handler-installed* t)))
  *exception-handler-installed*)

(defun forget-exception-handler ()
  "A restored image is a new process with a fresh runtime: the callable is
rebuilt and the previous handler read again by the next
ENSURE-OBJC-INITIALIZED."
  (setf *exception-handler-installed* nil
        *previous-uncaught-exception-handler* nil
        *uncaught-exception-handler* nil))

(add-image-restore-thunk 'forget-exception-handler)
