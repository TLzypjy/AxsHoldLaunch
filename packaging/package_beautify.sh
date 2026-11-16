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

VERSION="2.0.5+beautify.26"
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
    echo " 接通光圈自定义取色：颜色行/色块点击打开系统取色器（支持 alpha，写回 #RRGGBB(AA) 即时刷新存活环）；自定义开关 ON=所选单色，OFF=彩虹跑马灯。"
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
check "dylib has color picker" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'UIColorPickerViewController'"
check "dylib has picker finish handler" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'colorPickerControllerDidFinish:'"
check "dylib has no overlay engine marker" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'ring engine start') -eq 0"
check "dylib has no overlay window marker" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'ring window frame') -eq 0"
check "dylib has no overlay window class" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'AXSRingOverlayWindow') -eq 0"
check "dylib has no sc_sessionDidBeginHosting selector" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'sc_sessionDidBeginHosting:') -eq 0"
check "dylib has no sc_closeSession selector" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'sc_closeSession:') -eq 0"
check "dylib has no sc_dockSession selector" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'sc_dockSession:fromCorner:') -eq 0"
check "dylib has no sc_sessionForContainerView selector" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'sc_sessionForContainerView:') -eq 0"
check "dylib has ring log path" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'Documents/sc-ring.log'"
check "dylib has zero-session-hook startup log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring hooks ring=0 sessionHooks=0 layout='"
check "dylib has scan attach log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring attach: scan container=%p'"
check "dylib has scan detach log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring detach: scan container=%p'"
check "dylib has displayLink driver" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'AXSRingLinkDriver'"
check "dylib has whole-frame mask probe" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring probe: mask class=%@ bbox=%@ radius=%.1f'"
check "dylib has radius conversion attach fields" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'rRing=%.1f source=%@ curve=%@'"
check "dylib has mount layer attach fields" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'realFrame=%@ convRect=%@ corner=%.1f'"
check "dylib has real clip finder" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'realCorner'"
check "dylib has layout hook install log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring layout hook installed on SCFloatingContainerView'"
check "dylib has tree probe" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring tree: window=%@ frame=%@ bounds=%@'"
check "dylib has no AXSRingFrame class" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'AXSRingFrame') -eq 0"
check "dylib has rotation marquee (z keypath)" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'transform.rotation.z'"
check "dylib has no fullscreen selectors" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -Ec 'sc_handleFullscreenTap|sc_floatingContainerViewDidRequestFullscreen|promoteSceneToFullscreen') -eq 0"
check "dylib has holdpress log in Documents" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'Documents/AxsHoldLaunch.log'"
check "dylib has no Caches log path left" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'Caches/AxsHoldLaunch.log') -eq 0"

# 7) package + verify
DEB="$OUT/com.susudear.screencore_${VERSION}_iphoneos-arm64.deb"
dpkg-deb --root-owner-group -b "$PKG" "$DEB"
echo "=== dpkg-deb -I ==="
dpkg-deb -I "$DEB"
echo "=== dpkg-deb -c ==="
dpkg-deb -c "$DEB"
echo "=== packaged: $DEB ==="
ls -la "$OUT"
