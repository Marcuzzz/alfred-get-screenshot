#!/bin/bash
# Build (and publish) an .alfredworkflow release.
#
#   ./release.command                    bump patch version, build, commit, tag, push, GitHub release
#   ./release.command pass-patch         build only, using the current version (no git / GitHub)
#   ./release.command pass-patch --force release the current version without bumping
set -euo pipefail

# Double-clicked .command files start in $HOME with a minimal PATH
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Files that make up the workflow (bin/ is left out: gallery.swift is compiled on first use)
FILES=(info.plist icon.png list-screenshots.js gallery.swift)

BUNDLEID=$(plutil -extract bundleid raw -o - info.plist)
NAME=${BUNDLEID##*.}
VERSION=$(plutil -extract version raw -o - info.plist)
PUBLISH=false

if [ "${1:-}" != "pass-patch" ]; then
    if [ -n "$(git status --porcelain)" ]; then
        echo "Working tree not clean, commit or stash your changes first."
        exit 1
    fi
    # Increment the patch version
    IFS=. read -r MAJOR MINOR PATCH <<<"$VERSION"
    VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
    plutil -replace version -string "$VERSION" info.plist
    git commit -q -m "chore: release v$VERSION" info.plist
    echo "patched..."
    PUBLISH=true
elif [ "${2:-}" == "--force" ]; then
    PUBLISH=true
fi

FILENAME="$NAME.v$VERSION.alfredworkflow"

echo "NAME: $NAME"
echo "NEW VERSION: v$VERSION"

echo "Building release..."
echo
mkdir -p releases
rm -f "releases/$FILENAME"
zip -X "releases/$FILENAME" "${FILES[@]}"
echo

echo "Released $NAME v$VERSION"
echo " * releases/$FILENAME"

if [ "$PUBLISH" = true ]; then
    git tag -a "v$VERSION" -m "Released $NAME v$VERSION"
    git push origin HEAD "v$VERSION"
    gh release create "v$VERSION" "./releases/$FILENAME" --title "v$VERSION" --notes "Released $NAME v$VERSION"
    echo "..."
fi

# Reveal instead of open: opening would import a copy over the symlinked dev workflow in Alfred
echo "Revealing new release"
open -R "./releases/$FILENAME"
