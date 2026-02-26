.PHONY: generate build test clean

XCODEGEN ?= $(shell command -v xcodegen 2>/dev/null || echo /opt/homebrew/bin/xcodegen)

generate:
	$(XCODEGEN) generate

build: generate
	xcodebuild -scheme Gridka -configuration Debug build

test: generate
	xcodebuild -scheme Gridka -configuration Debug test -destination 'platform=macOS'

clean:
	xcodebuild -scheme Gridka -configuration Debug clean
