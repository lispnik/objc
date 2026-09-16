# Makefile for objc.
#
# Targets:
#   make test        load #:objc/test and run the FiveAM suite (default)
#   make test-clean  the same, but with no ~/.sbclrc and no site init
#   make deps     restore ocicl-vendored dependencies
#   make repl     an SBCL with the library loaded
#   make oracle   print how to regenerate test/oracle/answers.lisp
#   make bench    run bench/bench.lisp on SBCL and ECL, merge into bench/RESULTS.md
#   make bench-lispworks  print how to run the same file in LispWorks
#   make clean    remove fasls, including the ASDF cache for this tree
#
# LISP overrides the Lisp used (default sbcl).  This library is SBCL only: the
# dynamic dispatch in src/abi.lisp is built on sb-alien, for reasons documented
# at the top of that file.

LISP ?= sbcl
# ECL for the benchmark.  Stock Homebrew ECL cannot resolve symbols through
# :default (see README, "ECL"); point this at one built from lispnik/ecl.
ECL ?= ecl

.PHONY: all test test-clean deps repl oracle clean \
        bench bench-sbcl bench-ecl bench-lispworks bench-compare

all: test

# RUN-TESTS returns the status and the .asd signals on a NIL result; FIVEAM's
# RUN! alone would exit 0 on a failing suite.
test:
	$(LISP) --non-interactive \
	  --eval '(asdf:load-system :objc/test)' \
	  --eval '(uiop:quit (if (objc/test:run-tests) 0 1))'

# The suite with nothing inherited from the developer's environment: no
# ~/.sbclrc, no site init, source registry built from this tree alone.  This is
# what CI sees, and the difference is not academic -- the dump test spawns a
# subprocess that could only find the system because ~/.sbclrc happened to set
# up ocicl, so it passed here and failed on the first CI run.
test-clean:
	$(LISP) --non-interactive --no-userinit --no-sysinit \
	  --eval '(require :asdf)' \
	  --eval '(asdf:initialize-source-registry `(:source-registry (:tree ,(truename "./")) :ignore-inherited-configuration))' \
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

# The benchmark.  One file compiled on each Lisp; each run writes
# bench/results/<lisp>.txt and bench-compare merges whatever files exist.
# LispWorks Personal cannot be scripted, so its column is produced by hand
# with the same file -- bench-lispworks prints the two forms to type.
bench: bench-sbcl bench-ecl bench-compare

bench-sbcl:
	$(LISP) --non-interactive \
	  --eval '(asdf:load-system :objc)' \
	  --eval '(load (compile-file "bench/bench.lisp"))' \
	  --eval '(objc-bench:run)'

bench-ecl:
	$(ECL) --norc \
	  --eval '(require :asdf)' \
	  --eval '(asdf:initialize-source-registry `(:source-registry (:tree ,(truename "./")) :ignore-inherited-configuration))' \
	  --eval '(asdf:load-system :objc)' \
	  --eval '(load (compile-file "bench/bench.lisp"))' \
	  --eval '(objc-bench:run)' \
	  --eval '(ext:quit 0)'

bench-lispworks:
	@echo "In a LispWorks Listener, evaluate:"
	@echo '  (load (compile-file "$(CURDIR)/bench/bench.lisp"))'
	@echo '  (objc-bench:run)'
	@echo "then run 'make bench-compare' here."

bench-compare:
	$(LISP) --non-interactive \
	  --eval '(asdf:load-system :objc)' \
	  --eval '(load (compile-file "bench/bench.lisp"))' \
	  --eval '(objc-bench:compare)'

clean:
	rm -rf *.fasl bench/*.fasl bench/*.fas bench/*.64yfasl
	rm -rf $(HOME)/.cache/common-lisp/*/$(CURDIR)
