#pragma once

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import "AxsHoldLaunchPaths.h"

static NSString * const AxsHoldLaunchPreferencesDomain = @"com.axs.holdlaunch";
static NSString * const AxsHoldLaunchPreferencesChanged = @"com.axs.holdlaunch.preferences-changed";

// ScreenCore's own preference domain: the ring/glow rows in its settings
// bundle read/write here, and the SpringBoard side listens for its save ping.
static NSString * const AxsHoldLaunchTheirDomain = @"com.susudear.screencoreprefs";
static NSString * const AxsHoldLaunchTheirPrefsSaved = @"com.susudear.screencoreprefs/saved";

// Write one key into ScreenCore's domain via cfprefsd (cross-process safe),
// then post the same Darwin notification its own specifier cells post.
static inline BOOL axs_holdlaunch_writeTheirPreference(NSString *key, id value) {
    if (key.length == 0) return NO;
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                            (__bridge CFTypeRef)value,
                            (__bridge CFStringRef)AxsHoldLaunchTheirDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)AxsHoldLaunchTheirDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)AxsHoldLaunchTheirPrefsSaved, NULL, NULL, true);
    return YES;
}

static inline NSDictionary *axs_holdlaunch_readPreferences(void) {
    NSString *path = axs_holdlaunch_preferencesPath();
    NSDictionary *values = path.length > 0 ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    if ([values isKindOfClass:[NSDictionary class]]) {
        return values;
    }
    // Compatibility fallback, not a second writable file location.
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:AxsHoldLaunchPreferencesDomain];
    [defaults synchronize];
    return [defaults persistentDomainForName:AxsHoldLaunchPreferencesDomain] ?: @{};
}

// The injected specifier cells are the only callers allowed to write.
static inline BOOL axs_holdlaunch_writePreference(NSString *key, id value, NSError **error) {
    NSString *path = axs_holdlaunch_preferencesPath();
    if (key.length == 0 || path.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:AxsHoldLaunchPreferencesDomain code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"Invalid preference path or key"}];
        }
        return NO;
    }
    NSFileManager *manager = [NSFileManager defaultManager];
    NSMutableDictionary *values;
    if ([manager fileExistsAtPath:path]) {
        NSData *existing = [NSData dataWithContentsOfFile:path options:0 error:error];
        id decoded = existing ? [NSPropertyListSerialization propertyListWithData:existing
                         options:NSPropertyListMutableContainers format:NULL error:error] : nil;
        if (![decoded isKindOfClass:[NSDictionary class]]) {
            if (error && !*error) {
                *error = [NSError errorWithDomain:AxsHoldLaunchPreferencesDomain code:2
                                    userInfo:@{NSLocalizedDescriptionKey: @"Preferences are not a dictionary"}];
            }
            return NO;
        }
        values = [decoded mutableCopy];
    } else {
        values = [axs_holdlaunch_readPreferences() mutableCopy];
    }
    if (value) values[key] = value;
    else [values removeObjectForKey:key];
    if (![manager createDirectoryAtPath:[path stringByDeletingLastPathComponent]
            withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:values
                         format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error]) {
        return NO;
    }
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:AxsHoldLaunchPreferencesDomain];
    // Mirror the whole snapshot so cfprefsd cannot flush stale unrelated keys.
    [defaults setPersistentDomain:values forName:AxsHoldLaunchPreferencesDomain];
    [defaults synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)AxsHoldLaunchPreferencesChanged, NULL, NULL, true);
    return YES;
}
