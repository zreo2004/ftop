#!/bin/bash
# Builds a release and assembles build/Ftop.app. It is ad-hoc signed for this machine
# unless FTOP_SIGN_IDENTITY names a Developer ID certificate in the keychain; then
# every executable is signed with it, the hardened runtime, and a secure timestamp,
# as notarization requires (scripts/release.sh does this).
#
# FTOP_ARCH builds for one architecture (x86_64 on an Intel Mac); by default the
# machine's own. FTOP_SOURCE_ROOT records the checkout in the bundle, which is what
# lets the installed app rebuild itself with scripts/rebuild.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release ${FTOP_ARCH:+--arch "$FTOP_ARCH"}
bin="$(swift build -c release ${FTOP_ARCH:+--arch "$FTOP_ARCH"} --show-bin-path)"
app="build/Ftop.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Support/Info.plist "$app/Contents/Info.plist"
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
if [ -n "${FTOP_SOURCE_ROOT:-}" ]; then
    plutil -insert FtopSourceRoot -string "$FTOP_SOURCE_ROOT" "$app/Contents/Info.plist"
    plutil -insert FtopBuildCommit -string "$(git -C "$FTOP_SOURCE_ROOT" rev-parse --short HEAD)$(git -C "$FTOP_SOURCE_ROOT" diff --quiet HEAD 2>/dev/null || echo -dirty)" "$app/Contents/Info.plist"
fi
# The panel is named FtopPanel because "Ftop" and "ftop" are the same file on a
# case-insensitive disk.
cp "$bin/FtopApp" "$app/Contents/MacOS/FtopPanel"
cp "$bin/ftop" "$bin/ftop-helper" "$app/Contents/MacOS/"
if [ -n "${FTOP_SIGN_IDENTITY:-}" ]; then
    sign=(codesign --force --options runtime --timestamp --sign "$FTOP_SIGN_IDENTITY")
else
    sign=(codesign --force --sign -)
fi
# Inside out: the bundle's signature seals the executables signed before it.
"${sign[@]}" "$app/Contents/MacOS/ftop-helper" "$app/Contents/MacOS/ftop"
"${sign[@]}" "$app"
echo "Built $app"
