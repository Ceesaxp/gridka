.PHONY: generate build test clean

generate:
	/opt/homebrew/bin/xcodegen generate

build: generate
	xcodebuild -scheme Gridka -configuration Debug build

test: generate
	xcodebuild -scheme Gridka -configuration Debug test -destination 'platform=macOS'

clean:
	xcodebuild -scheme Gridka -configuration Debug clean
