PYTHON ?= python3
.PHONY: all test clean
all:
	$(PYTHON) tools/build.py
test: all
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v
clean:
	rm -f build/asm-doom build/build-evidence.json
