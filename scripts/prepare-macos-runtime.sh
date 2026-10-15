#!/usr/bin/env bash
# Sourced by package-native.sh. Downloads stay in the ignored build directory.
RUNTIME_CACHE="$PWD/build/intel-runtime"
mkdir -p "$RUNTIME_CACHE"
NODE_VERSION="$(node -p 'process.version')"
NODE_SLICES=()
for required in "${REQUIRED_ARCHES[@]}"; do
  node_arch="$required"; [[ "$required" != x86_64 ]] || node_arch=x64
  node_root="$RUNTIME_CACHE/node-$NODE_VERSION-darwin-$node_arch"
  if [[ ! -f "$node_root/bin/node" ]]; then
    curl -fL --retry 2 --max-time 180 "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-darwin-$node_arch.tar.gz" -o "$RUNTIME_CACHE/node-$node_arch.tar.gz"
    tar -xzf "$RUNTIME_CACHE/node-$node_arch.tar.gz" -C "$RUNTIME_CACHE"
  fi
  NODE_SLICES+=("$node_root/bin/node")
done
if [[ ${#NODE_SLICES[@]} == 2 ]]; then
  lipo -create "${NODE_SLICES[@]}" -output "$RUNTIME_CACHE/node-universal"
  NODE_BIN="$RUNTIME_CACHE/node-universal"
else
  NODE_BIN="${NODE_SLICES[0]}"
fi
if [[ ! -d "assets/gstreamer/macos-arm64/lib/gstreamer-1.0" ]]; then
  echo "==> Bundled GStreamer plugins not found in assets/gstreamer/macos-arm64. Fetching prebuilt runtime..."
  UPSTREAM_DMG="$RUNTIME_CACHE/MacPlay-1.2.2-arm64.dmg"
  if [[ ! -f "$UPSTREAM_DMG" ]]; then
    curl -fL --retry 3 --max-time 180 "https://github.com/Roylyl/MacPlay/releases/download/V1.2.2/MacPlay-1.2.2-arm64.dmg" -o "$UPSTREAM_DMG"
  fi
  MOUNT_DIR="$(mktemp -d "$RUNTIME_CACHE/macplay-mount.XXXXXX")"
  hdiutil attach "$UPSTREAM_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -readonly
  mkdir -p assets/gstreamer/macos-arm64
  cp -R "$MOUNT_DIR/MacPlay.app/Contents/Resources/gstreamer/macos-arm64/." assets/gstreamer/macos-arm64/
  hdiutil detach "$MOUNT_DIR" 2>/dev/null || diskutil eject "$MOUNT_DIR" 2>/dev/null || true
  rm -rf "$MOUNT_DIR"
fi
# WebRTC stack (webrtc/dtls/nice/srtp) is not part of the upstream release
# runtime. Add it from a local Homebrew prefix when available (1.28.x plugins
# are ABI-compatible with the bundled 1.28.7 core); the bundling script
# rewrites all Homebrew paths to @rpath so the DMG stays self-contained.
if [[ ! -f "assets/gstreamer/macos-arm64/lib/gstreamer-1.0/libgstwebrtc.dylib" ]]; then
  if [[ -x /opt/homebrew/bin/brew && -f /opt/homebrew/lib/gstreamer-1.0/libgstwebrtc.dylib ]]; then
    echo "==> Adding WebRTC plugins to bundled GStreamer from Homebrew..."
    brew list --versions libnice-gstreamer >/dev/null 2>&1 || brew install libnice-gstreamer
    python3 scripts/prepare-webrtc-gstreamer.py /opt/homebrew arm64 \
      libgio-2.0.0.dylib libglib-2.0.0.dylib libgobject-2.0.0.dylib \
      libgmodule-2.0.0.dylib libgthread-2.0.0.dylib libintl.8.dylib
  else
    echo "==> WARNING: bundled GStreamer has no WebRTC plugins and no Homebrew GStreamer found; WebRTC passthrough will be disabled at runtime."
  fi
fi
if [[ "$TARGET_ARCH" != arm64 ]]; then
  GST_VERSION="$(cat assets/gstreamer/macos-arm64/version.txt | head -1 | sed 's/[^0-9.]*//g')"
  # The bundled patched applemedia plugin currently has only an ARM slice.
  if ! lipo -verify_arch x86_64 assets/gstreamer/macos-arm64/lib/gstreamer-1.0/libgstapplemedia.dylib 2>/dev/null; then
    GST_VERSION="${GST_VERSION:-1.28.7}"
    official="$RUNTIME_CACHE/gst-complete"
    if [[ ! -d "$official" ]]; then
      curl -fL --retry 2 --max-time 180 "https://gstreamer.freedesktop.org/data/pkg/osx/$GST_VERSION/gstreamer-1.0-$GST_VERSION-universal.pkg" -o "$RUNTIME_CACHE/gstreamer-complete.pkg"
      extraction="$(mktemp -d "$RUNTIME_CACHE/gst-extract.XXXXXX")"
      pkgutil --expand-full "$RUNTIME_CACHE/gstreamer-complete.pkg" "$extraction/runtime"
      mv "$extraction/runtime" "$official"
      rmdir "$extraction"
    fi
    python3 scripts/prepare-intel-gstreamer.py "$official" "$RUNTIME_CACHE/extra"
    MACPLAY_APPLEMEDIA_UNIVERSAL="$RUNTIME_CACHE/extra/lib/gstreamer-1.0/libgstapplemedia.dylib"
    MACPLAY_GSTREAMER_EXTRA="$RUNTIME_CACHE/extra"
  fi
fi
