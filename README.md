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

## Requirements

SBCL on macOS. Dependencies come from [ocicl](https://github.com/ocicl/ocicl):

```
ocicl install
make test
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

(objc/examples:test-area-calculator)   ; returns (values controller window)
(objc/examples:test-pdf-kit "/path/to/some.pdf")
(objc/examples:test-movie-view "/path/to/some.mov")
(objc/examples:test-web-kit "https://www.lispworks.com/")
```

Each shows its window and returns. **A Cocoa window only responds while
something is running the event loop**, so to actually click on one, pump:

```lisp
(objc.runloop:pump-events :max-seconds 30d0)
```

That is the REPL-friendly substitute for `[NSApp run]`, which is what the manual
uses and what `objc.runloop:run-cocoa-application` calls -- it never returns, and
in a REPL it takes the session with it. Neither is LispWorks API: driving the
event loop is CAPI's job there, and there is no CAPI here.

Do not run these under `--non-interactive` and expect to interact with them; the
process exits as soon as the form returns.

## Testing

```
make test
```

The suite runs about 620 checks. Behaviour that the manual leaves ambiguous was
settled by running the real thing: `test/oracle/answers.lisp` records what
LispWorks Personal 8.1 actually does, and `test/oracle-tests.lisp` asserts
against it. The answers were gathered by hand because LispWorks Personal cannot
be scripted — it ignores `-eval` and launches the IDE.

The `gui` suite skips itself without a window server.

## License

MIT.
