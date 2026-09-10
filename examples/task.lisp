;;;; examples/task.lisp -- NSTask and NSPipe, and the deadlock in between.
;;;;
;;;; Running a subprocess and reading what it wrote.  notifications.lisp already
;;;; launches an NSTask to watch its termination notification arrive; this is the
;;;; other half, which is the pipe -- and the pipe is where the trap is.
;;;;
;;;; -waitUntilExit BEFORE DRAINING THE PIPE DEADLOCKS, and it deadlocks only
;;;; when the child writes more than the pipe buffer holds.  A pipe on macOS
;;;; takes about 64KB.  Under that, the child writes everything, exits, and the
;;;; obvious order works; over it, the child blocks in write(2) waiting for a
;;;; reader, the parent blocks in -waitUntilExit waiting for the child, and
;;;; neither moves again.  Measured: 200000 bytes, and the process had to be
;;;; killed.
;;;;
;;;; This is the worst shape a bug can have.  It is not a crash, there is no
;;;; error, and the version you wrote first -- launch, wait, then read the
;;;; output -- is correct for every small test you will write and wrong for the
;;;; first real one.  READ FIRST, WAIT AFTER: -readDataToEndOfFile returns when
;;;; the child closes its end, which is exactly the condition -waitUntilExit was
;;;; going to wait for anyway.
;;;;
;;;; The deadlock is documented here rather than demonstrated, for the same
;;;; reason memory.lisp does not demonstrate draining a pool on the wrong
;;;; thread: an example that hangs the test suite is not an example.  What the
;;;; test does run is the correct order over a payload big enough that the wrong
;;;; order would hang -- so the assertion is meaningful rather than decorative.
;;;;
;;;; -launch RAISES ON A BAD PATH, and an NSException ends the process.  There
;;;; is no error return and no NSError argument, so the path is checked in Lisp
;;;; before the call.  macOS 10.13 added -launchAndReturnError:, which reports
;;;; instead; RUN-COMMAND uses it when it is there.

(in-package #:objc/examples)

;;; Building one --------------------------------------------------------------------

(defparameter +pipe-buffer-bytes+ 65536
  "Roughly what a macOS pipe holds before a writer blocks.

Approximate on purpose -- the kernel grows the buffer under some conditions --
and used only to pick a payload for the test that is comfortably over it.")

(defun make-shell-task (command &key standard-output)
  "An NSTask that runs COMMAND under /bin/sh -c, writing to STANDARD-OUTPUT.

Not launched.  STANDARD-OUTPUT is an NSPipe or an NSFileHandle; without one the
child inherits ours, which in a test suite means the child's output lands in the
middle of the test report."
  (objc:ensure-objc-initialized)
  (let ((task (objc:alloc-init-object "NSTask"))
        (arguments (objc:alloc-init-object "NSMutableArray")))
    (objc:invoke arguments "addObject:" "-c")
    (objc:invoke arguments "addObject:" command)
    (objc:invoke task "setLaunchPath:" "/bin/sh")
    (objc:invoke task "setArguments:" arguments)
    (when standard-output
      (objc:invoke task "setStandardOutput:" standard-output))
    (objc:autorelease arguments)
    (objc:autorelease task)))

(defun launch-task (task)
  "Launch TASK, reporting a failure as a Lisp error rather than an NSException.

-launch raises for a path that does not exist, and an NSException here ends the
process -- there is nothing to catch it.  -launchAndReturnError: has existed
since 10.13 and answers NO with an NSError instead, so use it when the runtime
has it and fall back to checking the path ourselves when it does not."
  (if (objc:can-invoke-p task "launchAndReturnError:")
      (cffi:with-foreign-object (error-out :pointer)
        (setf (cffi:mem-ref error-out :pointer) (cffi:null-pointer))
        (unless (objc:invoke-bool task "launchAndReturnError:" error-out)
          (let ((error (cffi:mem-ref error-out :pointer)))
            (error "Could not launch the task: ~A"
                   (if (cffi:null-pointer-p error)
                       "no reason given"
                       (objc:invoke-into 'string error "localizedDescription"))))))
      (let ((path (objc:invoke-into 'string task "launchPath")))
        (unless (probe-file path)
          (error "No such launch path: ~S." path))
        (objc:invoke task "launch")))
  task)

;;; Running one to completion -----------------------------------------------------------

(defun run-command (command)
  "Run COMMAND under /bin/sh and return (VALUES OUTPUT EXIT-STATUS).

    (run-command \"echo hello\")            => \"hello\", 0
    (run-command \"exit 3\")                => \"\", 3
    (run-command \"yes x | head -c 200000\")  => 200000 characters, 0

THE ORDER OF THE LAST THREE LINES IS THE ENTIRE POINT.  Read the pipe to the end
FIRST, and only then wait: -readDataToEndOfFile returns when the child closes
its end of the pipe, which is what -waitUntilExit was going to wait for.  Put
the wait first and this deadlocks the moment the output exceeds the pipe buffer
-- about 64KB -- with no error and no timeout.  See the header."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (let* ((pipe (objc:invoke "NSPipe" "pipe"))
           (task (make-shell-task command :standard-output pipe))
           (handle (objc:invoke pipe "fileHandleForReading")))
      (launch-task task)
      (let ((data (objc:invoke handle "readDataToEndOfFile")))
        (objc:invoke task "waitUntilExit")
        (values (data-to-string data)
                (objc:invoke task "terminationStatus"))))))

(defun data-to-string (data)
  "An NSData's bytes as a Lisp string, assuming UTF-8.

-[NSData bytes] is a void *, not a C string: there is no terminator, and the
length comes from -length.  Reading it as a char * works right up until the
output happens not to contain a zero byte at the end of the buffer, which is
most of the time -- so it is read as counted bytes, deliberately."
  (let ((length (objc:invoke data "length"))
        (bytes (objc:invoke data "bytes")))
    (if (zerop length)
        ""
        (let ((octets (make-array length :element-type '(unsigned-byte 8))))
          (dotimes (i length)
            (setf (aref octets i) (cffi:mem-aref bytes :unsigned-char i)))
          (babel:octets-to-string octets :encoding :utf-8)))))

(defun command-output-lines (command)
  "Run COMMAND and return its output as a list of lines."
  (with-input-from-string (stream (run-command command))
    (loop for line = (read-line stream nil) while line collect line)))

;;; A worked example -----------------------------------------------------------------------

(defun test-task ()
  "Run several commands and check output, status and a payload past the buffer.

    (objc/examples:test-task)
    => (:OUTPUT \"hello\" :STATUS 0 :FAILING-STATUS 3 :EMPTY \"\"
        :LINES (\"one\" \"two\") :LARGE-BYTES 200000
        :BAD-PATH-REPORTED T)

:LARGE-BYTES is the assertion that means anything.  200000 bytes is comfortably
past the pipe buffer, so the same code with -waitUntilExit moved above the read
would hang here rather than fail -- which is why the correct order is worth a
test rather than a comment.

:BAD-PATH-REPORTED checks that a launch failure arrives as a Lisp error.  The
alternative is an NSException, which would end the process rather than fail the
test."
  (objc:ensure-objc-initialized)
  (multiple-value-bind (output status) (run-command "echo hello")
    (multiple-value-bind (empty failing) (run-command "exit 3")
      (list :output (string-right-trim '(#\Newline) output)
            :status status
            :failing-status failing
            :empty empty
            :lines (command-output-lines "printf 'one\\ntwo\\n'")
            :large-bytes (length (run-command
                                  (format nil "yes x | head -c ~D"
                                          (* 3 +pipe-buffer-bytes+))))
            :bad-path-reported
            (objc:with-autorelease-pool ()
              (let ((task (make-shell-task "true")))
                (objc:invoke task "setLaunchPath:" "/no/such/binary/here")
                (handler-case (progn (launch-task task) nil)
                  (error () t))))))))

(defun report-task ()
  "Run a few commands and print what came back."
  (objc:ensure-objc-initialized)
  (dolist (command '("echo hello" "sw_vers -productVersion" "exit 3"))
    (multiple-value-bind (output status) (run-command command)
      (format t "~&~28A status ~D  ~S~%"
              command status (string-right-trim '(#\Newline) output))))
  (let ((bytes (* 3 +pipe-buffer-bytes+)))
    (format t "~&~D bytes through the pipe: ~D read back~%"
            bytes (length (run-command (format nil "yes x | head -c ~D" bytes))))))
