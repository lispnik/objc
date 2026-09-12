# Lisp Notes

A document-based Mac application with every class in Lisp: an `NSDocument`
subclass, an `NSDocumentController` subclass, an application delegate, and
a menu built without a nib. Packaged as a signed `.app` by
[asdf-macos-app](https://github.com/lispnik/asdf-macos-app).

```lisp
(asdf:make "notes-app")      ; => examples/notes-app/build/Lisp Notes.app
```

with `objc` and `asdf-macos-app` on the source registry. Set
`MACOS_SIGNING_IDENTITY` to a Developer ID certificate name to sign for
distribution; unset, the bundle is signed ad hoc and runs on this machine.
`macos-app:notarize` takes it the rest of the way.

## What is inherited

The document architecture supplies, for a class that answers four messages:
New and Open, Save and Save As with the standard panels, the dirty dot in the
close button, Autosave and Versions, Revert, the window title and its proxy
icon, and Undo shared between the text view and the document. None of it is
in `notes.lisp`.

## What is written

- `readFromData:ofType:error:` and `dataOfType:error:`, the document's
  contents in and out as UTF-8.
- `makeWindowControllers`, a window with a scrolling `NSTextView`, handed to
  an `NSWindowController`. Undo is turned on in the text view and nothing
  else: the window controller supplies the document's undo manager, which is
  what makes the document dirty and Undo reach it.
- `autosavesInPlace`, a class method returning YES, which is what turns on
  Versions and the modern close behaviour.
- A document controller that answers `defaultType`,
  `documentClassForType:` and `typeForContentsOfURL:error:` itself, so the
  same code runs from a REPL with no Info.plist to consult.
- The menu, since a program with no nib has no menu bar. Every item's target
  is nil and the responder chain finds whoever answers.

## Two things learned writing it

AppKit makes the documents, not Lisp, so the Lisp object for one appears
when the bridge first sees the pointer, with its slots unbound rather than
initialised. Each method starts by giving unbound slots their defaults.

`NOTES_SNAPSHOT=path` writes the front window as a PNG two seconds after
launch and quits, and `NOTES_OPEN=file` opens that file first: how the app
was verified from a shell, both from SBCL and as the built bundle.
