# A live-coding demo: a native macOS window, sculpted from a REPL

A four-minute screen recording. The claim it makes is narrow and true: an
Objective-C bridge lets a running Lisp reshape a real AppKit view without a
rebuild, a restart, or an editor plugin — and the thing on screen is a genuine
`NSView`, not a canvas library pretending to be one.

Everything below has been run end to end. The timings are measured on an M-series
Mac, not estimated.

## What you need

- A **plain `sbcl` REPL in a terminal.** Not SLY, not SLIME, not a `--script`.
- A window server — an ordinary logged-in desktop session.
- Metal, for the second half. Any Mac made in the last decade.

### Why a plain terminal REPL, and not Emacs

This is the one thing that will ruin a take, so get it out of the way first.

**AppKit must run on thread 1.** In a plain `sbcl` the REPL *is* thread 1, so
`(test-canvas)` works. Under SLY or SLIME the REPL evaluates on a worker thread,
thread 1 is busy elsewhere, and the AppKit entry points refuse — deliberately,
with `not-main-thread`, rather than corrupting something. `objc.runloop`'s
`check-main-thread` is what stops you.

So the demo is a terminal and a window, side by side. That is not a consolation
prize: no editor integration is on screen, which makes it obvious that nothing
up the sleeve is doing the work.

## Staging

Terminal on the left, roughly half the screen. The Cocoa window opens at
`#(200 200 480 480)` — screen coordinates, bottom-left origin — so put the
terminal on the left and leave the right side clear. Use a large terminal font;
the audience needs to read the forms as you type them.

## The script

### Act 1 — from nothing to a window (about 40 seconds)

```lisp
(asdf:load-system :objc/examples)
```

Measured at **1.4 seconds** with fasls present. Do a throwaway run before
recording so you are not filming a compile.

```lisp
(in-package :objc/examples)
(test-canvas)
```

A window appears, and **the REPL prompt comes straight back.** Say that part out
loud — it is the whole premise. `run-canvas` is the version that blocks; this one
hands the window to AppKit and returns, so the listener stays yours.

> "That's an `NSView` subclass defined in Lisp. Its `-drawRect:` calls a Lisp
> function. The window is up and I still have a REPL."

### Act 2 — the live loop (about 80 seconds)

This is the demo. Everything else is setup or dessert.

```lisp
(defun draw-default (width height)
  (set-color 0.1 0.1 0.15)
  (fill-rect 0 0 width height)
  (set-color 1 0.6 0.2)
  (fill-oval 90 90 300 300))

(refresh)
```

The window repaints into the new definition. Then change it again, in front of
them — a colour, a shape, a loop:

```lisp
(defun draw-default (width height)
  (set-color 0.05 0.05 0.1)
  (fill-rect 0 0 width height)
  (dotimes (i 12)
    (set-color (/ i 12.0) 0.5 (- 1 (/ i 12.0)))
    (stroke-oval (- 240 (* i 18)) (- 240 (* i 18))
                 (* i 36) (* i 36) 2)))

(refresh)
```

Twelve nested rings. Verified: `-drawRect:` runs the *current* definition on
each `refresh`, so a redefinition between two calls takes effect on the second.

Two things to say while it repaints:

> "No rebuild. The window never closed. `-drawRect:` is being handed a dirty
> rectangle as a C struct **by value** — that is the hard part of a bridge like
> this, and it happens on every one of those shapes."

> "And if I get it wrong—"

Then get it wrong on purpose. Misspell a function inside `draw-default`, call
`(refresh)`, and let the drawing error land in the view:

```lisp
(defun draw-default (width height)
  (declare (ignore width height))
  (set-color 0 0 0)
  (fill-rect 0 0 100 100)
  (this-function-does-not-exist))

(refresh)
```

The window goes red and the REPL prints

```
[canvas] draw error: The function OBJC/EXAMPLES::THIS-FUNCTION-DOES-NOT-EXIST is undefined.
```

`draw-error` paints the condition into the window rather than taking down
AppKit. Fix it, `(refresh)`, and you are back. That recovery is worth more to a
sceptical audience than any picture: **a Lisp condition inside an AppKit
callback did not end the process.**

### Act 3 — one expression per pixel (about 90 seconds)

Hand the same view over to Metal:

```lisp
(ensure-shader)
(setf *canvas-draw* 'draw-shader)
(setf *shader* "float3(uv, 0.5)")
(refresh)
```

A corner-to-corner gradient. Now edit the expression — this is a Metal Shading
Language fragment, compiled at run time from a Lisp string:

```lisp
(setf *shader* "float3(fract(uv * 8.0), abs(sin(time)))")
(refresh)

(setf *shader* "float3(0.5 + 0.5 * sin(40.0 * distance(uv, float2(0.5)) - time * 3.0))")
(refresh)
```

Measured: **0.21 seconds** per refresh including a fresh kernel compile, and
7 ms once a shader is cached on its source. Say the number:

> "The GPU program is a string another function wrote. Changing it recompiles
> once — about a fifth of a second — and then costs nothing."

Finish with the animation, which is the shape people expect and the only
blocking call in the demo:

```lisp
(run-shader (cdr (assoc "plasma" +sample-shaders+ :test #'string=)) :seconds 8)
```

Eight seconds of plasma, then the REPL returns.

### Act 4 — the point, in one form (about 30 seconds)

Close on what was actually happening, because it is more interesting than the
pictures:

```lisp
(describe-objc-class "LispCanvasView")
```

The class browser prints the methods *you* defined, read back out of the
Objective-C runtime:

```
LispCanvasView : NSView : NSResponder : NSObject
4 instance methods
  copyWithZone:
      (POINTER VOID) -> OBJC-OBJECT-POINTER
  dealloc
      (no arguments) -> VOID
  drawRect:
      (STRUCT NS-RECT) -> VOID
  isFlipped
      (no arguments) -> OBJC-C++-BOOL
```

Three things in that output are worth a sentence each, and they are the best
thirty seconds in the demo:

- **Four methods, and you wrote two.** `-copyWithZone:` and `-dealloc` are
  installed on every Lisp-defined class by the library, which is what makes a
  Lisp object safe to put in an `NSDictionary` — see `examples/collections.lisp`.
- **`(STRUCT NS-RECT) -> VOID`** is read out of the runtime, not out of your
  source. `-drawRect:` really is taking a C struct by value on every repaint you
  just watched.
- **`OBJC-C++-BOOL`**, not `OBJC-BOOL`. That is `B` in the encoding, which is how
  `BOOL` spells itself on Apple silicon; on Intel the same method reads back as
  `c`. Nobody wrote that type anywhere — the runtime handed it over.

> "That's not a wrapper object. Objective-C has a real class here, with real
> method implementations, and they are Lisp functions. The runtime cannot tell
> the difference, which is why AppKit will call them."

## Recording notes

- **Type, don't paste.** The forms are short on purpose. Pasting reads as a
  canned script; typing `(refresh)` and having the window change reads as live.
- **Keep the window visible the whole time.** Never let the terminal cover it —
  the cut where the window changes is the entire product.
- **One take per act.** Editing between acts is fine; editing inside the live
  loop undercuts it.
- Skip the mouse. Nothing here is clicked.

## Measured, so you can check the machine before filming

| Step | Time |
|---|---|
| `(asdf:load-system :objc/examples)`, fasls present | 1.4 s |
| `(test-canvas)` to a window on screen | immediate |
| `(refresh)` after a redefinition | under 0.2 s |
| First shader frame | 37 ms |
| Shader refresh, cached on its source | 7 ms |
| Shader refresh, new expression (Metal compiles) | 0.21 s |

## Failure modes, and what they mean

- **`not-main-thread`** — you are in SLY or SLIME. Use a plain terminal `sbcl`.
- **The window opens behind the terminal** — `remember-frontmost` and
  `restore-frontmost` in `objc.runloop` are deliberate about focus. Move the
  terminal before you start rather than clicking during the take.
- **`No Metal device, so nothing to draw with`** — Act 3 needs a GPU the process
  can see. Acts 1, 2 and 4 do not; they are Foundation and AppKit only.
- **The drawing does not change after `(refresh)`** — you redefined a function
  the view is not calling. `*canvas-draw*` names the current one, and Act 3 sets
  it to `draw-shader`; `(setf *canvas-draw* 'draw-default)` puts it back.
