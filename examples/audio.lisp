;;;; examples/audio.lisp -- sound, generated a sample at a time by a Lisp closure.
;;;;
;;;; AVAudioSourceNode takes a block and calls it whenever the engine needs
;;;; audio, handing it a buffer to fill.  So the block is the instrument: what
;;;; comes out of the speakers is whatever a Lisp function put in the buffer,
;;;; computed while you listen.  Nothing else in this set produces output that
;;;; continues after the call returns.
;;;;
;;;; THE RENDER BLOCK RUNS ON A REAL-TIME AUDIO THREAD, and that is the fact
;;;; worth taking away.  The thread has a deadline: fill the buffer before the
;;;; hardware needs it or the user hears a gap.  A Lisp closure there is
;;;; therefore subject to something no other example has to think about -- a
;;;; garbage collection that pauses it past the deadline is audible.  For a sine
;;;; wave that allocates nothing this is fine, and it stops being fine the moment
;;;; the instrument conses.  Consing in a render block is the audio equivalent of
;;;; consing in an interrupt handler.
;;;;
;;;; It is one thread, so it is on the safe side of the line gcd.lisp draws.
;;;;
;;;; TESTED OFFLINE AND DEMONSTRATED LIVE, and the split matters.  AVAudioEngine
;;;; has a manual rendering mode that runs the whole graph as fast as it can into
;;;; a buffer, with no audio device involved -- so SYNTHESIZE is deterministic,
;;;; needs no sound hardware, makes no noise, and works on a CI runner.  PLAY is
;;;; the same instrument through the speakers, and no test calls it.

(in-package #:objc/examples)

(defparameter +audio-frameworks+
  '("/System/Library/Frameworks/AVFAudio.framework/AVFAudio"))

(defun ensure-audio ()
  (objc:ensure-objc-initialized :modules +audio-frameworks+))

(defconstant +default-sample-rate+ 44100)

;;; The render block ------------------------------------------------------------------
;;;
;;; OSStatus (^)(BOOL *isSilence, const AudioTimeStamp *, AVAudioFrameCount,
;;;              AudioBufferList *)
;;;
;;; The AudioBufferList layout is the only fiddly part, and it is fiddly only
;;; because it is a C struct with a trailing array:
;;;
;;;     0   UInt32      mNumberBuffers
;;;     4   (padding, because the next member needs eight-byte alignment)
;;;     8   AudioBuffer mBuffers[0].mNumberChannels
;;;     12              mBuffers[0].mDataByteSize
;;;     16              mBuffers[0].mData      <- the floats go here
;;;
;;; Read out rather than declared, because DEFINE-OBJC-STRUCT describes a
;;; structure passed by value and this one arrives as a pointer.

(objc:define-objc-block-type audio-render-block
    :int ((:pointer objc:objc-bool) (:pointer :void) (:unsigned :int)
          (:pointer :void)))

(defconstant +buffer-list-data-offset+ 16
  "Where mBuffers[0].mData sits in an AudioBufferList.")

(defun buffer-list-channel (buffer-list &optional (channel 0))
  "The float* for one channel of an AudioBufferList.

Each channel is its own AudioBuffer for a non-interleaved format, which is what
-initStandardFormatWithSampleRate:channels: gives you, and they are 16 bytes
apart."
  (cffi:mem-ref buffer-list :pointer (+ +buffer-list-data-offset+ (* channel 16))))

(defun make-render-block (instrument rate channels)
  "A block that fills each buffer by calling INSTRUMENT with the time in seconds.

INSTRUMENT is called once per frame and must return an amplitude in -1.0 to 1.0.
It runs on the audio thread; see the header."
  (let ((frame 0))
    (objc:make-objc-block
     'audio-render-block
     (lambda (silence timestamp frame-count buffer-list)
       (declare (ignore silence timestamp))
       (let ((pointers (loop for channel below channels
                             collect (buffer-list-channel buffer-list channel))))
         (dotimes (i frame-count)
           (let ((value (float (funcall instrument (/ (+ frame i) rate)) 1.0)))
             (dolist (pointer pointers)
               (setf (cffi:mem-aref pointer :float i) value)))))
       (incf frame frame-count)
       0))))                            ; noErr

;;; Building an engine ---------------------------------------------------------------

(defun make-audio-engine (instrument &key (rate +default-sample-rate+) (channels 1))
  "An AVAudioEngine with INSTRUMENT wired to the main mixer.

Returns (VALUES ENGINE FORMAT BLOCK).  The block must outlive the engine, so the
caller keeps it and frees it after stopping -- an engine that is still running
will call it."
  (ensure-audio)
  (let* ((engine (objc:alloc-init-object "AVAudioEngine"))
         (format (objc:invoke (objc:invoke "AVAudioFormat" "alloc")
                              "initStandardFormatWithSampleRate:channels:"
                              (float rate 1d0) channels))
         (block (make-render-block instrument rate channels))
         (node (objc:invoke (objc:invoke "AVAudioSourceNode" "alloc")
                            "initWithFormat:renderBlock:" format block)))
    (objc:invoke engine "attachNode:" node)
    (objc:invoke engine "connect:to:format:" node
                 (objc:invoke engine "mainMixerNode") format)
    (values engine format block)))

;;; Offline -- what the tests use --------------------------------------------------------

(defun synthesize (instrument &key (seconds 1) (rate +default-sample-rate+))
  "Render INSTRUMENT offline and return the samples as a single-float vector.

    (synthesize (sine 440) :seconds 0.5)

Manual rendering mode: the graph runs as fast as it can into a buffer with no
audio device involved, so this is deterministic, silent, and works where there
is no sound hardware at all.  The same instrument played by PLAY sounds like
what this returns."
  (ensure-audio)
  (let ((frames (round (* seconds rate))))
    (multiple-value-bind (engine format block) (make-audio-engine instrument :rate rate)
      (unwind-protect
           (objc:with-autorelease-pool ()
             (cffi:with-foreign-object (error-out :pointer)
               (setf (cffi:mem-ref error-out :pointer) (cffi:null-pointer))
               (unless (objc:invoke-bool engine
                                         "enableManualRenderingMode:format:maximumFrameCount:error:"
                                         0 format (min frames 4096) error-out)
                 (error "Could not put the engine into manual rendering mode."))
               (unless (objc:invoke-bool engine "startAndReturnError:" error-out)
                 (error "The audio engine would not start.")))
             (let* ((render-format (objc:invoke engine "manualRenderingFormat"))
                    (chunk (min frames 4096))
                    (buffer (objc:invoke (objc:invoke "AVAudioPCMBuffer" "alloc")
                                         "initWithPCMFormat:frameCapacity:"
                                         render-format chunk))
                    (samples (make-array frames :element-type 'single-float))
                    (written 0))
               (cffi:with-foreign-object (error-out :pointer)
                 (loop while (< written frames)
                       for want = (min chunk (- frames written))
                       do (setf (cffi:mem-ref error-out :pointer) (cffi:null-pointer))
                          (let ((status (objc:invoke engine "renderOffline:toBuffer:error:"
                                                     want buffer error-out)))
                            (unless (zerop status)
                              (error "Offline rendering stopped with status ~D." status))
                            (let* ((channels (objc:invoke buffer "floatChannelData"))
                                   (channel (cffi:mem-ref channels :pointer))
                                   (got (objc:invoke buffer "frameLength")))
                              (when (zerop got)
                                (error "Offline rendering produced no frames."))
                              (dotimes (i (min got (- frames written)))
                                (setf (aref samples (+ written i))
                                      (cffi:mem-aref channel :float i)))
                              (incf written got)))))
               (objc:invoke engine "stop")
               (objc:release buffer)
               samples))
        (objc:free-objc-block block)))))

;;; Live -- what no test calls -------------------------------------------------------------

(defun play (instrument &key (seconds 2) (rate +default-sample-rate+))
  "Play INSTRUMENT through the speakers for SECONDS.  Makes noise.

    (play (sine 440))
    (play (fm 220 :ratio 2.5 :depth 300) :seconds 3)

Not called by any test, for the obvious reason.  The render block runs on the
audio thread while this sleeps; see the header for what that means for a Lisp
closure."
  (ensure-audio)
  (multiple-value-bind (engine format block) (make-audio-engine instrument :rate rate)
    (declare (ignore format))
    (unwind-protect
         (progn
           (cffi:with-foreign-object (error-out :pointer)
             (setf (cffi:mem-ref error-out :pointer) (cffi:null-pointer))
             (unless (objc:invoke-bool engine "startAndReturnError:" error-out)
               (error "The audio engine would not start.")))
           (sleep seconds)
           (objc:invoke engine "stop"))
      ;; After -stop, so the engine cannot be mid-callback into a freed block.
      (objc:free-objc-block block))
    seconds))

;;; Instruments -------------------------------------------------------------------------

(defun sine (frequency &key (amplitude 0.25))
  "A pure tone.  Allocates nothing per sample, which is what a render block wants."
  (let ((k (* 2 pi frequency)))
    (lambda (time) (* amplitude (sin (* k time))))))

(defun fm (carrier &key (ratio 2.0) (depth 200) (amplitude 0.25))
  "Frequency modulation: a carrier whose frequency is wobbled by a modulator.

Two oscillators and a multiply, which is the cheapest way to get a sound that
is obviously not a sine wave."
  (let ((kc (* 2 pi carrier))
        (km (* 2 pi carrier ratio)))
    (lambda (time)
      (* amplitude (sin (+ (* kc time) (* depth (sin (* km time)))))))))

(defun chord (frequencies &key (amplitude 0.2))
  "Several tones at once, summed and scaled so they do not clip."
  (let ((voices (mapcar (lambda (f) (sine f :amplitude 1.0)) frequencies))
        (scale (/ amplitude (max 1 (length frequencies)))))
    (lambda (time)
      (* scale (reduce #'+ voices :key (lambda (voice) (funcall voice time)))))))

;;; Writing it down -----------------------------------------------------------------------

(defun write-wav (samples path &key (rate +default-sample-rate+))
  "Write SAMPLES to PATH as a 16-bit mono WAV, and return PATH.

The header is written by hand because it is forty-four bytes and doing it here
keeps the example free of a second framework -- and because a file you can play
is the point of having rendered offline at all."
  (let* ((count (length samples))
         (data-bytes (* 2 count))
         (buffer (make-array (+ 44 data-bytes) :element-type '(unsigned-byte 8)))
         (position 0))
    (flet ((u8 (value) (setf (aref buffer position) (logand value #xff)) (incf position))
           (ascii (string) (loop for character across string
                                 do (setf (aref buffer position) (char-code character))
                                    (incf position))))
      (flet ((u16 (value) (u8 value) (u8 (ash value -8)))
             (u32 (value) (u8 value) (u8 (ash value -8))
                          (u8 (ash value -16)) (u8 (ash value -24))))
        (ascii "RIFF") (u32 (+ 36 data-bytes)) (ascii "WAVE")
        (ascii "fmt ") (u32 16) (u16 1) (u16 1)
        (u32 rate) (u32 (* rate 2)) (u16 2) (u16 16)
        (ascii "data") (u32 data-bytes)
        (loop for sample across samples
              for clipped = (max -1.0 (min 1.0 sample))
              for value = (round (* clipped 32767))
              do (u16 (ldb (byte 16 0) value)))))
    (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                              :if-exists :supersede)
      (write-sequence buffer out))
    path))

;;; A worked example ------------------------------------------------------------------------

(defun test-audio ()
  "Render instruments offline and check the waveform is the one asked for.

    (objc/examples:test-audio)
    => (:FRAMES 4410 :STARTS-AT-ZERO T :IN-RANGE T :PEAK 0.3536
        :ZERO-CROSSINGS 43 :FM-DIFFERS T :WAV-HEADER T)

:ZERO-CROSSINGS is the assertion with teeth: it is a claim about the FREQUENCY
of what came back rather than about some numbers having arrived.  A 440Hz tone
completes 44 cycles in a tenth of a second and crosses zero UPWARD once per
cycle, so 43 or 44 -- the one at the very end may fall past the last sample.
Checked at 100Hz over a full second too, where it is 99.  A render block that
filled the buffer with the wrong thing, or ignored the frame count it was given,
would land nowhere near.

:PEAK is 0.3536 for an instrument whose amplitude is 0.5, which is not a bug and
took a moment to believe: 0.5 divided by the square root of two, exactly.  The
main mixer attenuates by that much on the way through -- consistent with the
equal-power pan law a mono source gets when it is spread across a stereo output,
though that explanation is inference and the 1/sqrt(2) is the measurement.  The
assertion is on the measured figure, so it will notice if it ever changes."
  (ensure-audio)
  (let* ((rate +default-sample-rate+)
         (seconds 1/10)
         (samples (synthesize (sine 440 :amplitude 0.5) :seconds seconds :rate rate))
         (fm-samples (synthesize (fm 220) :seconds seconds :rate rate))
         (crossings (loop for i from 1 below (length samples)
                          count (and (< (aref samples (1- i)) 0)
                                     (>= (aref samples i) 0))))
         (peak (reduce #'max samples :key #'abs)))
    (list :frames (length samples)
          :starts-at-zero (< (abs (aref samples 0)) 0.001)
          :in-range (every (lambda (s) (<= -1.0 s 1.0)) samples)
          :peak peak
          :zero-crossings crossings
          :fm-differs (not (equalp samples fm-samples))
          :wav-header
          (uiop:with-temporary-file (:pathname path :type "wav")
            (write-wav samples path)
            (with-open-file (in path :element-type '(unsigned-byte 8))
              (let ((header (make-array 12 :element-type '(unsigned-byte 8))))
                (read-sequence header in)
                (and (equalp (subseq header 0 4) #(82 73 70 70))    ; RIFF
                     (equalp (subseq header 8 12) #(87 65 86 69))   ; WAVE
                     (= (+ 44 (* 2 (length samples))) (file-length in)))))))))

(defun report-audio (&key (path "/tmp/objc-audio.wav") play)
  "Render a chord to PATH, and play it if asked.

    (report-audio)             ; writes a file
    (report-audio :play t)     ; and makes a noise"
  (let* ((samples (synthesize (chord '(261.63 329.63 392.0)) :seconds 2)))
    (write-wav samples path)
    (format t "~&~D samples -> ~A~%" (length samples) path)
    (when play
      (format t "playing...~%")
      (finish-output)
      (play (chord '(261.63 329.63 392.0)) :seconds 2))
    path))
