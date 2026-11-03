#!/usr/bin/env bash
set -euo pipefail
# Downloads whisper.cpp Apple XCFramework (nightly b5454) and keeps iOS slices only.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
TAG="${WHISPER_XCFRAMEWORK_TAG:-b5454}"
URL="https://github.com/ggml-org/whisper.cpp/releases/download/${TAG}/whisper-${TAG}-xcframework.zip"
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$VENDOR"
echo "Downloading $URL ..."
curl -L --fail --progress-bar -o "$TMP/whisper.xcframework.zip" "$URL"
unzip -q -o "$TMP/whisper.xcframework.zip" -d "$TMP"
SRC="$TMP/build-apple/whisper.xcframework"
if [[ ! -d "$SRC" ]]; then
  SRC="$(find "$TMP" -type d -name 'whisper.xcframework' | head -1)"
fi
rm -rf "$VENDOR/whisper.xcframework"
mkdir -p "$VENDOR/whisper.xcframework"
cp -R "$SRC/ios-arm64" "$VENDOR/whisper.xcframework/"
cp -R "$SRC/ios-arm64_x86_64-simulator" "$VENDOR/whisper.xcframework/"
python3 - "$SRC" "$VENDOR/whisper.xcframework" "$TAG" <<'PY'
import plistlib, pathlib, sys
src = pathlib.Path(sys.argv[1]) / "Info.plist"
dst = pathlib.Path(sys.argv[2]) / "Info.plist"
tag = sys.argv[3]
info = plistlib.loads(src.read_bytes())
info["AvailableLibraries"] = [
    lib for lib in info["AvailableLibraries"]
    if str(lib.get("LibraryIdentifier","")).startswith("ios-")
]
dst.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML))
print(f"Installed iOS-only whisper.xcframework from {tag}")
PY
