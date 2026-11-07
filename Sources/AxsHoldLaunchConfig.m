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
    if (!(threshold > 0.05)) threshold = 0.05;
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
