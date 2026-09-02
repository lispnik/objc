;;;; examples/web-kit.lisp
;;;;
;;;; Ported from LispWorks' examples/objc/web-kit.lisp -- with a substitution
;;;; that has to be called out.
;;;;
;;;; The original uses WebView, WebFrame and -setFrameLoadDelegate:.  That whole
;;;; legacy WebKit API has been REMOVED from macOS; it is not merely deprecated.
;;;; So this uses WKWebView and WKNavigationDelegate instead.
;;;;
;;;; What is preserved is the thing the example is actually about: a Lisp class
;;;; acting as a Cocoa delegate, receiving callbacks from a framework that knows
;;;; nothing about Lisp, and reading an NSString argument through the STRING
;;;; argument style.  The delegate class below has the same shape as the
;;;; original's, method for method.

(in-package #:objc/examples)

;;; WebKit has to be loaded BEFORE the delegate class is created: the
;;; :OBJC-PROTOCOLS option resolves its names with objc_getProtocol at class
;;; definition time, and a protocol from a framework nobody has opened yet is
;;; simply not there.  The class would still be created and still work -- the
;;; runtime dispatches delegate callbacks by selector, not by conformance -- but
;;; -conformsToProtocol: would answer NO, and some AppKit code asks.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (objc::ensure-libobjc)
  (objc::register-module "/System/Library/Frameworks/WebKit.framework/WebKit"
                         :errorp nil))

(objc:define-objc-class web-kit-test-delegate ()
  ((title :initform nil :accessor web-kit-test-delegate-title)
   (address :initform nil :accessor web-kit-test-delegate-address)
   (finished :initform nil :accessor web-kit-test-delegate-finished-p)
   (web-view :initform nil :accessor web-kit-test-delegate-web-view))
  (:objc-class-name "WebKitTestDelegate")
  (:objc-protocols "WKNavigationDelegate"))

;;; The original's -webView:didReceiveTitle:forFrame:.  Same shape: the title
;;; arrives as an NSString and the STRING argument style converts it.
(objc:define-objc-method ("webView:didFinishNavigation:" :void)
    ((self web-kit-test-delegate)
     (sender objc:objc-object-pointer)
     (navigation objc:objc-object-pointer))
  (declare (ignore navigation))
  (setf (web-kit-test-delegate-title self)
        (objc:invoke-into 'string sender "title")
        (web-kit-test-delegate-finished-p self) t)
  ;; The document title is published shortly after the navigation finishes, so
  ;; the first read can legitimately be empty.  Re-reading on the next runloop
  ;; pass is what the original's -webView:didReceiveTitle:forFrame: got for
  ;; free; WKWebView has no such callback and publishes -title through KVO.
  (setf (web-kit-test-delegate-web-view self) sender))

;;; The original's -webView:didStartProvisionalLoadForFrame:.
(objc:define-objc-method ("webView:didStartProvisionalNavigation:" :void)
    ((self web-kit-test-delegate)
     (sender objc:objc-object-pointer)
     (navigation objc:objc-object-pointer))
  (declare (ignore navigation))
  (setf (web-kit-test-delegate-address self)
        (objc:invoke-into 'string (objc:invoke sender "URL") "absoluteString")))

(defun web-kit-test-go (web-view url-string)
  "Load URL-STRING.  The original's WEB-KIT-TEST-GO, one API generation on:
-[WKWebView loadRequest:] where the original used -[WebFrame loadRequest:]."
  (objc:invoke web-view
               "loadRequest:"
               (objc:invoke "NSURLRequest"
                            "requestWithURL:"
                            (objc:invoke "NSURL"
                                         "URLWithString:"
                                         url-string))))

(defun make-web-view (rect)
  (objc::register-module "/System/Library/Frameworks/WebKit.framework/WebKit"
                         :errorp nil)
  (make-view "WKWebView" rect))

(defun test-web-kit (&optional (url "https://www.lispworks.com/"))
  "Show a web view loading URL, with a Lisp delegate watching it.
Returns (VALUES WINDOW DELEGATE VIEW)."
  (let* ((window (make-window :title "Web Kit Test" :rect #(200d0 200d0 800d0 600d0)))
         (view (make-web-view #(0d0 0d0 800d0 600d0)))
         (delegate (make-instance 'web-kit-test-delegate)))
    (objc:invoke view "setNavigationDelegate:" (objc:objc-object-pointer delegate))
    (add-subview window view)
    (web-kit-test-go view url)
    (show-window window :seconds 2d0)
    (values window delegate view)))
