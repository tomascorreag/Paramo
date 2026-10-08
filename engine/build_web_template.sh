#!/usr/bin/env bash
# Build Paramo's size-stripped web export template from Godot source.
#
#   engine/build_web_template.sh <godot-4.6.1-stable source dir>
#
# Needs emscripten on PATH (Godot 4.6 CI pins 4.0.11: `emsdk install 4.0.11`)
# and SCons >= 4. Writes engine/templates/web_nothreads_release.zip, which the
# "Web" and "Web Profile" presets point at via custom_template/release.
set -euo pipefail

GODOT_SRC="${1:?usage: $0 <godot source dir>}"
ENGINE_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPECTED_TAG="4.6.1-stable"

tag="$(git -C "$GODOT_SRC" describe --tags --exact-match 2>/dev/null || true)"
if [[ "$tag" != "$EXPECTED_TAG" ]]; then
	echo "error: $GODOT_SRC is at '${tag:-untagged}', expected $EXPECTED_TAG" >&2
	exit 1
fi

jobs="$(getconf _NPROCESSORS_ONLN)"
scons -C "$GODOT_SRC" -j"$jobs" platform=web target=template_release \
	profile="$ENGINE_DIR/paramo_web.py"

mkdir -p "$ENGINE_DIR/templates"
cp "$GODOT_SRC/bin/godot.web.template_release.wasm32.nothreads.zip" \
	"$ENGINE_DIR/templates/web_nothreads_release.zip"
echo "wrote $ENGINE_DIR/templates/web_nothreads_release.zip"
