#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AxsHoldLaunchConfig.h"
#import "AxsHoldLaunchPreferences.h"
#import "AxsHoldLaunchPrivate.h"

// ---------------------------------------------------------------------------
// SpringBoard side
//
// Signature-safe hook set only. Every hook below has a confirmed ABI:
//   - setSelectedBundleIdentifier: receives NSString values (proven by logs)
//   - splitGestureLaunchMode / splitArcGestureLaunchMode getters are plain
//     long -> long (Tq in the ObjC metadata; 0 = split, 1 = fullscreen per
//     the specifier's validValues)
//   - sc_routeApplicationRequestForBundleIdentifier:options:origin:forward:
//     only bundleIdentifier is read as an object, the rest pass through as
//     integer bits
//   - sc_sessionForBundleIdentifier: object in, object out
// The deep open funnel (sc_openTargetIdentifier:...launchFullscreen:) is
// deliberately NOT hooked: two of its arguments have unconfirmed types and
// getting them wrong crashed inside objc_retain.
// ---------------------------------------------------------------------------

static NSTimeInterval axs_holdlaunch_now(void) {
    return [[NSDate date] timeIntervalSince1970];
}

// NSLog goes into the unified log which is hard to read on-device; mirror
// every line into a plain file the user can open with Filza.
static void axs_holdlaunch_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void axs_holdlaunch_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[AxsHoldLaunch] %@", message);

    NSString *path = @"/var/mobile/Library/Caches/AxsHoldLaunch.log";
    @try {
        NSFileManager *manager = [NSFileManager defaultManager];
        NSDictionary *attributes = [manager attributesOfItemAtPath:path error:nil];
        if ([attributes fileSize] > 512 * 1024) {
            [manager removeItemAtPath:path error:nil];
        }
        NSString *line = [NSString stringWithFormat:@"%.3f %@\n",
                          [[NSDate date] timeIntervalSince1970], message];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle == nil) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
    } @catch (NSException *exception) {
        // logging must never take the host process down
    }
}

// Main-thread gesture state; the hooks all run on the main thread.
static NSTimeInterval axs_arrivalTime = 0;        // when the current icon became selected
static NSString *axs_arrivalBundle = nil;         // bundle id selected at axs_arrivalTime
static NSString *axs_lastSeenBundle = nil;
static NSString *axs_lastARCBundle = nil;         // last bundle opened through a user gesture
static NSString *axs_activeFloatingBundle = nil;  // bundle whose floating window is currently up

static IMP axs_origSetSelectedBundle = NULL;
static IMP axs_origGestureMode = NULL;
static IMP axs_origArcGestureMode = NULL;
static IMP axs_origSessionFor = NULL;

// Captured from sc_sessionForBundleIdentifier: so the auto-close can resolve
// sessions without knowing the manager's class beyond its selector surface.
static __weak id axs_sessionManager = nil;
static BOOL axs_sessionManagerLogged = NO;

static void axs_holdlaunch_closeSessionForBundle(NSString *bundleIdentifier, NSString *reason) {
    id manager = axs_sessionManager;
    if (manager == nil || bundleIdentifier.length == 0) return;
    // Resolve through the UNGHOOKED original IMP: calling the hooked selector
    // here would re-enter our own sessionFor hook (infinite recursion).
    id session = ((id(*)(id, SEL, id))axs_origSessionFor)(manager, @selector(sc_sessionForBundleIdentifier:), bundleIdentifier);
    if (session == nil) return;
    axs_sessionHookDepth++;
    ((void(*)(id, SEL, id, BOOL))objc_msgSend)(manager, @selector(sc_closeSession:animated:), session, YES);
    axs_sessionHookDepth--;
    axs_holdlaunch_log(@"auto-closed floating window bundle=%@ reason=%@", bundleIdentifier, reason);
}

// Dock (minimize to the side) a session via ScreenCore's own single-window
// dock method. The method's arity is verified from its type encoding before
// calling; an unrecognized signature falls back to closing.
static void axs_holdlaunch_dockSessionForBundle(NSString *bundleIdentifier, NSString *reason) {
    id manager = axs_sessionManager;
    if (manager == nil || bundleIdentifier.length == 0) return;
    SEL selDock = @selector(sc_dockSessionForSingleActiveWindow:);
    Method dockMethod = class_getInstanceMethod([manager class], selDock);
    if (!dockMethod) {
        axs_holdlaunch_log(@"dock unavailable (selector missing), closing %@ instead", bundleIdentifier);
        axs_holdlaunch_closeSessionForBundle(bundleIdentifier, reason);
        return;
    }
    // UNGHOOKED original IMP for session resolution (no hook re-entry).
    id session = ((id(*)(id, SEL, id))axs_origSessionFor)(manager, @selector(sc_sessionForBundleIdentifier:), bundleIdentifier);
    if (session == nil) return;
    axs_sessionHookDepth++;
    NSString *encoding = [NSString stringWithUTF8String:method_getTypeEncoding(dockMethod)];
    // enc starts with "@@:" (return, self, cmd); extra argument chars follow.
    NSUInteger extra = encoding.length > 3 ? encoding.length - 3 : 0;
    if (extra == 0) {
        ((void(*)(id, SEL, id))objc_msgSend)(manager, selDock, session);
    } else if (extra == 1) {
        char arg = [encoding characterAtIndex:3];
        if (arg == '@') {
            ((void(*)(id, SEL, id, id))objc_msgSend)(manager, selDock, session, nil);
        } else if (arg == 'c' || arg == 'B') {
            ((void(*)(id, SEL, id, BOOL))objc_msgSend)(manager, selDock, session, YES);
        } else if (arg == 'q' || arg == 'l' || arg == 'i' || arg == 'I' || arg == 'Q' || arg == 'L' || arg == 's' || arg == 'S') {
            ((void(*)(id, SEL, id, long))objc_msgSend)(manager, selDock, session, 0);
        } else {
            axs_sessionHookDepth--;
            axs_holdlaunch_log(@"dock encoding %@ unsupported, closing %@ instead", encoding, bundleIdentifier);
            axs_holdlaunch_closeSessionForBundle(bundleIdentifier, reason);
            return;
        }
    } else {
        axs_sessionHookDepth--;
        axs_holdlaunch_log(@"dock encoding %@ unsupported, closing %@ instead", encoding, bundleIdentifier);
        axs_holdlaunch_closeSessionForBundle(bundleIdentifier, reason);
        return;
    }
    axs_sessionHookDepth--;
    axs_holdlaunch_log(@"docked floating window bundle=%@ reason=%@", bundleIdentifier, reason);
}

static BOOL axs_holdlaunch_isRealAppBundle(NSString *bundle) {
    return [bundle isKindOfClass:[NSString class]]
        && bundle.length > 0
        && ![bundle hasPrefix:@"system-tool:"];
}

static void axs_holdlaunch_recordArrival(NSString *bundle) {
    if (![bundle isKindOfClass:[NSString class]] || bundle.length == 0) return;
    if ([bundle isEqualToString:axs_lastSeenBundle]) return;
    axs_lastSeenBundle = bundle;
    axs_arrivalBundle = bundle;
    axs_arrivalTime = axs_holdlaunch_now();
}

static void axs_holdlaunch_setSelectedBundle(id self, SEL _cmd, id bundle) {
    ((void(*)(id, SEL, id))axs_origSetSelectedBundle)(self, _cmd, bundle);
    axs_holdlaunch_recordArrival(bundle);
    // A user-gesture open updates the expected bundle, so the sessionFor hook
    // can tell user opens (matching) from programmatic jumps (mismatched).
    if (axs_holdlaunch_isRealAppBundle(bundle)) {
        axs_lastARCBundle = bundle;
    }
    if (axs_arrivalTime > 0 && [bundle isEqualToString:axs_arrivalBundle]) {
        axs_holdlaunch_log(@"arrival(set) bundle=%@", bundle);
    }
}

// The open-mode decision reads splitGestureLaunchMode / splitArcGestureLaunch
// Mode (long: 0 = split, 1 = fullscreen, per the specifier's validValues).
// Overriding the getter avoids every unknown-type argument of the deep open
// funnel, which crashed inside objc_retain twice.
static long axs_holdlaunch_gestureMode_imp(id self, SEL _cmd, IMP original) {
    long mode = ((long(*)(id, SEL))original)(self, _cmd);
    if (axs_arrivalTime > 0) {
        NSTimeInterval dwell = axs_holdlaunch_now() - axs_arrivalTime;
        if (dwell >= 0.0 && dwell <= 5.0
            && [[AxsHoldLaunchConfig axs_holdlaunch_shared] axs_holdlaunch_isEnabled]) {
            AxsHoldLaunchConfig *config = [AxsHoldLaunchConfig axs_holdlaunch_shared];
            double threshold = [config axs_holdlaunch_threshold];
            BOOL reverse = [config axs_holdlaunch_reverse];
            BOOL wantFullscreen = reverse ? (dwell < threshold) : (dwell >= threshold);
            long forced = wantFullscreen ? 1 : 0;
            axs_holdlaunch_log(@"mode override bundle=%@ dwell=%.2f threshold=%.2f reverse=%d orig=%ld forced=%ld",
                               axs_arrivalBundle, dwell, threshold, reverse, mode, forced);
            axs_arrivalTime = 0;
            axs_arrivalBundle = nil;
            axs_lastSeenBundle = nil;
            return forced;
        }
    }
    return mode;
}

static long axs_holdlaunch_gestureMode_imp_a(id self, SEL _cmd) {
    return axs_holdlaunch_gestureMode_imp(self, _cmd, axs_origGestureMode);
}

static long axs_holdlaunch_gestureMode_imp_b(id self, SEL _cmd) {
    return axs_holdlaunch_gestureMode_imp(self, _cmd, axs_origArcGestureMode);
}

// ---------------------------------------------------------------------------
// Jump/callback auto-close: when ScreenCore routes an open request to app B
// (payment page, converter, ...) and shortly afterwards routes back to a
// DIFFERENT app A (payment completion callback, conversion finished), close
// the floating session of B. Uses only signature-safe hooks.
// ---------------------------------------------------------------------------

static int axs_sessionHookDepth = 0;  // re-entrancy guard: while our close/dock
                                      // helpers run, ScreenCore's own internals may
                                      // query sessions again - those calls must
                                      // pass straight through the original IMP.

static id axs_holdlaunch_sessionFor_imp(id self, SEL _cmd, id bundleIdentifier) {
    if (axs_sessionHookDepth > 0) {
        // Called from our own close/dock helpers: plain passthrough.
        return ((id(*)(id, SEL, id))axs_origSessionFor)(self, _cmd, bundleIdentifier);
    }
    if (axs_sessionManager == nil) {
        axs_sessionManager = self;
        if (!axs_sessionManagerLogged) {
            axs_sessionManagerLogged = YES;
            axs_holdlaunch_log(@"session manager captured: %@", NSStringFromClass([self class]));
        }
    }
    if (axs_holdlaunch_isRealAppBundle(bundleIdentifier)) {
        // Jump/callback flows never fire setSelectedBundleIdentifier:, while
        // user-gesture opens always do. A session lookup for a bundle other
        // than the last user-opened one therefore means a programmatic jump:
        // dock (single-window mode) or close the CURRENTLY floating window.
        // The target is the tracked active floating window, NOT the stale
        // setter record - jump flows bypass the setter entirely.
        AxsHoldLaunchConfig *config = [AxsHoldLaunchConfig axs_holdlaunch_shared];
        BOOL gated = [config axs_holdlaunch_isTheirCallbackCloseEnabled]
                  || [config axs_holdlaunch_isTheirSingleWindowEnabled];
        BOOL userOpen = [bundleIdentifier isEqualToString:axs_lastARCBundle];
        NSString *previous = axs_activeFloatingBundle;
        if (gated
            && !userOpen
            && previous.length > 0
            && ![bundleIdentifier isEqualToString:previous]) {
            axs_sessionHookDepth++;
            if ([config axs_holdlaunch_isTheirSingleWindowEnabled]) {
                axs_holdlaunch_dockSessionForBundle(previous,
                    [NSString stringWithFormat:@"jumped-to:%@", bundleIdentifier]);
            } else {
                axs_holdlaunch_closeSessionForBundle(previous,
                    [NSString stringWithFormat:@"jumped-to:%@", bundleIdentifier]);
            }
            axs_sessionHookDepth--;
        }
        axs_activeFloatingBundle = bundleIdentifier;
    }
    return ((id(*)(id, SEL, id))axs_origSessionFor)(self, _cmd, bundleIdentifier);
}

static IMP axs_origCloseSession = NULL;

static void axs_holdlaunch_closeSession_imp(id self, SEL _cmd, id session, BOOL animated) {
    axs_holdlaunch_log(@"closeSession <%@:%p> animated=%d",
                       NSStringFromClass([session class]), session, animated);
    ((void(*)(id, SEL, id, BOOL))axs_origCloseSession)(self, _cmd, session, animated);
}

static BOOL axs_springboardHooksInstalled = NO;

// scanAllClasses: some ScreenCore selectors are dispatched dynamically and
// implemented on classes outside the SC* prefix, so the prefix filter would
// never find them (sc_routeApplicationRequest... was one).
static NSUInteger axs_holdlaunch_hookSelectorInScope(SEL selector, IMP replacement, IMP *original, BOOL scanAllClasses) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return 0;
    NSUInteger hooked = 0;
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (!scanAllClasses) {
            const char *name = class_getName(cls);
            if (strncmp(name, "SC", 2) != 0) continue;
        }
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        BOOL declared = NO;
        for (unsigned int m = 0; m < methodCount; m++) {
            if (method_getName(methods[m]) == selector) { declared = YES; break; }
        }
        free(methods);
        if (declared) {
            MSHookMessageEx(cls, selector, replacement, original);
            hooked++;
        }
    }
    free(classes);
    return hooked;
}

static NSUInteger axs_holdlaunch_hookSelector(SEL selector, IMP replacement, IMP *original) {
    return axs_holdlaunch_hookSelectorInScope(selector, replacement, original, NO);
}

static void axs_holdlaunch_installSpringBoardHooks(void) {
    if (axs_springboardHooksInstalled) return;
    axs_springboardHooksInstalled = YES;
    SEL selSetBundle = NSSelectorFromString(AxsHoldLaunchSelSetSelectedBundle);
    SEL selMode = @selector(splitGestureLaunchMode);
    SEL selArcMode = @selector(splitArcGestureLaunchMode);

    NSUInteger setBundleCount = axs_holdlaunch_hookSelector(selSetBundle, (IMP)axs_holdlaunch_setSelectedBundle, &axs_origSetSelectedBundle);
    NSUInteger modeCount = axs_holdlaunch_hookSelector(selMode, (IMP)axs_holdlaunch_gestureMode_imp_a, &axs_origGestureMode);
    NSUInteger arcModeCount = axs_holdlaunch_hookSelector(selArcMode, (IMP)axs_holdlaunch_gestureMode_imp_b, &axs_origArcGestureMode);

    // Captures SCFloatingSceneManager so the auto-close can resolve sessions.
    SEL selSessionFor = @selector(sc_sessionForBundleIdentifier:);
    NSUInteger sessionForCount = axs_holdlaunch_hookSelector(selSessionFor, (IMP)axs_holdlaunch_sessionFor_imp, &axs_origSessionFor);
    SEL selCloseSession = @selector(sc_closeSession:animated:);
    NSUInteger closeCount = axs_holdlaunch_hookSelector(selCloseSession, (IMP)axs_holdlaunch_closeSession_imp, &axs_origCloseSession);

    axs_holdlaunch_log(@"springboard hooks: setBundle=%lu mode=%lu arcMode=%lu sessionFor=%lu close=%lu | callback-close gate=%d",
                       (unsigned long)setBundleCount,
                       (unsigned long)modeCount, (unsigned long)arcModeCount,
                       (unsigned long)sessionForCount, (unsigned long)closeCount,
                       [[AxsHoldLaunchConfig axs_holdlaunch_shared] axs_holdlaunch_isTheirCallbackCloseEnabled]);
}

// ---------------------------------------------------------------------------
// Settings side: the specifier rows themselves live in the patched
// SplitSettings.plist; these hooks quantize the threshold value (input dialog
// prefill + writes) so it never shows more than two decimals.
// ---------------------------------------------------------------------------

static NSString * const AxsHoldLaunchKeyEnabled = @"HoldPressEnabled";
static NSString * const AxsHoldLaunchKeyThreshold = @"HoldPressThreshold";
static NSString * const AxsHoldLaunchKeyReverse = @"HoldPressReverse";

static IMP axs_origSpecifiers = NULL;
static IMP axs_origReadPrefValue = NULL;
static IMP axs_origSetPrefValue = NULL;
static BOOL axs_settingsInstalled = NO;

static double axs_holdlaunch_quantizeThreshold(double value) {
    double v = round(value / 0.05) * 0.05;
    if (v < 0.2) v = 0.2;
    if (v > 5.0) v = 5.0;
    return v;
}

static id axs_readPreferenceValue_imp(id self, SEL _cmd, id specifier) {
    id value = ((id(*)(id, SEL, id))axs_origReadPrefValue)(self, _cmd, specifier);
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:AxsHoldLaunchKeyThreshold] && [value isKindOfClass:[NSNumber class]]) {
        return @(axs_holdlaunch_quantizeThreshold([value doubleValue]));
    }
    return value;
}

static void axs_setPreferenceValue_imp(id self, SEL _cmd, id value, id specifier) {
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:AxsHoldLaunchKeyThreshold] && [value isKindOfClass:[NSNumber class]]) {
        value = @(axs_holdlaunch_quantizeThreshold([value doubleValue]));
    }
    ((void(*)(id, SEL, id, id))axs_origSetPrefValue)(self, _cmd, value, specifier);
}

// PSSpecifier is resolved at runtime; direct class references would break
// linking for the SpringBoard slice.
static PSSpecifier *axs_holdlaunch_specifier(NSString *name, id target, SEL set, SEL get) {
    Class PSSpecifierClass = objc_getClass("PSSpecifier");
    return ((PSSpecifier *(*)(id, SEL, NSString *, id, SEL, SEL, id, NSInteger, id))objc_msgSend)(
        PSSpecifierClass, @selector(preferenceSpecifierNamed:target:set:get:detail:cell:edit:),
        name, target, set, get, nil, 1, nil);
}

static NSArray *axs_holdlaunch_injectedSpecifiers_imp(id self, SEL _cmd) {
    SEL setSel = @selector(axs_holdlaunch_writeValue:forSpecifier:);
    SEL getSel = @selector(axs_holdlaunch_readValueForSpecifier:);

    PSSpecifier *enabled = axs_holdlaunch_specifier(@"长按松手触发", self, setSel, getSel);
    [enabled setProperty:AxsHoldLaunchKeyEnabled forKey:@"key"];
    [enabled setProperty:@"PSSwitchCell" forKey:@"cellClass"];
    [enabled setIdentifier:@"axsHoldLaunchEnabledSpecifier"];

    PSSpecifier *threshold = axs_holdlaunch_specifier(@"触发时间（秒）", self, setSel, getSel);
    [threshold setProperty:AxsHoldLaunchKeyThreshold forKey:@"key"];
    [threshold setProperty:@"PSSliderCell" forKey:@"cellClass"];
    [threshold setProperty:@(0.2) forKey:@"min"];
    [threshold setProperty:@(5.0) forKey:@"max"];
    [threshold setProperty:@YES forKey:@"showValue"];
    [threshold setIdentifier:@"axsHoldLaunchThresholdSpecifier"];

    PSSpecifier *reverse = axs_holdlaunch_specifier(@"反转长按动作", self, setSel, getSel);
    [reverse setProperty:AxsHoldLaunchKeyReverse forKey:@"key"];
    [reverse setProperty:@"PSSwitchCell" forKey:@"cellClass"];
    [reverse setIdentifier:@"axsHoldLaunchReverseSpecifier"];

    return @[enabled, threshold, reverse];
}

static id axs_holdlaunch_readValue_imp(id self, SEL _cmd, PSSpecifier *spec) {
    NSString *key = [spec propertyForKey:@"key"];
    id value = [[AxsHoldLaunchConfig axs_holdlaunch_shared] axs_holdlaunch_valueForKey:key defaultValue:nil];
    if ([key isEqualToString:AxsHoldLaunchKeyEnabled]) return value ?: @NO;
    if ([key isEqualToString:AxsHoldLaunchKeyReverse]) return value ?: @NO;
    if ([key isEqualToString:AxsHoldLaunchKeyThreshold]) return value ?: @1.0;
    return value;
}

static void axs_holdlaunch_writeValue_imp(id self, SEL _cmd, id value, PSSpecifier *spec) {
    NSString *key = [spec propertyForKey:@"key"];
    if ([key isEqualToString:AxsHoldLaunchKeyThreshold]) {
        double threshold = [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 1.0;
        value = @(axs_holdlaunch_quantizeThreshold(threshold));
    }
    NSError *error = nil;
    if (!axs_holdlaunch_writePreference(key, value, &error)) {
        NSString *message = [NSString stringWithFormat:@"Save failed: %@",
                             error.localizedDescription ?: @"unknown error"];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AxsHoldLaunch"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

static NSArray *axs_specifiers_imp(id self, SEL _cmd) {
    NSArray *original = ((NSArray *(*)(id, SEL))axs_origSpecifiers)(self, _cmd);
    NSMutableArray *specifiers = [original mutableCopy] ?: [NSMutableArray array];
    for (PSSpecifier *spec in specifiers) {
        if ([[spec propertyForKey:@"key"] isEqualToString:AxsHoldLaunchKeyEnabled]) {
            return original; // already provided by the patched SplitSettings.plist
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

    NSArray *added = axs_holdlaunch_injectedSpecifiers_imp(self, _cmd);
    if (anchor == NSNotFound) {
        [specifiers addObjectsFromArray:added];
    } else {
        [specifiers insertObjects:added
                        atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(anchor + 1, added.count)]];
    }
    return specifiers;
}

static void axs_holdlaunch_installSettingsHooks(void) {
    if (axs_settingsInstalled) return;
    Class cls = objc_getClass("SCSplitSettingsController");
    if (!cls) return;
    SEL sel = @selector(specifiers);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;

    const char *types = method_getTypeEncoding(method);
    IMP original = method_getImplementation(method);
    if (class_addMethod(cls, sel, (IMP)axs_specifiers_imp, types)) {
        // The subclass inherited -specifiers; adding it locally keeps every
        // other list controller untouched.
        axs_origSpecifiers = original;
    } else {
        MSHookMessageEx(cls, sel, (IMP)axs_specifiers_imp, &axs_origSpecifiers);
    }
    class_addMethod(cls, @selector(axs_holdlaunch_injectedSpecifiers), (IMP)axs_holdlaunch_injectedSpecifiers_imp, "@@:");
    class_addMethod(cls, @selector(axs_holdlaunch_readValueForSpecifier:), (IMP)axs_holdlaunch_readValue_imp, "@@:@");
    class_addMethod(cls, @selector(axs_holdlaunch_writeValue:forSpecifier:), (IMP)axs_holdlaunch_writeValue_imp, "v@:@");

    // Quantize the threshold slider (read = input dialog prefill, write =
    // slider drags and typed values) so it never shows more than 2 decimals.
    SEL selRead = @selector(readPreferenceValue:);
    Method readMethod = class_getInstanceMethod(cls, selRead);
    if (readMethod) {
        IMP readOrig = method_getImplementation(readMethod);
        if (class_addMethod(cls, selRead, (IMP)axs_readPreferenceValue_imp, method_getTypeEncoding(readMethod))) {
            axs_origReadPrefValue = readOrig;
        } else {
            MSHookMessageEx(cls, selRead, (IMP)axs_readPreferenceValue_imp, &axs_origReadPrefValue);
        }
    }
    SEL selWrite = @selector(setPreferenceValue:specifier:);
    Method writeMethod = class_getInstanceMethod(cls, selWrite);
    if (writeMethod) {
        IMP writeOrig = method_getImplementation(writeMethod);
        if (class_addMethod(cls, selWrite, (IMP)axs_setPreferenceValue_imp, method_getTypeEncoding(writeMethod))) {
            axs_origSetPrefValue = writeOrig;
        } else {
            MSHookMessageEx(cls, selWrite, (IMP)axs_setPreferenceValue_imp, &axs_origSetPrefValue);
        }
    }
    axs_settingsInstalled = YES;
    axs_holdlaunch_log(@"settings hooks installed");
}

%group AxsHoldLaunchSettingsTrigger

%hook PSListController

- (void)loadView {
    // ScreenCorePrefs.bundle is already loaded by the time a ScreenCore list
    // controller loads its view.
    axs_holdlaunch_log(@"PSListController loadView: %@",
                       NSStringFromClass([self class]));
    axs_holdlaunch_installSettingsHooks();
    %orig;
}

%end

%end // AxsHoldLaunchSettingsTrigger

// ---------------------------------------------------------------------------

%group AxsHoldLaunchSpringBoardTrigger

%hook SpringBoard

// ScreenCore's dylib may load AFTER this tweak (dlopen order is not
// guaranteed), so its classes are only guaranteed to exist once the
// system has finished launching -- install the real hooks there.
- (void)applicationDidFinishLaunching:(id)application {
    axs_holdlaunch_log(@"springboard didFinishLaunching");
    axs_holdlaunch_installSpringBoardHooks();
    %orig;
}

%end

%end // AxsHoldLaunchSpringBoardTrigger

// ---------------------------------------------------------------------------

%ctor {
    @autoreleasepool {
        // Readers load a snapshot; they never write default preferences.
        [AxsHoldLaunchConfig axs_holdlaunch_shared];

        if (objc_getClass("SpringBoard") != nil) {
            axs_holdlaunch_log(@"loaded in SpringBoard");
            %init(AxsHoldLaunchSpringBoardTrigger);
        } else if (objc_getClass("PSListController") != nil) {
            axs_holdlaunch_log(@"loaded in Settings");
            %init(AxsHoldLaunchSettingsTrigger);
        } else {
            axs_holdlaunch_log(@"loaded in unknown process");
        }
    }
}
