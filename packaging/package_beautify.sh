#!/bin/sh
# Repackage the clean 2.0.5+holdpress.1 base with the beautify panel overlay
# (SplitSettings.plist + two SplitSettings.strings) and the freshly built
# AxsHoldLaunch.dylib, then verify with dpkg-deb.
#
# Inputs:
#   AXS_DYLIB  - path to the rootless AxsHoldLaunch.dylib from the CI build
# Output:
#   out/com.susudear.screencore_2.0.5+beautify.1_iphoneos-arm64.deb
set -eu
cd "$(dirname "$0")"

VERSION="2.0.5+beautify.1"
BASE_DEB="base/com.susudear.screencore_2.0.5+holdpress.1.deb"
OUT="out"
PKG="$OUT/pkg"

if [ -z "${AXS_DYLIB:-}" ] || [ ! -f "$AXS_DYLIB" ]; then
    echo "ERROR: AXS_DYLIB not set or missing" >&2
    exit 1
fi
if [ ! -f "$BASE_DEB" ]; then
    echo "ERROR: base deb missing: $BASE_DEB" >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$PKG/DEBIAN"

# 1) baseline data + control (ScreenCore dylibs and the prefs bundle binary
#    stay exactly as shipped by 2.0.5+holdpress.1)
dpkg-deb -x "$BASE_DEB" "$PKG"
dpkg-deb -e "$BASE_DEB" "$PKG/DEBIAN"
rm -f "$PKG/DEBIAN/control"

# 2) overlay: the three patched files in ScreenCorePrefs.bundle
BUNDLE="$PKG/var/jb/Library/PreferenceBundles/ScreenCorePrefs.bundle"
cp overlay/SplitSettings.plist                     "$BUNDLE/SplitSettings.plist"
cp overlay/zh-Hans.lproj/SplitSettings.strings     "$BUNDLE/zh-Hans.lproj/SplitSettings.strings"
cp overlay/en.lproj/SplitSettings.strings          "$BUNDLE/en.lproj/SplitSettings.strings"

# 3) our module dylib from this CI build; filter plist stays the baseline's
DYLIB_DIR="$PKG/var/jb/Library/MobileSubstrate/DynamicLibraries"
cp "$AXS_DYLIB" "$DYLIB_DIR/AxsHoldLaunch.dylib"

# 4) control: field lines only, clean Description continuation
SIZE=$(find "$PKG" -type f -not -path "*/DEBIAN/*" -exec stat -f%z {} + | awk '{s+=$1} END {printf "%d", int(s/1024)+1}')
{
    echo "Package: com.susudear.screencore"
    echo "Name: ScreenCore"
    echo "Description: 分屏而已"
    echo " 在分屏设置的「启动」与「外观」之间新增「美化」分组（本轮仅显示面板，不实现功能）。"
    echo "Maintainer: SuSu"
    echo "Author: SuSu"
    echo "Icon: https://repo.susubaby.cn/icons/ScreenCore.png"
    echo "Section: Tweaks"
    echo "Depends: mobilesubstrate, preferenceloader, com.opa334.altlist"
    echo "Architecture: iphoneos-arm64"
    echo "Version: $VERSION"
    echo "Installed-Size: $SIZE"
} > "$PKG/DEBIAN/control"

# 5) permissions: dirs 0755, files 0644, dylibs + usr/libexec binaries 0755
find "$PKG" -type d -exec chmod 755 {} +
find "$PKG" -type f -exec chmod 644 {} +
find "$PKG" -name "*.dylib" -exec chmod 755 {} +
chmod 755 "$PKG/var/jb/usr/libexec/screencore-userspace-reboot"

# 6) sanity checks before packing
plutil -p "$DYLIB_DIR/AxsHoldLaunch.plist" | grep -q "com.apple.springboard"
plutil -p "$DYLIB_DIR/AxsHoldLaunch.plist" | grep -q "com.apple.Preferences"
plutil -p "$BUNDLE/SplitSettings.plist" | grep -q "splitBeautifyRingFrameEnabled"
plutil -p "$BUNDLE/SplitSettings.plist" | grep -q "splitBeautifyGlowRadius"
plutil -p "$BUNDLE/zh-Hans.lproj/SplitSettings.strings" | grep -q "美化"
plutil -p "$BUNDLE/en.lproj/SplitSettings.strings" | grep -q "Beautify"
strings -a "$DYLIB_DIR/AxsHoldLaunch.dylib" | grep -q "splitBeautifyRingFrameColor"
LC_ALL=C grep -q "该功能尚未实现" "$DYLIB_DIR/AxsHoldLaunch.dylib"

# 7) package + verify
DEB="$OUT/com.susudear.screencore_${VERSION}_iphoneos-arm64.deb"
dpkg-deb --root-owner-group -b "$PKG" "$DEB"
echo "=== dpkg-deb -I ==="
dpkg-deb -I "$DEB"
echo "=== dpkg-deb -c ==="
dpkg-deb -c "$DEB"
echo "=== packaged: $DEB ==="
ls -la "$OUT"
