# Requires tectonic (brew install tectonic)
.PHONY: all phase1 phase2 clean

all: phase1 phase2

phase1: phase1-report.pdf
phase2: phase2-report.pdf

phase1-report.pdf: phase1-report.tex diagrams.tex
	tectonic phase1-report.tex

phase2-report.pdf: phase2-report.tex diagrams.tex
	tectonic phase2-report.tex

clean:
	rm -f *.aux *.log *.out *.toc *.synctex.gz
