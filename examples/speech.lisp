;;;; examples/speech.lisp -- text to speech, into a buffer or out loud.
;;;;
;;;; AVSpeechSynthesizer will speak a string, and -- more interestingly -- will
;;;; hand the audio back instead of playing it, a buffer at a time, through a
;;;; block.  So a sentence becomes a vector of samples, which composes with the
;;;; WAV writer in audio.lisp: text in, a file you can play out.
;;;;
;;;; THE CALLBACK ARRIVES ON THE MAIN THREAD, VIA THE RUN LOOP, and unlike
;;;; MapKit there is no second selector that takes a queue.  So a blocking wait
;;;; does not merely deadlock -- there is no arrangement of threads that fixes
;;;; it.  The only way to receive the buffers is to SERVICE THE RUN LOOP while
;;;; waiting, which is what OBJC.RUNLOOP:PUMP-EVENTS does.
;;;;
;;;; That makes this the first example needing the run-loop helpers for
;;;; something with no window in it at all.  They were written for AppKit, where
;;;; the need is obvious; this is a headless API that turns out to have the same
;;;; requirement, and it is the reason those helpers are not an AppKit detail.
;;;; Measured: a semaphore wait sees zero buffers in twenty seconds, and pumping
;;;; sees 122 of them in about a second.
;;;;
;;;; A ZERO-LENGTH BUFFER MEANS THE END.  There is no other completion signal --
;;;; no error argument, no separate callback -- so a reader that waits for a
;;;; count it guessed will hang, and one that stops at the first short buffer
;;;; will truncate.

(in-package #:objc/examples)

(defparameter +speech-frameworks+
  '("/System/Library/Frameworks/AVFAudio.framework/AVFAudio"))

(defun ensure-speech ()
  (objc:ensure-objc-initialized :modules +speech-frameworks+))

(objc:define-objc-block-type speech-buffer-block
    :void (objc:objc-object-pointer))

;;; Voices ------------------------------------------------------------------------

(defun voices (&key language)
  "Every installed voice, as plists, optionally filtered by LANGUAGE prefix.

    (voices :language \"en\")
    => ((:NAME \"Daniel\" :LANGUAGE \"en-GB\" :IDENTIFIER \"com.apple...\") ...)"
  (ensure-speech)
  (objc:with-autorelease-pool ()
    (let ((all (objc:invoke "AVSpeechSynthesisVoice" "speechVoices")))
      (loop for i below (objc:invoke all "count")
            for voice = (objc:invoke all "objectAtIndex:" i)
            for code = (objc:invoke-into 'string voice "language")
            when (or (null language)
                     (and (<= (length language) (length code))
                          (string= language code :end2 (length language))))
              collect (list :name (objc:invoke-into 'string voice "name")
                            :language code
                            :identifier (objc:invoke-into 'string voice "identifier"))))))

(defun make-utterance (text &key voice (rate nil) (pitch nil) (volume nil))
  "An AVSpeechUtterance for TEXT.

VOICE is a language code like \"en-GB\", a voice identifier, or NIL for the
system default.  RATE is roughly 0.0 to 1.0 with 0.5 normal."
  (ensure-speech)
  (let ((utterance (objc:invoke "AVSpeechUtterance" "speechUtteranceWithString:" text)))
    (when voice
      (let ((object (or (find-voice voice)
                        (error "No voice matching ~S; try (voices)." voice))))
        (objc:invoke utterance "setVoice:" object)))
    (when rate (objc:invoke utterance "setRate:" (float rate 1.0)))
    (when pitch (objc:invoke utterance "setPitchMultiplier:" (float pitch 1.0)))
    (when volume (objc:invoke utterance "setVolume:" (float volume 1.0)))
    utterance))

(defun find-voice (designator)
  "A voice object for a language code or an identifier, or NIL."
  (ensure-speech)
  (let ((by-language (objc:invoke "AVSpeechSynthesisVoice" "voiceWithLanguage:"
                                  designator)))
    (if (not (cffi:null-pointer-p (objc:objc-object-pointer by-language)))
        by-language
        (let ((by-identifier (objc:invoke "AVSpeechSynthesisVoice"
                                          "voiceWithIdentifier:" designator)))
          (unless (cffi:null-pointer-p (objc:objc-object-pointer by-identifier))
            by-identifier)))))

;;; Into a buffer ---------------------------------------------------------------------

(defun speak-to-samples (text &key voice rate pitch (timeout 30))
  "Synthesise TEXT and return (VALUES SAMPLES SAMPLE-RATE).

    (speak-to-samples \"Hello from Common Lisp.\" :voice \"en-GB\")
    => #(0.0 0.0 ...), 22050.0d0

Nothing is played.  The sample rate is the VOICE's, not one you choose -- 22050
for the compact voices, more for the better ones -- so it is returned rather
than assumed, and WRITE-WAV wants it.

Pumps the run loop while waiting, because that is the only way the buffers
arrive; see the header."
  (ensure-speech)
  (objc:with-autorelease-pool ()
    (let ((synthesiser (objc:alloc-init-object "AVSpeechSynthesizer"))
          (utterance (make-utterance text :voice voice :rate rate :pitch pitch))
          (chunks '())
          (total 0)
          (sample-rate nil)
          (finished nil))
      (objc:with-objc-block
          (block 'speech-buffer-block
                 (lambda (buffer)
                   (objc:with-autorelease-pool ()
                     (let ((frames (objc:invoke buffer "frameLength")))
                       (cond
                         ((zerop frames) (setf finished t))
                         (t
                          (unless sample-rate
                            (setf sample-rate
                                  (objc:invoke (objc:invoke buffer "format")
                                               "sampleRate")))
                          (let ((channel (cffi:mem-ref
                                          (objc:invoke buffer "floatChannelData")
                                          :pointer))
                                (chunk (make-array frames
                                                   :element-type 'single-float)))
                            (dotimes (i frames)
                              (setf (aref chunk i) (cffi:mem-aref channel :float i)))
                            (push chunk chunks)
                            (incf total frames))))))))
        (objc:invoke synthesiser "writeUtterance:toBufferCallback:" utterance block)
        ;; PUMP, do not wait.  The callback wants this thread.
        (let ((deadline (+ (get-internal-real-time)
                           (* timeout internal-time-units-per-second))))
          (loop until (or finished (> (get-internal-real-time) deadline))
                do (objc.runloop:pump-events :seconds 0.02d0 :max-seconds 0.2d0))))
      (unless finished
        (error "The synthesiser produced no end-of-stream within ~D second~:P."
               timeout))
      (let ((samples (make-array total :element-type 'single-float))
            (at 0))
        (dolist (chunk (nreverse chunks))
          (replace samples chunk :start1 at)
          (incf at (length chunk)))
        (values samples (or sample-rate 22050d0))))))

(defun speak-to-file (text path &rest options)
  "Synthesise TEXT and write it to PATH as a WAV.  Returns PATH.

    (speak-to-file \"Lisp is a programmable programming language.\"
                   #p\"/tmp/quote.wav\")"
  (multiple-value-bind (samples rate) (apply #'speak-to-samples text options)
    (write-wav samples path :rate (round rate))
    path))

;;; Out loud -- not called by any test ---------------------------------------------------

(defun say (text &key voice rate pitch (wait t))
  "Speak TEXT through the speakers.  Makes a noise.

Pumps the run loop while it speaks, for the same reason SPEAK-TO-SAMPLES does:
the synthesiser wants this thread.  With :WAIT NIL it starts and returns, which
is only useful if something else is servicing the run loop."
  (ensure-speech)
  (let ((synthesiser (objc:alloc-init-object "AVSpeechSynthesizer"))
        (utterance (make-utterance text :voice voice :rate rate :pitch pitch)))
    (objc:invoke synthesiser "speakUtterance:" utterance)
    (when wait
      (loop while (objc:invoke-bool synthesiser "isSpeaking")
            do (objc.runloop:pump-events :seconds 0.05d0 :max-seconds 0.2d0)))
    text))

;;; A worked example -----------------------------------------------------------------------

(defun test-speech ()
  "Synthesise a sentence into a buffer and check it is speech-shaped.

    (objc/examples:test-speech)
    => (:VOICES 100 :SAMPLES 30637 :RATE 22050.0d0 :SECONDS 1.39 :NOT-SILENT T
        :LONGER-IS-LONGER T :WAV T)

:LONGER-IS-LONGER is the one with teeth.  A longer sentence must give more
samples, which is a claim that the synthesiser actually rendered THIS text --
where a fixed buffer, a truncation at the first chunk, or an early end-of-stream
would all give the same length twice and satisfy everything else here."
  (ensure-speech)
  (let ((available (voices :language "en")))
    (if (null available)
        (list :voices 0)
        (multiple-value-bind (samples rate)
            (speak-to-samples "Hello from Common Lisp.")
          (let ((longer (speak-to-samples
                         "Hello from Common Lisp, speaking rather more words \
than the first sentence did.")))
            (list :voices (length available)
                  :samples (length samples)
                  :rate rate
                  :seconds (float (/ (length samples) rate) 1.0)
                  :not-silent (some (lambda (s) (> (abs s) 0.01)) samples)
                  :longer-is-longer (> (length longer) (length samples))
                  :wav (uiop:with-temporary-file (:pathname path :type "wav")
                         (write-wav samples path :rate (round rate))
                         (with-open-file (in path :element-type '(unsigned-byte 8))
                           (= (+ 44 (* 2 (length samples)))
                              (file-length in))))))))))

(defun report-speech (&key (path "/tmp/objc-speech.wav") say)
  "Synthesise a sentence to PATH, and say it out loud if asked."
  (ensure-speech)
  (let ((english (voices :language "en")))
    (format t "~&~D voices installed, ~D of them English~%"
            (length (voices)) (length english))
    (loop for voice in (subseq english 0 (min 5 (length english)))
          do (format t "  ~-12A ~A~%" (getf voice :language) (getf voice :name))))
  (multiple-value-bind (samples rate)
      (speak-to-samples "Lisp is a programmable programming language.")
    (write-wav samples path :rate (round rate))
    (format t "~D samples at ~,0FHz (~,2F seconds) -> ~A~%"
            (length samples) rate (/ (length samples) rate) path))
  (when say
    (say "Lisp is a programmable programming language."))
  path)
