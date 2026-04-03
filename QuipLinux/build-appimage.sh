#!/bin/bash
set -euo pipefail

# Build Quip Linux as an AppImage
# Run this on your openSUSE Tumbleweed machine
#
# Prerequisites:
#   sudo zypper install gtk4-devel libadwaita-devel gcc pkg-config xdotool wmctrl
#   cargo (install via rustup: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Building release binary..."
cargo build --release

echo "==> Setting up AppDir..."
APP_DIR="$SCRIPT_DIR/Quip.AppDir"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/usr/bin"
mkdir -p "$APP_DIR/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$APP_DIR/usr/share/applications"

# Copy binary
cp target/release/quip-linux "$APP_DIR/usr/bin/quip"

# Copy icon (use the Mac icon, it's a standard PNG)
if [ -f "../QuipMac/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" ]; then
    cp "../QuipMac/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" \
       "$APP_DIR/usr/share/icons/hicolor/256x256/apps/quip.png"
    cp "../QuipMac/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" \
       "$APP_DIR/quip.png"
else
    echo "Warning: icon not found, AppImage will have no icon"
fi

# Desktop file
cat > "$APP_DIR/quip.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Quip
Comment=Voice remote for Claude Code
Exec=quip
Icon=quip
Categories=Utility;Development;
Terminal=false
DESKTOP
cp "$APP_DIR/quip.desktop" "$APP_DIR/usr/share/applications/quip.desktop"

# AppRun script
cat > "$APP_DIR/AppRun" <<'APPRUN'
#!/bin/bash
SELF="$(readlink -f "$0")"
APPDIR="$(dirname "$SELF")"
export PATH="$APPDIR/usr/bin:$PATH"
exec "$APPDIR/usr/bin/quip" "$@"
APPRUN
chmod +x "$APP_DIR/AppRun"

# Download appimagetool if not present
TOOL="$SCRIPT_DIR/appimagetool"
if [ ! -f "$TOOL" ]; then
    echo "==> Downloading appimagetool..."
    ARCH="$(uname -m)"
    curl -sSL "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${ARCH}.AppImage" \
         -o "$TOOL"
    chmod +x "$TOOL"
fi

echo "==> Building AppImage..."
ARCH="$(uname -m)" "$TOOL" "$APP_DIR" "Quip-${ARCH}.AppImage"

echo ""
echo "==> Done! AppImage created: Quip-$(uname -m).AppImage"
echo "    chmod +x Quip-$(uname -m).AppImage && ./Quip-$(uname -m).AppImage"
