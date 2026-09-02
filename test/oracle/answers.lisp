;;;; test/oracle/answers.lisp -- ground truth recorded from LispWorks 8.1.
;;;;
;;;; LispWorks Personal 8.1 cannot be scripted: -eval is not honoured, the
;;;; process ignores it and launches the IDE, and the heap says why --
;;;; "Initialization files are not available in the Personal Edition of
;;;; LispWorks."  SAVE-IMAGE, DELIVER and LOAD-ALL-PATCHES are blocked the same
;;;; way.  So these answers were produced by pasting test/oracle/probe.lisp into
;;;; the IDE Listener by hand and recording the output verbatim, once.
;;;;
;;;; Committing them is what lets the differential tests run in CI on a machine
;;;; with no LispWorks installed.  Regenerating is deliberate and rare; see
;;;; "make oracle".
;;;;
;;;; Recorded: LispWorks Personal 8.1.2, arm64 (Apple silicon), macOS 15/Darwin 25.

(in-package #:objc/test)

(defparameter *oracle-answers*
  '(;; -- BOOL --------------------------------------------------------------
    ;; THE important one.  On Apple silicon BOOL encodes as 'B' (C99 _Bool),
    ;; not 'c', so it was reasonable to expect INVOKE to hand back a genuine
    ;; Lisp boolean -- LispWorks' precompiled dispatch table even carries
    ;; matched (SIGNED CHAR) / OBJC-C++-BOOL pairs.  It does not.  INVOKE
    ;; normalises a BOOL result to 1 or 0 on every architecture, exactly as the
    ;; reference page says, and only INVOKE-BOOL returns T/NIL.  Getting this
    ;; backwards would have silently broken every ported (if (invoke ...) ...).
    (:bool-invoke-true            . 1)
    (:bool-invoke-false           . 0)
    (:bool-invoke-bool            . t)

    ;; -- scalars and struct returns ----------------------------------------
    (:length                      . 11)
    ;; Bare INVOKE converts an NSRange result to a cons, no INVOKE-INTO needed.
    (:range-of-string             . (6 . 5))

    ;; -- struct sizes ------------------------------------------------------
    ;; The manual's reference pages say ns-point/ns-size slots are :FLOAT and
    ;; ns-range slots are (:UNSIGNED :INT).  That is stale 32-bit text; the
    ;; implementation uses doubles and 64-bit integers, matching the encodings
    ;; {_NSPoint=dd} and _NSRange=QQ found in the LispWorks heap.
    (:sizeof-ns-point             . 16)
    (:sizeof-ns-size              . 16)
    (:sizeof-ns-rect              . 32)
    (:sizeof-ns-range             . 16)

    ;; -- objc-class-method-signature ---------------------------------------
    ;; Three values; arg-types always starts (objc-object-pointer sel).
    (:sig-length
     . ((objc:objc-object-pointer objc:sel)
        (:unsigned :long-long)
        "Q16@0:8"))
    (:sig-range-of-string
     . ((objc:objc-object-pointer objc:sel objc:objc-object-pointer)
        (:struct cocoa:ns-range)
        "{_NSRange=QQ}24@0:8@16"))
    (:sig-substring-with-range
     . ((objc:objc-object-pointer objc:sel (:struct cocoa:ns-range))
        objc:objc-object-pointer
        "@32@0:8{_NSRange=QQ}16"))
    ;; Given a class NAME and a selector that exists as both a class and an
    ;; instance method, the INSTANCE method wins: "@16@0:8" is -[NSObject
    ;; description], not +[NSObject description].
    (:sig-description
     . ((objc:objc-object-pointer objc:sel)
        objc:objc-object-pointer
        "@16@0:8"))

    ;; -- selectors ---------------------------------------------------------
    (:can-invoke-p-bogus          . nil)
    ;; SELECTOR-NAME passes a string straight through, unregistered.
    (:selector-name-string        . "notAColonName")
    (:selector-name-sel           . "setWidth:height:")

    ;; -- memory ------------------------------------------------------------
    (:retain-count-new            . 1)

    ;; -- Objective-C exceptions --------------------------------------------
    ;; -[NSArray objectAtIndex:] out of range, wrapped in HANDLER-CASE.
    ;; LispWorks "caught" it -- but as SYSTEM::EXCEPTION-ERROR reporting
    ;; "Abort(6) ... Foreign code offset #x8 from symbol \"__pthread_kill\"",
    ;; with a register dump.  That is not exception bridging.  The NSException
    ;; went uncaught, reached objc_terminate, and called abort(); LispWorks'
    ;; generic fatal-signal handler turned the SIGABRT into a condition.  It
    ;; matches the static evidence exactly: the 8.1 image imports no
    ;; __cxa_begin_catch, no objc_exception_*, and no NSSetUncaughtExceptionHandler.
    ;;
    ;; We do not reproduce this.  SBCL does not convert SIGABRT into a
    ;; condition, and unwinding out of a signal handler that fired inside
    ;; abort() during C++ terminate is unsafe -- the Objective-C runtime state
    ;; is already inconsistent.  Our answer is the one LispWorks also relies on
    ;; in practice: resolve the Method before sending, so the overwhelmingly
    ;; common case (an unimplemented selector) is a Lisp error and never a
    ;; foreign exception at all.  A genuine NSException terminates the process,
    ;; and that is documented rather than papered over.
    (:objc-exception-outcome      . :process-aborts)
    ;; Recorded as a string: SYSTEM is a LispWorks package and naming it as a
    ;; symbol would make this file unreadable anywhere else.
    (:objc-exception-lispworks-condition . "SYSTEM::EXCEPTION-ERROR")

    ;; -- error behaviour ---------------------------------------------------
    ;; A missing method is a plain SIMPLE-ERROR signalled from Lisp before any
    ;; message is sent, so doesNotRecognizeSelector: never fires.  Note the
    ;; class in the message is the RUNTIME class (__NSCFString), i.e. it comes
    ;; from object_getClass, not from the class the caller named.
    (:missing-method-condition    . "SIMPLE-ERROR")
    (:missing-method-report
     . "No method \"noSuchMethodAtAll\" for object #<Pointer: OBJC:OBJC-OBJECT-POINTER = #x00000008679CF880>, class \"__NSCFString\"."))
  "Alist of LispWorks 8.1 observed behaviour, keyed by probe name.
See the file header for how it was produced and why it is committed.")
