;;;; test/example-tests.lisp -- the examples, asserted.
;;;;
;;;; Every example that needs no window server has a TEST-<thing> entry point
;;;; returning a plist of what happened, and this suite checks those plists.
;;;; They live here rather than beside the feature each one demonstrates
;;;; because an example is a thing in its own right: it can rot when a framework
;;;; changes underneath it without anything in the library having moved.
;;;;
;;;; The windowed examples -- the canvas, the menu-bar item, WebKit -- are in
;;;; gui-tests.lisp instead, because they skip without a window server and this
;;;; suite does not.

(in-package #:objc/test)

(def-suite examples :in all-tests
  :description "The examples, run headless and asserted.")

(in-suite examples)


(test the-gcd-example-runs-every-shape
  "examples/gcd.lisp is what block creation was for: GCD is plain C functions
that all take a block, so it needed nothing else from the bridge.  Foundation
only, no window server.

Deliberately not asserted: which thread dispatch_sync used.  It is entitled to
run the block on the caller and normally does."
  (with-runtime
    (let ((result (objc/examples:test-gcd)))
      (is (= 42 (getf result :sync)))
      (is (eq :other (getf result :async-thread))
          "the queued blocks ran on a thread SBCL did not create")
      (is-true (getf result :group) "the group finished")
      (is (= 4950 (getf result :total)) "every one of the 100 blocks ran, once")
      (is-true (getf result :overlapped)
               "and the main thread kept working while they did"))))

(test the-file-watcher-example-runs-every-shape
  "examples/file-watcher.lisp is dispatch sources: the kernel notices something
and a Lisp closure runs.  Blocks and GCD, on a serial queue, so it is safe on
any build.

:SURVIVED-ATOMIC-SAVE is the assertion with teeth, and it took two attempts to
make it one.  A vnode source watches a descriptor, not a path, so after an
editor's write-temporary-and-rename the watch reports the rename and then goes
silent -- while still answering WATCHER-LIVE with true.  Asserting that the
rename was seen passes either way; the test has to write again afterwards and
require an event."
  (with-runtime
    (let ((result (objc/examples:test-file-watcher)))
      (is (equal '(:write :extend) (getf result :write))
          "an append reports write and extend")
      (is-true (getf result :survived-atomic-save)
               "and the watch still sees writes to the file that replaced it")
      (is-true (getf result :directory) "a directory watch saw a new entry")
      (is (= 3 (getf result :timer)) "the timer source fired three times"))))

(test the-natural-language-example-runs-every-shape
  "examples/natural-language.lisp is where struct-by-value into a block meets a
real framework: the tagger and the tokenizer both hand their closure an NSRange
by value, and the embedding hands it a double.  Until this example those paths
existed only in the tests above.

Foundation-level, so no window server, no network and no permissions."
  (with-runtime
    (let ((result (objc/examples:test-natural-language)))
      (is (equal '("en" "fr" "ja") (getf result :languages))
          "three languages identified from text alone")
      (is (equal '("Cons" "cells" "cheaply") (getf result :tokens))
          "the tokenizer's NSRanges came through by value")
      (is (equal '(("PersonalName" . "Ada Lovelace")
                   ("PersonalName" . "Charles Babbage")
                   ("PlaceName" . "London"))
                 (getf result :entities))
          "both two-word names stayed whole, and London is a place")
      (is-true (getf result :nouns))
      (is-true (getf result :closer)
               "cat is nearer dog than table -- the doubles arrived intact")
      (is (= 5 (getf result :neighbours))))))

(test the-core-image-example-runs-every-shape
  "examples/core-image.lisp generates its own images, so it ships no assets and
needs nothing on disk.  Headless: a CIContext renders without a window server.

The QR assertion is the one with teeth.  Everything else checks that bytes came
back and start with a PNG signature, which a broken filter graph could satisfy;
that one round-trips through Vision and insists the payload matches."
  (with-runtime
    (let ((result (objc/examples:test-core-image)))
      (is (plusp (getf result :filters)) "the framework listed its filters")
      (is (= 264 (getf result :format))
          "kCIFormatRGBA8, read from CoreImage rather than guessed")
      (is-true (getf result :checkerboard))
      (is-true (getf result :blurred) "the blur changed the image")
      (is-true (getf result :gradient))
      (is-true (getf result :qr))
      (is-true (getf result :qr-decodes)
               "Vision read the generated QR code back and the payload matched")
      (is-true (getf result :infinite-refused)
               "rendering an uncropped generator is reported, not silently empty"))))

(test the-url-session-example-runs-every-shape
  "examples/url-session.lisp is the completion-handler API, which is the shape
of most modern Cocoa and the reason block creation matters at all.

file:// URLs throughout, so the suite needs no network -- a data task serves
those through the same machinery as http.  The concurrent case is the one worth
having: eight transfers issued together, on a session whose delegate queue runs
its completion handlers one at a time, which is what keeps it alive on a stock
build."
  (with-runtime
    (let ((result (objc/examples:test-url-session)))
      (is (string= "payload 0" (getf result :one)))
      (is (null (getf result :status))
          "a file:// transfer has no HTTP status, whatever -statusCode answers")
      (is-true (getf result :missing)
               "a URL that does not exist reported an error rather than nothing")
      (is (= 8 (getf result :all)) "every concurrent transfer came back")
      (is-true (getf result :concurrent) "and each result went to its own slot"))))


(test the-kvo-example-runs-every-shape
  "examples/kvo.lisp is the third of Cocoa's callback mechanisms, and the one
most able to end the process: KVO reports misuse by raising an NSException, and
there is no @try here.  So the example is about the discipline, and what can be
asserted is that the discipline holds.

What cannot be asserted, and is worth saying rather than leaving as apparent
coverage: that removing an unregistered observer raises.  It does, and it would
take the test run with it."
  (with-runtime
    (let ((result (objc/examples:test-kvo)))
      (is (equal '((:kind :setting :new 3.0d0 :old 0.0d0)
                   (:kind :setting :new 7.0d0 :old 3.0d0))
                 (getf result :changes))
          "both changes arrived, with old and new values")
      (is-true (getf result :context-respected)
               "a second observation of the same key path reached its own closure")
      (is-true (getf result :idempotent) "stopping twice did not raise")
      (is-true (getf result :unregistered)))))

(test the-data-detector-example-runs-every-shape
  "examples/data-detector.lisp: another framework handing a block an NSRange by
value, and the ranges are checked against the text they claim to name -- which
is what would catch a structure that arrived wrong rather than absent."
  (with-runtime
    (let ((result (objc/examples:test-data-detector)))
      (is (equal '(:phone-number :date :link :address) (getf result :types)))
      (is (string= "https://example.com/notes" (getf result :link)))
      (is (string= "+1 555-123-4567" (getf result :phone)))
      (is-true (getf result :ranges-line-up)
               "every match's text is the substring its range names")
      (is (= 1 (getf result :narrowed)) "asking only for links found only the link"))))

(test the-predicates-example-runs-every-shape
  "examples/predicates.lisp exists for the variadic send, which the README warns
about and nothing outside invoke-tests demonstrated.  A missing
:VARIADIC-NUM-OF-FIXED does not error on Apple silicon -- the arguments are read
from registers instead of the stack -- so :FORMATTED is the assertion that would
notice."
  (with-runtime
    (let ((result (objc/examples:test-predicates)))
      (is (string= "Ada is 36" (getf result :formatted))
          "the variadic stringWithFormat: read its arguments from the stack")
      (is (equal '("Charles Babbage" "Grace Hopper" "Alonzo Church")
                 (getf result :over-50)))
      (is (equal '("Ada Lovelace" "Alan Turing" "Alonzo Church")
                 (getf result :beginning-with-a)))
      (is (string= "Ada Lovelace" (getf result :youngest))
          "sorted ascending -- which needed the BOOL argument fix to be true")
      (is (= 5 (getf result :column))))))

;;; A class for the BOOL regression above ----------------------------------------

(objc:define-objc-class bool-argument-test ()
  ()
  (:objc-class-name "BoolArgumentTest"))

(objc:define-objc-method ("sawFlag:" objc:objc-object-pointer)
    ((self bool-argument-test) (flag objc:objc-bool))
  (declare (ignore self))
  (objc:invoke "NSString" "stringWithUTF8String:" (format nil "~S" flag)))

;;; The bug the examples found ---------------------------------------------------

(test a-bool-argument-arrives-as-yes
  "Regression.  Every BOOL argument this library sent was NO, in both
directions, and the suite had not noticed because it covered only BOOL RESULTS
-- which SBCL converted on the way back and which were right the whole time.

The cause was (BOOLEAN 8) as the alien type: it converts on SBCL's side and
wants a generalized boolean, while every conversion function here produces the
integer 1 or 0, and (BOOLEAN 8) given 1 arrives as NO.  Found by
sortDescriptorWithKey:ascending: sorting descending whichever way it was asked."
  (with-runtime
    (objc:with-autorelease-pool ()
      (is (= 1 (objc:invoke (objc:invoke "NSNumber" "numberWithBool:" t) "boolValue"))
          "T is YES")
      (is (= 0 (objc:invoke (objc:invoke "NSNumber" "numberWithBool:" nil) "boolValue"))
          "NIL is NO")
      (is (= 1 (objc:invoke (objc:invoke "NSNumber" "numberWithBool:" 1) "boolValue"))
          "and an integer still passes through")
      (is (= 0 (objc:invoke (objc:invoke "NSNumber" "numberWithBool:" 0) "boolValue"))))))

(test a-bool-argument-reaches-a-lisp-method-unchanged
  "The other half, and the mirror bug: ARGUMENT-CONVERSION-FORM read the
incoming byte with (NOT (EQL 0 RAW)) against a value that was already T or NIL,
so NO arrived as T."
  (with-runtime
    (objc:with-autorelease-pool ()
      (let ((object (objc:alloc-init-object "BoolArgumentTest")))
        (is (string= "T" (objc:invoke-into 'string object "sawFlag:" t)))
        (is (string= "NIL" (objc:invoke-into 'string object "sawFlag:" nil)))))))

(test the-pdf-document-example-round-trips
  "examples/pdf-document.lisp is the half of PDFKit with no window in it, and it
writes the PDF it reads: an offscreen NSTextView rendered with
-dataWithPDFInsideRect: is a PDF with real text, so -string gets the words back.

:TEXT-FOUND is what distinguishes that from a picture of the same words, which
would give a PDF of about the same size that reads as nothing."
  (with-runtime
    (let ((result (objc/examples:test-pdf-document)))
      (is (= 1 (getf result :pages)))
      (is-true (getf result :text-found) "the PDF has a text layer, not an image")
      (is-true (getf result :page-text-matches) "and the page's text is exact")
      (is-true (getf result :bytes-round-trip)
               "reading from a byte vector works as well as from a file"))))

(test the-thumbnail-example-renders-a-preview
  "examples/thumbnail.lisp asks Quick Look -- the machinery Finder uses -- for a
preview of a file, through a completion handler.

The size assertion is deliberately the one that is true: SIZE is a bounding box,
not a result size, so a portrait page fits 256 by coming back 185 by 256.

SKIPS where Quick Look does not answer, which is not hypothetical: it answers on
GitHub's arm64 runner and never answers on the Intel one, because it renders
through an agent process that belongs to a login session.  This test failed
there, correctly reporting a timeout, and a red build for that reason says
nothing about the library."
  (with-runtime
    (let ((result (objc/examples:test-thumbnail)))
      (if (not (getf result :available))
          (skip "Quick Look did not answer on this machine")
          (progn
            (is-true (getf result :png) "a PNG came back")
            (is-true (getf result :fits-the-box)
                     "the longer side is the size asked for and neither side exceeds it")
            (is-true (getf result :from-text-file)
                     "a plain text file has a preview too"))))))

(test the-workspace-example-answers-questions-about-the-desktop
  "examples/workspace.lisp queries launch services -- no window server needed,
and nothing here changes anything.  Its side-effectful half, OPEN-URL and
REVEAL-IN-FINDER, is deliberately not called: it would bring an application
forward on whatever machine the suite is running on.

Deliberately NOT asserted, though the example reports both: that this process
appears in its own -runningApplications list, and that Finder is running.  The
first is false for a plain command-line sbcl and becomes true only once
something registers the process as an application -- asking Quick Look for a
thumbnail does exactly that, which is how an earlier version of this test
passed: the thumbnail test ran first in the same image, and the assertion was
really about test ordering.  The second needs a logged-in session, which a CI
runner has not got.  Neither is a property of this library."
  (with-runtime
    (let ((result (objc/examples:test-workspace)))
      (is (plusp (getf result :running)) "some applications are running")
      (is-true (getf result :well-formed) "every entry has a real process id")
      (is-true (getf result :finder-path) "launch services knows where Finder is")
      (is-true (getf result :opens-text) "and what would open a .txt"))))

(test the-metal-example-computes-on-the-gpu
  "examples/metal.lisp compiles a Metal Shading Language kernel at run time and
runs it on the GPU over data a Lisp function handed it.  The flagship: a C entry
point, message sends, an owned-object convention, and a 24-byte structure passed
by value, all in one pipeline.

SKIPS where there is no Metal device, which a virtualised runner may not have.

:BAD-KERNEL-REPORTED keeps the error path honest -- a kernel that does not
compile has to say so, with the compiler's own message, rather than crash or
return nonsense."
  (with-runtime
    (let ((result (objc/examples:test-metal)))
      (if (not (getf result :available))
          (skip "no Metal device on this machine")
          (progn
            (is-true (getf result :device) "the device has a name")
            (is-true (getf result :squares) "x*x over eight elements")
            (is-true (getf result :square-roots) "and sqrt over five")
            (is-true (getf result :large) "a hundred thousand elements, all correct")
            (is-true (getf result :cached)
                     "the same kernel source compiled once, not twice")
            (is-true (getf result :bad-kernel-reported)
                     "a kernel that will not compile reports the compiler's message"))))))

(test the-scene-kit-example-renders-a-3d-scene
  "examples/scene-kit.lisp builds a scene graph from Lisp forms and renders it
to a PNG with no window: SCNRenderer draws into an image rather than a view.

:ANIMATES is the assertion with teeth.  Two renders of the same scene at
different times must differ, which is what says the time argument reached
SceneKit; comparing the PNGs byte for byte is blunt and exactly right, because
if nothing moved they are identical.

SKIPS without a Metal device, which SCNRenderer requires."
  (with-runtime
    (let ((result (objc/examples:test-scene-kit)))
      (if (not (getf result :available))
          (skip "no Metal device, so no SceneKit renderer")
          (progn
            (is-true (getf result :png) "a PNG came out")
            (is (equal '(480 360) (getf result :pixels)) "at the size asked for")
            (is-true (getf result :animates) "and the scene time changed the picture")
            (is (= 10 (getf result :nodes)) "camera, two lights, sphere, five boxes, torus"))))))

(test the-audio-example-synthesises-a-waveform
  "examples/audio.lisp fills an audio buffer from a Lisp closure -- the block is
the instrument.  Rendered OFFLINE here, through AVAudioEngine's manual rendering
mode, so this is deterministic, silent, and needs no sound hardware.  PLAY is
the same instrument through the speakers and no test calls it.

:ZERO-CROSSINGS is the one that checks the frequency rather than the mere
presence of numbers: 440Hz completes 44 cycles in a tenth of a second, crossing
zero upward once each, and the last may fall past the final sample."
  (with-runtime
    (let ((result (objc/examples:test-audio)))
      (is (= 4410 (getf result :frames)) "a tenth of a second at 44.1kHz")
      (is-true (getf result :starts-at-zero) "sin(0) is 0")
      (is-true (getf result :in-range) "nothing clipped")
      (is (<= 43 (getf result :zero-crossings) 44)
          "the tone came back at the frequency it was asked for")
      (is (< 0.35 (getf result :peak) 0.36)
          "amplitude 0.5 arrives as 0.5/sqrt(2); the mixer attenuates")
      (is-true (getf result :fm-differs) "a different instrument gives a different wave")
      (is-true (getf result :wav-header) "and the WAV written from it is well formed"))))

(test the-shader-example-draws-what-it-was-asked-for
  "examples/shader.lisp compiles a one-expression Metal kernel per pixel and
turns the result into a PNG -- a shader playground whose headless half is
testable and whose live half animates in a window.

:CORNER is the assertion with teeth.  \"float3(uv, 0.25)\" makes the pixel at
the origin exactly (0, 0, 0.25), so its bytes are 0, 0 and 63.  That is a claim
about one specific pixel, where everything else here would be satisfied by any
picture at all: a shader running on transposed coordinates, or off by a row,
would not land on it.

:BOUNDS-RESPECTED renders 37x23, which is not a multiple of the 8x8 threadgroup.
-dispatchThreads: rounds the grid up, so threads exist for pixels that do not,
and without the kernel's early return they write past the buffer.

SKIPS without a Metal device."
  (with-runtime
    (let ((result (objc/examples:test-shader)))
      (if (not (getf result :available))
          (skip "no Metal device on this machine")
          (progn
            (is-true (getf result :all-png) "every sample shader produced a PNG")
            (is (equal '(64 48) (getf result :pixels)) "at the size asked for")
            (is (equal '(0 0 63) (getf result :corner))
                "float3(uv, 0.25) at the origin is (0, 0, 63)")
            (is-true (getf result :animates) "and time changes the picture")
            (is-true (getf result :bounds-respected)
                     "a size that is not a multiple of the threadgroup is fine"))))))
