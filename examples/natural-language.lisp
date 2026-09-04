;;;; examples/natural-language.lisp -- on-device NLP, from the REPL.
;;;;
;;;; The NaturalLanguage framework does language identification, tokenisation,
;;;; part-of-speech tagging, named-entity recognition and word embeddings, all
;;;; on the machine, with no model to download and nothing to install.  It is
;;;; Foundation-level: no window server, no permissions, no network.  For a Lisp
;;;; that is a good bargain -- ask what the entities in a sentence are, and get
;;;; an answer at the REPL.
;;;;
;;;; It is also where this library's newest capability meets a real framework.
;;;; -enumerateTagsInRange:unit:scheme:options:usingBlock: hands the block an
;;;; NSRange BY VALUE, and so does the tokenizer; the embedding callback takes a
;;;; double the same way.  Structures passed by value into a Lisp closure were
;;;; the last gap in the block support, and until now only the test suite
;;;; exercised them.
;;;;
;;;; THE RUNTIME IS AUTHORITATIVE ABOUT SELECTORS, which this framework
;;;; demonstrates at some cost.  Apple's documentation and headers name
;;;; -distanceBetweenWord:andWord:distanceType:; the selector NLEmbedding
;;;; actually implements is -distanceBetweenString:andString:distanceType:, and
;;;; likewise -enumerateNeighborsForString:... rather than ...ForWord:.  Writing
;;;; the documented name gets a Lisp error naming the selector -- which is worth
;;;; something, since the alternative in C is a runtime exception that takes the
;;;; process out -- but the way to settle it is to ask.  CLASS-SELECTORS was
;;;; written here for that, and now lives in browser.lisp with the rest of the
;;;; introspection.

(in-package #:objc/examples)

(defparameter +natural-language-framework+
  "/System/Library/Frameworks/NaturalLanguage.framework/NaturalLanguage")

(defun ensure-natural-language ()
  (objc:ensure-objc-initialized :modules (list +natural-language-framework+)))

;;; Asking the runtime what a class can do is in browser.lisp -- CLASS-SELECTORS
;;; and DESCRIBE-OBJC-CLASS live there now.  They were written here first, for
;;; the reason below, and belong with the rest of the introspection.

;;; Constants ------------------------------------------------------------------
;;;
;;; Plain enumerations, so they are written out rather than read from the
;;; framework; the names are the documented ones.

(defconstant +unit-word+ 0)
(defconstant +unit-sentence+ 1)
(defconstant +unit-paragraph+ 2)
(defconstant +unit-document+ 3)

(defconstant +omit-words+ 1)
(defconstant +omit-punctuation+ 2)
(defconstant +omit-whitespace+ 4)
(defconstant +omit-other+ 8)
(defconstant +join-names+ 16)
(defconstant +join-contractions+ 32)

(defconstant +distance-cosine+ 0)

(defun unit-designator (unit)
  (ecase unit
    (:word +unit-word+) (:sentence +unit-sentence+)
    (:paragraph +unit-paragraph+) (:document +unit-document+)))

;;; Language identification ----------------------------------------------------

(defun language-of (text)
  "The BCP-47 code of the language TEXT is most likely written in, or NIL.

    (language-of \"Le renard brun rapide\")   ;; => \"fr\""
  (ensure-natural-language)
  (objc:with-autorelease-pool ()
    (let ((language (objc:invoke "NLLanguageRecognizer"
                                 "dominantLanguageForString:" text)))
      (unless (cffi:null-pointer-p (objc:objc-object-pointer language))
        (objc:ns-string-to-string language)))))

;;; Tokenising -----------------------------------------------------------------

(defun tokenize (text &key (unit :word))
  "Split TEXT into words, sentences or paragraphs, and return them as strings.

The block Foundation calls here takes its NSRange BY VALUE; the closure sees it
as (start . length), which is what COCOA:NS-RANGE converts to."
  (ensure-natural-language)
  (objc:with-autorelease-pool ()
    (let ((tokenizer (objc:invoke (objc:invoke "NLTokenizer" "alloc")
                                  "initWithUnit:" (unit-designator unit)))
          (tokens '()))
      (objc:invoke tokenizer "setString:" text)
      (objc:with-objc-block
          (block '(:void (cocoa:ns-range (:unsigned :long-long)
                          (:pointer objc:objc-bool)))
                 (lambda (range attributes stop)
                   (declare (ignore attributes stop))
                   (push (subseq text (car range) (+ (car range) (cdr range)))
                         tokens)))
        (objc:invoke tokenizer "enumerateTokensInRange:usingBlock:"
                     (cons 0 (length text)) block))
      (nreverse tokens))))

;;; Tagging --------------------------------------------------------------------

(defun tag-text (text scheme &key (unit :word) (options (logior +omit-punctuation+
                                                                +omit-whitespace+)))
  "Tag TEXT with SCHEME and return a list of (TAG . SUBSTRING).

SCHEME is an NLTagScheme name: \"NameType\", \"LexicalClass\", \"Lemma\".
Tokens the tagger has no opinion about are dropped -- but note that under
\"NameType\" it has an opinion about everything, tagging ordinary words
\"OtherWord\" rather than leaving them untagged.  ENTITIES below is what filters
those out."
  (ensure-natural-language)
  (objc:with-autorelease-pool ()
    (let* ((schemes (objc:invoke "NSArray" "arrayWithArray:" (vector scheme)))
           (tagger (objc:invoke (objc:invoke "NLTagger" "alloc")
                                "initWithTagSchemes:" schemes))
           (found '()))
      (objc:invoke tagger "setString:" text)
      (objc:with-objc-block
          (block '(:void (objc:objc-object-pointer cocoa:ns-range
                          (:pointer objc:objc-bool)))
                 (lambda (tag range stop)
                   (declare (ignore stop))
                   (unless (cffi:null-pointer-p (objc:objc-object-pointer tag))
                     (push (cons (objc:ns-string-to-string tag)
                                 (subseq text (car range) (+ (car range) (cdr range))))
                           found))))
        (objc:invoke tagger "enumerateTagsInRange:unit:scheme:options:usingBlock:"
                     (cons 0 (length text)) (unit-designator unit) scheme options block))
      (nreverse found))))

(defun entities (text)
  "The people, places and organisations named in TEXT, as (TAG . NAME).

    (entities \"Ada Lovelace and Charles Babbage worked together in London.\")
    => ((\"PersonalName\" . \"Ada Lovelace\") (\"PersonalName\" . \"Charles Babbage\")
        (\"PlaceName\" . \"London\"))

Two things this does beyond TAG-TEXT, both learned the hard way.  +JOIN-NAMES+
makes \"Ada Lovelace\" one entity rather than two, and without it the tagger
reports each word separately -- which looks like it works until a name has two
parts.  And the \"NameType\" scheme tags every other word \"OtherWord\" rather
than leaving it alone, so the name tags have to be selected for; the tagger
having an opinion about \"and\" is not the same as \"and\" being an entity.

How much the model gets right depends on how much context it has.  The same
sentence cut down to \"Ada Lovelace met Charles Babbage in London.\" gets London
as an OrganizationName -- and is identified as Indonesian."
  (remove-if-not (lambda (pair)
                   (let ((tag (car pair)))
                     (and (> (length tag) 4)
                          (string= "Name" tag :start2 (- (length tag) 4)))))
                 (tag-text text "NameType"
                           :options (logior +omit-punctuation+ +omit-whitespace+
                                            +join-names+))))

(defun parts-of-speech (text)
  "TEXT as (PART-OF-SPEECH . WORD) pairs -- \"Noun\", \"Verb\", \"Adjective\"..."
  (tag-text text "LexicalClass"))

(defun lemmas (text)
  "The dictionary form of each word: \"running\" -> \"run\"."
  (tag-text text "Lemma"))

;;; Word embeddings ------------------------------------------------------------

(defun word-embedding (&optional (language "en"))
  "The built-in word embedding for LANGUAGE, or NIL when there is not one."
  (ensure-natural-language)
  (let ((embedding (objc:invoke "NLEmbedding" "wordEmbeddingForLanguage:" language)))
    (unless (cffi:null-pointer-p (objc:objc-object-pointer embedding))
      embedding)))

(defun word-distance (first second &key (language "en"))
  "How far apart FIRST and SECOND are in meaning: 0 is identical, 2 is opposite.

    (word-distance \"cat\" \"dog\")     ;; => 0.717...
    (word-distance \"cat\" \"table\")   ;; => 1.236...

NIL when the language has no embedding.  Note the selector: the documented name
is -distanceBetweenWord:andWord:distanceType: and the implemented one says
String, not Word."
  (objc:with-autorelease-pool ()
    (let ((embedding (word-embedding language)))
      (when embedding
        (objc:invoke embedding "distanceBetweenString:andString:distanceType:"
                     first second +distance-cosine+)))))

(defun neighbours (word &key (count 5) (language "en"))
  "The COUNT words nearest WORD in meaning, as (WORD . DISTANCE), nearest first.

    (neighbours \"lisp\" :count 3)
    => ((\"compiler\" . 0.967...) ...)

The block takes its distance as a double BY VALUE."
  (objc:with-autorelease-pool ()
    (let ((embedding (word-embedding language))
          (found '()))
      (when embedding
        (objc:with-objc-block
            (block '(:void (objc:objc-object-pointer :double
                            (:pointer objc:objc-bool)))
                   (lambda (neighbour distance stop)
                     (declare (ignore stop))
                     (push (cons (objc:ns-string-to-string neighbour) distance) found)))
          (objc:invoke embedding
                       "enumerateNeighborsForString:maximumCount:distanceType:usingBlock:"
                       word count +distance-cosine+ block))
        (nreverse found)))))

;;; A worked example -----------------------------------------------------------

(defun test-natural-language ()
  "Run each shape and return a plist.  No window server, no network.

    (objc/examples:test-natural-language)
    => (:LANGUAGES (\"en\" \"fr\" \"ja\") :TOKENS (\"Cons\" \"cells\" \"cheaply\")
        :ENTITIES ((\"PersonalName\" . \"Ada Lovelace\")
                   (\"PersonalName\" . \"Charles Babbage\") (\"PlaceName\" . \"London\"))
        :NOUNS T :CLOSER T :NEIGHBOURS 5)

:CLOSER is the one worth having: cat is nearer dog than table, which is a claim
about the embedding rather than about the plumbing, and it would fail if the
double came back through the block wrong."
  (ensure-natural-language)
  (let* ((sentence "Ada Lovelace and Charles Babbage worked together in London.")
         (cat-dog (word-distance "cat" "dog"))
         (cat-table (word-distance "cat" "table")))
    (list :languages (mapcar #'language-of
                             '("The quick brown fox jumps over the lazy dog"
                               "Le renard brun rapide saute par-dessus le chien"
                               "すばやい茶色の狐"))
          :tokens (tokenize "Cons cells, cheaply.")
          :entities (entities sentence)
          :nouns (let ((tagged (parts-of-speech "The compiler emits fast code")))
                   (and (assoc "Noun" tagged :test #'string=) t))
          :closer (and cat-dog cat-table (< cat-dog cat-table))
          :neighbours (length (neighbours "lisp" :count 5)))))

(defun report-natural-language
    (&optional (text "Ada Lovelace and Charles Babbage worked together in London."))
  "Print everything the framework can say about TEXT."
  (ensure-natural-language)
  (format t "~&language: ~A~%" (language-of text))
  (format t "words: ~{~A~^ | ~}~%" (tokenize text))
  (format t "entities:~%")
  (loop for (tag . name) in (entities text)
        do (format t "  ~14A ~A~%" tag name))
  (format t "parts of speech:~%")
  (loop for (tag . word) in (parts-of-speech text)
        do (format t "  ~14A ~A~%" tag word))
  (let ((near (neighbours "computer" :count 5)))
    (when near
      (format t "words near \"computer\":~%")
      (loop for (word . distance) in near
            do (format t "  ~,3F ~A~%" distance word)))))
