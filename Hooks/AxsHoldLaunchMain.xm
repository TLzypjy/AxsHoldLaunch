#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AxsHoldLaunchConfig.h"
#import "AxsHoldLaunchPreferences.h"
#import "AxsHoldLaunchPrivate.h"

// ---------------------------------------------------------------------------
// SpringBoard side
//
// ScreenCore's ARC menu is tracked with these known selectors (binary is not
// obfuscated; classes are discovered at runtime because the owning class is
// not worth hardcoding). Dwell time = how long the finger stays on the
// currently selected menu icon before releasing:
//   dwell >= threshold -> fullscreen launch (reverse: split launch)
//   dwell <  threshold -> split launch     (reverse: fullscreen launch)
// ---------------------------------------------------------------------------

static NSTimeInterval axs_holdlaunch_now(void) {
    return [[NSDate date] timeIntervalSince1970];
}

// Main-thread gesture state; the hooks all run on the main thread.
static NSTimeInterval axs_arrivalTime = 0;        // when the current icon became selected
static NSString *axs_arrivalBundle = nil;         // bundle id selected at axs_arrivalTime
static NSString *axs_lastSeenBundle = nil;
static NSTimeInterval axs_lastTrackingActivity = 0;
static NSTimeInterval axs_pendingArmTime = 0;     // 0 = nothing pending
static NSTimeInterval axs_pendingDwell = -1;
static NSString *axs_pendingBundle = nil;

static IMP axs_origUpdateSelection = NULL;
static IMP axs_origSetSelectedBundle = NULL;
static IMP axs_origHandleSelected = NULL;
static IMP axs_origOpenTarget = NULL;
static IMP axs_origFinishTracking = NULL;

static void axs_holdlaunch_recordArrival(NSString *bundle) {
    if (![bundle isKindOfClass:[NSString class]] || bundle.length == 0) return;
    if ([bundle isEqualToString:axs_lastSeenBundle]) return;
    axs_lastSeenBundle = bundle;
    axs_arrivalBundle = bundle;
    axs_arrivalTime = axs_holdlaunch_now();
}

static void axs_holdlaunch_updateSelectionAtPoint(id self, SEL _cmd, CGPoint point) {
    ((void(*)(id, SEL, CGPoint))axs_origUpdateSelection)(self, _cmd, point);
    axs_lastTrackingActivity = axs_holdlaunch_now();
    if ([self respondsToSelector:@selector(selectedBundleIdentifier)]) {
        id bundle = ((id(*)(id, SEL))objc_msgSend)(self, @selector(selectedBundleIdentifier));
        axs_holdlaunch_recordArrival(bundle);
    }
}

static void axs_holdlaunch_setSelectedBundle(id self, SEL _cmd, id bundle) {
    ((void(*)(id, SEL, id))axs_origSetSelectedBundle)(self, _cmd, bundle);
    // Ignore programmatic writes far away from any menu tracking session.
    if (axs_holdlaunch_now() - axs_lastTrackingActivity > 5.0) return;
    axs_lastTrackingActivity = axs_holdlaunch_now();
    axs_holdlaunch_recordArrival(bundle);
}

static void axs_holdlaunch_handleSelected(id self, SEL _cmd, id bundle, id sourceFrame) {
    if ([[AxsHoldLaunchConfig axs_holdlaunch_shared] axs_holdlaunch_isEnabled]) {
        NSTimeInterval dwell = -1.0;
        if ([bundle isKindOfClass:[NSString class]]
            && [bundle isEqualToString:axs_arrivalBundle]
            && axs_arrivalTime > 0) {
            dwell = axs_holdlaunch_now() - axs_arrivalTime;
        }
        if (dwell >= 0.0 && dwell <= 30.0) {
            axs_pendingDwell = dwell;
            axs_pendingBundle = bundle;
            axs_pendingArmTime = axs_holdlaunch_now();
            NSLog(@"[AxsHoldLaunch] armed dwell=%.2f bundle=%@", dwell, bundle);
        }
    }
    ((void(*)(id, SEL, id, id))axs_origHandleSelected)(self, _cmd, bundle, sourceFrame);
}

static id axs_holdlaunch_openTarget(id self, SEL _cmd, id targetIdentifier, id transitionContext,
                                    id sourceRect, id gestureProfile, BOOL launchFullscreen) {
    BOOL fullscreen = launchFullscreen;
    if (axs_pendingDwell >= 0.0 && axs_holdlaunch_now() - axs_pendingArmTime <= 3.0) {
        BOOL matches = YES;
        if ([targetIdentifier isKindOfClass:[NSString class]] && axs_pendingBundle.length > 0
            && ![targetIdentifier isEqualToString:axs_pendingBundle]) {
            matches = NO;
        }
        if (matches) {
            AxsHoldLaunchConfig *config = [AxsHoldLaunchConfig axs_holdlaunch_shared];
            double threshold = [config axs_holdlaunch_threshold];
            BOOL reverse = [config axs_holdlaunch_reverse];
            fullscreen = reverse ? (axs_pendingDwell < threshold) : (axs_pendingDwell >= threshold);
            NSLog(@"[AxsHoldLaunch] override dwell=%.2f threshold=%.2f reverse=%d -> fullscreen=%d",
                  axs_pendingDwell, threshold, reverse, fullscreen);
        }
    }
    axs_pendingDwell = -1.0;
    axs_pendingArmTime = 0;
    return ((id(*)(id, SEL, id, id, id, id, BOOL))axs_origOpenTarget)(
        self, _cmd, targetIdentifier, transitionContext, sourceRect, gestureProfile, fullscreen);
}

static void axs_holdlaunch_finishTracking(id self, SEL _cmd) {
    ((void(*)(id, SEL))axs_origFinishTracking)(self, _cmd);
    axs_lastSeenBundle = nil;
    axs_arrivalBundle = nil;
    axs_arrivalTime = 0;
}

static NSArray<Class> *axs_holdlaunch_classesDeclaring(SEL selector) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return @[];
    NSMutableArray<Class> *result = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        // ScreenCore classes all start with SC / SCWS; limit the scan to them.
        const char *name = class_getName(cls);
        if (strncmp(name, "SC", 2) != 0) continue;
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        BOOL declared = NO;
        for (unsigned int m = 0; m < methodCount; m++) {
            if (method_getName(methods[m]) == selector) { declared = YES; break; }
        }
        free(methods);
        if (declared) [result addObject:cls];
    }
    free(classes);
    return result;
}

static NSUInteger axs_holdlaunch_hookSelector(SEL selector, IMP replacement, IMP *original) {
    NSUInteger hooked = 0;
    for (Class cls in axs_holdlaunch_classesDeclaring(selector)) {
        MSHookMessageEx(cls, selector, replacement, original);
        hooked++;
    }
    return hooked;
}

static void axs_holdlaunch_installSpringBoardHooks(void) {
    SEL selUpdate = NSSelectorFromString(AxsHoldLaunchSelUpdateSelection);
    SEL selSetBundle = NSSelectorFromString(AxsHoldLaunchSelSetSelectedBundle);
    SEL selHandle = NSSelectorFromString(AxsHoldLaunchSelHandleSelected);
    SEL selOpenTarget = NSSelectorFromString(AxsHoldLaunchSelOpenTarget);
    SEL selFinish = NSSelectorFromString(AxsHoldLaunchSelFinishTracking);

    NSUInteger updateCount = axs_holdlaunch_hookSelector(selUpdate, (IMP)axs_holdlaunch_updateSelectionAtPoint, &axs_origUpdateSelection);
    NSUInteger setBundleCount = axs_holdlaunch_hookSelector(selSetBundle, (IMP)axs_holdlaunch_setSelectedBundle, &axs_origSetSelectedBundle);
    NSUInteger handleCount = axs_holdlaunch_hookSelector(selHandle, (IMP)axs_holdlaunch_handleSelected, &axs_origHandleSelected);
    NSUInteger openCount = axs_holdlaunch_hookSelector(selOpenTarget, (IMP)axs_holdlaunch_openTarget, &axs_origOpenTarget);
    NSUInteger finishCount = axs_holdlaunch_hookSelector(selFinish, (IMP)axs_holdlaunch_finishTracking, &axs_origFinishTracking);

    NSLog(@"[AxsHoldLaunch] springboard hooks: update=%lu setBundle=%lu handle=%lu openTarget=%lu finish=%lu",
          (unsigned long)updateCount, (unsigned long)setBundleCount,
          (unsigned long)handleCount, (unsigned long)openCount, (unsigned long)finishCount);
}

// ---------------------------------------------------------------------------
// Settings side: inject three rows into ScreenCore's split settings "启动" group.
// ---------------------------------------------------------------------------

static NSString * const AxsHoldLaunchKeyEnabled = @"HoldPressEnabled";
static NSString * const AxsHoldLaunchKeyThreshold = @"HoldPressThreshold";
static NSString * const AxsHoldLaunchKeyReverse = @"HoldPressReverse";

// PSSpecifier is resolved at runtime; direct class references would break
// linking for the SpringBoard slice.
static PSSpecifier *axs_holdlaunch_specifier(NSString *name, id target, SEL set, SEL get) {
    Class PSSpecifierClass = objc_getClass("PSSpecifier");
    return ((PSSpecifier *(*)(id, SEL, NSString *, id, SEL, SEL, id, NSInteger, id))objc_msgSend)(
        PSSpecifierClass, @selector(preferenceSpecifierNamed:target:set:get:detail:cell:edit:),
        name, target, set, get, nil, 1, nil);
}

%group AxsHoldLaunchSettings

// ScreenCore preference bundle controller (loaded only in the Settings process).
@interface SCSplitSettingsController : PSListController
- (NSArray *)axs_holdlaunch_injectedSpecifiers;
- (id)axs_holdlaunch_readValueForSpecifier:(PSSpecifier *)spec;
- (void)axs_holdlaunch_writeValue:(id)value forSpecifier:(PSSpecifier *)spec;
@end

%hook SCSplitSettingsController

- (NSArray *)specifiers {
    NSArray *original = %orig;
    NSMutableArray *specifiers = [original mutableCopy] ?: [NSMutableArray array];
    for (PSSpecifier *spec in specifiers) {
        if ([[spec propertyForKey:@"key"] isEqualToString:AxsHoldLaunchKeyEnabled]) {
            return original; // already injected
        }
    }

    NSUInteger anchor = NSNotFound;
    for (NSUInteger i = 0; i < specifiers.count; i++) {
        NSString *key = [(PSSpecifier *)specifiers[i] propertyForKey:@"key"];
        if ([key isEqualToString:@"splitSideGestureLaunchMode"]
            || [key isEqualToString:@"splitArcGestureLaunchMode"]) {
            anchor = i; // keep the last match: the end of the "启动" group
        }
    }

    NSArray *added = [self axs_holdlaunch_injectedSpecifiers];
    if (anchor == NSNotFound) {
        [specifiers addObjectsFromArray:added];
    } else {
        [specifiers insertObjects:added
                        atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(anchor + 1, added.count)]];
    }
    return specifiers;
}

%new
- (NSArray *)axs_holdlaunch_injectedSpecifiers {
    SEL setSel = @selector(axs_holdlaunch_writeValue:forSpecifier:);
    SEL getSel = @selector(axs_holdlaunch_readValueForSpecifier:);

    PSSpecifier *enabled = axs_holdlaunch_specifier(@"长按松手触发", self, setSel, getSel);
    [enabled setProperty:AxsHoldLaunchKeyEnabled forKey:@"key"];
    [enabled setProperty:@"PSSwitchCell" forKey:@"cellClass"];
    [enabled setIdentifier:@"axsHoldLaunchEnabledSpecifier"];

    PSSpecifier *threshold = axs_holdlaunch_specifier(@"长按触发时间", self, setSel, getSel);
    [threshold setProperty:AxsHoldLaunchKeyThreshold forKey:@"key"];
    [threshold setProperty:@"PSSliderCell" forKey:@"cellClass"];
    [threshold setProperty:@(0.1) forKey:@"min"];
    [threshold setProperty:@(3.0) forKey:@"max"];
    [threshold setProperty:@YES forKey:@"showValue"];
    [threshold setIdentifier:@"axsHoldLaunchThresholdSpecifier"];

    PSSpecifier *reverse = axs_holdlaunch_specifier(@"反转长按动作", self, setSel, getSel);
    [reverse setProperty:AxsHoldLaunchKeyReverse forKey:@"key"];
    [reverse setProperty:@"PSSwitchCell" forKey:@"cellClass"];
    [reverse setIdentifier:@"axsHoldLaunchReverseSpecifier"];

    return @[enabled, threshold, reverse];
}

%new
- (id)axs_holdlaunch_readValueForSpecifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    id value = [[AxsHoldLaunchConfig axs_holdlaunch_shared] axs_holdlaunch_valueForKey:key defaultValue:nil];
    if ([key isEqualToString:AxsHoldLaunchKeyEnabled]) return value ?: @NO;
    if ([key isEqualToString:AxsHoldLaunchKeyReverse]) return value ?: @NO;
    if ([key isEqualToString:AxsHoldLaunchKeyThreshold]) return value ?: @1.0;
    return value;
}

%new
- (void)axs_holdlaunch_writeValue:(id)value forSpecifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if ([key isEqualToString:AxsHoldLaunchKeyThreshold]) {
        double threshold = [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 1.0;
        threshold = round(threshold / 0.05) * 0.05;
        threshold = MIN(3.0, MAX(0.1, threshold));
        value = @(threshold);
    }
    NSError *error = nil;
    if (!axs_holdlaunch_writePreference(key, value, &error)) {
        NSString *message = [NSString stringWithFormat:@"写入设置失败：%@", error.localizedDescription ?: @"未知错误"];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ARC 长按全屏启动"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

%end

%end // AxsHoldLaunchSettings

// ---------------------------------------------------------------------------

%ctor {
    @autoreleasepool {
        // Readers load a snapshot; they never write default preferences.
        [AxsHoldLaunchConfig axs_holdlaunch_shared];

        if (objc_getClass("SpringBoard") != nil) {
            axs_holdlaunch_installSpringBoardHooks();
        } else if (objc_getClass("SCSplitSettingsController") != nil) {
            %init(AxsHoldLaunchSettings);
        }
    }
}
