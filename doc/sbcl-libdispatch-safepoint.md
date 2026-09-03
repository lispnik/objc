# SBCL on macOS: a GC during concurrent libdispatch callbacks kills the process

*Written up for upstream (sbcl-devel or the bug tracker). Kept in this repository
because it is also the evidence behind the concurrency limit the README and
`examples/gcd.lisp` describe, and because a report is easier to check than to
re-derive.*

## Summary

On macOS, if a garbage collection happens while **two or more libdispatch worker
threads are inside Lisp**, SBCL dies:

```
fatal error encountered in SBCL pid 67919 pthread 0x1f68d2180:
cannot suspend thread 0x16bec7000: 45, Operation not supported
```

The process, immediately — no condition, no Lisp backtrace, nothing a handler
can see. **One** callback at a time is fine, which is why this is easy to miss:
it appears only under real concurrency.

Building with `--with-sb-safepoint` fixes it completely.

The request is not that the signalling GC be made to work — it cannot be, see
below — but that this be **documented**: any macOS program that uses GCD,
`NSURLSession` completion handlers, `NSOperationQueue`, or anything else that
calls back on libdispatch's pool needs a safepoint build, and there is currently
nothing that says so.

## Environment

- macOS 26.6.2 (25G83), arm64 (Apple silicon)
- SBCL 2.6.7 (Homebrew) — reproduces every run
- SBCL 2.6.8 built `--with-sb-safepoint` from the same tree — survives every run

## Reproducer

No libraries and no Objective-C. `dispatch_apply_f` takes a plain C function
pointer, which is what `define-alien-callable` produces, so this is a
self-contained script. Save and run with `sbcl --script`.

```lisp
(in-package :cl-user)

(defvar *iterations* 64)
(defvar *threads* (make-hash-table :test 'eq :synchronized t))
(defvar *concurrent* (make-array 1 :element-type 'fixnum :initial-element 0))
(defvar *peak* (make-array 1 :element-type 'fixnum :initial-element 0))
(defvar *lock* (sb-thread:make-mutex))

(sb-alien:define-alien-callable work sb-alien:void
    ((context (sb-alien:* t)) (index sb-alien:unsigned-long))
  (declare (ignore context index))
  (sb-thread:with-mutex (*lock*)
    (setf (gethash sb-thread:*current-thread* *threads*) t)
    (incf (aref *concurrent* 0))
    (when (> (aref *concurrent* 0) (aref *peak* 0))
      (setf (aref *peak* 0) (aref *concurrent* 0))))
  ;; Allocate a lot, outside the lock, so several threads are in Lisp at once.
  (let ((acc '()))
    (dotimes (i 200000) (push (list i) acc))
    (length acc))
  (sb-thread:with-mutex (*lock*) (decf (aref *concurrent* 0))))

(defun global-queue ()
  (sb-alien:alien-funcall
   (sb-alien:extern-alien "dispatch_get_global_queue"
                          (function sb-alien:system-area-pointer
                                    sb-alien:long sb-alien:unsigned-long))
   0 0))

(format t "~&SBCL ~A, safepoint: ~A~%" (lisp-implementation-version)
        (and (member :sb-safepoint *features*) t))
(finish-output)

(sb-alien:alien-funcall
 (sb-alien:extern-alien "dispatch_apply_f"
                        (function sb-alien:void
                                  sb-alien:unsigned-long
                                  sb-alien:system-area-pointer
                                  sb-alien:system-area-pointer
                                  sb-alien:system-area-pointer))
 *iterations* (global-queue) (sb-sys:int-sap 0)
 (sb-alien:alien-sap (sb-alien:alien-callable-function 'work)))

(format t "SURVIVED: ~D distinct threads ran the work, peak ~D inside Lisp at once~%"
        (hash-table-count *threads*) (aref *peak* 0))
(finish-output)
```

Results, three runs each:

| build | outcome |
|---|---|
| SBCL 2.6.7, stock | `cannot suspend thread ...: 45, Operation not supported`, 3/3 |
| SBCL 2.6.8, `--with-sb-safepoint` | `SURVIVED: 56 distinct threads ran the work, peak 8 inside Lisp at once`, 3/3 |

**The amount of work per iteration matters.** An earlier version of this script
allocated 20,000 conses per iteration and did *not* reproduce — libdispatch ran
the iterations without ever having two in Lisp simultaneously. At 200,000 the
peak concurrency is 8 and it dies every time. Anyone checking this should print
the peak, as above, rather than concluding from a light workload that it is
fixed.

## Cause

`stop_the_world` in `src/runtime/stop-the-world.c` suspends every other thread
with

```c
rc = pthread_kill(th->os_thread, SIG_STOP_FOR_GC);
if (rc) lose("cannot suspend thread %p: %d, %s", ...);
```

and `attach_os_thread` (`src/runtime/thread.c`) has stored the foreign thread's
real `pthread_t` via `ASSOCIATE_OS_THREAD`.

**Darwin refuses to signal a libdispatch worker thread.** Measured directly with
signal 0, the standard "is this thread signallable" probe:

| thread | `pthread_kill(th, 0)` |
|---|---|
| main thread | 0 |
| `sb-thread:make-thread` thread | 0 |
| libdispatch worker, alive and inside a callback | **45 (`ENOTSUP`)** |

So it is not a transient state, a race, or bookkeeping: these threads are never
signallable.

**Why one callback survives.** `for_each_thread` skips `me`. With a single
worker in Lisp, that worker is the one that triggered the collection, so it is
never signalled and the only other threads are ordinary ones. With two, the
second must be signalled, and cannot be. That is the whole of the one-versus-two
boundary.

**A mutex does not help.** Serialising entry into Lisp behind a lock leaves the
second worker parked *inside* a Lisp function — already adopted, still in the
thread list, still requiring a signal. Taking the lock before adoption would
need a C shim ahead of the callable.

## Why `--with-sb-safepoint` fixes it

Safepoint builds stop the world by polling rather than by signalling, so an
unsignallable thread stops being a problem.

The detail that confirms the mechanism: **on the safepoint build the worker
thread is still `ENOTSUP`.** Nothing about the platform changed. Safepoint does
not make signalling work; it removes the need for it.

Support already exists — `make-config.sh` forces `:sb-safepoint` on win32,
`src/runtime/arm64-arch.c` carries the safepoint code, and the macOS
`--with-sb-safepoint` build failure (`SIGRTMIN` undefined, launchpad #1382811)
was fixed in 2020. It simply is not enabled, or mentioned, on macOS.

One build note, for whoever tries it: an SBCL contrib build calls
`upgrade-asdf`, so a source registry containing any ASDF or UIOP *source* will
fail the build at `sb-manual` with the core already built and working. Build
with `CL_SOURCE_REGISTRY="(:source-registry :ignore-inherited-configuration)"`
if that applies.

## What would help

In rough order of value:

1. **A note in the manual** — under threading or foreign callbacks — saying that
   on macOS, callbacks arriving on libdispatch worker threads require a
   safepoint build, and why. This is the whole of the ask; everything else is
   optional.
2. **A clearer death.** `lose()` here prints the `pthread_kill` errno, which is
   accurate but gives no hint that the thread is a workqueue thread or that
   safepoint is the fix. A sentence in the message would save the next person
   the afternoon this took.
3. Enabling `:sb-safepoint` by default on darwin, if it is considered solid
   enough — a much larger question, and not one this report has evidence for
   beyond a single library's suite passing on it.

## Provenance

Found while adding Objective-C block creation to
<https://github.com/lispnik/objc>, a reimplementation of the LispWorks
Objective-C interface for SBCL. Its GCD example
(`examples/gcd.lisp`) documents the limit, defaults asynchronous work to a
serial queue because of it, and gates its `parallel-map` on
`(member :sb-safepoint *features*)` so a stock build gets an error rather than a
dead process. Its full suite passes on both builds.
