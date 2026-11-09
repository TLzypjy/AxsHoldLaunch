#import "AxsHoldLaunchConfig.h"
#import "AxsHoldLaunchPreferences.h"

// defined in AxsBeautifyFrame.xm: 光圈外框样式/开关变化后重建图层
extern void axs_bf_configChanged(void);
extern void axs_bf_engine_wake(void);

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
    // ScreenCore 自己的设置保存通知：美化行跟随它的域
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
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, axs_holdlaunch_theirPrefsDidChange,
            (__bridge CFStringRef)AxsHoldLaunchTheirPrefsSaved, NULL,
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
    // ScreenCore 原装域：走 cfprefsd 实时读取（文件落盘有延迟，直读文件会让
    // 滑条/颜色的调整不实时）；文件仅在域为空时兜底。
    NSUserDefaults *theirDefaults = [[NSUserDefaults alloc] initWithSuiteName:AxsHoldLaunchTheirDomain];
    [theirDefaults synchronize];
    NSDictionary *their = [theirDefaults persistentDomainForName:AxsHoldLaunchTheirDomain];
    if (![their isKindOfClass:[NSDictionary class]] || their.count == 0) {
        NSString *theirPath = axs_holdlaunch_theirPreferencesPath();
        their = theirPath.length > 0 ? [NSDictionary dictionaryWithContentsOfFile:theirPath] : nil;
    }
    self.theirSnapshot = [their isKindOfClass:[NSDictionary class]] ? their : @{};
    if (![oldTheir isEqualToDictionary:[self axs_holdlaunch_theirSnapshot]]) {
        axs_bf_configChanged();
    }
    axs_bf_engine_wake();
}

#pragma mark - 美化 · 光圈外框

static BOOL axs_theirBool(AxsHoldLaunchConfig *config, NSString *key, BOOL fallback) {
    id value = [config axs_holdlaunch_theirValueForKey:key defaultValue:@(fallback)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}

static NSString *axs_theirString(AxsHoldLaunchConfig *config, NSString *key, NSString *fallback) {
    id value = [config axs_holdlaunch_theirValueForKey:key defaultValue:fallback];
    return [value isKindOfClass:[NSString class]] ? value : fallback;
}

static double axs_theirDouble(AxsHoldLaunchConfig *config, NSString *key,
                              double fallback, double lo, double hi) {
    id value = [config axs_holdlaunch_theirValueForKey:key defaultValue:@(fallback)];
    double v = [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : fallback;
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    return v;
}

- (BOOL)axs_holdlaunch_bfFrameEnabled {
    return axs_theirBool(self, @"splitWindowRingFrameEnabled", NO);
}

- (BOOL)axs_holdlaunch_bfCustomEnabled {
    return axs_theirBool(self, @"splitWindowRingFrameCustomEnabled", NO);
}

- (NSString *)axs_holdlaunch_bfFrameColor {
    return axs_theirString(self, @"splitWindowRingFrameColor", @"#93E3FD");
}

- (double)axs_holdlaunch_bfFrameWidth {
    return axs_theirDouble(self, @"splitWindowRingFrameWidth", 3.0, 0.5, 30);
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

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
