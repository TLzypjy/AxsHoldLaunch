#pragma once

#import <Foundation/Foundation.h>

#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#else
#import <rootless.h>
#endif

static inline NSString *axs_holdlaunch_resourcePath(NSString *rootfsPath) {
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
    return jbroot(rootfsPath);
#else
    return ROOT_PATH_NS_VAR(rootfsPath);
#endif
}

static inline NSString *axs_holdlaunch_preferencesPath(void) {
    NSString *path = @"/var/mobile/Library/Preferences/com.axs.holdlaunch.plist";
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
    return jbroot(path);
#else
    // Mobile user preferences do not use the rootless installation prefix.
    return path;
#endif
}

// ScreenCore 原装设置域 (光圈设置读这里)
static inline NSString *axs_holdlaunch_theirPreferencesPath(void) {
    NSString *path = @"/var/mobile/Library/Preferences/com.susudear.screencoreprefs.plist";
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
    return jbroot(path);
#else
    return path;
#endif
}
