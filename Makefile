PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin
APPDIR ?= $(HOME)/Applications
BUNDLE := .build/Shire.app

.PHONY: build test install uninstall app install-app

build:
	swift build -c release

test:
	swift test

# LaunchAgents point at the installed binary, so install before `shire apply`.
install: build
	mkdir -p $(BINDIR)
	install -m 755 .build/release/shire $(BINDIR)/shire
	@echo "Installed $(BINDIR)/shire"

uninstall:
	rm -f $(BINDIR)/shire
	rm -rf "$(APPDIR)/Shire.app"

# The menu bar app: the ShireApp executable wrapped in a bundle and signed ad hoc (fine for your own Mac).
app:
	swift build -c release --product ShireApp
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp .build/release/ShireApp $(BUNDLE)/Contents/MacOS/Shire
	cp App/Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --sign - --timestamp=none $(BUNDLE)
	@echo "Built $(BUNDLE)"

install-app: app
	mkdir -p "$(APPDIR)"
	-osascript -e 'tell application id "com.shire.app" to quit' 2>/dev/null
	rm -rf "$(APPDIR)/Shire.app"
	cp -R $(BUNDLE) "$(APPDIR)/Shire.app"
	open "$(APPDIR)/Shire.app"
	@echo "Installed $(APPDIR)/Shire.app"
