PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin

.PHONY: build test install uninstall

build:
	swift build -c release

test:
	swift test

# LaunchAgents point at the installed binary, so install before `uplift apply`.
install: build
	mkdir -p $(BINDIR)
	install -m 755 .build/release/uplift $(BINDIR)/uplift
	@echo "Installed $(BINDIR)/uplift"

uninstall:
	rm -f $(BINDIR)/uplift
