PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin

.PHONY: build test install uninstall

build:
	swift build -c release

test:
	swift test

# LaunchAgents point at the installed binary, so install before `tender apply`.
install: build
	mkdir -p $(BINDIR)
	install -m 755 .build/release/tender $(BINDIR)/tender
	@echo "Installed $(BINDIR)/tender"

uninstall:
	rm -f $(BINDIR)/tender
