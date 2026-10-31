#!/bin/bash
# Copyright (C) 2026 Antonio Marogna — EVRApps
# SPDX-License-Identifier: GPL-3.0-only

# Build a self-contained "Readback Check.app" in ./build/portable: the app, the
# engine, evr_copyhash and a minimal Python 3 for both architectures. On the
# target Mac it needs nothing but macOS 14+: no Python, no Xcode tools.
#
#   ./build_portable.sh [path/to/evr_copyhash]
#
# evr_copyhash is proprietary and not part of this repository (see
# licenses/evr_copyhash.txt): only EVRApps' official build has it. It runs as
# a separate program from Contents/Helpers and is never linked into the app.
# Without an argument, ./evr_copyhash is used.
#
# The result is signed ad hoc; sign it with a Developer ID and notarize it
# before handing it out. Layout inside the bundle:
#
#   Contents/MacOS/ReadbackCheck                  the app
#   Contents/Helpers/evr_copyhash                calibration copier (universal)
#   Contents/Resources/AppIcon.icns               built from icon/ (see icon/README.md)
#   Contents/Resources/engine/verify_offload_app.py
#   Contents/Resources/evr_copyhash   ->   ../Helpers/evr_copyhash
#   Contents/Resources/python-<arch>/            Python, one tree per architecture
#   Contents/Resources/Licenses/                  GPL v3, additional terms, icon,
#                                                 evr_copyhash and third-party licenses
#   Contents/Resources/Licenses/Python-libraries/ libraries built into Python
#
# The engine finds evr_copyhash at ../evr_copyhash from its own folder, as in
# the source tree, so the link keeps it unchanged. Python never writes into the
# bundle (it would break the signature): the app runs it with -B, and the
# standard library is precompiled here, before signing.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
COPYHASH="${1:-$HERE/evr_copyhash}"
VERSION="$(sed -n 's/^VERSION=//p' "$HERE/build_app.sh")"
BUILD="$(sed -n 's/^BUILD=//p' "$HERE/build_app.sh")"

# ---- pinned Python (python-build-standalone), checked against the release's SHA256SUMS
PY_TAG=20261009
PY_VER=3.12.15
PY_MINOR=3.12
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/$PY_TAG"
# Under Resources, not Frameworks: codesign rejects a data tree (the standard
# library) inside Frameworks. The Mach-O files in the trees are signed one by one.
PY_HOME=Resources

APP="$HERE/build/portable/Readback Check.app"
DL="$HERE/build/downloads"
WORK="$HERE/build/work"

say() { printf '\n== %s\n' "$*"; }

# --------------------------------------------------------------------------
say "app binary (universal)"
(cd "$HERE" && swift build -c release --arch arm64 --arch x86_64 >/dev/null)
BIN="$(cd "$HERE" && swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ReadbackCheck"
[ -x "$COPYHASH" ] || { echo "evr_copyhash not found: $COPYHASH"; exit 1; }
lipo "$COPYHASH" -verify_arch arm64 x86_64 || { echo "evr_copyhash is not universal: $COPYHASH"; exit 1; }

# --------------------------------------------------------------------------
say "Python $PY_VER ($PY_TAG)"
mkdir -p "$DL"
[ -f "$DL/SHA256SUMS" ] || curl -fsSL -o "$DL/SHA256SUMS" "$PY_URL/SHA256SUMS"
rm -rf "$WORK"; mkdir -p "$WORK"
fetch() {                                         # download once, check every time
    local f="$1"
    [ -f "$DL/$f" ] || curl -fsSL -o "$DL/$f" "$PY_URL/${f//+/%2B}"
    local exp got
    exp="$(grep " $f\$" "$DL/SHA256SUMS" | awk '{print $1}')"
    got="$(shasum -a 256 "$DL/$f" | awk '{print $1}')"
    [ -n "$exp" ] && [ "$exp" = "$got" ] || { echo "checksum mismatch: $f"; exit 1; }
}
command -v zstd >/dev/null || { echo "zstd is needed to read the full Python archives (brew install zstd)"; exit 1; }
for A in aarch64 x86_64; do
    f="cpython-$PY_VER+$PY_TAG-$A-apple-darwin-install_only_stripped.tar.gz"
    fetch "$f"
    mkdir -p "$WORK/$A" && tar -xzf "$DL/$f" -C "$WORK/$A"
    # The install_only archive has no licenses for the libraries built into
    # Python; the full archive of the same build has them, with PYTHON.json
    # saying which module uses which.
    f="cpython-$PY_VER+$PY_TAG-$A-apple-darwin-pgo+lto-full.tar.zst"
    fetch "$f"
    mkdir -p "$WORK/full-$A" && tar -xf "$DL/$f" -C "$WORK/full-$A" python/PYTHON.json python/licenses
done

# Keep the interpreter and the standard library the engine can reach; drop the
# rest (pip, Tcl/Tk, IDLE, the test suite, headers, 2to3...).
trim() {
    local p="$1" L="$1/lib/python$PY_MINOR"
    rm -rf "$p/include" "$p/share" "$p/lib/pkgconfig" "$p/lib/"itcl* "$p/lib/"thread* \
           "$p/lib/"tcl* "$p/lib/"tk* "$p/lib/libtcl"* "$p/lib/libpython$PY_MINOR.dylib"
    find "$p/bin" -mindepth 1 ! -name "python$PY_MINOR" -delete
    rm -rf "$L/site-packages" "$L/idlelib" "$L/tkinter" "$L/turtledemo" "$L/ensurepip" \
           "$L/lib2to3" "$L/pydoc_data" "$L/test" "$L/unittest" "$L/venv" \
           "$L/config-$PY_MINOR-darwin" "$L/lib-dynload/_tkinter"*.so "$L/turtle.py"
    find "$p" -name "__pycache__" -type d -prune -exec rm -rf {} +
    mkdir -p "$L/site-packages"
}

# --------------------------------------------------------------------------
say "bundle"
rm -rf "$APP"
C="$APP/Contents"
mkdir -p "$C/MacOS" "$C/Helpers" "$C/Resources/engine" "$C/Resources/Licenses"
cp "$BIN" "$C/MacOS/ReadbackCheck"
cp "$COPYHASH" "$C/Helpers/evr_copyhash"
cp "$HERE/engine/verify_offload_app.py" "$C/Resources/engine/"
cp "$HERE/icon/AppIcon.icns" "$C/Resources/"
ln -s ../Helpers/evr_copyhash "$C/Resources/evr_copyhash"
for A in aarch64 x86_64; do
    arch=$([ "$A" = aarch64 ] && echo arm64 || echo x86_64)
    trim "$WORK/$A/python"
    cp -R "$WORK/$A/python" "$C/$PY_HOME/python-$arch"
done
cp "$HERE/LICENSE" "$C/Resources/Licenses/ReadbackCheck-LICENSE.txt"
cp "$HERE/ADDITIONAL_TERMS.md" "$C/Resources/Licenses/ReadbackCheck-ADDITIONAL_TERMS.md"
cp "$HERE/icon/LICENSE" "$C/Resources/Licenses/ReadbackCheck-icon-LICENSE.txt"
cp "$HERE"/licenses/*.txt "$C/Resources/Licenses/"          # evr_copyhash.txt, xxHash
cp "$WORK/x86_64/python/lib/python$PY_MINOR/LICENSE.txt" "$C/Resources/Licenses/Python-LICENSE.txt"
curl -fsSL -o "$C/Resources/Licenses/python-build-standalone-LICENSE.txt" \
    "https://raw.githubusercontent.com/astral-sh/python-build-standalone/$PY_TAG/LICENSE" \
    || { echo "python-build-standalone LICENSE not fetched: the app can't ship without it"; exit 1; }

# Precompile the standard library with an interpreter this Mac can run; .pyc
# files depend on the Python version, not on the architecture. unchecked-hash:
# valid whatever the files' dates become after copying and signing.
HOSTPY=""
for arch in arm64 x86_64; do
    "$C/$PY_HOME/python-$arch/bin/python$PY_MINOR" -c '' 2>/dev/null \
        && { HOSTPY="$C/$PY_HOME/python-$arch/bin/python$PY_MINOR"; break; }
done
[ -n "$HOSTPY" ] || { echo "no runnable Python in the bundle"; exit 1; }
for arch in arm64 x86_64; do
    "$HOSTPY" -I -m compileall -q -j 0 --invalidation-mode unchecked-hash \
        "$C/$PY_HOME/python-$arch/lib/python$PY_MINOR" >/dev/null
done

# Licenses of the libraries built into the modules left in the bundle
# (OpenSSL, SQLite, libffi, xz, bzip2...). A module linked only to macOS's own
# libraries (zlib, ncurses, libedit) needs none; one that bundles a library
# and has no license file stops the build.
mkdir -p "$C/Resources/Licenses/Python-libraries"
for A in aarch64 x86_64; do
    arch=$([ "$A" = aarch64 ] && echo arm64 || echo x86_64)
    "$HOSTPY" -I - "$WORK/full-$A/python" "$C/$PY_HOME/python-$arch/lib/python$PY_MINOR/lib-dynload" \
        "$C/Resources/Licenses/Python-libraries" <<'PY' || exit 1
import json, os, shutil, sys
full, dynload, out = sys.argv[1:]
info = json.load(open(os.path.join(full, "PYTHON.json")))
left = set(os.listdir(dynload))
for name, variants in info["build_info"]["extensions"].items():
    ext = variants[0]
    # Most modules are built into the interpreter; one shipped as its own
    # file counts only if the trimming above kept it (tkinter goes).
    if ext.get("shared_lib") and os.path.basename(ext["shared_lib"]) not in left:
        continue
    bundled = [l["name"] for l in ext["links"] if not l.get("system") and not l.get("framework")]
    if not bundled:
        continue
    found = [p for p in ext.get("license_paths") or [] if os.path.exists(os.path.join(full, p))]
    if not found:
        sys.exit(f"no license file for {name} ({', '.join(bundled)})")
    for p in found:
        shutil.copy(os.path.join(full, p), out)
PY
done
ls "$C/Resources/Licenses/Python-libraries"

cat > "$C/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ReadbackCheck</string>
    <key>CFBundleIdentifier</key><string>com.evrapps.readbackcheck</string>
    <key>CFBundleName</key><string>Readback Check</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>RCPythonHome</key><string>$PY_HOME</string>
    <key>RCPythonVersion</key><string>$PY_VER ($PY_TAG)</string>
</dict>
</plist>
EOF

# --------------------------------------------------------------------------
say "ad-hoc signature (inside out, hardened runtime): replace with a Developer ID"
find "$C/$PY_HOME" "$C/Helpers" -type f \( -perm -u+x -o -name "*.so" -o -name "*.dylib" \) -print0 \
    | while IFS= read -r -d '' f; do
        file -b "$f" | grep -q Mach-O && codesign --force --options runtime --sign - "$f"
      done
codesign --force --options runtime --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "codesign --verify --deep --strict: OK"

rm -rf "$WORK"                                   # extracted runtimes; downloads/ stays as a cache

say "done"
du -sh "$APP" "$C/$PY_HOME"/python-*
echo "$APP"
