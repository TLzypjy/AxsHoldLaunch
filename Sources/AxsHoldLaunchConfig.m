#import "AxsHoldLaunchConfig.h"
#import "AxsHoldLaunchPreferences.h"

// defined in AXSRingEngine.xm; clears the per-container exclusion cache so a
// changed exclusion list takes effect without recreating floating windows
extern void axs_ring_configChanged(void);

@interface AxsHoldLaunchConfig ()
@property (atomic, copy) NSDictionary *snapshot;
@property (atomic, copy) NSDictionary *theirSnapshot;   // com.susudear.screencoreprefs
@property (nonatomic, strong) dispatch_queue_t reloadQueue;
@end

static void axs_holdlaunch_preferencesDidChange(CFNotificationCenterRef center, void *observer,
                                                CFStringRef name, const void *object, CFDictionaryRef info) {
    AxsHoldLaunchConfig *config = (__bridge AxsHoldLaunchConfig *)observer;
    dispatch_async(config.reloadQueue, ^{
        [config axs_holdlaunch_reload];
    });
}

static void axs_holdlaunch_theirPrefsDidChange(CFNotificationCenterRef center, void *observer,
                                               CFStringRef name, const void *object, CFDictionaryRef info) {
    // ScreenCore 自己的设置保存通知: 光圈设置跟它的域走
    AxsHoldLaunchConfig *config = (__bridge AxsHoldLaunchConfig *)observer;
    dispatch_async(config.reloadQueue, ^{
        [config axs_holdlaunch_reload];
    });
}

@implementation AxsHoldLaunchConfig

+ (instancetype)axs_holdlaunch_shared {
    static AxsHoldLaunchConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _reloadQueue = dispatch_queue_create("com.axs.holdlaunch.preferences", DISPATCH_QUEUE_SERIAL);
        [self axs_holdlaunch_reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, axs_holdlaunch_preferencesDidChange,
            (__bridge CFStringRef)AxsHoldLaunchPreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // ScreenCore 自己的设置保存通知: 光圈设置跟随它的域
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, axs_holdlaunch_theirPrefsDidChange,
            CFSTR("com.susudear.screencoreprefs/saved"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // Close the window between the first read and observer registration.
        dispatch_async(_reloadQueue, ^{ [self axs_holdlaunch_reload]; });
    }
    return self;
}

- (NSDictionary *)axs_holdlaunch_theirSnapshot {
    return self.theirSnapshot ?: @{};
}

- (id)axs_holdlaunch_theirValueForKey:(NSString *)key defaultValue:(id)defaultValue {
    id value = [self axs_holdlaunch_theirSnapshot objectForKey:key];
    return value ?: defaultValue;
}

- (void)axs_holdlaunch_reload {
    NSArray *oldExclusions = [self axs_holdlaunch_ringExcludedApplications];
    self.snapshot = axs_holdlaunch_readPreferences();
    // ScreenCore 原装域: 直读它的 plist 文件 (PS 写入 + cfprefsd 落盘)
    NSString *theirPath = axs_holdlaunch_theirPreferencesPath();
    NSDictionary *their = theirPath.length > 0 ? [NSDictionary dictionaryWithContentsOfFile:theirPath] : nil;
    self.theirSnapshot = [their isKindOfClass:[NSDictionary class]] ? their : @{};
    NSArray *newExclusions = [self axs_holdlaunch_ringExcludedApplications];
    if (![oldExclusions isEqualToArray:newExclusions]) {
        axs_ring_configChanged();
    }
}

- (id)axs_holdlaunch_valueForKey:(NSString *)key defaultValue:(id)defaultValue {
    return self.snapshot[key] ?: defaultValue;
}

- (BOOL)axs_holdlaunch_isEnabled {
    id value = [self axs_holdlaunch_valueForKey:@"HoldPressEnabled" defaultValue:@NO];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

- (double)axs_holdlaunch_threshold {
    id value = [self axs_holdlaunch_valueForKey:@"HoldPressThreshold" defaultValue:@1.0];
    double threshold = [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 1.0;
    if (!(threshold >= 0.2)) threshold = 0.2;
    if (threshold > 5.0) threshold = 5.0;
    return threshold;
}

- (BOOL)axs_holdlaunch_reverse {
    id value = [self axs_holdlaunch_valueForKey:@"HoldPressReverse" defaultValue:@NO];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

#pragma mark - ScreenCore 原装域 (光圈设置)

- (BOOL)axs_holdlaunch_isTheirRingEnabled {
    id value = [self axs_holdlaunch_theirValueForKey:@"splitWindowRingEnabled" defaultValue:@NO];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

- (BOOL)axs_holdlaunch_isTheirMiniRingEnabled {
    id value = [self axs_holdlaunch_theirValueForKey:@"splitMiniWindowRingEnabled" defaultValue:@NO];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

- (BOOL)axs_holdlaunch_isTheirRingCustomEnabled {
    id value = [self axs_holdlaunch_theirValueForKey:@"splitWindowRingCustomEnabled" defaultValue:@NO];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

- (NSString *)axs_holdlaunch_isTheirRingColor {
    id value = [self axs_holdlaunch_theirValueForKey:@"splitWindowRingColor" defaultValue:@"#34A1FF"];
    return [value isKindOfClass:[NSString class]] ? value : @"#34A1FF";
}

- (BOOL)axs_holdlaunch_isTheirGlowEnabled {
    id value = [self axs_holdlaunch_theirValueForKey:@"splitWindowGlowEnabled" defaultValue:@NO];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

- (BOOL)axs_holdlaunch_isTheirGlowCustomEnabled {
    id value = [self axs_holdlaunch_theirValueForKey:@"splitWindowGlowCustomEnabled" defaultValue:@NO];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

- (NSString *)axs_holdlaunch_isTheirGlowColor {
    id value = [self axs_holdlaunch_theirValueForKey:@"splitWindowGlowColor" defaultValue:@"#FFFFFF"];
    return [value isKindOfClass:[NSString class]] ? value : @"#FFFFFF";
}

- (NSArray *)axs_holdlaunch_ringExcludedApplications {
    id value = [self axs_holdlaunch_theirValueForKey:@"splitWindowRingExcludedApplications" defaultValue:@[]];
    if ([value isKindOfClass:[NSArray class]]) return value;
    // SCFilteredApplicationListMultiSelectionController may store a bundle->BOOL map
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableArray *enabled = [NSMutableArray array];
        for (NSString *bundle in value) {
            NSNumber *on = value[bundle];
            if ([on isKindOfClass:[NSNumber class]] && [on boolValue]) [enabled addObject:bundle];
        }
        return enabled;
    }
    return @[];
}

- (double)axs_holdlaunch_splitWindowCornerRadius {
    id value = [self axs_holdlaunch_theirValueForKey:@"splitWindowCornerRadius" defaultValue:@47.0];
    double v = [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 47.0;
    if (v < 0) v = 0;
    if (v > 60) v = 60;
    return v;
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
