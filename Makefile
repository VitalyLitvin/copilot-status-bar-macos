APP_NAME := Copilot Statusbar
BINARY := copilot-statusbar
BUILD_DIR := .build/release
APP_DIR := dist/$(APP_NAME).app
CONTENTS := $(APP_DIR)/Contents
MACOS := $(CONTENTS)/MacOS
RESOURCES := $(CONTENTS)/Resources
DMG_STAGING := dist/dmg-staging
DMG_PATH := dist/$(APP_NAME).dmg

.PHONY: build run app install uninstall dmg clean

build:
	swift build -c release

run:
	swift run

app: build
	rm -rf "dist"
	mkdir -p "$(MACOS)" "$(RESOURCES)"
	cp "$(BUILD_DIR)/$(BINARY)" "$(MACOS)/$(BINARY)"
	chmod +x "$(MACOS)/$(BINARY)"
	cp "Resources/AppIcon.icns" "$(RESOURCES)/AppIcon.icns"
	printf '%s\n' \
	'<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0">' \
	'<dict>' \
	'  <key>CFBundleExecutable</key>' \
	'  <string>$(BINARY)</string>' \
	'  <key>CFBundleIdentifier</key>' \
	'  <string>dev.vitaly.copilot-statusbar</string>' \
	'  <key>CFBundleName</key>' \
	'  <string>$(APP_NAME)</string>' \
	'  <key>CFBundleIconFile</key>' \
	'  <string>AppIcon</string>' \
	'  <key>CFBundlePackageType</key>' \
	'  <string>APPL</string>' \
	'  <key>CFBundleShortVersionString</key>' \
	'  <string>0.1.0</string>' \
	'  <key>CFBundleVersion</key>' \
	'  <string>1</string>' \
	'  <key>LSMinimumSystemVersion</key>' \
	'  <string>13.0</string>' \
	'  <key>LSUIElement</key>' \
	'  <true/>' \
	'</dict>' \
	'</plist>' > "$(CONTENTS)/Info.plist"

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP_DIR)" /Applications/

uninstall:
	rm -rf "/Applications/$(APP_NAME).app"

# Builds a drag-to-install DMG: user opens it and drags the .app onto the
# Applications shortcut, same as any other macOS app.
dmg: app
	rm -rf "$(DMG_STAGING)" "$(DMG_PATH)"
	mkdir -p "$(DMG_STAGING)"
	cp -R "$(APP_DIR)" "$(DMG_STAGING)/"
	ln -s /Applications "$(DMG_STAGING)/Applications"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DMG_STAGING)" -ov -format UDZO "$(DMG_PATH)"
	rm -rf "$(DMG_STAGING)"
	@echo "Created $(DMG_PATH)"

clean:
	rm -rf .build dist
