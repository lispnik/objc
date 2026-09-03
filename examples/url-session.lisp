;;;; examples/url-session.lisp -- NSURLSession, the completion-handler API.
;;;;
;;;; If GCD is the shortest answer to "what did block creation buy", this is the
;;;; one people actually meet first.  -dataTaskWithURL:completionHandler: is the
;;;; shape of nearly every modern Cocoa API: you hand it a block, it does the
;;;; work somewhere else, and it calls your block when the answer is ready.
;;;; Before MAKE-OBJC-BLOCK there was no way to call it at all.
;;;;
;;;; The interesting part is not the fetching.  It is that a completion handler
;;;; runs on a queue Foundation chooses, and by default that queue runs several
;;;; handlers at once -- which, on a stock SBCL, is the thing that kills the
;;;; process.  See the header of gcd.lisp for why: a collection has to signal
;;;; every thread that is in Lisp, and Darwin will not signal a libdispatch
;;;; worker at all.
;;;;
;;;; The fix is one line, and it is the reason this example is worth reading:
;;;;
;;;;     (objc:invoke queue "setMaxConcurrentOperationCount:" 1)
;;;;
;;;; A session built with that delegate queue runs its completion handlers ONE
;;;; AT A TIME.  What it does not do is serialise the transfers -- eight requests
;;;; still go out together and download together, because that concurrency lives
;;;; inside Foundation where no Lisp runs.  Only the handing-back is serialised,
;;;; which is exactly the part that has to be.  So FETCH-ALL below issues every
;;;; request at once and is safe on any build; measured, eight at a time, on a
;;;; stock SBCL that dies immediately if you let the handlers overlap.
;;;;
;;;; Everything here is tested against file:// URLs.  A data task serves those
;;;; through the same machinery as http, so the example is honest without the
;;;; suite depending on a network, and FETCH takes an http URL just as happily.

(in-package #:objc/examples)

;;; Reading what came back -----------------------------------------------------

(defun ns-data-to-bytes (data)
  "The contents of an NSData as an (UNSIGNED-BYTE 8) vector."
  (let* ((length (objc:invoke data "length"))
         (bytes (objc:invoke data "bytes"))
         (result (make-array length :element-type '(unsigned-byte 8))))
    (dotimes (i length result)
      (setf (aref result i) (cffi:mem-aref bytes :uint8 i)))))

(defun ns-data-to-string (data &key (encoding :utf-8))
  "The contents of an NSData decoded as text."
  (cffi:foreign-string-to-lisp (objc:invoke data "bytes")
                               :count (objc:invoke data "length")
                               :encoding encoding))

(defun response-status (response)
  "The HTTP status of RESPONSE, or NIL when it is not an HTTP response.

An -isKindOfClass: check, and not the tidier-looking CAN-INVOKE-P on
\"statusCode\", because that one is wrong: a file:// transfer comes back as a
plain NSURLResponse -- measured, that is its actual class -- which nevertheless
answers -statusCode, with 200.  The selector exists on the class without being
part of its documented interface, so asking whether the object responds to it
reports an HTTP status for a transfer that never spoke HTTP.

A good illustration of where CAN-INVOKE-P belongs and where it does not: it
answers \"will this send work\", which is not the same question as \"is this
that kind of object\"."
  (when (objc:invoke-bool response "isKindOfClass:"
                          (objc:coerce-to-objc-class "NSHTTPURLResponse"))
    (objc:invoke response "statusCode")))

;;; The session ----------------------------------------------------------------

(defun serial-session (&key (timeout 30))
  "An NSURLSession whose completion handlers run one at a time.

The delegate queue's concurrency is the whole point -- see the header.  Requests
still overlap; only the callbacks into Lisp are serialised.

Release it with -finishTasksAndInvalidate, or use WITH-URL-SESSION."
  (let ((queue (objc:invoke (objc:alloc-init-object "NSOperationQueue") "self"))
        (configuration (objc:invoke "NSURLSessionConfiguration"
                                    "defaultSessionConfiguration")))
    (objc:invoke queue "setMaxConcurrentOperationCount:" 1)
    (objc:invoke queue "setName:" "lisp.url-session")
    (objc:invoke configuration "setTimeoutIntervalForRequest:" (float timeout 1d0))
    (objc:invoke "NSURLSession" "sessionWithConfiguration:delegate:delegateQueue:"
                 configuration nil queue)))

(defmacro with-url-session ((session &key (timeout 30)) &body body)
  "Bind SESSION for the extent of BODY and let its outstanding tasks finish.

-finishTasksAndInvalidate rather than -invalidateAndCancel: a task still in
flight when BODY returns is allowed to complete, which is what you want after a
FETCH-ALL that timed out waiting."
  `(let ((,session (serial-session :timeout ,timeout)))
     (unwind-protect (locally ,@body)
       (objc:invoke ,session "finishTasksAndInvalidate"))))

(defun coerce-url (url)
  "An NSURL from a string, a pathname, or an NSURL.

A pathname, or a string naming an existing file, becomes a file:// URL -- which
is what makes this example testable without a network."
  (etypecase url
    (pathname (objc:invoke "NSURL" "fileURLWithPath:" (namestring (truename url))))
    (string (if (probe-file url)
                (objc:invoke "NSURL" "fileURLWithPath:" (namestring (truename url)))
                (objc:invoke "NSURL" "URLWithString:" url)))
    (t url)))

;;; Fetching -------------------------------------------------------------------

(defun fetch-async (url function &key session)
  "Start a request for URL and call FUNCTION with the result when it arrives.

FUNCTION is called as (CONTENT STATUS ERROR) on the session's delegate queue --
a thread SBCL did not create -- so it needs its own autorelease pool if it
touches Cocoa, and it must not assume it is the main thread.  Returns the task.

WITH-OBJC-BLOCK even though the work outlives this call: the task copies the
block before -dataTaskWithURL:completionHandler: returns, and the copy holds the
Lisp closure until Foundation is done with it.  That is what the block API's copy
and dispose helpers are for."
  (let* ((session (or session (serial-session)))
         (task nil))
    (objc:with-objc-block
        (block '(:void (objc:objc-object-pointer objc:objc-object-pointer
                        objc:objc-object-pointer))
               (lambda (data response error)
                 (objc:with-autorelease-pool ()
                   (let ((failed (not (cffi:null-pointer-p
                                       (objc:objc-object-pointer error)))))
                     (funcall function
                              (unless failed (ns-data-to-bytes data))
                              (unless failed (response-status response))
                              (when failed
                                (objc:ns-string-to-string
                                 (objc:invoke error "localizedDescription"))))))))
      (setf task (objc:invoke session "dataTaskWithURL:completionHandler:"
                              (coerce-url url) block))
      (objc:invoke task "resume"))
    task))

(defun fetch (url &key (as :string) (timeout 30) session)
  "Fetch URL and return (VALUES CONTENT STATUS ERROR).  Blocks until it is done.

AS is :STRING or :BYTES.  CONTENT and STATUS are NIL when the transfer failed and
ERROR is then the localised description; STATUS is NIL for a file:// URL, which
has no HTTP status.

    (fetch \"https://example.com/\")
    (fetch #p\"/etc/hosts\" :as :bytes)

The waiting is a semaphore the completion handler signals.  That is one queue
thread inside Lisp while this one blocks, which is the safe side of the line
gcd.lisp draws."
  (let ((done (bt:make-semaphore))
        (content nil) (status nil) (failure nil))
    (flet ((run (session)
             (fetch-async url
                          (lambda (bytes code error)
                            (setf content bytes status code failure error)
                            (bt:signal-semaphore done))
                          :session session)
             (unless (bt:wait-on-semaphore done :timeout timeout)
               (setf failure (format nil "timed out after ~D second~:P" timeout)))))
      (if session
          (run session)
          (with-url-session (owned :timeout timeout) (run owned))))
    (values (when content
              (ecase as
                (:bytes content)
                (:string (sb-ext:octets-to-string content :external-format :utf-8))))
            status
            failure)))

(defun fetch-all (urls &key (as :string) (timeout 30))
  "Fetch every URL, all at once, and return a vector of (VALUES ...) lists.

Each element is (CONTENT STATUS ERROR), in the order given.  Every request is in
flight together -- the transfers genuinely overlap -- while the completion
handlers run one at a time, which is what makes this safe on a stock SBCL where
overlapping handlers would end the process."
  (let* ((urls (coerce urls 'vector))
         (results (make-array (length urls) :initial-element nil))
         (remaining (length urls))
         (lock (bt:make-lock "url-session"))
         (done (bt:make-semaphore)))
    (when (zerop (length urls))
      (return-from fetch-all results))
    (with-url-session (session :timeout timeout)
      (loop for url across urls
            for i from 0
            do (let ((i i))
                 (fetch-async url
                              (lambda (bytes code error)
                                (setf (aref results i)
                                      (list (when bytes
                                              (ecase as
                                                (:bytes bytes)
                                                (:string (sb-ext:octets-to-string
                                                          bytes :external-format :utf-8))))
                                            code error))
                                (bt:with-lock-held (lock)
                                  (when (zerop (decf remaining))
                                    (bt:signal-semaphore done))))
                              :session session)))
      (unless (bt:wait-on-semaphore done :timeout timeout)
        (bt:with-lock-held (lock)
          (loop for i below (length results)
                unless (aref results i)
                  do (setf (aref results i) (list nil nil "timed out"))))))
    results))

;;; A worked example -----------------------------------------------------------

(defun test-url-session (&key (count 8))
  "Exercise every shape against file:// URLs.  No network, no window server.

    (objc/examples:test-url-session)
    => (:ONE \"payload 0\" :STATUS NIL :MISSING T :ALL 8 :CONCURRENT T)

:MISSING is true when a URL that does not exist reported an error rather than
pretending to succeed, and :CONCURRENT is true when all COUNT transfers came
back -- issued together, handed back one at a time."
  (objc:ensure-objc-initialized)
  (let ((paths (loop for i below count
                     for path = (format nil "~Aobjc-url-session-~D.txt"
                                        (uiop:temporary-directory) i)
                     do (with-open-file (out path :direction :output
                                                  :if-exists :supersede)
                          (format out "payload ~D" i))
                     collect path)))
    (unwind-protect
         (objc:with-autorelease-pool ()
           (multiple-value-bind (content status error) (fetch (first paths))
             (declare (ignore error))
             (let* ((missing (nth-value 2 (fetch "/nonexistent/objc-url-session")))
                    (all (fetch-all paths)))
               (list :one content
                     :status status
                     :missing (and missing t)
                     :all (count-if (lambda (r) (first r)) all)
                     :concurrent (equal (loop for i below count
                                              collect (format nil "payload ~D" i))
                                        (map 'list #'first all))))))
      (mapc (lambda (p) (ignore-errors (delete-file p))) paths))))

(defun report-url-session ()
  "Print what TEST-URL-SESSION found, then fetch one real URL if the network is
there -- which is not part of the test, because a suite should not need one."
  (let ((result (test-url-session)))
    (format t "~&one file:// fetch returned ~S (status ~A)~%"
            (getf result :one) (getf result :status))
    (format t "a missing file reported an error: ~A~%" (getf result :missing))
    (format t "~D concurrent transfers, all in order: ~A~%"
            (getf result :all) (getf result :concurrent))
    (multiple-value-bind (content status error) (fetch "https://example.com/" :timeout 10)
      (if error
          (format t "no network, or it refused: ~A~%" error)
          (format t "https://example.com/ -> status ~A, ~D characters~%"
                  status (length content))))
    result))
