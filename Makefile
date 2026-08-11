PROJECT := ScopedFolderMirror.xcodeproj
SCHEME := ScopedFolderMirror
DESTINATION ?= platform=macOS

.PHONY: test lint build package-preview verify clean

test:
	./scripts/test.sh '$(DESTINATION)'

lint:
	swift-format lint --strict --recursive ScopedFolderMirror ScopedFolderMirrorTests ScopedFolderMirrorUITests

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -destination '$(DESTINATION)' build

package-preview:
	./scripts/package-preview.sh "$(VERSION)" "$(ARCH)"

verify: test lint
	./scripts/audit-release.sh

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
