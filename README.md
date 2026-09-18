# objc

[![macOS/SBCL](https://github.com/lispnik/objc/actions/workflows/ci-macos.yml/badge.svg)](https://github.com/lispnik/objc/actions/workflows/ci-macos.yml)
[![macOS/iOS/ECL](https://github.com/lispnik/objc/actions/workflows/ci-ecl.yml/badge.svg)](https://github.com/lispnik/objc/actions/workflows/ci-ecl.yml)

<img width=200 src="https://github.com/lispnik/upc-logger/raw/main/screenshot.png" alt="A device screenshot of a Common Lisp iOS app"> <img width=600 src="https://github.com/lispnik/cathode-ray-tube/raw/main/screenshot.png" alt="A screenshot of a macOS app port of cool-retro-term to Common Lisp"> <img width="275" src="https://github.com/lispnik/utc-status-app/raw/master/screenshot.png" alt="A screenshot of the UTC status bar app">

## AI;DR

You can use this to build legit apps for macOS (using SBCL or ECL) as well as apps for your 
iOS device (using ECL). This library is super-set of the LispWorks Objective-C interface, 
reimplemented for SBCL and ECL on macOS, and for ECL on iOS. 

Works with stock SBCL, or a safepoint build of SBCL (if you want to use anything in macOS 
GCD, you need the safepoint build). For ECL, you need a fork of it from here 
https://github.com/lispnik/ecl -- which we'll try and sort out for upstream later.

Yes, you can connect to your iOS app (simulator or actual device) via SLIME/SLY and [redfine 
anything at runtime](https://github.com/lispnik/asdf-ios-app/blob/master/doc/videos/live-tour.gif) like a civilized person.

### See also:

- https://github.com/lispnik/asdf-macos-app 
- https://github.com/lispnik/asdf-ios-app 

### Examples:

- https://github.com/lispnik/objc/tree/master/examples (many macOS examples)
- https://github.com/lispnik/asdf-ios-app/tree/master/examples (many iOS example apps and screenshots)
- https://github.com/lispnik/cathode-ray-tube (port of my favorite macOS app)
- https://github.com/lispnik/utc-status-app (also see the time in UTC for macOS)
- https://github.com/lispnik/upc-logger (no bullshit UPC scanner for inventoring)

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

Past it, five deliberate additions, each named in the seam test so an
accidental export still fails: **creating Objective-C blocks** from Lisp
closures, which LispWorks does in its FLI and has no `OBJC` interface for, see
[Blocks](#blocks); **`declare-objc-signature`**, for the methods whose type
encoding the runtime cannot write, see [SIMD vectors](#simd-vectors); **an
Objective-C exception raised inside a send is a condition**, `objc-exception`,
where LispWorks lets it abort the process; **`invoke-with-error`**, which
supplies and checks a method's `NSError **` and signals `ns-error`, see
[Exceptions and NSError](#exceptions-and-nserror); and **`invoke*`**, a chain
of sends each to the result of the one before, which expands to exactly the
nested `invoke`s the manual would have you write:

```lisp
(objc:invoke* "CSSearchableItem"
              "alloc"
              ("initWithUniqueIdentifier:domainIdentifier:attributeSet:" id domain attributes)
              "autorelease")
```

934 checks on SBCL, green on a clean GitHub runner as well as locally.
Behaviour the manual leaves ambiguous was settled by running LispWorks Personal
8.1 and recording what it actually did; those answers are committed and asserted
against, so the differential tests run without LispWorks installed.

### ECL

999 checks, none skipped. Everything above works there: `invoke`,
real IMPs, blocks from Lisp closures, structures by value in both directions,
and a block invoked on a libdispatch worker — which used to hang, and was the
one skipped test. It arrived on a thread ECL had never seen and libffi's
executor asked for that thread's environment without importing one; the
executor imports it now, on the `lispnik/ecl` `develop` this needs. Everything the
backend does is the dynamic FFI, so what runs on a Mac is what runs on a phone.

**iOS runs, on a device.** Cross-compiled with
[asdf-ios-app](https://github.com/lispnik/asdf-ios-app), signed with an Apple
Development identity, installed with `devicectl` and run on an iPhone 16e —
with no C compiler anywhere in the picture:

```
1. dispatch                    -length 11, NSNumber round trip 42
2. a structure by value        rangeOfString: (6 . 5)
                               -[UIScreen mainScreen] bounds
                                 #(0.0d0 0.0d0 390.0d0 844.0d0)
3. a Lisp class with real IMPs 6 x 7 through objc_msgSend => 42
                               a method returning NSRange => (3 . 6)
4. a block from a Lisp closure 42
```

390x844 is that phone's own screen; the simulator reports 402x874, which is one
way to tell the two runs apart.

Two defects only the device could surface, both now fixed in `asdf-ios-app`. A
wildcard provisioning profile's `application-identifier` is a *pattern*, and
copying `TEAMID.*` into the binary is rejected by the installer. And ECL's
documentation pool holds the pathname `SYS:help.doc`, so an ordinary
`(setf (documentation ...))` at load time — which this library does thirteen
times — opens a file no bundle contains. Neither can happen on the simulator,
where `SYS:` resolves to a readable directory on the Mac.

### What will bite you

- **An Objective-C exception inside a send is a condition; outside one it still
  terminates the process.** An `NSException` that no Objective-C frame catches
  reaches the runtime's uncaught-exception handler, which is this library's,
  and becomes `objc:objc-exception` in the innermost `invoke` on that thread.
  The frames between are abandoned without their cleanups, so treat the
  subsystem that raised as suspect afterwards. One raised outside any send, or
  on a thread the runtime made, aborts as before, and one Cocoa catches itself
  is not touched. See [Exceptions and NSError](#exceptions-and-nserror). The
  common case is still prevented rather than caught: dispatch resolves the
  `Method` first, so a selector the class does not implement is a Lisp error
  raised before anything is sent.
- **Running Lisp on two libdispatch threads at once needs a safepoint SBCL.** A
  block runs on a thread SBCL did not create; a garbage collection stops the
  world by signalling every other thread in Lisp, and Darwin refuses to signal a
  libdispatch worker at all. One block is fine only while that worker is the
  thread that triggers the collection — the collector skips itself — and any
  other case takes the process down with `cannot suspend thread: 45, Operation
  not supported`, no condition and no Lisp backtrace: a second worker, or the
  main thread filling the nursery while one block sits in Lisp. On a stock
  SBCL, keep asynchronous block work on a **serial** queue, `group-async` in
  the GCD example defaults to one, and keep your other threads out of
  allocation — in a run loop, a wait, or non-consing work — while a block is
  running. And a block is still running for a moment after it signals the
  semaphore you are waiting on — its autorelease pool, its unwinding — so
  the thread it woke asks `objc:wait-for-callbacks` before it allocates; the
  examples that hand a block to a queue do (`wait-for-callback-signal` in
  `examples/gcd.lisp`). Building SBCL `--with-sb-safepoint` lifts the limit
  entirely, verified — see [Blocks](#blocks).
- **Variadic methods need `:variadic-num-of-fixed`.** On Apple silicon a variadic
  call passes its variable arguments on the stack and a fixed-arity call passes
  them in registers, so `+stringWithFormat:` without it reads garbage. LispWorks
  fails silently here; this warns once, naming the fix.
- **A chain of sends is `invoke*`.** `(objc:invoke* "CSSearchableIndex"
  "defaultSearchableIndex" ("indexSearchableItems:completionHandler:" items
  done))` is the manual's nested `invoke`s spelled forwards, and expands to
  exactly them. Not a LispWorks interface; the spotlight example is written
  on it.
- **SIMD vectors need `declare-objc-signature`.** Clang writes *nothing* for a
  `vector_float2`: `-[GKAgent2D setPosition:]` is recorded as `v24@0:816`, an
  empty type between two offsets, and `position` as `16@0:8`, a signature with
  no result. `invoke` notices the hole and signals, naming the selector and the
  fix, instead of miscounting arguments; declared once, by selector, the vector
  goes in and comes out as a Lisp vector. Eight-byte vectors everywhere;
  sixteen-byte ones -- `float3`, `float4` -- on SBCL for Apple silicon and
  Intel, through a 128-bit alien type of this library's own. See
  [SIMD vectors](#simd-vectors).
- **Intel Macs are exercised only in CI.** The two architectures differ in the
  Objective-C ABI in ways that matter, and each is handled by measuring the
  runtime rather than by read-time conditionals: `BOOL` encodes as `c` on Intel
  and `B` on Apple silicon, and a structure result over 16 bytes goes through
  `objc_msgSend_stret` on Intel — a function that does not exist on arm64, where
  the same result returns through `x8`. Both paths are implemented, the
  selection logic is unit tested, and the whole suite runs on GitHub's Intel
  runner; but development happens on Apple silicon, and an Intel-only problem
  is found there rather than here.
- **There is no FLI, and there will not be one.** The type descriptor symbols
  work everywhere the Objective-C manual uses them — method argument and result
  types, `objc-class-method-signature`, `define-objc-struct` slots — but the
  wider LispWorks FLI does not exist here. Ported code that only uses `objc:`
  and `cocoa:` runs unchanged; code that also reaches for `fli:define-c-struct`
  or `fli:allocate-foreign-object` needs rewriting against CFFI. The examples
  carry a six-function `fli` shim for the handful of operators the manual's own
  examples use, and that is deliberately as far as it goes.
- **SBCL and ECL only.** Dynamic dispatch is built on `sb-alien` on SBCL and
  on ECL's dynamic FFI and compiled trampolines on ECL, each confined to one
  file that a test enforces, so another Lisp is one file's work — but only
  those two have it today.
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

SBCL or ECL on macOS; ECL also for iOS. Dependencies come from
[ocicl](https://github.com/ocicl/ocicl):

```
ocicl install
make test         # the suite
make test-clean   # the suite with no ~/.sbclrc and no site init, as CI sees it
```

There is no C toolchain in the build: no `cffi-grovel`, no `cffi-libffi`, and no
shim library.

### SBCL

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

### ECL

**A stock ECL will not do, and the reason is not iOS.** `ecl_library_symbol`
calls `dlsym(0, …)` for the `:default` module, and on Darwin a null handle is
not the global scope — `RTLD_DEFAULT` is `(void *)-2` — so nothing resolves at
all:

```lisp
;; Homebrew ECL 26.5.5
(si:find-foreign-symbol "strlen" :default :pointer-void 0)
=> FIND-FOREIGN-SYMBOL: Could not load foreign symbol "strlen"
   from module :DEFAULT
```

Not `objc_getClass` — `strlen`. CFFI's ECL backend resolves foreign functions by
name, so on a stock build CFFI resolves nothing and this library cannot load.

That is one of the fixes this library needs and stock ECL lacks. The others:
`ffi:callback` returned a libffi closure's writable record rather than its
entry point — the two coincide only where memory may be both, and on arm64
macOS and iOS calling the record jumps into the heap; a dynamic callback did
not import the thread it arrived on, so one called from a libdispatch worker
died in `ecl_process_env()`; and `si:call-cfun` could not pass or return a
structure by value. Each is on a branch of
[lispnik/ecl](https://github.com/lispnik/ecl), for sending upstream, and
`develop` there is upstream `develop` plus all of them:

```
git clone https://github.com/lispnik/ecl.git && cd ecl
git checkout develop
./configure --prefix=$HOME/.local/ecl --enable-gmp=included
make && make install
```

This is what CI builds, resolving `develop` to a commit at the start of each
run. The day the fixes land upstream, the `ECL` workflow can go.

An iOS build additionally needs `-DENABLE_DLOPEN=1`, because `configure` ties
that to `--enable-shared` and an app must link statically while still being able
to `dlsym`.

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
an Objective-C exception. An exception that is raised anyway, from inside the
method, is caught at the runtime's uncaught-exception handler and signalled as
`objc-exception`; see [Exceptions and NSError](#exceptions-and-nserror).

Everything implementation-specific lives in one file, and a test enforces that:
`src/abi.lisp` for SBCL, `src/abi-ecl.lisp` for ECL. Nothing above the seam
knows which is loaded.

### Two ways to reach `objc_msgSend`, on ECL

SBCL JITs a trampoline per signature. ECL runs on a platform where nothing can
be compiled at all, so it has a way that needs no compiler and a way that uses
one.

| | needs | reaches |
|---|---|---|
| **dynamic** — `si:call-cfun` and `si:make-dynamic-callback` | nothing | everything: structures by value both ways, variadic sends, IMPs, blocks |
| **compiled** — generated `ffi:c-inline`, cached per shape | a C compiler at run time | everything, faster |

The first is what a phone uses, and what a REPL attached to one uses, because
it works in an interpreted image. The second is a faster way of doing the same
thing where a compiler happens to exist — one subprocess per distinct call
shape, for the life of the image, the bargain SBCL strikes. Callables are
always the first: a libffi closure costs nothing to make and there is nothing a
compiled one does better.

A variadic send is the last thing the dynamic path learned. arm64 passes
variadic arguments on the stack, a fixed cif puts them in registers, and until
ECL exposed libffi's variadic preparation the only way to make one on a phone
was a trampoline compiled into the app in advance. `si:call-cfun` now takes
the count of fixed arguments, and `invoke`'s `:variadic-num-of-fixed` reaches
it directly, with the variadic arguments promoted the way C promotes them.

**This needs an ECL with fixes**, none upstream yet, all on
[lispnik/ecl](https://github.com/lispnik/ecl) and built by CI from its
`develop`. See [ECL](#ecl) under Requirements. There used to be a third
way here — a pool of trampolines and IMPs compiled into the app before it
shipped — because ECL's dynamic FFI could not name a structure and a libffi
closure was believed to kill the process on iOS. Neither was a property of the
platform: the first was a closed table of scalars in `src/c/ffi.d`, the second
was `ffi:callback` handing out a closure's writable record instead of its entry
point. Fixing ECL deleted the pool.

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

- **An Objective-C exception inside a send is a condition here and a crash
  there.** LispWorks has no exception bridging — its image imports no
  `__cxa_begin_catch`, no `objc_exception_*` and no
  `NSSetUncaughtExceptionHandler` — and what it reports is the SIGABRT that
  follows. This library installs the runtime's uncaught-exception handler and
  throws to the innermost send; see
  [Exceptions and NSError](#exceptions-and-nserror). Both prevent the common
  case rather than catch it: a selector the class does not implement is a Lisp
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

- **`OBJC` exports twenty symbols LispWorks does not.** Eight are the block API
  below — LispWorks has no block interface in `OBJC` at all; there it is
  `fli:allocate-foreign-block`, and there is no FLI here. One is
  `declare-objc-signature`, for a method whose encoding the runtime cannot
  write, which LispWorks, reading the same runtime, cannot call either. One is
  `invoke*`, a chain of sends that expands to the manual's nesting; a reading
  of the idiom, not a change to it. Ten are the two conditions `objc-exception`
  and `ns-error` with their readers and `invoke-with-error`, for what LispWorks
  does not do at all. Each is a deliberate widening of the package, and the
  seam test names all twenty explicitly so an accidental export still fails.

## Exceptions and NSError

```lisp
(handler-case (objc:invoke array "objectAtIndex:" 99)
  (objc:objc-exception (e)
    (objc:objc-exception-name e)     ; => "NSRangeException"
    (objc:objc-exception-reason e))) ; => "*** -[__NSArray0 objectAtIndex:]: index 99 beyond bounds ..."

(handler-case (objc:invoke-with-error "NSString" "stringWithContentsOfFile:encoding:error:" path 4)
  (objc:ns-error (e)
    (list (objc:ns-error-domain e) (objc:ns-error-code e) (objc:ns-error-description e))))
;; => ("NSCocoaErrorDomain" 260 "The file “x” couldn’t be opened because there is no such file.")
```

**An `NSException` raised inside a send becomes `objc-exception`.** The
mechanism is the runtime's uncaught-exception handler, `objc_setUncaughtExceptionHandler`,
which runs on the throwing thread after the C++ unwinder has found no handler
and before anything is unwound: the last moment at which the exception can
still be claimed. The handler is a Lisp callback; it throws to the innermost
`invoke` on that thread, which signals the condition with the exception's name,
reason, the thrown object, and the selector for the report. Not the exception
preprocessor, which sees every throw: Cocoa uses exceptions as control flow in
places you cannot enumerate, AppKit's event loop among them, and a handler that
fired on every throw would end that loop on an error it was about to recover
from. The uncaught handler runs only when the process was about to die, so an
exception Cocoa catches itself is not touched.

What that costs: the C frames between the send and the raise are abandoned
without their cleanups, so a lock or `@synchronized` held in one of them stays
held and a pool pushed there is drained by the enclosing one; per caught
exception the process keeps the runtime's own reference to the `NSException`
with the backtrace CoreFoundation attached to it, about 3 KB. `NSException` is
for programmer errors, and this is the price of surviving one: the subsystem
that raised is suspect afterwards, the process is not. An exception raised
outside any send, or on a thread the runtime made and Lisp only attached for a
callback, goes to the handler that was installed before ours and terminates the
process as it always did. A send inside a callback inside a send catches its
own. The thrown object is never released; do not release it either.

**`invoke-with-error` supplies and checks a method's `NSError **`**, the last
parameter of every `...error:` method, so the foreign pointer, the null, the
read-back and the `localizedDescription` are one call. The result is returned
as `invoke` would return it, an object pointer or 1 for a BOOL, unless it says
the method failed (nil, NO, or nothing for a void method) *and* an error was
written, in which case `ns-error` is signalled with the domain, code, localized
description and the `NSError` itself, retained once by the condition. A success
value comes back whatever the error slot holds, since Cocoa promises the error
only on failure; a method that reports through a status code rather than nil
or NO keeps its own check. `-[NSAppleScript executeAndReturnError:]` takes an
`NSDictionary **`, not an `NSError **`, and is not for this.

Neither is a LispWorks interface: LispWorks lets the exception abort the
process and has no NSError helper. Both are named in the seam test with the
other additions.

## Blocks

A block is C's closure: a struct carrying a function pointer, which every modern
Cocoa API that takes a completion handler expects. `make-objc-block` builds one
from an arbitrary Lisp closure, so `NSURLSession`, GCD, and the
`...UsingBlock:` half of Foundation are reachable.

On SBCL a Lisp-defined method is a block too, underneath. On Apple silicon
SBCL keeps every foreign callback's trampoline in a fixed 1 MB static code
space that is never reclaimed, and an IMP that was a callable of its own cost
about 7 KB of it, some 140 methods per image. So `define-objc-method` builds
one callable per method *signature*, wraps each method's body in a block over
it, and has `imp_implementationWithBlock` mint the entry point Cocoa calls in
libobjc's own trampoline pages. Twenty methods of a known signature cost that
space nothing; a redefinition costs nothing and gives the old trampoline back.
A block IMP is not passed `_cmd`, so the body receives the selector it was
installed for, which is the only one it could have been called with. The cost
is one hop, about 40 ns on a method Cocoa calls per element: the block's
closure is found by its id in a vector read without a lock. ECL keeps a
libffi closure per method: it has no fixed space to run out of, and the hop
measured four times slower there, so the seam decides (`methods-as-blocks-p`).

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

A structure you declare with `define-objc-struct` is written from a sequence
the same way the four Cocoa ones are: a vector or a list with one element per
field, each coerced to its field's type and stored at its field's offset, a
nested structure as a sequence of its own. That holds where a message wants
the structure by value and where a Lisp method returns one, so a
`UIEdgeInsets` goes out as `#(8 0 8 0)` and comes back from a delegate the
same way, and `invoke` on a method that returns one gives the vector back
too, nested structures nested, so `-[CLLocation coordinate]` is
`#(37.33 -122.01)` with no buffer to allocate. A pointer to foreign memory,
the manual's form, still works. (An argument *arriving* in a Lisp method is
still a pointer, as the manual says.)

Structs pass **by value** in both directions, so
`-[NSString enumerateSubstringsInRange:options:usingBlock:]` hands its `NSRange`s
straight to the closure and a block may return an `NSRect`, or any declared
struct, which `call-objc-block` hands back as a vector. The one gap is a
result struct that was never declared: with no layout to read by, the only
answer would be a pointer into a buffer the call frees on its way out, so it
signals instead.

### SIMD vectors

Objective-C's type encoding has no spelling for a SIMD vector, so Clang writes
nothing where one goes. The runtime then describes `-[GKAgent2D setPosition:]`
as a method with no arguments and `-[GKAgent2D position]` as one with no
result, and LispWorks, reading the same runtime, has no answer either. Here the
parser marks the hole rather than miscounting, and a hole in a signature is an
error that says what to declare:

```lisp
(objc:declare-objc-signature "setPosition:" '((:vector :float 2)))
(objc:declare-objc-signature "position" '() :result-type '(:vector :float 2))

(objc:invoke agent "setPosition:" #(3.0 4.0))
(objc:invoke agent "position")                  ; => #(3.0 4.0)
```

`(:vector element count)` is the type, an FLI descriptor like any other: it
goes in `define-objc-method` and `define-objc-block-type` too, where the body
sees a Lisp vector and may return one, and a method defined that way records
its own signature so `invoke` needs no telling. The list form of a method name
takes it per call, `'("setPosition:" ((:vector :float 2)))`, for a one-off. A
declaration is consulted only for a selector whose runtime signature has a
hole; a method the runtime describes fully is never second-guessed.

How it crosses: an eight-byte vector travels in one SIMD register, which is
exactly how a double travels on arm64 and x86-64, and *not* how a struct of two
floats travels, which is a homogeneous aggregate and goes in two registers. So
`float2`, `int2`, `short4` and the rest of the eight-byte family are carried
as the double occupying the same bytes, packed and unpacked on the Lisp side,
and the backends never see a vector at all.

The sixteen-byte family -- `float4`, `float3` (sixteen bytes, not twelve),
`double2`, `int4` -- travels in a 128-bit register, the whole of `v0` on arm64,
and no alien type can name a value of that shape. On SBCL the lanes are packed
with the kernel's own register instructions, the ones sb-simd's `f32.4` is
made of, so a vector never touches memory on its way to a register; and a
`simd-pack` is accepted as the value itself, so an `sb-simd-neon:f32.4` built
with sb-simd's arithmetic goes to SceneKit as it is. **On SBCL for macOS it is
carried anyway**, on Apple silicon and on Intel, both directions, `invoke` and
`call-objc-block` as well as a Lisp method or block taking or returning one.
sb-alien's type classes are a fixed table and `alien-type` is sealed, so a
class cannot be added; instead a second instance of the double-float type is
marked 128 bits wide, and that class's methods dispatch on the width -- a NEON
or SSE register and a `simd-pack` for the wide one, SBCL's own method for a
double. Callbacks go through SBCL's own callback wrapper for the architecture
with two branches added for the wide type, in `src/abi-neon.lisp` on arm64 and
`src/abi-sse.lisp` on x86-64, installed as a dispatcher so a signature with no
vector in it never leaves SBCL's own code. Measured against `GKAgent3D`, whose
position is a `vector_float3`. One limit: a sixteen-byte vector must be among
the first eight floating-point arguments of a call, which every Objective-C
method satisfies.

**On ECL the same family crosses a call**, through the compiled C trampolines:
the dynamic FFI cannot name a value that lives in a 128-bit register, so a
sixteen-byte vector or a matrix goes the way a structure does there, as a
pointer to a buffer the generated C loads by value with `simd_float4` and its
kin from `<simd/simd.h>`, and a result comes back through the out buffer. That
needs a C compiler, so a Mac has it and a phone does not; and it is calls and
block calls only -- a Lisp method or block on ECL is a libffi closure, and
libffi has no vector type, so a callback taking or returning one is refused
where it is defined. A structure with a vector field is refused everywhere:
Clang cannot encode it either, so the runtime would lay it out without the
field.

**Matrices** come with the sixteen-byte family, on the same build. `(:matrix
:float 4 4)` is `simd_float4x4`, and its value is a vector of column vectors,
simd's own layout: `#(#(1 0 0 0) #(0 1 0 0) #(0 0 1 0) #(x y z 1))`. To the ABI
a matrix is a homogeneous aggregate of short vectors, four registers in a row,
which is exactly four vector arguments in a row -- so a matrix is passed as
its columns, returned from a call as `values` of them, and returned from a
Lisp method or block through a marked type as wide as all its columns, which
the widened wrapper loads into `v0`-`v3`. The runtime writes `{?=[4]}` for one,
an anonymous struct of an array of four of nothing, and `{?=}` for a
quaternion; both parse as holes and take a declaration. On x86-64 nothing is
homogeneous past sixteen bytes, and SysV sends a matrix through memory like
any large struct; so there a matrix is a record of its padded columns, and
crosses the way a declared structure does, on both sides, with `float3x3`
forty-eight bytes as simd lays it out. The declaration is the same:

```lisp
(objc:declare-objc-signature "simdTransform" '() :result-type '(:matrix :float 4 4))
(objc:declare-objc-signature "setSimdTransform:" '((:matrix :float 4 4)))
```

Measured against `SCNNode`, which reads the translation back out of the
fourth column as `simdPosition`, under both Lisps. `float2x2`, `float3x3`,
`float4x4` and `double2x2`; a column wider than sixteen bytes, `double3` or
`double4`, is not a short vector and travels through memory, so those
matrices are refused.

**Only one libdispatch thread may be inside Lisp at a time.** This is SBCL's
limit, not GCD's, and it is worth knowing before writing anything concurrent. A
block runs on a thread SBCL did not create; a garbage collection stops the world
by sending every other thread a signal, and **Darwin refuses to signal a
libdispatch worker thread at all** — `pthread_kill` on one returns `ENOTSUP`
even for signal 0, where an ordinary SBCL thread returns 0. A single block gets
away with it because the collector skips the thread that triggered it — so
while a worker is inside Lisp, the only thread that may start a collection is
that worker. A second worker, or the main thread consing enough to fill the
nursery while the first sits in its callback, and the process dies outright:

```
fatal error encountered in SBCL: cannot suspend thread ...: 45, Operation not supported
```

Safe on a stock build: `dispatch_sync`; any number of blocks on a **serial**
queue; and your own Lisp threads running while a queue thread is in a callback,
provided they are in a foreign call — a run loop, `dispatch_group_wait`, a
semaphore — or doing work that does not allocate. Unsafe: concurrent queues
with more than one block in flight, `dispatch_apply`, and building anything on
the main thread while a block is running — the GCD example used to make its
hundred blocks while the first sat inside Lisp, and passed only as long as no
collection landed in that window; measured, a full collection on the main
thread with one worker parked in a block kills stock 2.6.8 on arm64 and x86-64
every time. With the nursery shrunk to 256 KB to make the window easy to hit,
four more examples died the same way — the map snapshot, Spotlight, XPC and the
file watcher — and their backtraces showed the window nobody draws: the block
had already signalled the semaphore, the main thread was awake and allocating,
and the worker was *still inside Lisp*, draining its autorelease pool and
unwinding. So the library has `objc:callbacks-in-progress-p`, true while any
thread Lisp did not create is inside a callback, and `objc:wait-for-callbacks`,
which spins without consing until none is; a woken thread calls the latter
before it goes on. The four examples do (`wait-for-callback-signal` in
`examples/gcd.lisp`); the other thirty-odd example tests survived that nursery
as they were. That closes the tail and not the whole window: traced, what still
kills the four under the shrunken nursery is the block's *dispose helper* — a
Lisp callback that runs on whichever thread Cocoa releases its copy of the
block on, after the block has returned and the main thread has moved on.
Nothing on the waiting side can time that, and forcing a collection "while it
is safe" is worse than nothing against it: a forced collection is a certain
stop-the-world at a moment chosen blind, and the Intel CI leg died in exactly
such a call. Helpers that never enter Lisp, a few instructions of machine code
keeping an atomic count for Lisp to reap later, are the fix for that and are
not written yet. They would pay for themselves on any build: the bench's
`worker:` rows put a helper's entry at about 22 µs on SBCL and 50 µs on ECL,
a second adoption of the worker for every block Cocoa copies and releases.
Serialising Lisp entry with a lock does not help — a worker parked on a Lisp
lock still has to be signalled.

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
- `examples/xpc.lisp` — a Lisp XPC service and its client. Over libxpc:
  both ends in one process over an anonymous endpoint for the test suite,
  and a launchd agent, installed and removed from Lisp, for a separate
  service process that any process of yours can send forms to. And over
  `NSXPCConnection`, which wants the extended method encodings only clang
  emits: `make-lisp-protocol` creates a protocol at run time and writes those
  encodings into the runtime's own structure, layout checked first, and a
  remote proxy then carries a Lisp method call and its reply block.
- `examples/swift.lisp` — Swift-only frameworks: CryptoKit, Swift Charts in
  SwiftUI, and FoundationModels, the on-device language model of macOS 26.
  None has an Objective-C surface, so `examples/swift/LispSwift.swift` gives
  them one -- a hundred lines of `@objc` Swift, built into a dylib by
  `build.sh` -- and the rest is `objc:invoke`. Measured: the hash and HMAC
  match their published vectors, a ChaChaPoly box round-trips and refuses
  tampering, SwiftUI renders a bar chart to a PNG, and the model answers a
  question from Lisp in about three seconds.
- `examples/menu-bar-lisp.lisp` — a Lisp in the menu bar: copy an expression
  in any application, press ⌃⌥⌘E, and the value replaces it on the clipboard
  and shows in a panel. The hotkey is a global event monitor, which macOS
  delivers only to a process granted Accessibility; the menu says whether it
  has been.
- `examples/notes-app/` — a document-based application as a signed `.app`:
  `NSDocument`, `NSDocumentController`, a menu without a nib, packaged by
  asdf-macos-app. See its README.
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
  mechanisms and the one most able to earn an `NSException`. See
  [Key-value observing](#key-value-observing).
- `examples/exceptions.lisp` — three failures earned on purpose and caught: an
  `NSRangeException`, an `NSInvalidArgumentException`, and an `NSError`. See
  [Exceptions, earned on purpose](#exceptions-earned-on-purpose).
- `examples/stress.lisp` — every hot path hammered in one image: sends,
  blocks made and freed, methods called and redefined, exceptions by the
  thousand, pools, threads, with memory watched per phase. See
  [Stress](#stress).
- `examples/data-detector.lisp` — the dates, links, addresses and phone numbers
  in ordinary prose, via `NSDataDetector`.
- `examples/predicates.lisp` — querying and sorting Cocoa collections with
  `NSPredicate`, and the only worked example of a **variadic** send. See
  [Variadic sends](#variadic-sends).
- `examples/pdf-document.lisp` — the half of PDFKit with no window in it: write
  a PDF, read its text back. Self-contained, because it writes the PDF it reads.
- `examples/thumbnail.lisp` — Quick Look previews of any file type, through a
  completion handler.
- `examples/accessibility.lisp` — the Accessibility API: the frontmost
  application's windows as a tree of plists, and a button pressed, for a
  process the user has trusted.
- `examples/scripting.lisp` — `NSAppleScript` and Scripting Bridge: AppleScript
  run from Lisp with its reply read out, and Finder's desktop items as
  message sends made up from the dictionary at run time.
- `examples/pasteboard.lisp` — `NSPasteboard` with a type of our own, a Lisp
  form alongside the plain text, and an `NSView` in Lisp that accepts drops.
- `examples/spotlight.lisp` — Core Spotlight: the app's own items indexed
  under a domain and found by title through `CSSearchQuery`'s blocks.
- `examples/workspace.lisp` — `NSWorkspace`: what is running, what opens what,
  and the smallest example here.
- `examples/metal.lisp` — GPU compute: a shader compiled at run time from a
  string and executed over a Lisp vector. See [Metal compute](#metal-compute).
- `examples/scene-kit.lisp` — a 3D scene built from Lisp forms and rendered to a
  PNG with no window, and the same scene placed by `float4x4` transforms
  composed in Lisp, SceneKit's own composition read back as a matrix. See
  [A 3D scene, headless](#a-3d-scene-headless).
- `examples/scene-view.lisp` — the same scene in an `SCNView` in a window,
  its orbit turned from Lisp one transform per frame, or by an `SCNAction`
  with Lisp idle. See [A 3D scene, in a window](#a-3d-scene-in-a-window).
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
- `examples/browser.lisp` — a class browser: point it at a class name and it
  prints the methods and their signatures, read from the runtime. See
  [A class browser](#a-class-browser).
- `examples/undo.lisp` — `NSUndoManager` with Lisp methods as the undo
  operations. See [Undo](#undo).
- `examples/memory.lisp` — retain counts, autorelease pools, and observing when
  an object actually dies. See [Memory](#memory).
- `examples/notifications.lisp` — `NSNotificationCenter` through
  `cocoa:add-observer`, and which thread the handler runs on. See
  [Notifications](#notifications).
- `examples/geometry.lisp` — the four `COCOA` structure types, by value and
  through a foreign buffer. See [Geometry](#geometry).
- `examples/strings.lisp` — `NSString` search and conversion, and where its
  indices stop matching Lisp's. See [Strings](#strings).
- `examples/task.lisp` — running a subprocess through an `NSPipe`. See
  [Subprocesses](#subprocesses).
- `examples/plugin.lisp` — protocols and typedefs, and what each one is not. See
  [Protocols and typedefs](#protocols-and-typedefs).

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

There is a four-minute screen-recording script for this in
[`doc/demo.md`](doc/demo.md) — staged, timed, and run end to end, including the
one thing that will ruin a take (AppKit needs thread 1, so it is a plain
terminal `sbcl` and not SLY).

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

It is also where `define-objc-struct` earns its place. Outside the manual's own
two-float `pair`, nothing used it; a `CGAffineTransform` is the natural case —
six doubles that mean something individually, passed by value to a real
framework method:

```lisp
(with-transform (m :a 2 :d 2)
  (image-extent (transform (checkerboard) m)))   ; => #(0 0 128 128)
```

The library needs no layout-table entry for this. The encoding the runtime hands
back carries the field list inline — `{CGAffineTransform=dddddd}` — which is
true of any structure a framework's own method signature mentions;
`*struct-layout-overrides*` is for the ones whose layout the runtime elides.
`-imageByApplyingTransform:` is not the same as scaling, either: a transform
moves the sampling grid and leaves the chain to interpolate, where
`CILanczosScaleTransform` resamples.

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

It is also **the easiest way to earn an `NSException`**, which is why the
example is shaped the way it is. KVO reports misuse by raising one, and though
that is a condition now, `objc-exception`, the frames it abandons are
Foundation's observation machinery, in no state to trust afterwards. Removing an
observer that isn't registered raises `NSRangeException`; letting an observed
object deallocate with observers attached raises from inside `dealloc`. So
`stop-observing` is idempotent and `with-observation` unregisters on unwind. The
first misuse is now earned once, on purpose, and asserted; the second is not,
since catching it abandons a half-deallocated object. Observing a key path the
class does not have, which this section once said raises, raises nothing on
the way in: KVO cannot know the key is missing until something is set through
it.

The `context` pointer is load-bearing, not decoration: a superclass may observe
the same key path on the same object, and only that pointer distinguishes your
registration from its.

### Exceptions, earned on purpose

```lisp
(report-exceptions)
;; objectAtIndex: past the end raised NSRangeException:
;;   *** -[__NSArray0 objectAtIndex:]: index 3 beyond bounds for empty array
;; an unrecognized selector raised NSInvalidArgumentException
;; a missing file is NSCocoaErrorDomain 260: The file “objc-exceptions-example” couldn’t be opened ...
;; the next send worked: T; caught inside a block 2 times
```

Every other example avoids raising an exception, because the frames it abandons
leave the subsystem that raised in a state not worth trusting. This one earns
three failures whose subsystems are disposable and shows what each is as a
condition: `objectAtIndex:` past the end, an `NSRangeException`; a selector
nothing implements, sent unresolved through `performSelector:` the way a
framework would, an `NSInvalidArgumentException` (sent through `invoke` it
would be a Lisp error before anything was sent); and a file that is not
there, an `NSError` that `invoke-with-error` turns into `ns-error` with its
domain, code and description. The send after them works, and the exception
earned inside a block inside a send is caught by the block's own send, so the
enumeration completes. See [Exceptions and NSError](#exceptions-and-nserror).

### Stress

```lisp
(report-stress)
;; SENDS          300,000 ops        339 ns/op  resident +35,648 KB  ok
;; BLOCKS         200,200 ops        167 ns/op  resident +480 KB  ok
;; METHODS         40,000 ops        248 ns/op  resident -1,376 KB  ok
;; CHURN              200 ops    415,890 ns/op  resident -6,128 KB  ok
;; EXCEPTIONS       2,000 ops     23,142 ns/op  resident +7,408 KB  ok
;; POOLS           80,000 ops        827 ns/op  resident +1,072 KB  ok
;; THREADS        160,000 ops         46 ns/op  resident +7,664 KB  ok
;; resident +12,880 KB, Lisp heap -16243232 bytes after a full collection
```

The benchmark measures one call of each shape in isolation; this asks what
happens when each shape runs a hundred thousand times in one image. Seven
phases, each checking its own answers throughout: plain sends of every
result kind; blocks made and freed by the thousand and one called back per
element over a thousand-element array; Lisp methods called from Lisp and per
element by Foundation; a method defined and redefined two hundred times,
which on SBCL must cost the static code space nothing (see [Blocks](#blocks));
a thousand exceptions caught and a thousand `NSError`s signalled; twenty
thousand autorelease pools; and four threads sending at once, each catching
an exception in fifty. The resident size is watched per phase and across the
run after a full collection, and that is the assertion: the growth must be
what the caught exceptions account for and nothing else. `test-stress` runs
it at a tenth of the size for the suite, on both Lisps.

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
everything else is a buffer -- or was, until declared structures learned to
cross as vectors.

**The simd half** is the same scene placed by transforms. SceneKit's other
face is `simdPosition`, a `vector_float3`, and `simdTransform`, a
`simd_float4x4`, neither of which Clang can encode, so the runtime describes
those methods as taking nothing and returning nothing. Declared once, by
selector, they take and return Lisp vectors -- a `float3` as `#(x y z)`, a
matrix as four column vectors -- and a transform composed in Lisp, a rotation
times a translation as plain arithmetic on columns, is handed over whole:

```lisp
(objc:invoke node "setSimdTransform:"
             (matrix-multiply (matrix-rotation-y angle) (matrix-translation 4 0 0)))
(objc:invoke satellite "simdWorldTransform")   ; => four columns, SceneKit's product
(report-scene-kit-simd)                          ; writes /tmp/objc-scene-simd.png
```

<img src="doc/screenshots/scene-kit.png" width="480" alt="A rendered 3D scene: a gold sphere at the centre, five coloured cubes around it on a thin grey ring, each placed by a transform composed in Lisp.">

The test with teeth is the world transform: a satellite sits under an orbit
node, SceneKit composes the two transforms itself, and the result must agree
to four decimals with the product Lisp computes from the same two matrices.
Two implementations of the multiplication agreeing says the columns went over
in the right order and the right registers, both ways. On SBCL a `simd-pack`
goes over as the position itself. This half runs wherever the build carries
sixteen bytes by value -- SBCL on macOS, and ECL with a C compiler -- and
declines by name elsewhere. See [SIMD vectors](#simd-vectors).

### A 3D scene, in a window

```lisp
(animate-scene-view :seconds 12)   ; Lisp places every frame; blocks while it does
(run-scene-view)                   ; SceneKit animates; blocks until the window closes
(report-scene-view)                ; two seconds, then /tmp/objc-scene-view.png
```

The same arrangement in an `SCNView` inside an `NSWindow`, moving.  Its
satellites hang under one orbit node, and `animate-scene-view` turns that node
from Lisp sixty times a second: a `float4x4` composed here and set whole
through `setSimdTransform:` where the build carries one, an Euler angle
through an `SCNVector3` where it does not, with the run loop pumped between
frames the way the canvas animates.  `run-scene-view` is the other shape of the
same thing: an `SCNAction` repeated forever, SceneKit rendering on its own
thread, Lisp idle in AppKit's modal loop until the window is closed.  Drag in
the view to move the camera; that is SceneKit's own camera control, switched
on.

<img src="doc/screenshots/scene-view.png" width="480" alt="A frame of the animated scene: the gold sphere with four visible coloured cubes on the grey ring around it, one cube passing behind, taken from the view itself while Lisp was turning the orbit.">

The frame above is the view's own `-snapshot`, which is also how the test
checks that anything moved: two snapshots twenty Lisp-placed frames apart
must differ byte for byte.

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

### A class browser

```lisp
(describe-objc-class "NSDate")
(describe-objc-class "CIImage" :containing "crop")
(class-chain "NSString")                            ; => ("NSString" "NSObject")
(describe-selector "NSString" "substringFromIndex:")
```

Every other example calls a framework; this one interrogates one. It is the
thing you actually want at a REPL when the documentation is a header you haven't
got: the methods a class implements, what each one takes and returns, and where
it came from — all read from the runtime, so it is accurate for the machine
you're on rather than for the documentation you found.

It exists because the library's own introspection was the part no example used.
`can-invoke-p`, `objc-class-method-signature`, `objc-class-name` and
`trace-invoke` were exported, documented, and called by nothing but the test
suite — while `natural-language.lisp` hand-rolled its own selector listing out of
`class_copyMethodList` rather than reaching for what was already there.

The division of labour is not arbitrary. `class_copyMethodList` is the only way
to *enumerate*, and the library does not wrap it — nothing in the LispWorks
manual does either, so the raw call stays here, in an example.
`objc-class-method-signature` answers the harder question, and answers it
parsed: given a class and a selector, what does the call look like? The argument
list always starts with the receiver and the selector, which is the single most
useful thing to see when a send isn't doing what you expect.

### Undo

```lisp
(let* ((manager (make-undo-manager))
       (counter (make-counter :manager manager)))
  (with-undo-group (manager "Set to 42")
    (set-counter counter 42))
  (undo manager)                        ; => 0
  (redo manager))                       ; => 42

(report-undo)
```

An undo manager is a stack of "how to put it back": register a target, a
selector and an argument, and `-undo` sends that message. Since the target can
be a Lisp object and the selector a Lisp-implemented method, **the undo
operations are ordinary Lisp code that Cocoa decides when to run.**

Two things bite immediately. `-groupsByEvent` defaults to YES, which means the
manager expects a run loop to open and close a group around each event; from a
REPL, a script or a test there is no such loop, the first registration raises
`NSInternalInconsistencyException`, and an `NSException` here ends the process.
Turn it off and manage the groups yourself.

And **an undo operation must register its own inverse**, or there is no redo.
That reads like a curiosity and is the whole design: while `-undo` is running,
the manager records registrations onto the *redo* stack instead of the undo one,
so a method that always registers the inverse of what it is about to do gives
you undo and redo out of one piece of code. Leave it out and undo works exactly
once, `-canRedo` answers NO, and nothing tells you why.

**The other registration style goes through a proxy, and works.**
`-prepareWithInvocationTarget:` hands back a proxy; you send the proxy the
message you want undone, and it records the `NSInvocation` rather than
performing it. The proxy does not *implement* the selector, it forwards it, so
there is no `Method` to resolve — and this library resolves the `Method` before
sending, which is what turns an unimplemented selector into a Lisp error
instead of an `NSException`. For a long time that made a forwarding object
invisible. Now, when there is no `Method`, `invoke` asks the object for the
selector's signature the way forwarding itself does, through
`-methodSignatureForSelector:`, and sends if there is one; a selector nobody
answers still fails in Lisp. That is not really about undo: it is what makes
`NSXPCConnection`'s remote object, `NSDistantObject`, and `UITextField`'s
text-input traits — forwarded, on iOS, from a class that never declared them —
reachable.

### Memory

```lisp
(ownership-walk)     ; => (:FRESH 1 :RETAINED 2 :RELEASED 1 :DIED-ON-LAST-RELEASE T)
(deaths-during-loop) ; => 0     -- one pool around the loop
(deaths-during-loop :per-iteration t)   ; => 200
(report-memory)
```

There is no ARC here — calling through a foreign function interface puts you in
manual retain/release whatever the surrounding code does — and yet every other
example gets away with never thinking about it, because `with-autorelease-pool`
is doing the work. This file is what it is doing.

Deaths are **observed rather than inferred**. A Lisp-defined class gets an
`objc-object-destroyed` hook, so "the object was deallocated" is a recorded fact
rather than a claim about what a retain count implies — which matters, because
the count is a worse witness than it looks:

**`-retainCount` on a tagged pointer is nonsense, and not even consistent
nonsense.** A short `NSString` is not a heap object at all — the characters live
in the pointer — and asking one for its retain count gives
`18446744073709551615`. A tagged `NSNumber` gives `9223372036854775807`. Both
mean "never deallocate me", spelled differently by different classes, and
neither is a number to compare against anything. A short literal string is
exactly what someone reaches for when writing a memory test.

**A count of 1 does not mean you own it.** `+dataWithLength:` returns an object
with a count of 1 that is already registered with the current pool; the pending
release is nowhere in the number. Ownership follows from the call you made —
`+alloc`, `-copy`, `-mutableCopy`, or a name containing "create" — and is not a
runtime property you can measure.

**Draining a pool on a thread that did not create it is a memory fault.** Not a
diagnostic: `Memory fault at 0x10` inside `-drain`, backtrace in libobjc,
process gone. That is why `with-autorelease-pool` is the default and
`make-autorelease-pool` is the sharp tool — and why the example documents this
one rather than demonstrating it.

**Without a pool there is no diagnostic either.** The autorelease simply does
not happen, and nothing is logged, on stderr or anywhere else, even under
`OBJC_DEBUG_MISSING_POOLS=YES`. On the main thread of a plain SBCL process the
object then lives until the process exits; on a thread you started, the runtime
pops the thread's pool page during teardown, so it dies at a moment unrelated to
anything in your code.

The measurement that justifies `make-autorelease-pool` being exported at all is
`deaths-during-loop`: 200 autoreleased objects, and at the end of the loop
**none** of them have died under a single enclosing pool against **all** of them
under one pool per iteration. For a loop over a large directory that is the
difference between a working program and one that grows until it is killed.

### Notifications

```lisp
(let ((listener (make-listener)))
  (with-subscription (listener "ExampleNote")
    (post-notification "ExampleNote" :info '(:who "a value"))
    (notifications-received listener)))
;; => ((:THREAD "main thread" :NAME "ExampleNote" :INFO ("who" "a value")))

(run-briefly)             ; => (:TERMINATED T ...)
(run-briefly :pump nil)   ; => (:TERMINATED NIL ...)
```

Foundation's one broadcast mechanism, and the half of the `COCOA` package that
had no example: `add-observer` and `remove-observer` are two of the eleven
symbols that package promises, and every notification in this repository was
being done by hand through `invoke` instead.

**This is not KVO.** `kvo.lisp` observes a key path with
`-addObserver:forKeyPath:`, a different mechanism with different rules and a
much sharper edge. The `COCOA` package covers only the notification centre.

**The handler runs on the thread that posted, not the thread that registered.**
Delivery is a synchronous message send inside `-postNotificationName:`, so
posting from a worker runs your handler on that worker. Measured: register from
the main thread, post from a thread named `poster`, and the handler reports
`poster`. An observer that touches AppKit is only as safe as every caller that
posts to it — which is not a property you can see by reading the observer.

**The centre does not retain the observer**, so keeping it alive is yours. But
**a dead observer is not a crash**, and this is where the advice you will find
is out of date: deallocate an observer without removing it, post, and nothing
happens — modern macOS zeroes the reference for the selector-based
registration. Measured, not assumed, and worth knowing precisely because the
folklore says otherwise. It is *not* true of
`-addObserverForName:object:queue:usingBlock:`, which retains the block until
you remove its token, and it is emphatically not true of KVO, which still ends
the image.

**A run-loop notification needs the run loop.** Everything above is synchronous.
Foundation's own notifications mostly are not: `NSTaskDidTerminateNotification`
is posted onto the run loop of the thread that launched the task, so sleeping
never sees it however long the child has been dead, and pumping sees it at once.
That is [Speech](#speech)'s lesson arriving somewhere far less expected — a
notification feels passive, and this one is not.

### Geometry

```lisp
(unbox (box-rect 1 2 3 4) :rect)     ; => #(1.0d0 2.0d0 3.0d0 4.0d0)
(unbox (box-range 5 7) :range)       ; => (5 . 7)   -- a cons, not a vector

(with-ns-rect (r 0 0 320 200)
  (objc:invoke "NSValue" "valueWithRect:" r))   ; a filled buffer works too
```

`ns-point`, `ns-size`, `ns-rect` and `ns-range` with the four `set-ns-*`
writers — six of the eleven symbols `COCOA` exports, and the part of it with no
example until now.

A structure crosses in one of two shapes. As a **Lisp value**: `#(x y)`,
`#(width height)`, `#(x y width height)` — and `ns-range` as a **cons**,
`(location . length)`, which is the manual's asymmetry and catches people. Or as
a **pointer** to memory you filled, which is what the `set-ns-*` writers are
for; a filled buffer is accepted anywhere the vector is.

**A vector of the wrong length is not checked**, and the two failures are not
symmetric: too few components signal from inside the conversion, naming an index
rather than your call, and too many are **silently dropped**.

**Foundation's own geometry functions are out of reach.** `NSUnionRect`,
`NSIntersectionRect` and `NSPointInRect` are plain C functions taking structures
by value, not messages — no encoding to read, no trampoline to build, and CFFI
signals `COMPILED-PROGRAM-ERROR` without libffi. Anything reachable by *message*
is fine, which is why the `NSValue` boxing route works; the arithmetic here is
in Lisp because there is no alternative.

### Strings

```lisp
(find-substring "hello, world" "world")   ; => (7 . 5)
(find-substring "hello, world" "zzz")     ; => NIL, not a range at NSNotFound
(report-strings)
```

Strings cross constantly and mostly invisibly. This is the two places that stops
being true, both of which fail quietly.

**A failed search returns `NSNotFound`, which is not −1.** It is `NSIntegerMax`,
9223372036854775807, arriving as the location of a zero-length range. Test it
against `cocoa:ns-not-found`; test it with `minusp` and you have a program that
indexes a string at nine quintillion.

**An `NSString` counts UTF-16 code units and a Lisp string counts characters.**
They agree until a character outside the basic plane appears, and then they
differ by one per such character, silently:

```
"a😀b tail and more"   Lisp LENGTH 17, -length 18
-rangeOfString: "tail"  location 5
POSITION of "tail"      4
(subseq text 5 9)       "ail "   -- in bounds, no error, wrong answer
```

An `NSRange` is an offset into a string Lisp is not holding. Keep ranges on the
Cocoa side — `-substringWithRange:` is right because Cocoa is consistent with
itself — and search Lisp strings with Lisp functions.

### Subprocesses

```lisp
(run-command "sw_vers -productVersion")   ; => "26.6.2", 0
(command-output-lines "printf 'one\ntwo\n'")
```

`NSTask` and `NSPipe`. `notifications.lisp` already launches a task to watch its
termination notification; this is the pipe half, and the pipe is where the trap
is.

**`-waitUntilExit` before draining the pipe deadlocks**, and only once the child
writes more than the buffer holds — about 64KB on macOS. Under that the obvious
order works; over it the child blocks in `write(2)` waiting for a reader and the
parent blocks waiting for the child, with no error and no timeout. Read to the
end *first*: `-readDataToEndOfFile` returns when the child closes its end, which
is what `-waitUntilExit` was going to wait for anyway. The test moves 196608
bytes, so the wrong order would hang it rather than fail it.

**`-launch` raises on a bad path**, and an `NSException` ends the process, so the
failure has to be turned into a Lisp error first — `-launchAndReturnError:` where
the runtime has it, a `probe-file` where it does not.

### Protocols and typedefs

```lisp
(conforms-p (make-plugin "example") "NSCopying")   ; => T
(conforms-p (make-plugin "example") "NSCoding")    ; => NIL
(report-plugin)
```

The last two defining macros, and neither does what its name suggests.

**`define-objc-protocol` does not create a protocol.** It records a
*declaration* — the methods you expect a protocol to have — for protocols that
already exist. Measured: `objc_getProtocol` still answers null for a name only
you have declared, so nothing can conform to it. The manual's reason for this
("impossible on 10.5 and later") is stale — `objc_allocateProtocol` has worked
since 10.7, and `src/protocol.lisp` records this repository verifying it — so
the restriction is the library's choice. What a runtime-created protocol still
cannot carry is the extended method signatures clang emits, which is why
`NSXPCInterface` refuses one. Conformance goes the other way, through
`define-objc-class`'s `:objc-protocols`, and that registration is real —
`-conformsToProtocol:` reads it back from the runtime.

**`define-objc-typedef` is for the reader, not the runtime.** A method declared
to return `time-interval` encodes as `"d@:"` and its signature reads back
`:double`; the name is erased at the boundary exactly as a C typedef is. That
buys code that reads like the headers, and no type checking whatsoever —
`NSTimeInterval` and `CGFloat` are both doubles and nothing will stop you
confusing them.

## Performance

`make bench` runs [bench/bench.lisp](bench/bench.lisp) on SBCL and ECL and
merges the results with a LispWorks column into
[bench/RESULTS.md](bench/RESULTS.md).  One file, compiled on each Lisp, the
median of five rounds of 200 000 calls; `make bench-lispworks` prints the two
forms to type into a LispWorks Listener for the third column, since LispWorks
Personal cannot be scripted.  The rows are the floors (a Lisp `length`, a bare
`objc_msgSend` through the FFI), a send for each kind of argument and result,
a block and a Lisp method called back per element, and the SIMD paths.  An
SBCL built `--with-sb-safepoint` gets its own column, `sbcl-safepoint`, since
it is a different runtime; `sbcl` is the stock Homebrew build.  Measured back
to back on 2026-09-17, the stock build is the slower of the two on most rows,
by a few nanoseconds on a send and by more on the declared-vector rows, which
was not the expected direction and is recorded rather than explained.
`make bench-sbcl LISP=/opt/homebrew/bin/sbcl` measures a particular build;
it inherits nothing from `~/.sbclrc` and compiles the benchmark through ASDF's
output translations, so two SBCLs of the same version never load each other's
fasls.

The three `worker:` rows measure what a block on a libdispatch thread costs
beyond the hop itself.  A C-only no-op block through a queue and back is the
floor, about 5 µs on SBCL and 10 µs on ECL.  A Lisp block held as a heap copy
adds one entry into Lisp on the worker, which SBCL must adopt as a thread for
the duration: about 22 µs, on the stock and the safepoint build alike, and
about 50 µs on ECL.  A Lisp block handed over fresh adds a second adoption of
the same size, because libdispatch's release of its copy runs the dispose
helper on the worker, and the helper is a Lisp callback too.  That second
adoption is what machine-code helpers, described under Blocks, would remove;
it doubles the cost of every block Cocoa copies and releases, on every build.

What the numbers say, measured 2026-09-16 on an M-series Mac, after the two
changes the first run of this benchmark called for (a send cache keyed by
class and selector instead of by Method, and runtime entry points resolved
once on ECL):

- **SBCL matches LispWorks on a plain send** -- 121 ns against 120 ns for
  `-length` -- and is ahead everywhere the method is not on the receiver's
  own class: `-self`, inherited from NSObject through the NSString cluster,
  is 116 ns on SBCL and 1870 ns on LispWorks.  LispWorks asks the runtime for
  the Method on every send, and `class_getInstanceMethod` walks the
  hierarchy with no cache of its own; this library did the same until the
  cache was re-keyed, when `-self` fell from 1119 ns.  A struct result is
  286 ns against 1565; a Lisp method called per element by Cocoa is 56 ns
  against 45; a block, 101 against 50.
- **ECL went from 15.9 µs to 0.46 µs per send.**  cffi's ECL backend runs in
  `:dffi` mode, where every `defcfun` call does a `dlsym` before it calls --
  7 µs each with GameplayKit loaded, two per send.  The runtime functions
  now resolve their address once (`define-runtime-function` in
  `src/library.lisp`), and the plain ones are C calls through that address.
  What is left is the dynamic `libffi` call itself, 119 ns for a bare
  `objc_msgSend`, plus ECL's pointer boxing; the send is within about 150 ns
  of that floor.
- **A Lisp string as an argument** costs 359 ns on SBCL against 580 on
  LispWorks.  It was 539: the NSString was made with -alloc and
  -initWithUTF8String:, two sends, and is now one call of
  CFStringCreateWithBytes on the string's UTF-8, which also keeps a NUL.
- **An eight-byte vector as a Lisp vector** is 193 ns in and 166 out, from
  382 and 372: the lanes are assembled into the carrier double's bits in
  registers instead of through a foreign buffer, with the loop written out
  for a simple vector.  The 50 ns over the same value passed as a double
  through the list form is the lane loop and the type check on the value.
- **ECL's buffer rows were never about the buffers.**  A struct result was
  3.2 µs, a string out 3.7, a string in 3.9 and a declared float3 7.0; they
  are 1.1, 1.0, 2.0 and 1.2 now.  A foreign allocation on ECL is 44 ns.  The
  costs were CFFI's `mem-aref` with a type or offset chosen at run time,
  which recasts the pointer per access at 1.4 µs, so every lane loop and the
  byte copy of a struct result paid it; CFFI's string conversions through
  babel at 2 to 3 µs for eleven characters where ECL's own are 0.3; and
  float bits through a foreign word.  The ECL seam now does lane access,
  `memcpy`, float bits and UTF-8 as C expressions, with the CFFI forms kept
  for a bytecode load.

## Testing

```
make test
```

The suite runs 934 checks. Behaviour that the manual leaves ambiguous was
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
