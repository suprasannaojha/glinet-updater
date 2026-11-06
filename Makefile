ENTRY_SOURCES = glu agent/agent.sh tests/*.sh
LIBRARY_SOURCES = lib/*.sh
SHELL_SOURCES = $(ENTRY_SOURCES) $(LIBRARY_SOURCES)
PYTHON_SOURCES = tools/distsign_verify.py tests/test_distsign.py

.PHONY: check lint format format-check test

check: lint format-check test

lint:
	shellcheck --shell=dash --severity=warning --exclude=SC1090,SC1091,SC2154 $(ENTRY_SOURCES)
	shellcheck --shell=dash --severity=warning --exclude=SC2034,SC2154 $(LIBRARY_SOURCES)
	python3 -I -c 'import ast, sys; [ast.parse(open(path).read(), path) for path in sys.argv[1:]]' $(PYTHON_SOURCES)

format:
	shfmt -w -i 2 -ci $(SHELL_SOURCES)

format-check:
	shfmt -d -i 2 -ci $(SHELL_SOURCES)

test:
	sh tests/run.sh
