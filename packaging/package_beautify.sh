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

VERSION="2.0.5+beautify.14"
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
    echo " 环重构（对齐 TrollOpen）：零会话 hook，0.5s 扫描发现浮窗并挂环（container.layer 子层，物理跟随），圆角取 overlay/region 的 CAShapeLayer mask 半径，config 兜底。"
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

# 6) sanity checks before packing (labeled, so a failure says which one)
check() {
    # check <label> <cmd...>
    label=$1; shift
    if ! "$@"; then
        echo "ERROR: sanity check failed: $label" >&2
        exit 1
    fi
}
check "filter has springboard" sh -c "plutil -p '$DYLIB_DIR/AxsHoldLaunch.plist' | grep -q 'com.apple.springboard'"
check "filter has preferences" sh -c "plutil -p '$DYLIB_DIR/AxsHoldLaunch.plist' | grep -q 'com.apple.Preferences'"
check "plist has beautify switches" sh -c "plutil -p '$BUNDLE/SplitSettings.plist' | grep -q 'splitBeautifyRingFrameEnabled'"
check "plist has beautify sliders" sh -c "plutil -p '$BUNDLE/SplitSettings.plist' | grep -q 'splitBeautifyGlowRadius'"
check "zh strings localized" sh -c "plutil -p '$BUNDLE/zh-Hans.lproj/SplitSettings.strings' | grep -q '美化'"
check "en strings localized" sh -c "plutil -p '$BUNDLE/en.lproj/SplitSettings.strings' | grep -q 'Beautify'"
check "dylib has beautify color key" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'splitBeautifyRingFrameColor'"
# the alert literal is compiled as UTF-16LE (__ustring), so grep its hex
check "dylib has alert message" sh -c "xxd -p '$DYLIB_DIR/AxsHoldLaunch.dylib' | tr -d '\n' | grep -q 'e58b9f52fd801a5c2a679e5bb073'"
check "dylib has no overlay engine marker" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'ring engine start') -eq 0"
check "dylib has no overlay window marker" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'ring window frame') -eq 0"
check "dylib has no overlay window class" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'AXSRingOverlayWindow') -eq 0"
check "dylib has no sc_sessionDidBeginHosting selector" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'sc_sessionDidBeginHosting:') -eq 0"
check "dylib has no sc_closeSession selector" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'sc_closeSession:') -eq 0"
check "dylib has no sc_dockSession selector" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'sc_dockSession:fromCorner:') -eq 0"
check "dylib has no sc_sessionForContainerView selector" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'sc_sessionForContainerView:') -eq 0"
check "dylib has ring log path" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'Documents/sc-ring.log'"
check "dylib has zero-hook startup log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring hooks ring=0 sessionHooks=0 holdPress=1'"
check "dylib has scan attach log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring attach: scan container=%p'"
check "dylib has scan detach log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring detach: scan container=%p'"
check "dylib has scan update log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring update: scan container=%p'"
check "dylib has probe container" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring probe: container class=%@'"
check "dylib has probe mask" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring probe: mask class=%@ path=%@ radius=%.1f'"
check "dylib has no AXSRingFrame class" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'AXSRingFrame') -eq 0"
check "dylib has no transform rotation marquee" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'transform.rotation.z') -eq 0"
check "dylib has no fullscreen selectors" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -Ec 'sc_handleFullscreenTap|sc_floatingContainerViewDidRequestFullscreen|promoteSceneToFullscreen') -eq 0"
check "dylib has reentry gate" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring reentry blocked: %s'"
check "dylib has holdpress log in Documents" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'Documents/AxsHoldLaunch.log'"
check "dylib has no Caches log path left" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'Caches/AxsHoldLaunch.log') -eq 0"
check "dylib has handover log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring handover: session=%p -> %p hostLayer=%p'"

# 7) package + verify
DEB="$OUT/com.susudear.screencore_${VERSION}_iphoneos-arm64.deb"
dpkg-deb --root-owner-group -b "$PKG" "$DEB"
echo "=== dpkg-deb -I ==="
dpkg-deb -I "$DEB"
echo "=== dpkg-deb -c ==="
dpkg-deb -c "$DEB"
echo "=== packaged: $DEB ==="
ls -la "$OUT"
