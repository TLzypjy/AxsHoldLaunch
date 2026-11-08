#import "AxsHoldLaunchConfig.h"
#import "AxsHoldLaunchPreferences.h"

@interface AxsHoldLaunchConfig ()
@property (atomic, copy) NSDictionary *snapshot;
@property (nonatomic, strong) dispatch_queue_t reloadQueue;
@end

static void axs_holdlaunch_preferencesDidChange(CFNotificationCenterRef center, void *observer,
                                                CFStringRef name, const void *object, CFDictionaryRef info) {
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
        // Close the window between the first read and observer registration.
        dispatch_async(_reloadQueue, ^{ [self axs_holdlaunch_reload]; });
    }
    return self;
}

- (void)axs_holdlaunch_reload {
    self.snapshot = axs_holdlaunch_readPreferences();
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

- (BOOL)axs_holdlaunch_glowFrameEnabled {
    id value = [self axs_holdlaunch_valueForKey:@"GlowFrameEnabled" defaultValue:@YES];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
}

- (BOOL)axs_holdlaunch_glowFrameCustom {
    id value = [self axs_holdlaunch_valueForKey:@"GlowFrameCustom" defaultValue:@NO];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

- (NSString *)axs_holdlaunch_glowFrameColor {
    id value = [self axs_holdlaunch_valueForKey:@"GlowFrameColor" defaultValue:@"#34A1FF"];
    return [value isKindOfClass:[NSString class]] ? value : @"#34A1FF";
}

- (BOOL)axs_holdlaunch_glowHaloEnabled {
    id value = [self axs_holdlaunch_valueForKey:@"GlowHaloEnabled" defaultValue:@YES];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
}

- (BOOL)axs_holdlaunch_glowHaloCustom {
    id value = [self axs_holdlaunch_valueForKey:@"GlowHaloCustom" defaultValue:@NO];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

- (NSString *)axs_holdlaunch_glowHaloColor {
    id value = [self axs_holdlaunch_valueForKey:@"GlowHaloColor" defaultValue:@"#FFFFFF"];
    return [value isKindOfClass:[NSString class]] ? value : @"#FFFFFF";
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
