;;;; examples/movie-view.lisp
;;;;
;;;; Ported from LispWorks' examples/objc/movie-view.lisp.  AVKit is current, so
;;;; MOVIE-VIEW-TEST-SET-MOVIE is unchanged from the original: the
;;;; fileURLWithPath: -> AVPlayer initWithURL: -> setPlayer: -> play chain is
;;;; exactly as LispWorks writes it.  Only the CAPI pane became an NSWindow with
;;;; an AVPlayerView in it.

(in-package #:objc/examples)

(defun movie-view-test-set-movie (movie-view path)
  "Load PATH into MOVIE-VIEW and start playing.  Unchanged from the original."
  (let* ((url (objc:invoke "NSURL"
                           "fileURLWithPath:"
                           (namestring path)))
         (player (objc:invoke (objc:invoke "AVPlayer" "alloc")
                              "initWithURL:"
                              url)))
    (objc:invoke movie-view "setPlayer:" player)
    (objc:invoke player "play")
    player))

(defun make-movie-view (rect)
  (objc::register-module "/System/Library/Frameworks/AVKit.framework/AVKit"
                         :errorp nil)
  (objc::register-module "/System/Library/Frameworks/AVFoundation.framework/AVFoundation"
                         :errorp nil)
  (make-view "AVPlayerView" rect))

(defun test-movie-view (&optional path)
  "Show a movie view, playing PATH if given."
  (let* ((window (make-window :title "Movie View" :rect #(240 240 640 400)))
         (view (make-movie-view #(0 0 640 400))))
    (add-subview window view)
    (when path
      (movie-view-test-set-movie view path))
    (show-window window)
    (values window view)))
