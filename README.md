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

743 checks, green on a clean GitHub runner as well as locally. Behaviour the
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

## Requirements

SBCL on macOS. Dependencies come from [ocicl](https://github.com/ocicl/ocicl):

```
ocicl install
make test         # the suite
make test-clean   # the suite with no ~/.sbclrc and no site init, as CI sees it
```

There is no C toolchain in the build: no `cffi-grovel`, no `cffi-libffi`, and no
shim library.

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

- **`define-objc-protocol` declares, it does not create.** The manual already
  says creating protocols has been impossible since macOS 10.5.

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

Safe: `dispatch_sync`; any number of blocks on a **serial** queue; and your own
Lisp threads running while a queue thread is in a callback. Unsafe: concurrent
queues with more than one block in flight, and `dispatch_apply`. Serialising
Lisp entry with a lock does not help — a worker parked on a Lisp lock still has
to be signalled. The mechanism that would fix it is an SBCL built
`--with-sb-safepoint`, which stops the world by polling rather than signalling;
untried here. See [Grand Central Dispatch](#grand-central-dispatch).

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

It is also where the concurrency limit above stops being abstract. The example
defaults every asynchronous entry point to a **serial** queue, and there is no
`parallel-map` in it however much the name suggests itself: `dispatch_apply` with
an allocating Lisp closure kills the process every time. `group-async`, by
contrast, is three lines and uses `with-objc-block` like everything else, even
though the work has not started when it returns — an earlier draft carried every
queued block on the group and freed them after the wait, which is what the job
takes without copy and dispose helpers.

## Testing

```
make test
```

The suite runs 743 checks. Behaviour that the manual leaves ambiguous was
settled by running the real thing: `test/oracle/answers.lisp` records what
LispWorks Personal 8.1 actually does, and `test/oracle-tests.lisp` asserts
against it. The answers were gathered by hand because LispWorks Personal cannot
be scripted — it ignores `-eval` and launches the IDE.

The `gui` suite skips itself without a window server.

## License

MIT.
