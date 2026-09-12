;;;; examples/swift.lisp -- Swift-only frameworks from Lisp: CryptoKit, Swift
;;;; Charts in SwiftUI, and FoundationModels, the on-device language model.
;;;;
;;;; None of these has an Objective-C surface, so none is reachable through
;;;; the bridge directly.  They are reachable through Swift, which can put an
;;;; @objc face on anything: examples/swift/LispSwift.swift is a hundred lines
;;;; of that, built into a dylib by examples/swift/build.sh, and once the
;;;; library is loaded its classes are ordinary Objective-C classes with
;;;; methods that take strings, arrays and blocks.  Everything below is
;;;; OBJC:INVOKE.
;;;;
;;;; The split is the thing to see.  Swift holds only what Swift alone can
;;;; say -- the generic hash and cipher types, a SwiftUI view, an async call
;;;; -- and nothing that decides anything; the decisions, the data and the
;;;; window are here, where they can be changed while the image runs.

(in-package #:objc/examples)

(defparameter *swift-bridge*
  (asdf:system-relative-pathname :objc "examples/swift/libLispSwift.dylib")
  "Where build.sh leaves the library.")

(defvar *swift-bridge-loaded* nil)

(defun build-swift-bridge ()
  "Run examples/swift/build.sh.  Needs swiftc, which Xcode provides."
  (uiop:run-program (list "/bin/sh" (namestring (asdf:system-relative-pathname :objc "examples/swift/build.sh")))
                    :output *standard-output* :error-output *error-output*)
  *swift-bridge*)

(defun ensure-swift-bridge ()
  "Load the library, building it first if it has not been.  Loading is
what registers its classes with the Objective-C runtime."
  (unless *swift-bridge-loaded*
    (objc:ensure-objc-initialized)
    (unless (probe-file *swift-bridge*)
      (build-swift-bridge))
    (cffi:load-foreign-library (namestring *swift-bridge*))
    (setf *swift-bridge-loaded* t))
  *swift-bridge*)

(defun swift-string (pointer)
  "A Lisp string from an NSString the Swift side returned, or NIL for nil."
  (if (cffi:null-pointer-p pointer) nil (objc:ns-string-to-string pointer)))

;;; CryptoKit ---------------------------------------------------------------------

(defun sha256 (string)
  "The SHA-256 of STRING's UTF-8, as hex, from CryptoKit."
  (ensure-swift-bridge)
  (swift-string (objc:invoke "LispCrypto" "sha256:" string)))

(defun hmac-sha256 (string key)
  (ensure-swift-bridge)
  (swift-string (objc:invoke "LispCrypto" "hmac:key:" string key)))

(defun random-key ()
  "A fresh 256-bit key, base64, for SEAL and OPEN."
  (ensure-swift-bridge)
  (swift-string (objc:invoke "LispCrypto" "randomKey")))

(defun seal (string key)
  "STRING sealed with ChaCha20-Poly1305 under KEY, base64."
  (ensure-swift-bridge)
  (swift-string (objc:invoke "LispCrypto" "seal:key:" string key)))

(defun open-sealed (sealed key)
  "What SEAL sealed, or NIL if KEY is wrong or SEALED was altered."
  (ensure-swift-bridge)
  (swift-string (objc:invoke "LispCrypto" "open:key:" sealed key)))

;;; Swift Charts ------------------------------------------------------------------

(defun ns-numbers (numbers)
  "An NSArray of NSNumbers, which is what the Swift side's [NSNumber] is."
  (let ((array (objc:invoke "NSMutableArray" "array")))
    (dolist (number numbers array)
      (objc:invoke array "addObject:" (objc:invoke "NSNumber" "numberWithDouble:" (float number 1d0))))))

(defun bar-chart-view (title data)
  "An NSView showing a Swift Charts bar chart of DATA, an alist of label to
value, to put in any AppKit window."
  (ensure-swift-bridge)
  (objc:invoke "LispCharts" "barChartWithTitle:labels:values:"
               title (coerce (mapcar #'car data) 'vector) (ns-numbers (mapcar #'cdr data))))

(defun bar-chart-png (title data path &key (width 480) (height 320))
  "The same chart rendered by SwiftUI itself into a PNG at PATH, with no
window involved.  Returns T when written."
  (ensure-swift-bridge)
  (objc:invoke-bool "LispCharts" "barChartWithTitle:labels:values:width:height:pngTo:"
                    title (coerce (mapcar #'car data) 'vector) (ns-numbers (mapcar #'cdr data))
                    (float width 1d0) (float height 1d0) (namestring path)))

(defun show-bar-chart (title data &key (seconds 3))
  "A window with the chart in it, kept on screen for SECONDS by pumping
the run loop, then closed.  Returns the window."
  (let* ((view (bar-chart-view title data))
         (window (make-window :title title :rect #(200 200 480 320))))
    (objc:invoke view "setFrame:" (objc:invoke (objc:invoke window "contentView") "bounds"))
    (objc:invoke view "setAutoresizingMask:" 18)
    (add-subview window view)
    (show-window window :seconds seconds)
    (objc:invoke window "close")
    window))

;;; FoundationModels ---------------------------------------------------------------

(objc:define-objc-block-type language-model-reply :void (objc:objc-object-pointer objc:objc-object-pointer))

(defun language-model-availability ()
  "\"available\", or \"unavailable: <why>\" -- Apple Intelligence off, the
model not downloaded, or the machine or region not supported."
  (ensure-swift-bridge)
  (swift-string (objc:invoke "LispLanguageModel" "availability")))

(defun ask-language-model (prompt &key instructions (timeout 120))
  "Ask the on-device model PROMPT, under INSTRUCTIONS if given, and wait
for its answer.  Signals with the model's reason if it cannot answer."
  (ensure-swift-bridge)
  (let ((semaphore (bt:make-semaphore))
        (answer nil)
        (failure nil))
    (objc:with-objc-block (block 'language-model-reply
                                 (lambda (response error)
                                   (setf answer (swift-string response)
                                         failure (swift-string error))
                                   (bt:signal-semaphore semaphore)))
      (objc:invoke "LispLanguageModel" "respondTo:instructions:reply:" prompt instructions block)
      (unless (bt:wait-on-semaphore semaphore :timeout timeout)
        (error "The language model did not answer in ~d seconds." timeout)))
    (when failure
      (error "The language model could not answer: ~a" failure))
    answer))

;;; All of it, measured -------------------------------------------------------------

(defun test-swift-bridge (&key (png (merge-pathnames "lisp-swift-chart.png" (uiop:temporary-directory))))
  "Exercise each framework and return a plist.  Needs swiftc the first time.

    (objc/examples:test-swift-bridge)
    => (:SHA256-OF-ABC \"ba7816bf...\" :HMAC-RFC-4231 \"5bdcc146...\" :SEALED-ROUND-TRIP T
        :TAMPERED-REFUSED T :CHART-PNG #P\"...\" :LANGUAGE-MODEL \"available\" :ANSWER \"...\")

The hash and HMAC are checked against their published test vectors; the
sealed round trip and its refusal of a tampered box are checked here; the
chart is written for eyes; the model is asked only when it says it can."
  (let* ((key (random-key))
         (sealed (seal "attack at dawn" key))
         (tampered (concatenate 'string (subseq sealed 0 (- (length sealed) 8))
                                (if (char= (char sealed (- (length sealed) 8)) #\A) "B" "A")
                                (subseq sealed (- (length sealed) 7))))
         (availability (language-model-availability)))
    (list :sha256-of-abc (sha256 "abc")
          :hmac-rfc-4231 (hmac-sha256 "what do ya want for nothing?" "Jefe")
          :sealed-round-trip (equal "attack at dawn" (open-sealed sealed key))
          :tampered-refused (null (open-sealed tampered key))
          :chart-png (and (bar-chart-png "Lines of Lisp per frontend"
                                         '(("ncurses" . 2100) ("sdl2" . 4800) ("webview" . 1900) ("cocoa" . 1300))
                                         png)
                          png)
          :language-model availability
          :answer (when (string= availability "available")
                    (ask-language-model "Reply with one short sentence: what is a Lisp macro?"
                                        :instructions "You are terse.")))))
