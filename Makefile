.PHONY: generate build test fetch-binaries clean open

# Generate the Xcode project from project.yml
generate:
	xcodegen generate

# Build the macOS app (no code signing for local dev)
build: generate
	xcodebuild -project grably.xcodeproj -scheme grably build CODE_SIGNING_ALLOWED=NO

# Run the GrablyCore Swift package tests
test:
	cd Packages/GrablyCore && swift test

# Download yt-dlp + ffmpeg/ffprobe binaries into Resources/bin
fetch-binaries:
	./Scripts/fetch-binaries.sh

# Open the generated Xcode project
open: generate
	open grably.xcodeproj

# Remove generated project and build artifacts
clean:
	rm -rf grably.xcodeproj DerivedData build
	cd Packages/GrablyCore && swift package clean
