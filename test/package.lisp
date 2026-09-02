;;;; test/package.lisp
;;;;
;;;; The test package deliberately does NOT :USE #:objc.  DESCRIPTION, RELEASE,
;;;; INVOKE and SEL are exactly the names a test helper wants for itself, and
;;;; importing them wholesale turns every such collision into a puzzling
;;;; redefinition warning.  Everything is qualified instead.

(defpackage #:objc/test
  (:use #:cl #:fiveam)
  (:export #:all-tests #:run-tests))

(in-package #:objc/test)

(def-suite all-tests
  :description "Every objc test.")

(defun run-tests ()
  "Run the whole suite.  Returns true when everything passed.

FIVEAM:RUN! prints a report but returns NIL on failure, and ASDF throws away
what a TEST-OP returns, so the .asd calls this and signals on a NIL result.
Do not replace it with RUN! in a batch context."
  (let ((results (run 'all-tests)))
    (explain! results)
    (results-status results)))
