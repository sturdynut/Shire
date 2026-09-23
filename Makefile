PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin
APPDIR ?= $(HOME)/Applications
BUNDLE := .build/Tender.app

.PHONY: build test install uninstall app install-app

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
	rm -rf "$(APPDIR)/Tender.app"

# The menu bar app: the TenderApp executable wrapped in a bundle and signed ad hoc (fine for your own Mac).
app:
	swift build -c release --product TenderApp
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp .build/release/TenderApp $(BUNDLE)/Contents/MacOS/Tender
	cp App/Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --sign - --timestamp=none $(BUNDLE)
	@echo "Built $(BUNDLE)"

install-app: app
	mkdir -p "$(APPDIR)"
	-osascript -e 'tell application id "com.tender.app" to quit' 2>/dev/null
	rm -rf "$(APPDIR)/Tender.app"
	cp -R $(BUNDLE) "$(APPDIR)/Tender.app"
	open "$(APPDIR)/Tender.app"
	@echo "Installed $(APPDIR)/Tender.app"
