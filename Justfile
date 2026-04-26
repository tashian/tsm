set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    @just --list

# Run all tests
test: test-go test-swift

test-go:
    go test ./...

test-swift:
    cd tsmd && swift test

# Build both binaries into ./dist/bin/
build: clean
    mkdir -p dist/bin
    go build -trimpath -ldflags="-s -w" -o dist/bin/tsm .
    cd tsmd && swift build -c release
    cp tsmd/.build/release/tsmd dist/bin/tsmd
    chmod +x dist/bin/tsm dist/bin/tsmd

clean:
    rm -rf dist

# Package binaries into a tarball + checksums (VERSION is bare, no leading "v")
package VERSION: build
    mkdir -p dist/release
    tar -C dist/bin -czf dist/release/tsm_{{VERSION}}_darwin_arm64.tar.gz tsm tsmd
    cd dist/release && shasum -a 256 *.tar.gz > checksums.txt
    @echo "✓ packaged dist/release/tsm_{{VERSION}}_darwin_arm64.tar.gz"

# Build + package only — no GitHub release, no npm publish
release-dryrun VERSION: (package VERSION)
    @echo "✓ dry-run artifacts ready in dist/release/ for v{{VERSION}}"
    @ls -lh dist/release/

# Create the GitHub Release and upload artifacts (requires `gh auth login`)
release VERSION: (package VERSION)
    gh release create v{{VERSION}} \
        dist/release/tsm_{{VERSION}}_darwin_arm64.tar.gz \
        dist/release/checksums.txt \
        --title "v{{VERSION}}" \
        --generate-notes
