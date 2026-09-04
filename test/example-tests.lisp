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
               "rendering an uncropped generator is reported, not silently empty")
      (is (equal '((0 0 128 128) (10 20 64 64)) (getf result :transformed))
          "a CGAffineTransform crossed by value: scaled to double, then moved"))))

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

(test the-map-example-renders-a-real-place
  "examples/map.lisp turns a pair of coordinates into a PNG: MKMapSnapshotter
fetches tiles and draws them into an image, with no window and no MKMapView.

:DIFFERENT-PLACES is the assertion worth having.  The region crosses as a
32-byte structure BY VALUE, and a snapshotter that ignored it would return the
same picture for every coordinate and satisfy every other check here.

SKIPS without a network, which is a fact about the machine and not this library.

Not assertable, and worth stating: -startWithCompletionHandler: answers on the
MAIN queue, so waiting for it on the main thread deadlocks -- the snapshot
finishes and the block queues behind the thread waiting for it.  Measured at
thirty seconds with no callback and no error.  The example uses
-startWithQueue:completionHandler: for that reason, and a test of the deadlock
would simply hang."
  (with-runtime
    (let ((result (objc/examples:test-map)))
      (if (not (getf result :available))
          (skip "no network, so no map tiles")
          (progn
            (is-true (getf result :png) "both coordinates produced a PNG")
            (is (equal '(600 400) (getf result :pixels)) "at the size asked for")
            (is-true (getf result :different-places)
                     "two coordinates give two different maps")
            (is-true (getf result :types-differ)
                     "and satellite does not look like standard"))))))

(test the-speech-example-synthesises-into-a-buffer
  "examples/speech.lisp asks AVSpeechSynthesizer for the audio instead of
playing it, a buffer at a time through a block, so a sentence becomes samples.

The mechanism is what makes it worth having: the callback arrives on the MAIN
THREAD via the run loop, and there is no queue-taking variant as MapKit has, so
a blocking wait cannot be made to work by any arrangement of threads.  The only
way to receive the buffers is to pump the run loop -- which makes this the first
example needing OBJC.RUNLOOP for something with no window in it.

:LONGER-IS-LONGER has the teeth: a longer sentence must give more samples, where
a fixed buffer, a truncation at the first chunk, or an early end-of-stream would
all give the same length twice."
  (with-runtime
    (let ((result (objc/examples:test-speech)))
      (if (zerop (getf result :voices))
          (skip "no English voices installed")
          (progn
            (is (plusp (getf result :samples)) "samples came back")
            (is (plusp (getf result :rate)) "at the voice's own sample rate")
            (is (< 0.5 (getf result :seconds) 10) "and a plausible duration")
            (is-true (getf result :not-silent) "the buffer is not all zeroes")
            (is-true (getf result :longer-is-longer)
                     "a longer sentence really did synthesise more audio")
            (is-true (getf result :wav) "and the WAV written from it is well formed"))))))

(test the-file-coordinator-example-outlives-an-atomic-save
  "examples/file-coordinator.lisp watches a file with an NSFilePresenter, which
is the other way to do what file-watcher.lisp does -- and the pair is the point.

A vnode source watches an INODE, so an editor's write-temporary-and-rename
leaves it holding a descriptor for a file that no longer has that name; that is
why file-watcher.lisp needs :REARM.  A presenter watches a PATH, so the same
save needs nothing, and :SURVIVED-ATOMIC-SAVE asserts the case that matters --
a write to the file that replaced the original.

It is also the only example whose Lisp class adopts a framework protocol, with
the required members answered from the instance's own CLOS slots."
  (with-runtime
    (let ((result (objc/examples:test-file-coordinator)))
      (is-true (getf result :saw-change) "an ordinary write was reported")
      (is-true (getf result :survived-atomic-save)
               "and so was a write to the file that replaced it, with no re-arming")
      (is-true (getf result :coordinated-write-seen)
               "a coordinated write was reported too"))))

(test the-collections-example-makes-a-lisp-object-a-cocoa-citizen
  "examples/collections.lisp is about the half of this library the other
examples ignore.  They exercise the calling machinery; this exercises
STANDARD-OBJC-OBJECT -- the CLOS integration, the identity map, and the two
lifecycle hooks, none of which any other example touches.

:SET-COUNT is what the file is for.  Three points go into an NSSet and two come
out, because Cocoa asked our -hash and -isEqual: and believed the answers.  A
wrong hash does not raise: the set would quietly hold all three, and a lookup
would quietly miss.

:KEYS-WERE-COPIED and :DESTROYED are the hooks.  An NSDictionary copies its
keys, so OBJC-OBJECT-COPIED fires on the way in; OBJC-OBJECT-DESTROYED fires
when the pool drains."
  (with-runtime
    (let ((result (objc/examples:test-collections)))
      (is (= 2 (getf result :set-count))
          "three points, two distinct, deduplicated by our own hash and equality")
      (is (string= "first" (getf result :equal-key-found))
          "and looked up by a different object that is merely EQUAL to the key")
      (is-true (getf result :keys-were-copied)
               "OBJC-OBJECT-COPIED fired -- an NSDictionary copies its keys")
      (is (equal '((1 2) (1 5) (3 4)) (getf result :sorted))
          "Cocoa sorted Lisp objects through a Lisp comparator")
      (is (string= "(1, 2)" (getf result :description))
          "-description answers from Lisp")
      (is-true (getf result :destroyed)
               "OBJC-OBJECT-DESTROYED fired when the pool drained")
      (is-true (getf result :foreign-not-equal)
               "and an object that is not one of ours is not EQUAL to one that is"))))

(test the-browser-example-asks-the-runtime
  "examples/browser.lisp is the library's own introspection put to use --
CAN-INVOKE-P, OBJC-CLASS-METHOD-SIGNATURE, OBJC-CLASS-NAME and TRACE-INVOKE, all
of which were exported, documented, and used by nothing but the test suite.

:LENGTH-SIGNATURE has the teeth: -[NSString length] takes the two hidden
arguments and nothing else and returns an NSUInteger, read from the runtime and
parsed.  If the encoding parser ever drifted, this notices.

The class of an NSString is deliberately not asserted exactly: a short string is
a tagged pointer, a longer one is __NSCFString.  That it is SOME string class is
all that is honestly true, and is itself worth knowing."
  (with-runtime
    (let ((result (objc/examples:test-browser)))
      (is (equal '("NSString" "NSObject") (getf result :chain))
          "the superclass chain, from the runtime")
      (is-true (getf result :found-substring) "NSString has substring methods")
      (is (equal '((objc:objc-object-pointer objc:sel) (:unsigned :long-long))
                 (getf result :length-signature))
          "-length takes only the hidden arguments and returns an NSUInteger")
      (is-true (getf result :responds) "CAN-INVOKE-P says -length will work")
      (is-true (getf result :does-not-respond) "and that a made-up selector will not")
      (is (search "String" (getf result :class-of))
          "the runtime's class for an NSString is some kind of string")
      (is-true (getf result :traced) "TRACE-INVOKE reported the send"))))

(test the-undo-example-lets-cocoa-run-lisp
  "examples/undo.lisp hands NSUndoManager a Lisp target and a Lisp-implemented
selector, so undoing is Cocoa deciding when to call our method.

:VALUES is the whole assertion and the last element is the interesting one.
Undoing after a second change must give the value from before that change, which
only holds because -setValueFrom: registers its own inverse every time it runs --
during an undo the manager is recording onto the redo stack, so one method serves
set, undo and redo.  Leave the registration out and undo works exactly once.

:PROXY-REFUSED records a limitation rather than hiding it.
-prepareWithInvocationTarget: returns a forwarding proxy, which this library
cannot send to because it resolves the Method first; that is true of every
-forwardInvocation: proxy, not just this one."
  (with-runtime
    (let ((result (objc/examples:test-undo)))
      (is (equal '(42 0 42 7 42) (getf result :values))
          "set, undo, redo, set again, undo -- each step ran the Lisp method")
      (is (string= "Set Value" (getf result :action-name))
          "the group's action name came back from the manager")
      (is-true (getf result :can-redo-after-undo)
               "the undo registered its own inverse, so there is something to redo")
      (is-true (getf result :proxy-refused)
               "a forwarding proxy is invisible to CAN-INVOKE-P and INVOKE"))))

(test the-memory-example-observes-deallocation
  "examples/memory.lisp is the only one that thinks about ownership, which every
other example gets away with ignoring because WITH-AUTORELEASE-POOL does it.

Deaths are observed through OBJC-OBJECT-DESTROYED rather than inferred from a
retain count, and :TAGGED-COUNT-IS-ABSURD is why.  A short NSString is a tagged
pointer -- the characters are in the pointer, there is no heap object -- and it
answers -retainCount with 18446744073709551615, while a tagged NSNumber answers
9223372036854775807.  Both pass any \"the count went up\" check, before and
after, so a memory test written with a short literal string measures nothing.

:DEATHS-IN-LOOP is the argument for MAKE-AUTORELEASE-POOL existing at all: with
one pool around the loop, none of the 200 objects have died by the time it ends;
with one pool per iteration, all of them have."
  (with-runtime
    (let ((result (objc/examples:test-memory)))
      (let ((ownership (getf result :ownership)))
        (is (= 1 (getf ownership :fresh)) "+alloc gives a count of one")
        (is (= 2 (getf ownership :retained)))
        (is (= 1 (getf ownership :released)))
        (is-true (getf ownership :died-on-last-release)
                 "-dealloc ran, which is the only observable form of reaching zero"))
      (is (equal '(:dead-inside nil :dead-after (:pooled))
                 (getf result :autorelease))
          "an autoreleased object outlives the expression, and dies at the drain")
      (is (eq :tagged (getf result :tagged-string))
          "a short NSString is a tagged pointer, so the count question is void")
      (is (= 1 (getf result :heap-string)) "and a long one is an ordinary object")
      (is-true (getf result :tagged-count-is-absurd)
               "the count a tagged pointer reports would pass any comparison")
      (is (= 0 (getf result :deaths-in-loop))
          "one pool around the loop holds all 200 until it ends")
      (is (= 200 (getf result :deaths-in-loop-with-pools))
          "one pool per iteration frees them as it goes")
      (let ((no-pool (getf result :no-pool)))
        (is (null (getf no-pool :main-thread))
            "with no pool the autorelease simply does not happen, and is not logged")
        (is (equal '(:thread) (getf no-pool :secondary-thread))
            "on a thread that exits, the runtime pops the page during teardown")))))

(defun example-definition-name (line)
  "The name defined by LINE if it is a top-level DEFUN or DEFMACRO, else NIL."
  (let ((prefix (find-if (lambda (prefix)
                           (and (<= (length prefix) (length line))
                                (string= prefix line :end2 (length prefix))))
                         '("(defun " "(defmacro "))))
    (when prefix
      (let* ((rest (subseq line (length prefix)))
             (end (or (position-if (lambda (character)
                                     (member character '(#\Space #\Tab #\()))
                                   rest)
                      (length rest))))
        (and (plusp end) (subseq rest 0 end))))))

(test no-two-example-files-define-the-same-function
  "examples/ is one flat package, so a name defined in two files is the later
file silently replacing the earlier one's definition.

Not hypothetical: notifications.lisp arrived with OBSERVE and STOP-OBSERVING,
which kvo.lisp already had.  ASDF loads kvo.lisp second, so kvo's definitions
won -- and the only symptom was an arity error from a caller inside
notifications.lisp, pointing at a function whose source looked perfectly
correct.  Reading either file told you nothing.

A grep rather than DO-SYMBOLS, because by the time the image is loaded the
evidence is gone: there is one function left and nothing records that there
were two.

UIOP:DIRECTORY-FILES rather than DIRECTORY, for the reason spelled out in
ONLY-ABI-LISP-KNOWS-ABOUT-SB-ALIEN -- which had been scanning nothing, and which
this test was written in the image of before that was noticed."
  (let ((definitions (make-hash-table :test #'equal)))
    (dolist (path (uiop:directory-files
                   (asdf:system-relative-pathname :objc "examples/") "*.lisp"))
      (with-open-file (stream path)
        (loop for line = (read-line stream nil)
              while line
              do (let ((name (example-definition-name line)))
                   (when name
                     (pushnew (file-namestring path) (gethash name definitions)
                              :test #'string=))))))
    (let ((clashes '()))
      (maphash (lambda (name files)
                 (when (rest files)
                   (push (format nil "~A in ~{~A~^ and ~}" name (reverse files))
                         clashes)))
               definitions)
      (is (null clashes) "defined in more than one example file:~%~{  ~A~%~}"
          (sort clashes #'string<)))))

(test the-notifications-example-knows-where-it-runs
  "examples/notifications.lisp is NSNotificationCenter through COCOA:ADD-OBSERVER
and COCOA:REMOVE-OBSERVER -- two of the eleven symbols that package promises,
and both of which had no example, while every notification in this repository
was done by hand through INVOKE instead.

:HANDLER-THREAD is the assertion nothing else here would catch.  Delivery is a
synchronous message send inside -postNotificationName:, so the handler runs on
the thread that POSTED, not the one that registered.  The listener registers on
the main thread, a thread named \"poster\" posts, and the handler -- which
records its own thread, because asking afterwards would only report where the
test was standing -- says \"poster\".  An observer that touches AppKit is
therefore only as safe as every caller that posts to it.

:TASK-WITH-SLEEPING is the other one, and it is speech.lisp's lesson somewhere
much less expected.  Both halves run /bin/echo identically and differ only in
how they wait; NSTaskDidTerminateNotification goes onto the run loop of the
launching thread, so sleeping never hears it however long the child has been
dead, and pumping hears it at once.

:RETAINED-BY-CENTER records that the center does not retain its observers.
Keeping one alive is the caller's job -- though on modern macOS failing to is no
longer the crash the folklore promises: the selector-based registration zeroes
its reference, and a post to a deallocated observer does nothing at all.  That
is measured in the file header, and it is emphatically NOT true of KVO, which
still ends the image; see kvo.lisp."
  (with-runtime
    (let ((result (objc/examples:test-notifications)))
      (let ((first (first (getf result :received))))
        (is (string= "ExampleNote" (getf first :name)))
        (is (equal '("who" "a value") (getf first :info))
            "the userInfo dictionary came back unpacked")
        (is (string= "main thread" (getf first :thread))
            "posted from this thread, so handled on this thread"))
      (is-true (getf result :wrong-sender-ignored)
               "an :OBJECT registration filters on the sender")
      (is-true (getf result :right-sender-heard)
               "and hears that sender")
      (is (null (getf result :retained-by-center))
          "the center does not retain the observer")
      (is (string= "poster" (getf result :handler-thread))
          "the handler runs on the posting thread, not the registering one")
      (is-true (getf result :task-with-pumping)
               "NSTaskDidTerminateNotification arrives when the run loop is served")
      (is (null (getf result :task-with-sleeping))
          "and never arrives when it is not, however long you sleep"))))
