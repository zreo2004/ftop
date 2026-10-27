#!/bin/bash
# Rebuilds Ftop.app from this checkout for the machine it runs on and puts it where
# the installed app is. This is the update path of a copy built from source: the
# project's releases are Apple Silicon only, so there is no archive to download.
#
# The panel runs it from its Update row (`ftop update` does the same) and restarts
# itself afterwards; running it by hand only replaces the app.
#
# FTOP_REBUILD_TARGET names the app bundle to replace (default ~/Applications/Ftop.app).
set -euo pipefail
cd "$(dirname "$0")/.."

target="${FTOP_REBUILD_TARGET:-$HOME/Applications/Ftop.app}"
[ -d "$target" ] || { echo "No app at $target" >&2; exit 1; }
[ -w "$(dirname "$target")" ] || { echo "$(dirname "$target") is not writable" >&2; exit 1; }

echo "== fetch"
git fetch --quiet origin
if [ "$(git rev-parse HEAD)" != "$(git rev-parse FETCH_HEAD)" ]; then
    # A checkout that has diverged is merged by hand: building it again would only
    # produce the same app, once a day, for as long as the two stay apart.
    git merge --ff-only --quiet FETCH_HEAD || {
        echo "This checkout has commits of its own; merge origin/main by hand, then build again." >&2
        exit 1
    }
fi

echo "== build"
FTOP_ARCH="$(uname -m)" FTOP_SOURCE_ROOT="$PWD" scripts/bundle.sh

echo "== install"
# Beside the target, so the swap is a rename on one volume and never a half-copied app.
staged="$(dirname "$target")/.$(basename "$target" .app)-rebuild.app"
rm -rf "$staged"
ditto build/Ftop.app "$staged"
rm -rf "$target.previous"
mv "$target" "$target.previous"
if ! mv "$staged" "$target"; then
    mv "$target.previous" "$target"
    exit 1
fi
rm -rf "$target.previous"
echo "Installed $target ($(uname -m))"
