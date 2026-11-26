# Coq build for the consolidated NaN0S formal UTM tree.
# Requires Coq 8.20 (coq_makefile, coqc, coqchk) on PATH.

COQPROJECT = _CoqProject

.PHONY: all clean check

all: Makefile.coq
	$(MAKE) -f Makefile.coq

Makefile.coq: $(COQPROJECT)
	coq_makefile -f $(COQPROJECT) -o Makefile.coq

check: all
	coqchk -Q . NaNLM MinskyNaN16Universality.vo
	coqchk -Q . NaNLM MinskyNaN16LiteralRun.vo
	coqchk -Q . NaNLM MinskyNaN16LiteralBridge.vo

clean:
	rm -f Makefile.coq Makefile.coq.conf
	rm -f *.vo *.vos *.vok *.glob .*.aux
