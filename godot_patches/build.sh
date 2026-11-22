#!/usr/bin/env bash
# Builds the game's patched Godot editor.
#   godot_patches/build.sh [folder]      (default D:/godot_4.4.1_custom)
# Fetches the stock 4.4.1 source into <folder>/godot if it is not there,
# applies every .patch in this folder that is not applied yet, and builds.
# Needs: git, Python, SCons, Visual Studio 2022 build tools.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="${1:-/d/godot_4.4.1_custom}"
tag="4.4.1-stable"
mkdir -p "$dest"
if [ ! -d "$dest/godot/.git" ]; then
	git -c core.longpaths=true clone --depth 1 --branch "$tag" https://github.com/godotengine/godot.git "$dest/godot"
fi
cd "$dest/godot"
for patch in "$here"/*.patch; do
	if git apply --reverse --check "$patch" 2>/dev/null; then
		echo "already applied: $(basename "$patch")"
	else
		git apply --whitespace=nowarn "$patch"
		echo "applied: $(basename "$patch")"
	fi
done
scons platform=windows target=editor -j"${JOBS:-12}"
echo "editor: $dest/godot/bin/"
# Export templates, when a release needs them:
#   scons platform=windows target=template_release
#   scons platform=windows target=template_debug
