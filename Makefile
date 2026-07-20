.PHONY: build app run debug clean icon

# Build a release .app bundle.
app:
	@bash scripts/bundle.sh release

# Regenerate the app icon from scripts/generate_icon.swift.
icon:
	@swift scripts/generate_icon.swift Resources/AppIcon.iconset
	@iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "✓ Resources/AppIcon.icns"

# Build and launch.
run: app
	@open .build/DiskScope.app

# Quick debug build of the bundle.
debug:
	@bash scripts/bundle.sh debug
	@open .build/DiskScope.app

# Compile only (no bundle).
build:
	@swift build -c release

clean:
	@swift package clean
	@rm -rf .build/DiskScope.app
