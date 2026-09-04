# objc

[![macOS](https://github.com/lispnik/objc/actions/workflows/ci-macos.yml/badge.svg)](https://github.com/lispnik/objc/actions/workflows/ci-macos.yml)

The LispWorks Objective-C interface, reimplemented for SBCL on macOS.

The packages are literally named `OBJC` and `COCOA`, the exported symbols have
the LispWorks names and lambda lists, and code written against the *LispWorks
Objective-C and Cocoa Interface User Guide and Reference Manual* is intended to
load and run unchanged.

```lisp
(objc:ensure-objc-initialized)

(objc:invoke (objc:invoke "NSString" "stringWithUTF8String:" "hello world")
             "length")
;; => 11

(objc:invoke (objc:invoke "NSString" "stringWithUTF8String:" "hello world")
             "rangeOfString:" "world")
;; => (6 . 5)
```

Defining an Objective-C class in Lisp, from section 1.4 of the manual, unchanged:

```lisp
(objc:define-objc-class my-object ()
  ((slot1 :initarg :slot1 :initform nil))
  (:objc-class-name "MyObject"))

(objc:define-objc-method ("areaOfWidth:height:" (:unsigned :int))
    ((self my-object)
     (width (:unsigned :int))
     (height (:unsigned :int)))
  (* width height))

(objc:invoke (objc:alloc-init-object "MyObject") "areaOfWidth:height:" 6 7)
;; => 42
```

## Status

The whole documented interface is implemented: all 42 symbols of the `OBJC`
package and all 11 of `COCOA`, with the LispWorks names and lambda lists. That
includes the parts that are easy to leave out — `define-objc-class`,
`define-objc-method` and `define-objc-class-method` with real IMPs, structures
passed and returned by value in both directions, `define-objc-struct`,
`define-objc-typedef`, `define-objc-protocol`, the `standard-objc-object` CLOS
integration with `objc-object-copied` and `objc-object-destroyed`, and
`invoke-into`'s full set of result dispositions.

Past it, one deliberate addition: **creating Objective-C blocks** from Lisp
closures, which LispWorks does in its FLI and has no `OBJC` interface for. See
[Blocks](#blocks).

855 checks, green on a clean GitHub runner as well as locally. Behaviour the
manual leaves ambiguous was settled by running LispWorks Personal 8.1 and
recording what it actually did; those answers are committed and asserted
against, so the differential tests run without LispWorks installed.

### What will bite you

- **An Objective-C exception terminates the process.** There is no `@try`/`@catch`
  here — and none in LispWorks either, which its own image confirms. The common
  case is prevented rather than caught: dispatch resolves the `Method` first, so
  a selector the class does not implement is a Lisp error raised before anything
  is sent. A genuine `NSException` from inside a method that *does* exist will
  take the image down.
- **Running Lisp on two libdispatch threads at once needs a safepoint SBCL.** A
  block runs on a thread SBCL did not create; a garbage collection stops the
  world by signalling every other thread in Lisp, and Darwin refuses to signal a
  libdispatch worker at all. One block is fine — the collector skips the thread
  that triggered it — and two takes the process down with `cannot suspend
  thread: 45, Operation not supported`, no condition and no backtrace. On a
  stock SBCL, keep asynchronous block work on a **serial** queue; `group-async`
  in the GCD example defaults to one. Building SBCL `--with-sb-safepoint` lifts
  the limit entirely, verified — see [Blocks](#blocks).
- **Variadic methods need `:variadic-num-of-fixed`.** On Apple silicon a variadic
  call passes its variable arguments on the stack and a fixed-arity call passes
  them in registers, so `+stringWithFormat:` without it reads garbage. LispWorks
  fails silently here; this warns once, naming the fix.
- **arm64 is the only architecture this has run on.** The two differ in the
  Objective-C ABI in two ways that matter, and both are handled by measuring the
  runtime rather than by read-time conditionals: `BOOL` encodes as `c` on Intel
  and `B` on Apple silicon, and a structure result over 16 bytes goes through
  `objc_msgSend_stret` on Intel — a function that does not exist on arm64, where
  the same result returns through `x8`. Both paths are implemented and the
  selection logic is unit tested; CI runs an Intel leg to exercise them.
- **There is no FLI, and there will not be one.** The type descriptor symbols
  work everywhere the Objective-C manual uses them — method argument and result
  types, `objc-class-method-signature`, `define-objc-struct` slots — but the
  wider LispWorks FLI does not exist here. Ported code that only uses `objc:`
  and `cocoa:` runs unchanged; code that also reaches for `fli:define-c-struct`
  or `fli:allocate-foreign-object` needs rewriting against CFFI. The examples
  carry a six-function `fli` shim for the handful of operators the manual's own
  examples use, and that is deliberately as far as it goes.
- **SBCL only.** Dynamic dispatch is built on `sb-alien`, for reasons set out in
  `src/abi.lisp`. It is confined to that one file, which a test enforces, so
  porting is one file's work — but it is not portable today.
- **AppKit from a REPL needs care.** The event loop helpers in `OBJC.RUNLOOP` are
  additions, not LispWorks API; driving the event loop is CAPI's job there and
  there is no CAPI here. See the notes under Examples.
- **Swift-only frameworks are out of reach, and Apple Intelligence is one.**
  This library sends Objective-C messages, so it reaches what a class exposes to
  the Objective-C runtime. `FoundationModels` — the on-device LLM — is pure
  Swift: it ships no headers, and although its classes are registered with the
  runtime (Swift does that), `FoundationModels.LanguageModelSession` and
  `SystemLanguageModel` publish **zero** selectors, measured with
  `class-selectors`. Same for `Translation`. The reachable machine learning is
  `Vision`, `NaturalLanguage` and `CoreML`, all of which have real Objective-C
  interfaces — and two of which have examples here.

## Requirements

SBCL on macOS. Dependencies come from [ocicl](https://github.com/ocicl/ocicl):

```
ocicl install
make test         # the suite
make test-clean   # the suite with no ~/.sbclrc and no site init, as CI sees it
```

There is no C toolchain in the build: no `cffi-grovel`, no `cffi-libffi`, and no
shim library.

A stock SBCL runs everything here. If you intend to run **Lisp closures on
several libdispatch queues at once** — `dispatch_apply`, or a concurrent queue
with more than one block in flight — you need one built with safepoints, or the
process dies on the first garbage collection that lands while two blocks are
running:

```
./make.sh --with-sb-safepoint --prefix=$HOME/.local && sh install.sh
```

Nothing else needs it, and the suite is green either way. `objc/examples:concurrent-blocks-supported-p`
is the runtime predicate, and the calls that require it refuse with an
explanation on a build that lacks it rather than taking the image down. The
reason is under [Blocks](#blocks).

## How it works

A method's type encoding is read from the Objective-C runtime and parsed; the
parse becomes a compiled trampoline that calls `objc_msgSend` through one exact
non-variadic signature, and the trampolines are memoized so the compiler runs
once per distinct call shape. Objective-C classes defined from Lisp get real
IMPs built the same way in the other direction, so a Lisp method can take and
return C structs by value like any other. This is close to how LispWorks does it
— it JITs a function per signature and caches those too.

`invoke`, `invoke-bool` and `invoke-into` share one call path, and so does a
super send; they differ only in what happens to the result and which entry
address the trampoline was built for.

Dispatch resolves the `Method` before sending, which is how the call signature is
discovered and also what makes an unimplemented selector a Lisp error rather than
an Objective-C exception. That matters because there is no `@try/@catch` here —
and none in LispWorks either.

## Differences from LispWorks

These are the places where matching the manual exactly was impossible or wrong,
each one deliberate:

- **`ns-point`, `ns-size` and `ns-range` are 64-bit.** The manual's reference
  pages say `ns-point` and `ns-size` have `:float` slots and `ns-range` has
  `(:unsigned :int)` slots. That is stale 32-bit text: measured in LispWorks 8.1
  itself, they are 16, 16, 32 and 16 bytes — doubles and 64-bit integers. We
  follow the implementation.

- **There is no FLI.** The eight type descriptor symbols — `objc-object-pointer`,
  `objc-class`, `sel`, `objc-c-string`, `objc-bool`, `objc-c++-bool`,
  `objc-unknown`, `objc-at-question-mark` — work everywhere the Objective-C
  manual uses them, but not in the wider LispWorks FLI forms, which do not exist
  here.

- **`current-super`'s value is an ordinary heap object**, not stack allocated.
  The manual gives it dynamic extent; ours outlives the form, which is strictly
  more permissive and cannot break conforming code.

- **`define-objc-protocol` declares, it does not create** — following the
  manual, whose stated reason is now stale. Creating a protocol at run time
  became possible in macOS 10.7 with `objc_allocateProtocol` and friends, and it
  works: verified by allocating one, registering it, and finding it again under
  its own name. What it cannot carry is the **extended** method signatures clang
  emits, because no runtime function records them — so anything needing those
  rejects it. `NSXPCInterface` says so outright: *"Unable to get extended method
  signature from Protocol data … Use of clang is required."* Which puts
  `NSXPCConnection` out of reach here for the same reason there is no
  `cffi-grovel` in the build.

- **Driving the event loop is not in `OBJC`.** In LispWorks that is CAPI's job,
  and CAPI does not exist here, so `shared-application`, `pump-events`,
  `run-cocoa-application` and `window-server-p` live in `OBJC.RUNLOOP` rather
  than diluting the promise that every symbol in `OBJC` is one the manual
  documents.

- **Floating point traps are masked around every message send.** SBCL runs with
  `:invalid` and `:divide-by-zero` unmasked and CoreGraphics violates both;
  without this the first `NSWindow` creation kills the process with SIGFPE.
  LispWorks masks them by default and so never needed an equivalent.

- **An Objective-C exception terminates the process.** LispWorks has no exception
  bridging either — its image imports no `__cxa_begin_catch`, no
  `objc_exception_*` and no `NSSetUncaughtExceptionHandler`. The common case is
  prevented rather than caught: a selector the class does not implement is a Lisp
  error raised before anything is sent.

- **Variadic methods need `:variadic-num-of-fixed`.** On Apple silicon a variadic
  call passes its variable arguments on the stack and a fixed-arity call passes
  them in registers, so calling `+stringWithFormat:` without it reads garbage.
  LispWorks fails silently here; this warns once, naming the fix.

- **A structure result that is not one of the four Cocoa structures needs
  `invoke-into`.** `invoke` writes a struct result into a buffer it owns and
  frees on the way out, so the only thing it could return is a pointer into
  freed memory — which read back as plausible numbers rather than crashing. It
  signals now, naming the method and the fix. `NSRect`, `NSPoint`, `NSSize` and
  `NSRange` are unaffected: they come back as a vector or a cons. Whether
  LispWorks returns something usable here is untested — its Personal edition
  cannot be scripted, which is how the oracle answers were gathered — so this is
  a deliberate choice to fail loudly rather than a difference measured against
  it. The manual's own struct-returning example uses `invoke-into`.

- **`OBJC` exports eight symbols LispWorks does not**: the block API below.
  LispWorks has no block interface in `OBJC` at all — there it is
  `fli:allocate-foreign-block`, and there is no FLI here. It is the one
  deliberate widening of the package, and the seam test names the eight
  explicitly so an accidental forty-ninth export still fails.

## Blocks

A block is C's closure: a struct carrying a function pointer, which every modern
Cocoa API that takes a completion handler expects. `make-objc-block` builds one
from an arbitrary Lisp closure, so `NSURLSession`, GCD, and the
`...UsingBlock:` half of Foundation are reachable.

```lisp
;; -[NSArray sortedArrayUsingComparator:] -- Foundation sorts, Lisp compares.
(objc:with-objc-block (compare '(:long-long (objc:objc-object-pointer
                                             objc:objc-object-pointer))
                       (lambda (a b)
                         (let ((x (objc:ns-string-to-string a))
                               (y (objc:ns-string-to-string b)))
                           (cond ((string< x y) -1) ((string> x y) 1) (t 0)))))
  (objc:invoke array "sortedArrayUsingComparator:" compare))
```

The type is `(result-type (argument-type...))` using the ordinary type
descriptors, or a name given to `define-objc-block-type`. The block passes
straight to `invoke`. Building the invoke function calls the compiler, so it
happens once per distinct *signature* rather than once per block — which is why
LispWorks splits its own API into a load-time declaration and a run-time
allocation; here the memo makes the declaring form a convenience.

`call-objc-block` goes the other way, calling a block whoever made it.

**Lifetime is refcounted, so `with-objc-block` is almost always right** — including
for asynchronous work. Anything that keeps a block copies it, and the block
carries copy and dispose helpers that take and give up a reference to the Lisp
closure as libclosure copies and destroys those copies. Freeing the original
therefore releases only the reference *you* held:

```lisp
(objc:with-objc-block (b '(:void ()) (lambda () (do-something)))
  (dispatch-async queue b))       ; freed here; the copy keeps the closure alive
```

Reach for `make-objc-block` and an explicit `free-objc-block` when the *storage*
has to outlive the form — when the same block is handed out repeatedly. The one
way left to be wrong is to give a foreign API this exact pointer and have it keep
the pointer rather than a copy; nothing in Cocoa does that.

Structs pass **by value** in both directions, so
`-[NSString enumerateSubstringsInRange:options:usingBlock:]` hands its `NSRange`s
straight to the closure and a block may return an `NSRect`. The one gap is
`call-objc-block` *returning* a struct that has no Lisp representation: the only
answer would be a pointer into a buffer the call frees on its way out, so it
signals instead.

**Only one libdispatch thread may be inside Lisp at a time.** This is SBCL's
limit, not GCD's, and it is worth knowing before writing anything concurrent. A
block runs on a thread SBCL did not create; a garbage collection stops the world
by sending every other thread a signal, and **Darwin refuses to signal a
libdispatch worker thread at all** — `pthread_kill` on one returns `ENOTSUP`
even for signal 0, where an ordinary SBCL thread returns 0. A single block gets
away with it because the collector skips the thread that triggered it. Two, and
the process dies outright:

```
fatal error encountered in SBCL: cannot suspend thread ...: 45, Operation not supported
```

Safe on a stock build: `dispatch_sync`; any number of blocks on a **serial**
queue; and your own Lisp threads running while a queue thread is in a callback.
Unsafe: concurrent queues with more than one block in flight, and
`dispatch_apply`. Serialising Lisp entry with a lock does not help — a worker
parked on a Lisp lock still has to be signalled.

**Building SBCL `--with-sb-safepoint` lifts the limit**, and this is verified
rather than hoped for: the same source on a safepoint build runs an eight-way
concurrent barrier, `dispatch_apply` and a parallel map, five runs out of five,
with the whole suite green. The worker thread is still unsignallable there —
`ENOTSUP`, exactly as before — which is the point: safepoint doesn't make
signalling work, it makes it unnecessary.

```
./make.sh --with-sb-safepoint --prefix=$HOME/.local && sh install.sh
```

`objc/examples:parallel-map` is therefore real, and refuses with an explanation
rather than killing the process when the build cannot take it. See
[Grand Central Dispatch](#grand-central-dispatch).

## Examples

`examples/manual.lisp` is a near-verbatim port of the file LispWorks ships at
`Library/lib/8-1-0-0/examples/objc/manual.lisp`. Every `objc:` form in it is
unchanged from the original.

The GUI examples were CAPI programs, and CAPI does not exist on SBCL, so they
build a real `NSWindow` and put the same Cocoa view in it. The `objc:` forms are
unchanged:

- `examples/area-calculator.lisp` — the manual's `:objc-instance-vars` example.
  The nib is replaced by code that does what the nib did: store the fields in the
  controller's instance variables and point the button at a Lisp method.
- `examples/pdf-view.lisp` and `examples/movie-view.lisp` — PDFKit and AVKit are
  current, so these port almost unchanged.
- `examples/web-kit.lisp` — the original's `WebView` has been *removed* from
  macOS, not merely deprecated, so this uses `WKWebView` and
  `WKNavigationDelegate`. What it demonstrates is preserved: a Lisp class acting
  as a Cocoa delegate, receiving callbacks from a framework that knows nothing
  about Lisp.
- `examples/standalone.lisp` — section 3.4.1. There is no
  `mp:initialize-multiprocessing` equivalent and none is needed: that call exists
  in LispWorks to hand thread 1 to Cocoa, and on SBCL the initial thread already
  is thread 1.
- `examples/canvas.lisp` — the one example not ported from the manual, because
  it is the thing the manual's interface is *for*. A real `NSView` subclass whose
  `-drawRect:` calls a Lisp function you redefine at the REPL while the window is
  open; the next repaint runs the new definition. It also leans on the hardest
  thing the library does — `-drawRect:` receives its dirty rectangle as an
  `NSRect` *by value*, and each shape passes `NSRect`/`NSPoint` by value to
  `NSBezierPath` and `NSColor` — so a paint loop is where `src/abi.lisp` earns
  its keep. See [The live canvas](#the-live-canvas).
- `examples/vision.lisp` — optical character recognition through the Vision
  framework. `-[VNImageRequestHandler performRequests:error:]` is *synchronous*,
  so no Objective-C block is needed; each recognised line's bounding box comes
  back as a `CGRect` *by value*. See [Vision OCR](#vision-ocr).
- `examples/status-item.lisp` — a live item in the macOS menu bar. The canvas
  shows the drawing half of AppKit; this shows the wiring half: each menu item
  carries a target and an action selector, and AppKit sends that selector to a
  Lisp object, invoking a Lisp method, when the item is chosen. Target/action is
  how the whole of Cocoa's UI is connected, with a closure at the far end here.
  See [A menu-bar item](#a-menu-bar-item).
- `examples/gcd.lisp` — Grand Central Dispatch, which LispWorks also ships as an
  example and which needs nothing from the bridge except block creation: its
  entry points are plain C functions that all take a block. The shortest answer
  to what blocks bought, and where the concurrency limit above is drawn in code.
  See [Grand Central Dispatch](#grand-central-dispatch).
- `examples/url-session.lisp` — `NSURLSession`, the completion-handler API, and
  the shape of most modern Cocoa: hand it a block, it calls you back when the
  answer is ready. Also the practical answer to the concurrency limit, in one
  line of session configuration. See [NSURLSession](#nsurlsession).
- `examples/natural-language.lisp` — on-device NLP: language identification,
  tokenising, part-of-speech and named-entity tagging, and word embeddings, with
  no model to download. Where struct-by-value into a block meets a real
  framework — the tagger hands its closure an `NSRange` by value. See
  [Natural language](#natural-language).
- `examples/core-image.lisp` — a filter graph, headless. Generates its own
  images, so it ships no assets: a checkerboard, a gradient and a QR code that
  Vision reads back to prove it is one. See [Core Image](#core-image).
- `examples/file-watcher.lisp` — dispatch sources: watch a file or directory and
  run a Lisp closure when it changes, plus a periodic timer. The one here you
  might actually keep. See [Watching the filesystem](#watching-the-filesystem).
- `examples/kvo.lisp` — key-value observing, the third of Cocoa's callback
  mechanisms and the one most able to end the process. See
  [Key-value observing](#key-value-observing).
- `examples/data-detector.lisp` — the dates, links, addresses and phone numbers
  in ordinary prose, via `NSDataDetector`.
- `examples/predicates.lisp` — querying and sorting Cocoa collections with
  `NSPredicate`, and the only worked example of a **variadic** send. See
  [Variadic sends](#variadic-sends).
- `examples/pdf-document.lisp` — the half of PDFKit with no window in it: write
  a PDF, read its text back. Self-contained, because it writes the PDF it reads.
- `examples/thumbnail.lisp` — Quick Look previews of any file type, through a
  completion handler.
- `examples/workspace.lisp` — `NSWorkspace`: what is running, what opens what,
  and the smallest example here.
- `examples/metal.lisp` — GPU compute: a shader compiled at run time from a
  string and executed over a Lisp vector. See [Metal compute](#metal-compute).
- `examples/scene-kit.lisp` — a 3D scene built from Lisp forms and rendered to a
  PNG with no window. See [A 3D scene, headless](#a-3d-scene-headless).
- `examples/audio.lisp` — sound synthesised a sample at a time by a Lisp
  closure, offline or through the speakers. See [Sound](#sound).
- `examples/shader.lisp` — a shader playground: one expression per pixel,
  rendered to a PNG or animated in a window. See
  [A shader playground](#a-shader-playground).
- `examples/map.lisp` — coordinates in, a PNG of a real place out, with no
  window. See [Maps](#maps).
- `examples/speech.lisp` — text to audio samples, or out loud. See
  [Speech](#speech).
- `examples/file-coordinator.lisp` — `NSFilePresenter`, the other way to watch a
  file, and the contrast that explains `file-watcher`. See
  [Watching a file the other way](#watching-a-file-the-other-way).
- `examples/collections.lisp` — a Lisp object Cocoa deduplicates, copies, keys a
  dictionary by and sorts. See
  [A Lisp object Cocoa owns](#a-lisp-object-cocoa-owns).

### Running them

The manual's own examples are pure Objective-C interface and need no window
server:

```lisp
(asdf:load-system :objc/examples)
(objc/examples:run-manual-examples)
```

```
MyObject areaOfWidth:6 height:7    42
MySpecialObject, via current-super 168
MyOtherObject, via :objc-superclass-name 12
class pointer identity             T
MyData size, from the mixin        42
MyOtherData size, same mixin       42
pair, a struct-returning method    (1.0 2.0)
make-instance, slot value          :HELLO
objc-object-from-pointer round trip T
```

The GUI examples open a window, so run them from a **plain `sbcl` REPL** -- AppKit
needs thread 1, and that is the thread the REPL is on:

```lisp
(asdf:load-system :objc/examples)
(objc:ensure-objc-initialized)

;; Each demo returns its window first, so this wrapper works around any of
;; them.  It keeps the window live until you close it.
(objc/examples:run-until-closed (objc/examples:test-area-calculator))

(objc/examples:run-until-closed
 (objc/examples:test-pdf-kit
  "/System/Library/ProductDocuments/ProductGuides/ENERGY STAR.pdf"))

(objc/examples:run-until-closed (objc/examples:test-movie-view "/path/to/some.mov"))

(objc/examples:run-until-closed (objc/examples:test-web-kit "https://www.lispworks.com/"))
```

`run-until-closed` is the part that makes a demo behave like an application. It
runs AppKit's own event loop -- `-[NSApplication runModalForWindow:]` -- and
closing the window hands the REPL back. `(objc/examples:stop-running)` ends it
from elsewhere if you would rather not reach for the mouse.

Closing the window also hands the keyboard back to whatever had it -- your
terminal or editor. Without that, the process stays the frontmost macOS
application with no windows left, and the terminal *looks* frozen while sitting
at its prompt, because the window server is delivering your keystrokes here.

If closing the window does not hand the REPL back on your machine, pass a
watchdog and you cannot get stuck:

```lisp
(objc/examples:run-until-closed (objc/examples:test-area-calculator) :timeout 60)
```

and `(objc/examples:diagnose-close)` logs every step of closing to
`/tmp/objc-close.log` -- whether `-windowShouldClose:` and `-windowWillClose:`
reached Lisp, whether `-stopModal` was sent, and whether `-runModalForWindow:`
returned. Whichever of those is missing says where the fault is.

Do not be tempted to pump by hand instead. A `nextEventMatchingMask:` /
`sendEvent:` loop never gets to block, because AppKit keeps a supply of
`AppKitDefined` events coming: it spins at **100% CPU** re-dispatching them,
which makes the window sluggish rather than dead. Measured on this machine,
`runModalForWindow:` idles at **0.4%**.

To keep the objects and pump yourself:

```lisp
(multiple-value-bind (window controller) (objc/examples:test-area-calculator)
  (objc.runloop:pump-events :max-seconds 30d0)   ; live for 30 seconds
  (objc:invoke (objc:objc-object-var-value controller "areaField") "floatValue"))
```

Do not run these under `--non-interactive` and expect to interact with them; the
process exits as soon as the form returns.

### The live canvas

From a **plain `sbcl` REPL** (thread 1), open the canvas and then reshape what it
draws without closing it:

```lisp
(asdf:load-system :objc/examples)
(in-package :objc/examples)

(test-canvas)                     ; a window opens on the default scene

;; Redefine the drawing and repaint -- the running window updates.
(setf *canvas-draw*
      (lambda (w h)
        (set-color 0.05 0.05 0.08) (fill-rect 0 0 w h)
        (dotimes (i 60)
          (set-color (/ i 60.0) 0.5 (- 1.0 (/ i 60.0)))
          (fill-oval (* w (/ i 60.0)) (+ (/ h 2) (* 80 (sin (/ i 6.0))))
                     14 14))))
(refresh)                         ; setNeedsDisplay: + a brief pump

(animate-canvas :seconds 12)      ; a self-running clock, for comparison
(run-canvas)                      ; or: block until the window is closed
```

`(refresh)` is the REPL half of the loop: it marks the view dirty and pumps the
run loop briefly, so `-drawRect:` — and your new closure — has run before it
returns. Redefine `draw-default`, or `setf *canvas-draw*`, and `(refresh)`
again. `set-color`, `fill-rect`, `fill-oval`, `stroke-oval` and `draw-line` are
the drawing primitives; each is a few lines of `NSColor`/`NSBezierPath` and only
valid inside a draw function.

Because a Lisp `-drawRect:` is a real Cocoa draw, the view also renders offscreen
— no window, no focus stolen — which is how this example is tested:

```lisp
(setf *canvas-draw* 'draw-default)
(let* ((view (make-view "LispCanvasView" #(0 0 240 240)))
       (rep (invoke view "bitmapImageRepForCachingDisplayInRect:" (invoke view "bounds"))))
  (invoke view "cacheDisplayInRect:toBitmapImageRep:" (invoke view "bounds") rep)
  (invoke (invoke rep "representationUsingType:properties:" 4 (invoke "NSDictionary" "dictionary"))
          "writeToFile:atomically:" "/tmp/canvas.png" nil))
```

### Vision OCR

Recognise text in an image, from Lisp:

```lisp
(asdf:load-system :objc/examples)
(in-package :objc/examples)

(test-ocr "Hello, Lisp!  42")
;; => ((:text "Hello, Lisp! 42" :confidence 1.0
;;      :bounding-box #(0.05d0 0.31d0 0.50d0 0.36d0)))

(ocr-image #p"/path/to/scan.png")           ; a file you already have
(ocr-image #p"scan.png" :level :fast :languages '("en-US"))
```

`ocr-image` returns one plist per line — its `:text`, the `:confidence`, and a
`:bounding-box` normalised to 0..1 with a bottom-left origin. That box is a
`CGRect` the framework returned *by value*; the bridge turned it into
`#(x y width height)`, the same path a Lisp method's struct return takes.

`test-ocr` renders the string to a temporary image with `text-image` (offscreen
`NSImage` drawing, so it needs no window) and reads it straight back — which is
also how the example is tested, headless.

The whole thing works without an Objective-C block because
`-[VNImageRequestHandler performRequests:error:]` is synchronous: it runs the
request and the request holds its `-results` when the call returns. The Vision
methods that take a completion handler are reachable too — see
[Blocks](#blocks) — but a request that has already finished is the shorter road
to the same results.

### A menu-bar item

From a **plain `sbcl` REPL** (thread 1), put an item in the menu bar and drive it
from its menu:

```lisp
(asdf:load-system :objc/examples)
(in-package :objc/examples)

(run-status-item)     ; a λ appears in the menu bar; use its menu, Quit returns
```

The menu's items are wired to Lisp methods by target/action: **Greet** prints
from a Lisp method, **Increment** and **Reset** change the item's own title
(`λ 0`, `λ 1`, …), and **Quit** ends the loop and hands the REPL back. Redefine
`greet:` or `increment:` and the menu runs the new definition — the same live
loop as the canvas, on a control instead of a view.

`make-status-item` builds and returns the item and its controller without
running a loop, so you can wire it into your own; `run-status-item` is the
turnkey version, with an optional `:timeout` watchdog.

Two things about it are not obvious, and each one on its own makes the item look
broken — it appears in the menu bar and clicking it does nothing at all:

- **The application must be an *accessory*.** `shared-application` defaults to
  `Regular`, which is right for a program that owns windows. A `Regular`
  application with no window and no activation does not get its status-item menu
  tracked. `make-status-item` sets `NSApplicationActivationPolicyAccessory`,
  which is what a menu-bar-only app is.
- **It must use AppKit's own loop, not `pump-events`.** A status item's menu is
  tracked in AppKit's own nested run loop mode while the mouse is down;
  `pump-events` dequeues in `kCFRunLoopDefaultMode` only, which is exactly right
  for keeping a *window* responsive from a REPL and starves menu tracking.
  `run-status-item` calls `-[NSApplication run]` and the Quit action calls
  `-stop:` — with a dummy event posted behind it, since `-stop:` is only noticed
  when the loop next finishes an event and an idle loop would otherwise sit
  there.

The consequence is that `run-status-item` does not return until the item quits,
so unlike the Vision example there is no REPL interaction while it runs. That is
no loss for a menu-bar app, and `:timeout` means a session cannot get stuck.

### Grand Central Dispatch

Needs no window server, so it runs anywhere:

```lisp
(asdf:load-system :objc/examples)
(objc/examples:report-gcd)

;; dispatch_sync returned 42
;; a dispatch group of 100 blocks on a serial queue finished, summing to 4950,
;;   on a libdispatch thread
;; the main thread kept running while they did: T
```

GCD is the clearest case for block creation, and LispWorks ships an example of
it too — under the *FLI*, not under `OBJC`, because `dispatch_async` and friends
are plain C functions that need nothing from Objective-C except the block you
hand them. The entire binding here is a dozen lines of `defcfun`; what makes it
work is that the block is a Lisp closure.

It is also where the concurrency limit above stops being abstract. `group-async`
defaults to a **serial** queue, which is safe on any build. `parallel-map` and
`dispatch-apply` need a safepoint build and say so — `concurrent-blocks-supported-p`
is the predicate, and on a stock SBCL they signal an error naming the fix instead
of taking the process down.

`group-async` is also three lines and uses `with-objc-block` like everything
else, even though the work has not started when it returns — an earlier draft
carried every queued block on the group and freed them after the wait, which is
what the job takes without copy and dispose helpers.

### NSURLSession

```lisp
(asdf:load-system :objc/examples)
(in-package :objc/examples)

(fetch "https://example.com/")          ; => content, 200, NIL
(fetch #p"/etc/hosts" :as :bytes)       ; a file:// URL, same machinery
(fetch-all (list url-1 url-2 url-3))    ; all three at once
```

`-dataTaskWithURL:completionHandler:` is the shape of nearly every modern Cocoa
API, and before block creation there was no way to call it at all.

The interesting part is not the fetching. A completion handler runs on a queue
Foundation chooses, and by default that queue runs several at once — which is
precisely what a stock SBCL cannot survive. The fix is one line, and it is why
this example is worth reading:

```lisp
(objc:invoke queue "setMaxConcurrentOperationCount:" 1)
```

A session built with that delegate queue hands results back **one at a time**.
What it does not do is serialise the transfers: `fetch-all` puts every request
in flight together and they download together, because that concurrency lives
inside Foundation where no Lisp runs. Only the callback into Lisp is serialised,
which is the only part that has to be — so it is safe on a stock build, measured
with eight at a time.

One trap the example documents, because it is the kind that reads as working: a
`file://` transfer comes back as a plain `NSURLResponse` that nevertheless
answers `-statusCode`, with 200. Asking `can-invoke-p` whether it responds to
that selector therefore reports an HTTP status for a transfer that never spoke
HTTP. `response-status` does an `-isKindOfClass:` check instead. `can-invoke-p`
answers "will this send work", which is not the question.

### Natural language

```lisp
(asdf:load-system :objc/examples)
(in-package :objc/examples)

(language-of "Le renard brun rapide")     ; => "fr"
(entities "Ada Lovelace and Charles Babbage worked together in London.")
;; => (("PersonalName" . "Ada Lovelace") ("PersonalName" . "Charles Babbage")
;;     ("PlaceName" . "London"))
(word-distance "cat" "dog")               ; => 0.717...
(neighbours "computer" :count 3)          ; => (("workstation" . 0.838...) ...)
```

On-device, no model to download, no permissions, no network — and the closest
thing here to a reason to have a Lisp on a Mac at all. It is also where the
newest block capability meets a real framework:
`enumerateTagsInRange:unit:scheme:options:usingBlock:` hands the closure an
`NSRange` **by value**, and the embedding callback a `double` the same way.

Two things the example documents because they cost time. The `"NameType"` scheme
tags ordinary words `"OtherWord"` rather than leaving them alone, so `entities`
filters rather than merely collecting; and `+join-names+` is what keeps "Ada
Lovelace" one entity rather than two, which looks fine until a name has two
parts.

And one worth knowing generally: **the runtime is authoritative about
selectors**. Apple documents `-distanceBetweenWord:andWord:distanceType:`;
`NLEmbedding` actually implements `-distanceBetweenString:andString:distanceType:`.
Writing the documented name gets a Lisp error naming the selector, which beats a
C exception taking the process out — but `class-selectors` is how you settle it,
and it ships as part of the example rather than as a debugging leftover.

### Core Image

```lisp
(report-core-image)   ; writes a checkerboard, a gradient and a QR code

(render-png (qr-code "https://example.com/") :path #p"/tmp/qr.png")
(render-png (apply-filter "CIGaussianBlur" "inputImage" (checkerboard)
                          "inputRadius" 6)
            :rect #(0 0 256 256))
```

A filter graph, rendered without a window server. Every image is generated by
Core Image, so the example ships no assets and its test depends on nothing.

The whole framework is driven by `-setValue:forKey:` with string keys rather
than by selectors, so the bridge work is boxing Lisp values into the objects it
expects — a number into an `NSNumber`, a pair into a `CIVector`. Two traps are
called out in the file: a generator's output has **infinite extent** and renders
to nothing unless cropped, which fails silently; and `kCIFormatRGBA8` is 264, a
constant worth reading from the framework rather than guessing, because a wrong
value still renders *something*.

The test round-trips: it generates a QR code with Core Image and reads it back
with Vision, insisting the payload matches. That is the difference between
"plausible PNG bytes" and "a QR code".

### Watching the filesystem

```lisp
(asdf:load-system :objc/examples)
(in-package :objc/examples)

(defvar *w* (watch #p"/tmp/notes.txt"
                   (lambda (events) (format t "~&changed: ~S~%" events))))
;; changed: (:WRITE :EXTEND)
(unwatch *w*)

(every-seconds 5 (lambda () (format t "~&tick~%")))   ; a timer source
```

A dispatch source turns something the kernel notices into a block on a queue.
Like GCD, it needs nothing from Objective-C — the entry points are C functions
that take blocks — and the queue is serial, so it is safe on a stock build.

**The trap, and it is why most hand-rolled file watchers quietly stop working:**
a vnode source watches a *file descriptor*, not a path. Almost every editor saves
by writing a temporary file and renaming it over the original, so after one save
the descriptor names a file that no longer has that name, and the watch goes
silent while `watcher-live` still answers true. `:rearm` (the default) reopens
the path when a delete or rename is reported; watching the containing
**directory** instead is the more robust shape, since its descriptor survives
whatever happens to the files inside it.

Measured both ways: with `:rearm nil`, a write to the replacing file produces no
event at all.

### Key-value observing

```lisp
(with-observation (o progress "completedUnitCount"
                     (lambda (path object change)
                       (declare (ignore path object))
                       (print change)))          ; (:KIND :SETTING :NEW 3.0 :OLD 0.0)
  (objc:invoke progress "setCompletedUnitCount:" 3))
```

The third of Cocoa's callback mechanisms — notifications are in `COCOA`, target
and action are in the menu-bar example — and the one that puts a Lisp class on
the receiving end of a four-argument framework callback.

It is also **the easiest way to end the image**, which is why the example is
shaped the way it is. KVO reports misuse by raising an `NSException`, and an
`NSException` here is not a condition you can handle. Removing an observer that
isn't registered raises; letting an observed object deallocate with observers
attached raises; observing a key path that doesn't exist raises. So
`stop-observing` is idempotent, `with-observation` unregisters on unwind, and
none of those three is asserted in the suite — asserting them would end the run,
and the example says so rather than leaving the coverage looking thorough.

The `context` pointer is load-bearing, not decoration: a superclass may observe
the same key path on the same object, and only that pointer distinguishes your
registration from its.

### Variadic sends

```lisp
(format-string "%@ is %d years old" "Ada" 36)
(filter people "age > %@" 50)
```

`+[NSPredicate predicateWithFormat:]` and `+[NSString stringWithFormat:]` are
variadic, and on Apple silicon a variadic call passes its variable arguments on
the **stack** while a fixed-arity call passes them in registers. Calling one
without saying so doesn't fail — it reads whatever was in the registers. The
send has to carry the signature:

```lisp
(objc:invoke "NSPredicate"
             '("predicateWithFormat:" (objc:objc-object-pointer
                                       objc:objc-object-pointer)
               :result-type objc:objc-object-pointer
               :variadic-num-of-fixed 1)
             "name == %@" "Ada")
```

The example wraps that once in `predicate`, which is also the honest advice:
wrap a variadic selector where you use it rather than spreading the declaration
around. `format-string` notes the other honest thing — `cl:format` and a plain
string is very often the better answer.

### Metal compute

```lisp
(asdf:load-system :objc/examples)
(in-package :objc/examples)

(gpu-map "in[i] * in[i]" #(1 2 3 4))    ; => #(1.0 4.0 9.0 16.0)
(gpu-map "sqrt(in[i])"   #(1 4 9 16))   ; => #(1.0 2.0 3.0 4.0)
(report-metal)
```

A compute kernel written as a string, compiled by the system at run time, and
run on the GPU over data a Lisp function handed it — so the GPU program is data
another function wrote. Edit it, re-evaluate, run again.

It exercises more of the bridge at once than anything else here: a plain C entry
point, ordinary message sends, an owned-object convention, and `MTLSize` — three
`NSUInteger`s, 24 bytes — passed **by value**.

**`MTLCreateSystemDefaultDevice` signals `FLOATING-POINT-OVERFLOW`.** The bridge
masks the traps Cocoa violates around every message send and every
Lisp-implemented method, which is why nothing else here has to think about it —
but this is the first example calling a graphics C function *directly*, and a
`cffi:defcfun` is not a message send. Nothing masks it for you.

And the timings, which are not the shape people expect:

```
device: Apple M3
1000000 elements
300 iterations each:  GPU 21ms   CPU 5501ms   262x
one multiply each:    GPU 16ms   CPU 10ms   slower -- copying wins
```

The second line is the interesting one. For work that cheap the GPU **loses**,
and it loses to the copying rather than the arithmetic — getting a million
floats into a buffer and back out again is most of that time, one element at a
time through CFFI, and the kernel itself is nearly free. A GPU pays for itself
once the arithmetic per element covers two copies, and not before. That is a
fact about this bridge as much as about Metal: a lower-level marshalling path
would move the line.

### A 3D scene, headless

```lisp
(report-scene-kit)          ; writes /tmp/objc-scene.png
(render-scene (solar-scene :time 1.2) :path #p"/tmp/s.png" :width 800 :height 600)
```

`SCNRenderer` draws into an image rather than a view, so a scene graph described
in Lisp forms — spheres, boxes, a torus, a camera, two lights — becomes a PNG
with no window server, on a CI runner, in a script. It ships no assets: the
picture is described where you can read it.

`SCNVector3` is three `CGFloat`s, 24 bytes, passed **by value** to
`-setPosition:`. Like `MTLSize` it isn't one of the four Cocoa structures with a
Lisp reading, so it crosses as a pointer to a filled buffer. Three such
structures across the examples now, which makes the rule plain: the `#(x y w h)`
shorthand is a convenience for `NSRect`, `NSPoint`, `NSSize` and `NSRange`, and
everything else is a buffer.

### Sound

```lisp
(synthesize (sine 440) :seconds 0.5)   ; => #(0.0 0.0221 0.0442 ...)
(write-wav (synthesize (fm 220) :seconds 2) #p"/tmp/fm.wav")
(play (chord '(261.63 329.63 392.0)))  ; makes a noise
```

`AVAudioSourceNode` takes a block and calls it whenever the engine needs audio,
handing it a buffer to fill — so **the block is the instrument**, and what comes
out of the speakers is whatever a Lisp function put there. Nothing else here
produces output that continues after the call returns.

**The render block runs on a real-time audio thread**, which is the fact worth
taking away. It has a deadline: fill the buffer before the hardware needs it or
the listener hears a gap. A garbage collection that pauses it past that deadline
is *audible*. A sine wave that allocates nothing is fine; it stops being fine the
moment the instrument conses. Consing in a render block is the audio equivalent
of consing in an interrupt handler. It is one thread, so it sits on the safe side
of the concurrency limit above.

Tested **offline** and demonstrated **live**, and the split is the point.
`AVAudioEngine`'s manual rendering mode runs the graph as fast as it can into a
buffer with no audio device involved, so `synthesize` is deterministic, silent
and works on a CI runner. `play` is the same instrument through the speakers, and
no test calls it.

One measured surprise: an instrument of amplitude 0.5 comes back peaking at
0.3536 — exactly 0.5/√2. The main mixer attenuates by that much on the way
through, which is consistent with the equal-power pan law a mono source gets
across a stereo output. The number is measured; that explanation is inference.

### A shader playground

```lisp
(shader-file "float3(uv, 0.5 + 0.5 * sin(time))" #p"/tmp/a.png")
(run-shader "float3(fract(uv * 8.0), abs(sin(time)))")   ; animates in a window
(report-shader)                                          ; writes four samples
```

One expression in Metal Shading Language, evaluated once per **pixel**, with
`uv` running 0..1 across the image and `time` in seconds, returning a colour.
That is the whole interface, and it is the canvas's live loop with the GPU doing
the drawing.

A *compute* kernel rather than a fragment shader, which is worth saying because
the shape is borrowed from fragment-shader toys: one thread per pixel writing
RGBA into a buffer needs no vertices, no render pass and no drawable, and the
same kernel then serves both the headless half that writes a PNG and can be
tested, and the windowed half that animates.

Two things it documents. The kernel's early return is load-bearing:
`-dispatchThreads:` rounds the grid up to whole threadgroups, so threads exist
for pixels that do not, and without it they write past the buffer — the test
renders 37×23 against an 8×8 group for exactly that reason. And
**`-bitmapData` returns `unsigned char *`**, which encodes identically to a C
string, so plain `invoke` hands back a Lisp string — `""`, since the buffer
begins with a zero byte. `invoke-into` with `:pointer` is what the manual
provides for this, and this is the only example that needs it.

### Maps

```lisp
(map-snapshot 51.5007 -0.1246)                        ; => PNG bytes
(map-file 37.8199 -122.4783 #p"/tmp/bridge.png" :type :satellite)
(report-map)
```

`MKMapSnapshotter` fetches tiles and draws them into an image, so a pair of
coordinates becomes a PNG with no window and no `MKMapView`. The only example
here whose output is a picture of somewhere real.

**The deadlock is the lesson, and it is a new one** — none of the other
completion-handler examples can hit it.
`-startWithCompletionHandler:` delivers on the **main queue**. Waiting for it on
the main thread, which is what a REPL call does, means the thread that would run
the handler is the thread blocked waiting for it: the snapshot completes, the
block queues behind you, and you wait for ever. Measured at thirty seconds, no
callback and no error.

`-startWithQueue:completionHandler:` takes the queue to answer on, so a serial
queue puts the handler somewhere that isn't blocked — the same one-line move
`url-session.lisp` makes for the same underlying reason. A callback needs a
thread free to run it; `NSURLSession` lets you configure that, Quick Look picks
its own, and MapKit defaults to the worst choice for a REPL while offering a
better one in a second selector.

Two smaller things it records. `MKCoordinateRegion` is four doubles — centre and
span — passed by value, a buffer like every other non-Cocoa structure. And there
is no `:scale`, though there obviously should be: `-setScale:` exists on iOS and
not on macOS, which the runtime settled by raising a Lisp error naming the
selector.

### Speech

```lisp
(speak-to-file "Lisp is a programmable programming language." #p"/tmp/q.wav")
(speak-to-samples "Hello." :voice "en-GB")   ; => #(0.0 ...), 22050.0d0
(voices :language "en")
(say "Out loud, this time.")                 ; makes a noise
```

`AVSpeechSynthesizer` will hand the audio back instead of playing it, a buffer at
a time through a block, so a sentence becomes a vector of samples — which
composes with the WAV writer in the audio example.

**The callback arrives on the main thread via the run loop, and there is no
queue-taking variant** as MapKit has. So a blocking wait cannot be fixed by any
arrangement of threads: the only way to receive the buffers is to service the run
loop, with `objc.runloop:pump-events`. That makes this the first example needing
the run-loop helpers for something with no window in it at all — they were
written for AppKit, and it turns out a headless API has the same requirement.
Measured: a semaphore wait sees zero buffers in twenty seconds; pumping sees 122
in about one.

A zero-length buffer is the only end-of-stream signal — no error argument, no
second callback — so a reader waiting for a count it guessed will hang, and one
stopping at the first short buffer will truncate.

### Watching a file the other way

```lisp
(with-coordinated-watch (p #p"/tmp/notes.txt"
                           (lambda (event argument)
                             (format t "~&~S ~S~%" event argument)))
  (pump-for 30))
```

`NSFilePresenter` registered with `NSFileCoordinator` does what the dispatch
source in `file-watcher.lisp` does, and the pair is the point:

**A vnode source watches an inode; a presenter watches a path.** Everything else
follows. An editor's write-temporary-and-rename leaves the dispatch source
holding a descriptor for a file that no longer has that name — which is why
`file-watcher.lisp` needs `:rearm` — while the presenter needs nothing, and a
write to the *replacing* file still arrives. Measured both ways.

A presenter can also be told where the file *went*, be asked to accommodate a
deletion before it happens, and make a coordinated writer wait. What it costs is
that only coordinated writers wait for you, and most writers are not coordinated.
Uncoordinated changes are still reported, which was not what I expected.

It is also the only example whose Lisp class adopts a framework **protocol**,
with `-presentedItemURL` and `-presentedItemOperationQueue` answered from the
instance's own CLOS slots.

### A Lisp object Cocoa owns

```lisp
(point-set (points 1 2  1 2  3 4))       ; an NSSet of 2, not 3
(point-sorted (points 3 4  1 5  1 2))    ; Cocoa sorts, Lisp compares
(report-collections)
```

Every other example calls into Cocoa, or has Cocoa call a Lisp function back.
This one is about a Lisp object being a **first-class participant in Cocoa's own
data structures** — asked `-hash`, `-isEqual:` and `-description`, and answering
from CLOS slots. It exercises the half of the library the others ignore: not the
calling machinery but `standard-objc-object`, the identity map and the two
lifecycle hooks.

**An `NSDictionary` copies its keys.** That is not an optimisation you can
ignore: a key that cannot be copied raises, and one that copies badly gives a
dictionary you can't look anything up in. The library installs `-copyWithZone:`
on every Lisp-defined class and copies the CLOS slots by default, so this works
unasked — and `objc-object-copied` is where you hook it when the default is
wrong. Putting a point in a dictionary fires it, which is how you can see it at
all. `objc-object-destroyed` fires when the pool drains.

**A wrong `-hash` is silent.** Two objects that are `-isEqual:` must hash alike,
and if they don't, an `NSSet` simply contains both and a lookup simply misses.
Nothing raises. That's the failure the test asserts against, because it's the one
you'd otherwise ship.

## Testing

```
make test
```

The suite runs 855 checks. Behaviour that the manual leaves ambiguous was
settled by running the real thing: `test/oracle/answers.lisp` records what
LispWorks Personal 8.1 actually does, and `test/oracle-tests.lisp` asserts
against it. The answers were gathered by hand because LispWorks Personal cannot
be scripted — it ignores `-eval` and launches the IDE.

The `gui` suite skips itself without a window server.

`make test LISP=/path/to/sbcl` runs it under a particular Lisp, which is how the
safepoint build gets tested.

Two workflows. `macOS` runs the suite on stock SBCL on both architectures for
every push. `safepoint` builds an SBCL `--with-sb-safepoint` and runs the suite
on that — weekly and on demand, because the build costs about fifteen minutes
and the answer only changes when the block or GCD code does. It exists because
`parallel-map` and `dispatch-apply` cannot run at all on a stock build, so the
main workflow tests their refusal and nothing else.

That workflow checks that it really got a safepoint build, and fails if not. The
test they are covered by passes on either build — asserting the parallel result
on one and the refusal on the other — so a run that quietly came out stock would
be green having tested exactly what the other workflow already tests.

## License

MIT.
