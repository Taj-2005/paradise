# Requires tectonic (brew install tectonic)
.PHONY: all clean

all: report.pdf

report.pdf: report.tex diagrams.tex
	tectonic report.tex

clean:
	rm -f *.aux *.log *.out *.toc *.synctex.gz
