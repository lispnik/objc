# Makefile for objc.
#
# Targets:
#   make test     load #:objc/test and run the FiveAM suite (default)
#   make deps     restore ocicl-vendored dependencies
#   make repl     an SBCL with the library loaded
#   make oracle   print how to regenerate test/oracle/answers.lisp
#   make clean    remove fasls, including the ASDF cache for this tree
#
# LISP overrides the Lisp used (default sbcl).  This library is SBCL only: the
# dynamic dispatch in src/abi.lisp is built on sb-alien, for reasons documented
# at the top of that file.

LISP ?= sbcl

.PHONY: all test deps repl oracle clean

all: test

# RUN-TESTS returns the status and the .asd signals on a NIL result; FIVEAM's
# RUN! alone would exit 0 on a failing suite.
test:
	$(LISP) --non-interactive \
	  --eval '(asdf:load-system :objc/test)' \
	  --eval '(uiop:quit (if (objc/test:run-tests) 0 1))'

deps:
	ocicl install

repl:
	$(LISP) --eval '(asdf:load-system :objc)'

# LispWorks Personal cannot be scripted -- -eval is ignored and the heap says
# "Initialization files are not available in the Personal Edition of
# LispWorks" -- so the differential answers are gathered by hand, once, and
# committed.  See test/oracle/answers.lisp.
oracle:
	@echo "Open the LispWorks IDE, paste test/oracle/probe.lisp into the"
	@echo "Listener, and record the output in test/oracle/answers.lisp."

clean:
	rm -rf *.fasl
	rm -rf $(HOME)/.cache/common-lisp/*/$(CURDIR)
