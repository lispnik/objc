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

643 checks, green on a clean GitHub runner as well as locally. Behaviour the
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
  framework, and the clearest illustration of where the bindings' edge is.
  `-[VNImageRequestHandler performRequests:error:]` is *synchronous*, so no
  Objective-C block is needed; each recognised line's bounding box comes back as
  a `CGRect` *by value*. The block-based, completion-handler face of Vision would
  need block creation, which the library does not do yet — the synchronous face
  needs none of it. See [Vision OCR](#vision-ocr).

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
methods that take a completion handler would need block creation, which the
library does not have yet.

## Testing

```
make test
```

The suite runs 643 checks. Behaviour that the manual leaves ambiguous was
settled by running the real thing: `test/oracle/answers.lisp` records what
LispWorks Personal 8.1 actually does, and `test/oracle-tests.lisp` asserts
against it. The answers were gathered by hand because LispWorks Personal cannot
be scripted — it ignores `-eval` and launches the IDE.

The `gui` suite skips itself without a window server.

## License

MIT.
