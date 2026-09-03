# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A reimplementation of the LispWorks Objective-C interface for SBCL on macOS: the
packages are literally named `OBJC` and `COCOA`, the exported symbols have the
LispWorks names and lambda lists, and code written against the *LispWorks
Objective-C and Cocoa Interface User Guide and Reference Manual* is intended to
load and run unchanged. SBCL, ocicl, FiveAM. arm64 and Intel.

Dispatch is dynamic. A method's type encoding is read from the runtime, parsed,
and turned into a compiled trampoline that calls `objc_msgSend` through one exact
non-variadic signature; the trampolines are memoized. Objective-C classes defined
from Lisp get real IMPs built the same way in the other direction.

## Build & test

```
ocicl install    # restore dependencies (ocicl/ is gitignored)
make test        # load #:objc/test and run the suite
make repl        # an SBCL with the library loaded
make clean       # fasls plus the ASDF cache for this tree
```

Run one test from a REPL (FiveAM has no CLI selector):

```lisp
(asdf:load-system :objc/test)
(fiveam:run! 'objc/test::bool-results-are-integers-from-invoke)
(fiveam:run! 'objc/test::encoding)   ; or a whole suite
```

`fiveam:run!` prints failures but returns NIL on failure, and ASDF discards what
a `test-op` returns, so both the Makefile and the `.asd` go through
`objc/test:run-tests`, which returns the status. Don't replace it with `run!` in
a batch context.

The `gui` suite skips itself when `[NSScreen mainScreen]` is nil, so a headless
run is green with fewer checks rather than green with GUI tests silently not
running. The `dump` suite spawns a subprocess and takes about ten seconds; it is
the slowest thing here and it earns the time (see below).

## Architecture

Systems are defined in `objc.asd`; files load `:serial t`.

- `src/package.lisp` — `OBJC` (the 42 LispWorks symbols plus 8 block symbols),
  `COCOA` (11), and `OBJC.RUNLOOP`. Both Cocoa packages are created here because
  the type descriptor symbols cross between them.
- `src/conditions.lisp` — internal conditions, none exported.
- `src/library.lisp` — foreign library discovery, and the image dump/restore
  hooks.
- `src/runtime.lisp` — the `%`-prefixed libobjc `defcfun`s.
- `src/encoding.lisp` — the type encoding parser. Pure; no foreign calls.
- `src/types.lisp` — type descriptors, the struct layout table, node sizes.
- **`src/abi.lisp` — the implementation seam.** Trampolines, IMPs, float traps.
- `src/selectors.lisp`, `src/classes.lisp` — selectors, classes, signatures.
- `src/dispatch.lisp` — the single call path and the two trampoline caches.
- `src/convert.lisp` — Lisp ⇄ Cocoa conversion and per-call temporaries.
- `src/invoke.lisp` — `invoke`, `invoke-bool`, `invoke-into`.
- `src/memory.lisp` — retain/release/autorelease and pools.
- `src/struct.lisp`, `src/protocol.lisp` — `define-objc-struct`, typedefs,
  protocol declarations.
- `src/object.lisp` — `standard-objc-object` and the identity map.
- `src/class-def.lisp`, `src/method-def.lisp`, `src/root.lisp` — the defining
  macros and the three lifecycle methods.
- `src/blocks.lisp` — Objective-C blocks in both directions. The literal, the
  per-signature machinery cache, and the id-keyed closure registry; the
  `sb-alien` half is `build-block-invoke` / `build-block-caller` in `abi.lisp`.
- `src/cocoa.lisp`, `src/runloop.lisp`, `src/init.lisp`.

## Things that are easy to get wrong

Each of these is a bug that actually happened here.

- **`src/abi.lisp` is the only file allowed to mention `sb-alien:` or `sb-sys:`.**
  `test/seam-tests.lisp` greps the sources to enforce it, because a seam nobody
  checks stops being a seam. `src/runloop.lisp` is the one exception and uses
  only `sb-thread:main-thread-p`.

- **Do not reach for CFFI to make the calls.** Without libffi, CFFI cannot
  express a struct passed or returned by value at all: `foreign-funcall-pointer`
  signals `COMPILED-PROGRAM-ERROR` and `defcallback` signals `CASE-FAILURE`.
  That is not an edge case — `-[NSView frame]`, `-[NSString rangeOfString:]` and
  the manual's own `pair` example all need it. `cffi-libffi` would fix that and
  break two other things: it needs a C toolchain at build time, and it can never
  make an Apple arm64 variadic call because CFFI only ever calls `ffi_prep_cif`,
  never `ffi_prep_cif_var`. CFFI is still used for everything whose signature is
  known at compile time, which is most of the file count.

- **Floating point traps must be masked around every send and every callback.**
  SBCL runs with `:invalid` and `:divide-by-zero` unmasked; CoreGraphics violates
  both. The first `NSWindow` creation dies with SIGFPE without
  `with-fp-traps-masked`. This is very likely why earlier attempts at an SBCL
  Objective-C bridge reported that everything worked except that the window never
  appeared. Mask per entry point, never globally — masking globally would change
  Lisp's own arithmetic so `(/ 1d0 0d0)` returned infinity instead of signalling.

- **`sb-alien:void`, not the keyword `:void`.** The keyword compiles fine and
  fails at the call site with `COMPILED-PROGRAM-ERROR`, so every void-returning
  method — `-release` among them — breaks at once and the error names nothing
  useful.

- **`(boolean 8)` does its conversion on the caller's side.** An alien callable
  declared to return one wants a `1` or a `0`; returning `T` is a type error
  against `(unsigned-byte 8)`.

- **A callable's struct parameter is not addressable.** `(addr p)` is rejected
  with "P is not a valid L-value". Copy it into a `with-alien` local first; the
  address of that is fine.

- **`'l'` and `'L'` are 32 bits even on LP64.** `NSInteger` encodes as `'q'`.
  Reading `'l'` as a C long silently truncates. Confirmed against
  `NSGetSizeAndAlignment`, which is also how every entry in
  `*struct-layout-overrides*` is checked — Foundation ships a parser for the very
  notation the table is written in, which is a better oracle than groveling and
  needs no C toolchain.

- **Strip the decimal frame offsets from a type encoding.** `"Q16@0:8"` is three
  types, not a type named `Q16`. They are a 32-bit-era artefact.

- **`@?` is a block and must be tested before a bare `@`**, and `@"NSString"`
  carries a quoted class name that has to be consumed or the parse desynchronises
  and every following argument is wrong.

- **Resolve the Method before sending.** This is not an optimisation: reading the
  encoding is how the call signature is discovered, and it means an unimplemented
  selector fails in Lisp instead of raising an NSException. There is no
  `@try/@catch` here and none in LispWorks either — verified by reverse
  engineering its image, which imports no `__cxa_begin_catch`, no
  `objc_exception_*` and no `NSSetUncaughtExceptionHandler`. An NSException that
  does escape aborts the process.

- **A Lisp condition must never escape an IMP.** There is no handler on the
  Objective-C side, so an unwind past the callback frame aborts. Every IMP body
  is wrapped in `handler-case`. LispWorks does the same and calls it a catch-all
  frame.

- **`make-instance` has to adopt the object `+allocWithZone:` already made.**
  `+alloc` runs our own `+allocWithZone:`, which creates and registers a Lisp
  instance. Without the adoption step one foreign object ends up with two Lisp
  objects and `objc-object-from-pointer` returns the one with unset slots — which
  looks like a slot bug and is not.

- **`-init` may return a different object than `+alloc` did.** Class clusters do
  it routinely. Register on the final pointer or every later lookup finds nothing.

- **Every IMP is retained forever in `*imp-registry*`.** SBCL recycles a
  callback's trampoline once the callable becomes garbage, and Cocoa will still
  be holding the address. Redefining a method leaks a few hundred bytes and that
  is the right trade against crashing mid-session.

- **A block's closure must be keyed on an id inside the literal, never on the
  block's address.** `_Block_copy` — which is what every asynchronous API does to
  a block it keeps — returns a *different* address, and the copy would then find
  nothing. The id is inside the struct, so the copy carries it. Measured: an
  original and its copy reached the same closure from two different addresses.
  Ids are never reused, not even across an image restore, so reaching a retired
  entry is a reported miss rather than a call into whatever closure was
  allocated that id next.

- **The copy and dispose helpers count allocations, not retains.** `_Block_copy`
  on a block already on the heap bumps libclosure's own refcount and returns the
  *same pointer* without calling the copy helper, and the matching releases run
  that count back down before one dispose call arrives. So the two schemes nest:
  one dispose per copy-helper call. Counting every `_Block_copy` instead would
  leak every escaped closure, silently and forever, and nothing would notice.
  Measured and asserted, because it is not what the flag name suggests.

- **`BLOCK_HAS_COPY_DISPOSE` moves where the signature lives.** `_Block_signature`
  walks past `Block_descriptor_1`, then past `Block_descriptor_2` *if and only if*
  that flag is set. Setting the flag without widening the descriptor reads two
  fields past the allocation; widening it without the flag puts the signature
  sixteen bytes from where libclosure looks. The descriptor is allocated in full
  and zeroed either way, and a test asserts the offsets against a real
  `_Block_signature` call — which is the only check that proves flags and layout
  agree.

- **A structure result may only leave `unmarshal-result` as a value copied OUT
  of the buffer.** The buffer is `%invoke`'s own `with-foreign-object` and is
  gone the moment the call returns, so returning a pointer into it is a
  use-after-free that reads as plausible numbers — a struct holding `(7 8)` came
  back as `(4191 2)`. Only the four Cocoa structures have a Lisp representation
  to return instead; anything else now signals `unrepresentable-struct-result`
  and names `invoke-into`. This survived because the manual's own struct example,
  and therefore the test ported from it, uses `invoke-into` with a caller-owned
  destination — the plain-`invoke` path had no coverage at all. The same
  reasoning is why `call-objc-block` refuses the same case.

- **Only one libdispatch worker thread may be inside Lisp at a time**, and the
  reason is worth knowing exactly, because the obvious workarounds all fail for
  it. `stop-the-world.c` suspends every other thread with
  `pthread_kill(th->os_thread, SIG_STOP_FOR_GC)` and calls `lose()` if that
  fails; `attach_os_thread` has stored the workqueue thread's real `pthread_t`.
  **Darwin refuses to signal a libdispatch workqueue thread at all** — measured:
  `pthread_kill` returns `ENOTSUP` (45) on one even for signal 0, while the main
  thread and an ordinary SBCL thread return 0. One block gets away with it only
  because `for_each_thread` skips `me`, and the single worker in Lisp is the one
  that triggered the collection. Two, and the second must be signalled: `cannot
  suspend thread ...: 45, Operation not supported`, the process, no condition and
  no Lisp backtrace.

  So a mutex serialising Lisp entry does **not** help: a worker parked on a Lisp
  lock has already been adopted and still has to be signalled.

  **`--with-sb-safepoint` fixes it, verified.** Safepoint stops the world by
  polling rather than signalling, so the unsignallable thread stops mattering —
  and on such a build the worker is *still* `ENOTSUP`, which is the proof that
  the mechanism rather than the platform changed. Built from `~/Projects/sbcl`
  (`./make.sh --with-sb-safepoint --prefix=$HOME/.local`): the eight-way barrier,
  `dispatch_apply` and `parallel-map` all pass five runs out of five, and the
  whole suite is green including the dump test. `make-config.sh` forces safepoint
  on win32 only, but `arm64-arch.c` carries the code and the macOS build failure
  was fixed upstream in 2020.

  Safe on a stock build, also measured: `dispatch_sync`; any number of blocks on
  a **serial** queue; and SBCL's own threads running while one queue thread is in
  a callback. So `examples/gcd.lisp` defaults `group-async` to a serial queue,
  and gates `parallel-map` and `dispatch-apply` on
  `concurrent-blocks-supported-p` — they signal and name the build rather than
  killing the process.

  One trap when building SBCL here: `~/.config/common-lisp/source-registry.conf`
  puts a `:tree` over `~/Projects/common-lisp/`, which sweeps in an old vendored
  ASDF under `mezzano/MBuild`. The contrib build calls `upgrade-asdf`, finds it,
  fails to compile it, and the build dies at `sb-manual` with the core already
  fine. Build the contribs with
  `CL_SOURCE_REGISTRY="(:source-registry :ignore-inherited-configuration)"`.

- **`*block-machinery*` is the GC root for every block invoke callable**, exactly
  as `*imp-registry*` is for IMPs, and for the same reason. It is also the
  per-signature memo, so clearing it to "free some memory" looks harmless twice
  over and is a delayed crash. There is deliberately no public function that
  does, and the only caller is the image-restore thunk, where the callables are
  already dangling.

- **All ivars must be added before `objc_registerClassPair`.** The runtime
  silently refuses afterwards, so changing `:objc-instance-vars` needs a fresh
  image — same shape as needing to clear the fasl cache after changing a struct.

- **Recompiling a file re-runs `define-objc-class`, and
  `objc_allocateClassPair` returns NULL for a name that already exists.** Look
  the class up first and reuse it.

- **Register the image hooks with SBCL as well as UIOP.** UIOP's dump and restore
  hooks fire only from `uiop:dump-image`; a plain `sb-ext:save-lisp-and-die` —
  which is what ASDF's `program-op` ends up doing — bypasses them entirely.
  Nothing about a Lisp-defined Objective-C class survives a dump, so without the
  SBCL hooks a dumped executable died with a memory fault on its first message
  send, holding a class pointer from the previous process. `test/dump-tests.lisp`
  exists because of that bug.

- **Running the CoreFoundation run loop is not enough to make a window
  respond.** `CFRunLoopRunInMode` services the sources that put events into
  `NSApplication`'s queue, but nothing takes them out: AppKit dispatches events
  only from `-run`, or from an explicit
  `-nextEventMatchingMask:untilDate:inMode:dequeue:` plus `-sendEvent:`. With
  only the run loop running, a window appears and draws and then every click
  queues up undelivered until the window server decides the process has stopped
  responding and shows the spinning wait cursor. `pump-events` dequeues and
  sends, and calls `-finishLaunching` once, which `-run` would otherwise have
  done.

- **Bound the event drain.** Waiting for the queue to empty cannot terminate
  while a window is on screen: dispatching an event routinely makes AppKit
  enqueue more — a window update, a display, a cursor change. The first version
  of `pump-events` drained "until empty" and hung on the first click, which
  looked exactly like the bug it was written to fix.
  `+max-events-per-pass+` is what makes the loop finish.

- **Do not pump AppKit by hand for anything long-running.** A
  `nextEventMatchingMask:` / `sendEvent:` loop never gets to block: AppKit keeps
  a supply of `NSEventTypeAppKitDefined` events coming, so the loop hits its
  per-pass cap every pass and spins re-dispatching them. Measured: 100.9% CPU
  and 9280 events in three idle seconds. The window stays usable — text goes in,
  fields tab — but the machine works flat out for it, which reads as
  sluggishness rather than a freeze and took three wrong diagnoses to pin down.
  `-[NSApplication runModalForWindow:]` is AppKit's real loop and idles at 0.4%.
  `pump-events` remains right for servicing pending events briefly; anything
  that waits for a user belongs in a modal loop.

- **`NSWindow`'s `-releasedWhenClosed` defaults to YES.** Clicking the close
  button on a window built with `-initWithContentRect:...` *deallocates* it, so
  anything still holding the pointer — restoring a delegate, checking
  `-isVisible`, the variable you kept in the REPL — is messaging freed memory.
  That hangs or corrupts rather than erroring, and it is timing dependent, so it
  shows up as "it worked, and then the close button hung". `make-window` turns
  the flag off so Lisp owns the window, and `run-until-closed` retains it across
  the loop for windows that arrived from somewhere else.

- **Showing a window steals the keyboard, and closing it does not give it
  back.** `setActivationPolicy: NSApplicationActivationPolicyRegular` plus
  `activateIgnoringOtherApps:` makes this process the frontmost macOS
  application; when the window closes, the process is *still* frontmost, with no
  windows. The REPL is then at its prompt while the window server delivers every
  keystroke here, so the terminal looks frozen and is not. This was reported as
  a hang and cost four wrong diagnoses — a spinning event loop, a use-after-free
  on the window, an unresponsive close button, an uninterruptible pump — none of
  which were it. No automated test can catch this, because no test types;
  `[[NSWorkspace sharedWorkspace] frontmostApplication]` is what finally showed
  it. `objc.runloop:remember-frontmost` records who had the keyboard before the
  first activation, and `restore-frontmost` hands it back.

- **Do not send `-stopModal` synchronously from `-windowWillClose:`.** A real
  click on the close widget runs inside that button's mouse-tracking loop,
  nested inside the modal loop, and `-windowWillClose:` fires down there.
  Stopping the session on the spot returns control to the caller while AppKit is
  still unwinding the tracking loop and finishing the close — leaving the window
  drawn but dead on screen with nothing pumping events. Sending `-performClose:`
  programmatically skips the tracking loop entirely, which is why no test caught
  it. Defer with `-performSelector:withObject:afterDelay:inModes:`, **and note
  the modes**: a modal session runs in `NSModalPanelRunLoopMode`, so the plain
  `afterDelay:` variant queues the selector for a mode that is not running and
  it never fires at all — an outright hang rather than a late one.

- **A large structure result needs `objc_msgSend_stret` on x86-64 and must not
  use it on arm64.** Over 16 bytes, the x86-64 SysV ABI returns through a hidden
  pointer, and plain `objc_msgSend` cannot perform that call — the hidden result
  pointer displaces the receiver into the wrong register, so the receiver is read
  as garbage. arm64 has no such function at all; the same result comes back
  through `x8`. Which applies is decided by whether `objc_msgSend_stret`
  *resolves in libobjc*, which is measured at initialization rather than chosen
  by a read-time conditional — the symbol is genuinely absent on arm64. `CGRect`
  is 32 bytes, so `-[NSView frame]` is on the `_stret` side of the line.

- **A method body may open with declarations.** The manual's own
  area-calculator example starts `(declare (ignore sender))`, and they have to
  land inside the `let*` that binds the arguments.

- **Load a framework before defining a class that names its protocols.**
  `:objc-protocols` resolves names with `objc_getProtocol` at class definition
  time, and a protocol from a framework nobody has opened is simply not there.

- **A test that needs the runtime must call `ensure-objc-initialized`, not just
  open Foundation.** The defining macros are documented to work before
  initialization, so they queue their foreign work; a helper that only opened
  libobjc left every class defined at load time unrealized, and whether a test
  saw one depended on which suite happened to run first.

- **Bound WKWebView tests generously, and skip rather than fail.** It renders in
  a separate web content process, and how long that takes to spawn is not
  something this library controls. A tight bound made the suite fail about one
  run in six on a loaded machine, which is worse than useless: a suite that
  cries wolf gets ignored the one time it is right.

- **A subprocess spawned by a test does not inherit the source registry.** The
  dump test runs a bare `sbcl`, and on a developer machine `~/.sbclrc` sets up
  ocicl so it finds the system anyway. CI has no such file: the child could not
  find `:objc`, exited 1, and the test failed there and only there. It now
  writes an explicit `initialize-source-registry` into the child program. Run it
  with `--no-userinit --no-sysinit` to check this kind of thing locally.

- **One helper knows how to stop a modal loop, and everything goes through it.**
  `stop-modal-soon` defers `-stopModal` and names `NSModalPanelRunLoopMode`. A
  sweep for the pattern found the same bug in three more places after the first
  fix — including, pointedly, in `diagnose-close`, the diagnostic written to
  investigate the hang, which still contained the hang. If a rule is subtle
  enough to get wrong once, grep for it.

## Conventions specific to this codebase

- **`OBJC` exports the 42 symbols the LispWorks manual documents plus the 8
  block symbols, and `COCOA` exactly 11.** A test asserts **the exact sets**, in
  two named lists, rather than a count: a count lets the next accidental export
  through as soon as someone adjusts the number to match. Anything else is an
  implementation detail, however useful — adding to the list turns a detail into
  a compatibility promise nothing else keeps. SBCL-only additions such as
  `pump-events` live in `OBJC.RUNLOOP` for exactly that reason; blocks are in
  `OBJC` because a block is Objective-C's own notion and belongs beside `invoke`,
  and that widening was a decision, written down in both places.

- **No exported condition types.** LispWorks documents none and has none; its
  failures are plain `cl:error` calls. The internal hierarchy exists for
  debugging and subclasses `error`, so `handler-case` on `error` behaves the same
  either way. `no-such-method`'s report is worded exactly as LispWorks words it,
  down to printing pointers as `#<Pointer: OBJC:OBJC-OBJECT-POINTER = #x...>`.

- **`test/oracle/answers.lisp` is ground truth, gathered by hand.** LispWorks
  Personal 8.1 cannot be scripted — `-eval` is ignored and the heap says
  "Initialization files are not available in the Personal Edition of LispWorks" —
  so `test/oracle/probe.lisp` is pasted into the IDE Listener and its output
  recorded. That is what lets the differential tests run in CI with no LispWorks
  installed. Regenerating is deliberate and rare; `make oracle` prints how.

- **Architecture differences are measured, not conditionalised.** There are no
  `#+arm64` read-time conditionals. `BOOL`'s encoding is read from
  `-[NSObject isProxy]` at initialization, because it is a signed char on Intel
  and C99 `_Bool` on Apple silicon.

- **The manual is stale about `ns-point`, `ns-size` and `ns-range`.** Its
  reference pages claim `:float` and `(:unsigned :int)` slots. LispWorks itself
  does not agree: measured there, they are 16, 16, 32 and 16 bytes. We follow the
  implementation and say so in the README.

- **`invoke` returns 1 or 0 for a BOOL**, on every architecture, and only
  `invoke-bool` returns `T` and `NIL`. This was checked against LispWorks
  precisely because the opposite was the natural guess on Apple silicon.

## Tests

Suites: `encoding` and `types` are pure and run anywhere; `runtime`, `invoke`,
`memory`, `cocoa`, `classes`, `methods`, `manual` and `oracle` need a live
Objective-C runtime; `gui` needs a window server and skips without one; `seam`
greps the sources; `dump` spawns a subprocess.

`examples/manual.lisp` is a near-verbatim port of the file LispWorks ships at
`Library/lib/8-1-0-0/examples/objc/manual.lisp` — every `objc:` form in it is
unchanged from the original — and `test/manual-tests.lisp` asserts each one. It
is the closest thing here to a direct answer to "does LispWorks source run".
