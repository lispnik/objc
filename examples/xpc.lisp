;;;; examples/xpc.lisp -- a Lisp XPC service, and the client that talks to it.
;;;;
;;;; XPC is how macOS software is put together once it is more than one
;;;; process: a sandboxed app and its helpers, a system daemon and its
;;;; clients, Xcode and its build service.  A connection is a pair of Mach
;;;; ports wrapped so that each side sees messages -- dictionaries of
;;;; strings, numbers, data -- and a handler that runs on a dispatch queue.
;;;;
;;;; This is the C API, libxpc, rather than NSXPCConnection, and the reason is
;;;; recorded in plugin.lisp: NSXPCInterface wants a protocol carrying the
;;;; extended method signatures only clang emits, and a protocol made at run
;;;; time cannot have them.  libxpc asks for no protocol at all.  It asks for
;;;; blocks, which the bridge makes, and for a queue, which gcd.lisp explains:
;;;; the handlers run on a libdispatch thread, and on a stock SBCL only one
;;;; such thread may be inside Lisp at a time, so every connection here is
;;;; given the same SERIAL queue.
;;;;
;;;; Two ways to use it.  TEST-XPC runs both ends in this process over an
;;;; anonymous listener and its endpoint -- real Mach ports, no launchd --
;;;; which is what the test suite exercises.  INSTALL-LISP-SERVICE registers a
;;;; launchd agent so that a SEPARATE Lisp process answers the name
;;;; org.lispnik.objc.lisp-service, started on demand the first time anything
;;;; connects; LISP-SERVICE then evaluates a form there from here, or from any
;;;; other process of yours that can speak XPC.  UNINSTALL-LISP-SERVICE takes
;;;; it away again.
;;;;
;;;; The service evaluates whatever it is sent.  A launchd agent's Mach service
;;;; is reachable only by processes running as the same user, which is the
;;;; whole of its security, and it is an example.

(in-package #:objc/examples)

;;; libxpc ---------------------------------------------------------------------
;;; Inside libSystem, so already loaded.  Objects are refcounted with
;;; xpc_retain/xpc_release; on every macOS this library supports they are also
;;; Objective-C objects, but the C functions are the documented interface.

(cffi:defcfun ("xpc_connection_create" %xpc-connection-create) :pointer
  (name :pointer)
  (queue :pointer))

(cffi:defcfun ("xpc_connection_create_mach_service" %xpc-connection-create-mach-service) :pointer
  (name :string)
  (queue :pointer)
  (flags :unsigned-long-long))

(cffi:defcfun ("xpc_connection_create_from_endpoint" %xpc-connection-create-from-endpoint) :pointer
  (endpoint :pointer))

(cffi:defcfun ("xpc_endpoint_create" %xpc-endpoint-create) :pointer
  (connection :pointer))

(cffi:defcfun ("xpc_connection_set_event_handler" %xpc-connection-set-event-handler) :void
  (connection :pointer)
  (handler :pointer))

(cffi:defcfun ("xpc_connection_resume" %xpc-connection-resume) :void
  (connection :pointer))

(cffi:defcfun ("xpc_connection_cancel" %xpc-connection-cancel) :void
  (connection :pointer))

(cffi:defcfun ("xpc_connection_send_message" %xpc-connection-send-message) :void
  (connection :pointer)
  (message :pointer))

(cffi:defcfun ("xpc_connection_send_message_with_reply_sync" %xpc-connection-send-message-with-reply-sync) :pointer
  (connection :pointer)
  (message :pointer))

(cffi:defcfun ("xpc_dictionary_create" %xpc-dictionary-create) :pointer
  (keys :pointer)
  (values :pointer)
  (count :unsigned-long))

(cffi:defcfun ("xpc_dictionary_create_reply" %xpc-dictionary-create-reply) :pointer
  (original :pointer))

(cffi:defcfun ("xpc_dictionary_set_string" %xpc-dictionary-set-string) :void
  (dictionary :pointer)
  (key :string)
  (value :string))

(cffi:defcfun ("xpc_dictionary_get_string" %xpc-dictionary-get-string) :string
  (dictionary :pointer)
  (key :string))

(cffi:defcfun ("xpc_get_type" %xpc-get-type) :pointer
  (object :pointer))

(cffi:defcfun ("xpc_release" %xpc-release) :void
  (object :pointer))

(cffi:defcfun ("xpc_copy_description" %xpc-copy-description) :pointer
  (object :pointer))

(cffi:defcfun ("dispatch_main" %dispatch-main) :void)

(defconstant +xpc-connection-mach-service-listener+ 1)

(defun xpc-type (object)
  "One of :DICTIONARY, :CONNECTION, :ERROR, or the type's address for
anything else.  The type objects are exported data symbols, compared by
address, which is what the C macros do."
  (let ((type (%xpc-get-type object)))
    (flet ((is (name) (cffi:pointer-eq type (cffi:foreign-symbol-pointer name))))
      (cond ((is "_xpc_type_dictionary") :dictionary)
            ((is "_xpc_type_connection") :connection)
            ((is "_xpc_type_error") :error)
            (t type)))))

(defun xpc-description (object)
  "libxpc's own description of OBJECT, for messages and errors."
  (let ((pointer (%xpc-copy-description object)))
    (unwind-protect (cffi:foreign-string-to-lisp pointer)
      (cffi:foreign-free pointer))))

(defun make-message (&rest strings)
  "An XPC dictionary of STRINGS, given as key value key value."
  (let ((dictionary (%xpc-dictionary-create (cffi:null-pointer) (cffi:null-pointer) 0)))
    (loop :for (key value) :on strings :by #'cddr
          :do (%xpc-dictionary-set-string dictionary key value))
    dictionary))

;;; The handler block --------------------------------------------------------
;;; One shape serves listener and peer alike: a block of one xpc_object_t.

(objc:define-objc-block-type xpc-event-handler :void ((:pointer :void)))

(defun set-event-handler (connection function)
  "Make FUNCTION, of one XPC object, CONNECTION's event handler.

The block is freed on return: xpc_connection_set_event_handler copies it,
and the copy holds the closure for as long as the connection does."
  (objc:with-objc-block (block 'xpc-event-handler function)
    (%xpc-connection-set-event-handler connection (objc:objc-block-pointer block))))

;;; The service --------------------------------------------------------------

(defun evaluate-request (form)
  "Read and evaluate FORM in COMMON-LISP-USER, returning either the printed
value or a printed error, as (VALUES VALUE ERROR)."
  (handler-case
      (let ((*package* (find-package "COMMON-LISP-USER")))
        (values (prin1-to-string (eval (read-from-string form))) nil))
    (error (condition)
      (values nil (princ-to-string condition)))))

(defun answer (peer message)
  "Reply to MESSAGE on PEER: a dictionary with either value or error, and
the name of the thread that did the work, which is the interesting part."
  (let ((reply (%xpc-dictionary-create-reply message))
        (form (%xpc-dictionary-get-string message "form")))
    (unwind-protect
         (progn
           (if (null form)
               (%xpc-dictionary-set-string reply "error" "no form in the request")
               (multiple-value-bind (value error) (evaluate-request form)
                 (if error
                     (%xpc-dictionary-set-string reply "error" error)
                     (%xpc-dictionary-set-string reply "value" value))))
           (%xpc-dictionary-set-string reply "thread"
                                       (or (bt:thread-name (bt:current-thread)) "unnamed"))
           (%xpc-connection-send-message peer reply))
      (%xpc-release reply))))

(defun serve-peer (peer)
  "Answer every message a client sends on PEER until it goes away."
  (set-event-handler peer
                     (lambda (event)
                       (case (xpc-type event)
                         (:dictionary (answer peer event))
                         ;; An error here is the peer's end closing, which
                         ;; needs no reply and no action: the connection is
                         ;; done, and libxpc releases what it made.
                         (:error nil))))
  (%xpc-connection-resume peer))

(defun serve-listener (listener)
  "Accept every client that connects to LISTENER."
  (set-event-handler listener
                     (lambda (event)
                       (case (xpc-type event)
                         (:connection (serve-peer event))
                         (:error nil))))
  (%xpc-connection-resume listener))

(defun make-anonymous-listener (queue)
  "A listener with no name, reachable through its endpoint: what a process
uses to hand a connection to another over an existing one."
  (let ((listener (%xpc-connection-create (cffi:null-pointer) queue)))
    (serve-listener listener)
    listener))

(defun make-mach-listener (name queue)
  "A listener registered with launchd as the Mach service NAME.  Only a
process launchd started for that name may create one; see
INSTALL-LISP-SERVICE."
  (let ((listener (%xpc-connection-create-mach-service
                   name queue +xpc-connection-mach-service-listener+)))
    (serve-listener listener)
    listener))

;;; The client ---------------------------------------------------------------

(defun connect-client (connection)
  "Resume CONNECTION as a client.  Its handler has nothing to do: a client
that only ever sends with a synchronous reply learns of trouble from the
reply, and the one event it would otherwise see is the invalidation its own
cancel causes."
  (set-event-handler connection (lambda (event) (declare (ignore event)) nil))
  (%xpc-connection-resume connection)
  connection)

(defun call-service (connection form)
  "Have the service on CONNECTION evaluate FORM, a string.  Returns the
printed value, or signals with the service's error.  Waits for the reply."
  (let* ((message (make-message "op" "eval" "form" form))
         (reply (unwind-protect (%xpc-connection-send-message-with-reply-sync connection message)
                  (%xpc-release message))))
    (unwind-protect
         (ecase (xpc-type reply)
           (:dictionary
            (let ((error (%xpc-dictionary-get-string reply "error")))
              (if error
                  (error "The Lisp service said: ~a" error)
                  (values (%xpc-dictionary-get-string reply "value")
                          (%xpc-dictionary-get-string reply "thread")))))
           (:error
            (error "No reply from the Lisp service: ~a" (xpc-description reply))))
      (%xpc-release reply))))

;;; Both ends in one process --------------------------------------------------

(defun test-xpc ()
  "Serve and call over an anonymous listener, in this process, and return a
plist of what happened.  Needs no window server and no launchd.

    (objc/examples:test-xpc)
    => (:VALUE \"3\" :THREAD-DIFFERS T :ERROR \"...boom...\")

:THREAD-DIFFERS is the point: the value was computed on a libdispatch
thread the service's queue supplied, while this thread waited on the Mach
port for the reply."
  (with-serial-queue (queue "lisp.xpc")
    (let* ((listener (make-anonymous-listener queue))
           (endpoint (%xpc-endpoint-create listener))
           (client (connect-client (%xpc-connection-create-from-endpoint endpoint))))
      (unwind-protect
           (multiple-value-bind (value thread) (call-service client "(+ 1 2)")
             (list :value value
                   :thread-differs (not (equal thread (bt:thread-name (bt:current-thread))))
                   :error (handler-case (call-service client "(error \"boom\")")
                            (error (condition) (princ-to-string condition)))))
        (%xpc-connection-cancel client)
        (%xpc-connection-cancel listener)
        (%xpc-release endpoint)))))

;;; A separate process, through launchd -----------------------------------------

(defparameter *lisp-service-name* "org.lispnik.objc.lisp-service"
  "The Mach service name the agent answers to, and its launchd label.")

(defun lisp-service-main (&optional (name *lisp-service-name*))
  "The service process: listen as NAME and never return.  What the launchd
agent runs."
  (let ((queue (serial-queue "lisp.xpc.service")))
    (make-mach-listener name queue)
    (%dispatch-main)))

(defun launch-agent-path (name)
  (merge-pathnames (format nil "Library/LaunchAgents/~a.plist" name)
                   (user-homedir-pathname)))

(defun launch-agent-plist (name)
  "The agent: this same SBCL, loading this same objc checkout and its
libraries, then LISP-SERVICE-MAIN.  MachServices is what tells launchd to
hold the name and start the job when something connects to it."
  (let ((objc (asdf:system-source-directory :objc)))
    (format nil "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\"><dict>
  <key>Label</key><string>~a</string>
  <key>ProgramArguments</key><array>
    <string>~a</string>
    <string>--non-interactive</string>
    <string>--eval</string><string>(require :asdf)</string>
    <string>--eval</string><string>(asdf:initialize-source-registry (list :source-registry (list :directory ~s) (list :tree ~s) :inherit-configuration))</string>
    <string>--eval</string><string>(asdf:load-system :objc/examples)</string>
    <string>--eval</string><string>(objc/examples:lisp-service-main ~s)</string>
  </array>
  <key>MachServices</key><dict><key>~a</key><true/></dict>
  <key>StandardOutPath</key><string>~a</string>
  <key>StandardErrorPath</key><string>~a</string>
</dict></plist>
"
            name
            (namestring sb-ext:*runtime-pathname*)
            (namestring objc)
            (namestring (merge-pathnames "ocicl/" objc))
            name
            name
            (namestring (merge-pathnames "Library/Logs/lisp-service.log" (user-homedir-pathname)))
            (namestring (merge-pathnames "Library/Logs/lisp-service.log" (user-homedir-pathname))))))

(defun user-id ()
  "This user's numeric id, which names the launchd domain the agent lives in."
  (cffi:foreign-funcall "getuid" :unsigned-int))

(defun launchctl (&rest arguments)
  (uiop:run-program (list* "/bin/launchctl" arguments)
                    :output :string :error-output :output :ignore-error-status t))

(defun install-lisp-service (&key (name *lisp-service-name*))
  "Register the Lisp service with launchd for this user, and start it.
Writes ~/Library/LaunchAgents/NAME.plist; UNINSTALL-LISP-SERVICE removes it."
  (let ((path (launch-agent-path name)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede)
      (write-string (launch-agent-plist name) out))
    (launchctl "bootout" (format nil "gui/~d/~a" (user-id) name))
    (let ((report (launchctl "bootstrap" (format nil "gui/~d" (user-id))
                             (namestring path))))
      (unless (zerop (length (string-trim '(#\Newline #\Space) report)))
        (error "launchctl bootstrap: ~a" report)))
    path))

(defun uninstall-lisp-service (&key (name *lisp-service-name*))
  "Stop the Lisp service and remove its agent."
  (launchctl "bootout" (format nil "gui/~d/~a" (user-id) name))
  (let ((path (launch-agent-path name)))
    (when (probe-file path)
      (delete-file path))
    path))

(defun lisp-service (form &key (name *lisp-service-name*))
  "Evaluate FORM, a string, in the Lisp service process, starting it through
launchd if it is not running.  Returns the printed value and the name of
the thread it ran on there.

    (objc/examples:lisp-service \"(list (machine-instance) (sb-posix:getpid))\")"
  (with-serial-queue (queue "lisp.xpc.client")
    (let ((connection (connect-client (%xpc-connection-create-mach-service name queue 0))))
      (unwind-protect (call-service connection form)
        (%xpc-connection-cancel connection)))))
