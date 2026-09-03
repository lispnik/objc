;;;; test/dump-tests.lisp -- the library survives SAVE-LISP-AND-DIE.
;;;;
;;;; Nothing about a Lisp-defined Objective-C class survives a dump: the class
;;;; itself is foreign runtime state created by objc_allocateClassPair, the IMPs
;;;; are sb-alien callables, and the trampolines embed objc_msgSend's address as
;;;; an immediate.  All of it is rebuilt on the way back in.
;;;;
;;;; This has to run in a subprocess, because the only way to test a dump is to
;;;; take one.  It is the slowest test here by a wide margin and it earns the
;;;; time: the bug it caught was that UIOP's image hooks fire only from
;;;; UIOP:DUMP-IMAGE, so a plain SB-EXT:SAVE-LISP-AND-DIE -- which is what
;;;; ASDF's PROGRAM-OP ends up doing -- skipped the restore entirely and the
;;;; executable died with a memory fault on its first message send.

(in-package #:objc/test)

(def-suite dump :in all-tests
  :description "Surviving SAVE-LISP-AND-DIE.")

(in-suite dump)

(defun bootstrap-form ()
  "A form the spawned image can use to find this system.

The subprocess is a bare SBCL: it does not inherit the source registry, and on
a developer machine ~/.sbclrc happens to set one up so this went unnoticed
until CI ran, where it failed to find :OBJC and exited 1.  A :TREE over the
project directory covers both the system and its ocicl-vendored dependencies."
  (format nil "(require :asdf)~%~
               (asdf:initialize-source-registry~%~
                 '(:source-registry (:tree ~S) :inherit-configuration))~%"
          (namestring (asdf:system-source-directory :objc))))

(defparameter +dump-program+
  "(asdf:load-system :objc)
   (defpackage \"DUMPTEST\" (:use \"CL\" \"OBJC\"))
   (in-package \"DUMPTEST\")
   (objc:ensure-objc-initialized)
   (define-objc-class dumped ()
     ((tag :initarg :tag :initform :none :accessor dumped-tag))
     (:objc-class-name \"ObjcDumpedClass\"))
   (define-objc-method (\"tripled:\" :int) ((self dumped) (n :int))
     (* 3 n))
   (assert (= 15 (invoke (alloc-init-object \"ObjcDumpedClass\") \"tripled:\" 5)))
   ;; Deliberately not freed: the restored image must find it dead rather than
   ;; hand out a pointer into memory this process malloc'd.
   (defvar *doomed-block* (make-objc-block '(:void ()) (lambda () nil)))
   (sb-ext:save-lisp-and-die (second sb-ext:*posix-argv*) :executable t)")

(defparameter +restart-program+
  "(in-package \"DUMPTEST\")
   (objc:ensure-objc-initialized)
   (let ((object (make-instance 'dumped :tag :restored)))
     (format t \"~&CLASS ~a~%\" (not (cffi:null-pointer-p
                                      (objc::%objc-look-up-class \"ObjcDumpedClass\"))))
     (format t \"METHOD ~a~%\" (invoke (alloc-init-object \"ObjcDumpedClass\") \"tripled:\" 5))
     (format t \"IDENTITY ~a~%\" (eq object (objc-object-from-pointer
                                            (objc-object-pointer object))))
     (format t \"SLOT ~a~%\" (dumped-tag object))
     (format t \"INVOKE ~a~%\"
             (invoke (invoke \"NSString\" \"stringWithUTF8String:\" \"hello\") \"length\"))
     ;; The invoke functions were alien callables and the descriptors were
     ;; malloc'd, so none of it crossed the dump.  A block made before it must
     ;; report itself dead, and a new one must build fresh machinery and run.
     (format t \"STALE ~a~%\" (objc:objc-block-live-p *doomed-block*))
     (let ((hits 0))
       (objc:with-objc-block (b '(:void ()) (lambda () (incf hits)))
         (cffi:foreign-funcall
          \"dispatch_sync\"
          :pointer (cffi:foreign-funcall \"dispatch_get_global_queue\"
                                         :long 0 :unsigned-long 0 :pointer)
          :pointer (objc:objc-block-pointer b)
          :void))
       (format t \"BLOCK ~a~%\" hits)))")

(defun sbcl-available-p ()
  (handler-case
      (zerop (nth-value 2 (uiop:run-program '("sbcl" "--version")
                                            :ignore-error-status t
                                            :output nil :error-output nil)))
    (error () nil)))

(test a-dumped-image-rebuilds-its-objective-c-classes
  (cond
    ((not (ensure-initialized)) (skip "Objective-C runtime not available"))
    ((not (sbcl-available-p)) (skip "sbcl not on PATH"))
    (t
     (uiop:with-temporary-file (:pathname source :type "lisp" :keep nil)
       (with-open-file (out source :direction :output :if-exists :supersede)
         (write-string (bootstrap-form) out)
         (write-string +dump-program+ out))
       (uiop:with-temporary-file (:pathname restart :type "lisp" :keep nil)
         (with-open-file (out restart :direction :output :if-exists :supersede)
           (write-string +restart-program+ out))
         (let ((executable (uiop:merge-pathnames*
                            "objc-dump-test"
                            (uiop:temporary-directory))))
           (unwind-protect
                (progn
                  (uiop:run-program (list "sbcl" "--non-interactive"
                                          "--load" (namestring source)
                                          (namestring executable))
                                    :output nil :error-output nil
                                    :directory (asdf:system-source-directory :objc))
                  (is (probe-file executable) "the image was written")
                  (let ((output (uiop:run-program
                                 (list (namestring executable) "--non-interactive"
                                       "--load" (namestring restart))
                                 :output :string :error-output nil
                                 :ignore-error-status t)))
                    (is (search "CLASS T" output)
                        "the Objective-C class was recreated after the restart")
                    (is (search "METHOD 15" output)
                        "the Lisp-implemented method was reinstalled and runs")
                    (is (search "IDENTITY T" output)
                        "the pointer to Lisp object map works in the new image")
                    (is (search "SLOT RESTORED" output))
                    (is (search "INVOKE 5" output)
                        "ordinary dispatch works after the trampoline caches were cleared")
                    (is (search "STALE NIL" output)
                        "a block made before the dump reports itself freed")
                    (is (search "BLOCK 1" output)
                        "and a new block builds fresh machinery and is invoked")))
             (ignore-errors (delete-file executable)))))))))
