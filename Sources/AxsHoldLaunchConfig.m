#import "AxsHoldLaunchConfig.h"
#import "AxsHoldLaunchPreferences.h"

// defined in AXSRingEngine.xm; clears ring caches when their prefs change so
// style/exclusion updates take effect without recreating floating windows
extern void axs_ring_configChanged(void);
extern void axs_ring_engine_wake(void);

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
    id value = [[self axs_holdlaunch_theirSnapshot] objectForKey:key];
    return value ?: defaultValue;
}

- (void)axs_holdlaunch_reload {
    NSDictionary *oldTheir = [self axs_holdlaunch_theirSnapshot];
    self.snapshot = axs_holdlaunch_readPreferences();
    // ScreenCore 原装域: 走 cfprefsd 实时读取。之前直读 plist 文件，
    // cfprefsd 异步落盘有延迟，导致滑条/颜色调整不实时、选色不生效。
    NSUserDefaults *theirDefaults = [[NSUserDefaults alloc] initWithSuiteName:AxsHoldLaunchTheirDomain];
    [theirDefaults synchronize];
    NSDictionary *their = [theirDefaults persistentDomainForName:AxsHoldLaunchTheirDomain];
    if (![their isKindOfClass:[NSDictionary class]] || their.count == 0) {
        NSString *theirPath = axs_holdlaunch_theirPreferencesPath();
        their = theirPath.length > 0 ? [NSDictionary dictionaryWithContentsOfFile:theirPath] : nil;
    }
    self.theirSnapshot = [their isKindOfClass:[NSDictionary class]] ? their : @{};
    if (![oldTheir isEqualToDictionary:[self axs_holdlaunch_theirSnapshot]]) {
        axs_ring_configChanged();
        axs_ring_engine_wake();
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

#pragma mark - 原装域读取工具

static double axs_theirDouble(AxsHoldLaunchConfig *config, NSString *key,
                              double fallback, double lo, double hi) {
    id value = [config axs_holdlaunch_theirValueForKey:key defaultValue:@(fallback)];
    double v = [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : fallback;
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    return v;
}

static BOOL axs_theirBool(AxsHoldLaunchConfig *config, NSString *key, BOOL fallback) {
    id value = [config axs_holdlaunch_theirValueForKey:key defaultValue:@(fallback)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}

static NSString *axs_theirString(AxsHoldLaunchConfig *config, NSString *key, NSString *fallback) {
    id value = [config axs_holdlaunch_theirValueForKey:key defaultValue:fallback];
    return [value isKindOfClass:[NSString class]] ? value : fallback;
}

#pragma mark - 应用组

- (BOOL)axs_holdlaunch_isTheirRingEnabled {
    return axs_theirBool(self, @"splitWindowRingEnabled", YES);
}

- (BOOL)axs_holdlaunch_isTheirMiniRingEnabled {
    return axs_theirBool(self, @"splitMiniWindowRingEnabled", NO);
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
    return axs_theirDouble(self, @"splitWindowCornerRadius", 47.0, 0, 60);
}

#pragma mark - 外框组

- (double)axs_holdlaunch_ringFrameWidth {
    return axs_theirDouble(self, @"splitWindowRingFrameWidth", 2.0, 0, 30);
}

- (double)axs_holdlaunch_ringFrameAlpha {
    return axs_theirDouble(self, @"splitWindowRingFrameAlpha", 0.5, 0, 1);
}

- (double)axs_holdlaunch_ringFrameCornerRadius {
    return axs_theirDouble(self, @"splitWindowRingCornerRadius", 0.0, 0, 60);
}

- (BOOL)axs_holdlaunch_ringFrameCustomEnabled {
    return axs_theirBool(self, @"splitWindowRingFrameCustomEnabled", NO);
}

- (NSString *)axs_holdlaunch_ringFrameColor {
    return axs_theirString(self, @"splitWindowRingFrameColor", @"#34A1FF");
}

- (BOOL)axs_holdlaunch_ringFrameRandomColor {
    return axs_theirBool(self, @"splitWindowRingFrameRandomColor", NO);
}

#pragma mark - 光晕组

- (BOOL)axs_holdlaunch_ringGlowEnabled {
    return axs_theirBool(self, @"splitWindowGlowEnabled", YES);
}

- (double)axs_holdlaunch_ringGlowRange {
    return axs_theirDouble(self, @"splitWindowGlowRange", 6.0, 0, 50);
}

- (double)axs_holdlaunch_ringGlowOffsetY {
    return axs_theirDouble(self, @"splitWindowGlowOffsetY", 0.0, -50, 50);
}

- (double)axs_holdlaunch_ringGlowOffsetX {
    return axs_theirDouble(self, @"splitWindowGlowOffsetX", 0.0, -50, 50);
}

#pragma mark - 内圈组

- (BOOL)axs_holdlaunch_ringInnerEnabled {
    return axs_theirBool(self, @"splitWindowRingInnerEnabled", NO);
}

- (BOOL)axs_holdlaunch_ringInnerCustomEnabled {
    return axs_theirBool(self, @"splitWindowRingInnerCustomEnabled", NO);
}

- (double)axs_holdlaunch_ringInnerWidth {
    return axs_theirDouble(self, @"splitWindowRingInnerWidth", 2.0, 1, 30);
}

- (NSString *)axs_holdlaunch_ringInnerColor {
    return axs_theirString(self, @"splitWindowRingInnerColor", @"#CBD0FF");
}

- (BOOL)axs_holdlaunch_ringInnerRandomColor {
    return axs_theirBool(self, @"splitWindowRingInnerRandomColor", NO);
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
