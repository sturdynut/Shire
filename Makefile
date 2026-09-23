PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin
APPDIR ?= $(HOME)/Applications
BUNDLE := .build/Shire.app

.PHONY: build test install uninstall app install-app icons

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
app: .build/AppIcon.icns
	swift build -c release --product ShireApp
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp .build/release/ShireApp $(BUNDLE)/Contents/MacOS/Shire
	cp App/Info.plist $(BUNDLE)/Contents/Info.plist
	cp .build/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	codesign --force --sign - --timestamp=none $(BUNDLE)
	@echo "Built $(BUNDLE)"

.build/AppIcon.icns: assets/branding/shire-logo-transparent.png App/build-icon.sh
	sh App/build-icon.sh "$<" "$@"

install-app: app
	mkdir -p "$(APPDIR)"
	-osascript -e 'tell application id "com.shire.app" to quit' 2>/dev/null
	rm -rf "$(APPDIR)/Shire.app"
	cp -R $(BUNDLE) "$(APPDIR)/Shire.app"
	open "$(APPDIR)/Shire.app"
	@echo "Installed $(APPDIR)/Shire.app"

# Regenerate the phone page's icons from assets/branding/shire-logo-transparent.png (the app icon is built by `make app`).
icons:
	swift scripts/make-phone-icons.swift
