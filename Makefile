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
	cp App/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
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

# Regenerate the app and phone icons from assets/branding/shire-logo-transparent.png.
icons:
	rm -rf .build/AppIcon.iconset && mkdir -p .build/AppIcon.iconset
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s assets/branding/shire-logo-transparent.png --out .build/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) assets/branding/shire-logo-transparent.png --out .build/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns .build/AppIcon.iconset -o App/AppIcon.icns
	swift scripts/make-phone-icons.swift
