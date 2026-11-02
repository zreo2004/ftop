#!/bin/bash
# The single gate: formatting, a warning-free build, and all tests.
# Run before reporting any change complete.
set -euo pipefail
cd "$(dirname "$0")/.."

# With only the Command Line Tools installed, SwiftPM does not look in the toolchain's
# own Frameworks directory, so `import Testing` fails. The module and the dylib it links
# are both there; naming them is all it takes. With Xcode these paths do not exist and
# SwiftPM finds swift-testing on its own.
test_flags=()
if [ ! -d /Applications/Xcode.app ] && [ -d /Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework ]; then
    frameworks=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    libraries=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
    test_flags=(-Xswiftc -F -Xswiftc "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$libraries")
fi

echo "== format"
swift format lint --strict --recursive Package.swift Sources Tests

echo "== build"
swift build -Xswiftc -warnings-as-errors 2>&1 | tail -3

echo "== test"
swift test "${test_flags[@]}" 2>&1 | grep -E "✘|error:|failed|Test run with" || true
swift test "${test_flags[@]}" >/dev/null 2>&1

echo "check passed"
