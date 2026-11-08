#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AxsHoldLaunchConfig.h"
#import "AxsHoldLaunchPreferences.h"
#import "AxsHoldLaunchPrivate.h"

// ---------------------------------------------------------------------------
// Hold-to-launch: ARC 閼挎粌宕熼梹鎸庡瘻閺夌偓澧滅憴锕€褰?//
// ScreenCore 閻ㄥ嫭澧﹀鈧弬鐟扮础閸愬磭鐡ョ拠璇插絿 splitGestureLaunchMode (long: 0 = 閸掑棗鐫?
// 1 = 閸忋劌鐫? 鐟欎浇顔曠純顕€銆?validValues)閵嗗倹婀?tweak 閸欘亜浠涙稉銈勬娴?
//   1. setSelectedBundleIdentifier: 鐠佹澘缍嶉幍瀣瘹閽€钘夊煂閼挎粌宕熼崶鐐垼閻ㄥ嫭妞傞崚?(dwell 鐠ч鍋?
//   2. 閹垫挸绱戦弬鐟扮础 getter 鐞氼偄鍠呯粵鏍嚢閸欐牗妞? 閹?dwell >= 闂冨牆鈧吋鏁奸崘娆掔箲閸ョ偛鈧?(娑撯偓濞嗏剝婀侀弫?
// 闁解晛鐡欓崗銊╁劥娑撹櫣顒烽崥宥団€樼拋銈呯暔閸忋劎娈戠猾璇茬€?(鐎涙顑佹稉?setter + 缁?long getter)閵?// ---------------------------------------------------------------------------

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

static IMP axs_origSetSelectedBundle = NULL;
static IMP axs_origGestureMode = NULL;
static IMP axs_origArcGestureMode = NULL;

static void axs_holdlaunch_recordArrival(NSString *bundle) {
    if (![bundle isKindOfClass:[NSString class]] || bundle.length == 0) return;
    if ([bundle isEqualToString:axs_lastSeenBundle]) return;
    axs_lastSeenBundle = bundle;
    axs_arrivalBundle = bundle;
    axs_arrivalTime = axs_holdlaunch_now();
}

// Ring engine C API (defined in AXSRingEngine.xm)
void axs_ring_setSessionBundle(id session, NSString *bundle);
void axs_ring_noteContainerForSession(id container, id session);
void axs_ring_sessionClosed(id session);
void axs_ring_sessionDocked(id session);
void axs_ring_engine_wake(void);

static void axs_holdlaunch_setSelectedBundle(id self, SEL _cmd, id bundle) {
    ((void(*)(id, SEL, id))axs_origSetSelectedBundle)(self, _cmd, bundle);
    axs_holdlaunch_recordArrival(bundle);
    if (axs_arrivalTime > 0 && [bundle isEqualToString:axs_arrivalBundle]) {
        axs_holdlaunch_log(@"arrival(set) bundle=%@", bundle);
    }
}

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

static BOOL axs_springboardHooksInstalled = NO;

static NSArray<Class> *axs_holdlaunch_classesDeclaring(SEL selector) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return @[];
    NSMutableArray<Class> *result = [NSMutableArray array];
    unsigned int scClasses = 0;
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        // ScreenCore classes all start with SC / SCWS; limit the scan to them.
        const char *name = class_getName(cls);
        if (strncmp(name, "SC", 2) != 0) continue;
        scClasses++;
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
    axs_holdlaunch_log(@"scan '%s': %u SC classes of %u total", sel_getName(selector), scClasses, count);
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

// Ring engine feed hooks (all signature-safe: object args, object/void returns)
static IMP axs_origSessionForContainerView = NULL;
static IMP axs_origSessionForBundle = NULL;
static IMP axs_origCloseSession = NULL;
static IMP axs_origDockSession = NULL;

static id axs_holdlaunch_sessionForContainerView_imp(id self, SEL _cmd, id container) {
    id session = ((id(*)(id, SEL, id))axs_origSessionForContainerView)(self, _cmd, container);
    axs_ring_noteContainerForSession(container, session);
    return session;
}

static id axs_holdlaunch_sessionForBundle_imp(id self, SEL _cmd, id bundleIdentifier) {
    id session = ((id(*)(id, SEL, id))axs_origSessionForBundle)(self, _cmd, bundleIdentifier);
    axs_ring_setSessionBundle(session, bundleIdentifier);
    return session;
}

static void axs_holdlaunch_closeSession_imp(id self, SEL _cmd, id session, BOOL animated) {
    axs_ring_sessionClosed(session);
    ((void(*)(id, SEL, id, BOOL))axs_origCloseSession)(self, _cmd, session, animated);
}

static id axs_holdlaunch_dockSession_imp(id self, SEL _cmd, id session, unsigned long fromCorner) {
    axs_ring_sessionDocked(session);
    return ((id(*)(id, SEL, id, unsigned long))axs_origDockSession)(self, _cmd, session, fromCorner);
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

    // Ring engine feed hooks (all signature-safe: object args, object/void returns)
    SEL selSessionForContainer = @selector(sc_sessionForContainerView:);
    SEL selSessionForBundle = @selector(sc_sessionForBundleIdentifier:);
    SEL selCloseSession = @selector(sc_closeSession:animated:);
    SEL selDockSession = @selector(sc_dockSession:fromCorner:);

    NSUInteger sessionForContainerCount = axs_holdlaunch_hookSelector(selSessionForContainer, (IMP)axs_holdlaunch_sessionForContainerView_imp, &axs_origSessionForContainerView);
    NSUInteger sessionForBundleCount = axs_holdlaunch_hookSelector(selSessionForBundle, (IMP)axs_holdlaunch_sessionForBundle_imp, &axs_origSessionForBundle);
    NSUInteger closeSessionCount = axs_holdlaunch_hookSelector(selCloseSession, (IMP)axs_holdlaunch_closeSession_imp, &axs_origCloseSession);
    NSUInteger dockSessionCount = axs_holdlaunch_hookSelector(selDockSession, (IMP)axs_holdlaunch_dockSession_imp, &axs_origDockSession);

    axs_holdlaunch_log(@"springboard hooks: setBundle=%lu mode=%lu arcMode=%lu sessionForContainer=%lu sessionForBundle=%lu closeSession=%lu dockSession=%lu",
                       (unsigned long)setBundleCount,
                       (unsigned long)modeCount, (unsigned long)arcModeCount,
                       (unsigned long)sessionForContainerCount, (unsigned long)sessionForBundleCount,
                       (unsigned long)closeSessionCount, (unsigned long)dockSessionCount);
    axs_ring_engine_wake();
}

// ---------------------------------------------------------------------------
// Settings side: the specifier rows live in the patched SplitSettings.plist;
// these hooks quantize the threshold value (input dialog prefill + writes) so
// it never shows more than two decimals.
// ---------------------------------------------------------------------------

static NSString * const AxsHoldLaunchKeyEnabled = @"HoldPressEnabled";
static NSString * const AxsHoldLaunchKeyThreshold = @"HoldPressThreshold";
static NSString * const AxsHoldLaunchKeyReverse = @"HoldPressReverse";

static IMP axs_origSpecifiers = NULL;
static IMP axs_origReadPrefValue = NULL;
static IMP axs_origSetPrefValue = NULL;
static IMP axs_origDidSelect = NULL;
static BOOL axs_settingsInstalled = NO;

static NSString * const AxsHoldLaunchKeyRingColor = @"splitWindowRingColor";
static NSString * const AxsHoldLaunchKeyGlowColor = @"splitWindowGlowColor";

static UIColor *axs_holdlaunch_hexToColor(NSString *hex, UIColor *fallback) {
    if (![hex isKindOfClass:[NSString class]] || hex.length == 0) return fallback;
    NSString *h = [[hex stringByReplacingOccurrencesOfString:@"#" withString:@""] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (h.length != 6) return fallback;
    unsigned int v = 0;
    NSScanner *scanner = [NSScanner scannerWithString:h];
    [scanner scanHexInt:&v];
    return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                           green:((v >> 8) & 0xFF) / 255.0
                            blue:(v & 0xFF) / 255.0
                           alpha:1.0];
}

static NSString *axs_holdlaunch_colorToHex(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) return @"#FFFFFF";
    return [NSString stringWithFormat:@"#%02X%02X%02X",
            (int)round(r * 255), (int)round(g * 255), (int)round(b * 255)];
}

static void axs_holdlaunch_presentColorPicker(id self, NSString *title, NSString *key) {
    if (!objc_getClass("UIColorPickerViewController")) {
        axs_holdlaunch_log(@"UIColorPickerViewController unavailable");
        return;
    }
    UIViewController *picker = [[objc_getClass("UIColorPickerViewController") alloc] init];
    if ([picker respondsToSelector:@selector(setSupportsAlpha:)]) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(picker, @selector(setSupportsAlpha:), NO);
    }
    if ([picker respondsToSelector:@selector(setInitialColor:)]) {
        UIColor *initial = axs_holdlaunch_hexToColor(
            [[AxsHoldLaunchConfig axs_holdlaunch_shared] axs_holdlaunch_valueForKey:key defaultValue:nil],
            [UIColor colorWithRed:0.2 green:0.63 blue:1.0 alpha:1.0]);
        ((void(*)(id, SEL, id))objc_msgSend)(picker, @selector(setInitialColor:), initial);
    }
    if ([picker respondsToSelector:@selector(setTitle:)]) {
        ((void(*)(id, SEL, id))objc_msgSend)(picker, @selector(setTitle:), title);
    }
    objc_setAssociatedObject(picker, @selector(axsGlowColorKey), key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Delegate: colorPickerControllerDidFinish: was added to the controller
    // class in installSettingsHooks 閳?without this the picked color never saves.
    if ([picker respondsToSelector:@selector(setDelegate:)]) {
        ((void(*)(id, SEL, id))objc_msgSend)(picker, @selector(setDelegate:), self);
    }
    [self presentViewController:picker animated:YES completion:nil];
}

static void axs_holdlaunch_colorPickerDidFinish_imp(id self, SEL _cmd, id picker) {
    UIColor *color = nil;
    if ([picker respondsToSelector:@selector(selectedColor)]) {
        color = ((id(*)(id, SEL))objc_msgSend)(picker, @selector(selectedColor));
    }
    NSString *key = objc_getAssociatedObject(picker, @selector(axsGlowColorKey));
    if (color && key.length > 0) {
        NSString *hex = axs_holdlaunch_colorToHex(color);
        NSError *error = nil;
        axs_holdlaunch_writePreference(key, hex, &error);
        if ([self respondsToSelector:@selector(reloadSpecifiers)]) {
            ((void(*)(id, SEL))objc_msgSend)(self, @selector(reloadSpecifiers));
        }
    }
    [picker dismissViewControllerAnimated:YES completion:nil];
}

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

static void axs_didSelectRow_imp(id self, SEL _cmd, id tableView, id indexPath) {
    @try {
        NSString *key = nil;
        if ([self respondsToSelector:@selector(specifierAtIndexPath:)]) {
            PSSpecifier *spec = ((PSSpecifier *(*)(id, SEL, id))objc_msgSend)(self, @selector(specifierAtIndexPath:), indexPath);
            key = [spec propertyForKey:@"key"];
        }
        if ([key isEqualToString:AxsHoldLaunchKeyRingColor]) {
            axs_holdlaunch_presentColorPicker(self, @"閸忓婀€妫版粏澹?, AxsHoldLaunchKeyRingColor);
            return;
        }
        if ([key isEqualToString:AxsHoldLaunchKeyGlowColor]) {
            axs_holdlaunch_presentColorPicker(self, @"閸忓妾挎０婊嗗", AxsHoldLaunchKeyGlowColor);
            return;
        }
    } @catch (NSException *exception) {
        // fall through to the original handler
    }
    ((void(*)(id, SEL, id, id))axs_origDidSelect)(self, _cmd, tableView, indexPath);
}

// 妫版粏澹婄悰灞藉礁娓氀呮畱閸﹀棗婀€閹稿鎸? 閻愯瀵滃鐟板絿閼规彃娅?static void axs_holdlaunch_colorButtonTapped_imp(id self, SEL _cmd, id sender) {
    int tag = 0;
    if ([sender respondsToSelector:@selector(tag)]) {
        tag = (int)((long(*)(id, SEL))objc_msgSend)(sender, @selector(tag));
    }
    if (tag == 1) {
        axs_holdlaunch_presentColorPicker(self, @"閸忓妾挎０婊嗗", AxsHoldLaunchKeyGlowColor);
    } else {
        axs_holdlaunch_presentColorPicker(self, @"閸忓婀€妫版粏澹?, AxsHoldLaunchKeyRingColor);
    }
}

static IMP axs_origCellForRow = NULL;

static id axs_cellForRow_imp(id self, SEL _cmd, id tableView, id indexPath) {
    UITableViewCell *cell = ((UITableViewCell *(*)(id, SEL, id, id))axs_origCellForRow)(self, _cmd, tableView, indexPath);
    @try {
        NSString *key = nil;
        if ([self respondsToSelector:@selector(specifierAtIndexPath:)]) {
            PSSpecifier *spec = ((PSSpecifier *(*)(id, SEL, id))objc_msgSend)(self, @selector(specifierAtIndexPath:), indexPath);
            key = [spec propertyForKey:@"key"];
        }
        NSString *colorKey = nil;
        int tag = 0;
        if ([key isEqualToString:AxsHoldLaunchKeyRingColor]) { colorKey = key; tag = 0; }
        if ([key isEqualToString:AxsHoldLaunchKeyGlowColor]) { colorKey = key; tag = 1; }
        if (colorKey == nil) return cell;

        // 閸欏厖鏅惰ぐ鎾冲妫版粏澹婇崷鍡楁箑 (UIButton, 閻愮懓鍤鐟板絿閼规彃娅?
        NSString *hex = [[AxsHoldLaunchConfig axs_holdlaunch_shared] axs_holdlaunch_valueForKey:colorKey defaultValue:nil];
        UIColor *color = axs_holdlaunch_hexToColor(hex, [UIColor colorWithRed:0.2 green:0.63 blue:1.0 alpha:1.0]);
        UIButton *dot = [UIButton buttonWithType:UIButtonTypeCustom];
        dot.frame = CGRectMake(0, 0, 28, 28);
        dot.backgroundColor = color;
        dot.layer.cornerRadius = 14;
        dot.layer.borderWidth = 1.5;
        dot.layer.borderColor = [UIColor colorWithWhite:0.75 alpha:1.0].CGColor;
        dot.tag = tag;
        dot.userInteractionEnabled = YES;
        [dot addTarget:self action:@selector(axs_holdlaunch_colorButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        cell.accessoryView = dot;
    } @catch (NSException *exception) {
        // cell 鐟佸懘銈版径杈Е娑撳秴濂栭崫宥呭斧閸旂喕鍏?    }
    return cell;
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

    PSSpecifier *enabled = axs_holdlaunch_specifier(@"闂€鎸庡瘻閺夌偓澧滅憴锕€褰?, self, setSel, getSel);
    [enabled setProperty:AxsHoldLaunchKeyEnabled forKey:@"key"];
    [enabled setProperty:@"PSSwitchCell" forKey:@"cellClass"];
    [enabled setIdentifier:@"axsHoldLaunchEnabledSpecifier"];

    PSSpecifier *threshold = axs_holdlaunch_specifier(@"鐟欙箑褰傞弮鍫曟？閿涘牏顫楅敍?, self, setSel, getSel);
    [threshold setProperty:AxsHoldLaunchKeyThreshold forKey:@"key"];
    [threshold setProperty:@"PSSliderCell" forKey:@"cellClass"];
    [threshold setProperty:@(0.2) forKey:@"min"];
    [threshold setProperty:@(5.0) forKey:@"max"];
    [threshold setProperty:@YES forKey:@"showValue"];
    [threshold setIdentifier:@"axsHoldLaunchThresholdSpecifier"];

    PSSpecifier *reverse = axs_holdlaunch_specifier(@"閸欏秷娴嗛梹鎸庡瘻閸斻劋缍?, self, setSel, getSel);
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
            anchor = i; // keep the last match: the end of the "閸氼垰濮? group
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

    // Tap on a glow color row -> present the system color picker.
    SEL selDidSelect = @selector(tableView:didSelectRowAtIndexPath:);
    Method didSelectMethod = class_getInstanceMethod(cls, selDidSelect);
    if (didSelectMethod) {
        IMP didSelectOrig = method_getImplementation(didSelectMethod);
        if (class_addMethod(cls, selDidSelect, (IMP)axs_didSelectRow_imp, method_getTypeEncoding(didSelectMethod))) {
            axs_origDidSelect = didSelectOrig;
        } else {
            MSHookMessageEx(cls, selDidSelect, (IMP)axs_didSelectRow_imp, &axs_origDidSelect);
        }
        // Color picker completion (delegate method added to the controller).
        class_addMethod(cls, @selector(colorPickerControllerDidFinish:), (IMP)axs_holdlaunch_colorPickerDidFinish_imp, "v@:@");
    }

    // Color circle button on the row + its tap handler.
    SEL selCellForRow = @selector(tableView:cellForRowAtIndexPath:);
    Method cellForRowMethod = class_getInstanceMethod(cls, selCellForRow);
    if (cellForRowMethod) {
        IMP cellOrig = method_getImplementation(cellForRowMethod);
        if (class_addMethod(cls, selCellForRow, (IMP)axs_cellForRow_imp, method_getTypeEncoding(cellForRowMethod))) {
            axs_origCellForRow = cellOrig;
        } else {
            MSHookMessageEx(cls, selCellForRow, (IMP)axs_cellForRow_imp, &axs_origCellForRow);
        }
        class_addMethod(cls, @selector(axs_holdlaunch_colorButtonTapped:), (IMP)axs_holdlaunch_colorButtonTapped_imp, "v@:@");
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

void axs_ring_engine_wake(void);

%group AxsHoldLaunchSpringBoardTrigger

%hook SpringBoard

// ScreenCore's dylib may load AFTER this tweak (dlopen order is not
// guaranteed), so its classes are only guaranteed to exist once the
// system has finished launching -- install the real hooks there.
- (void)applicationDidFinishLaunching:(id)application {
    axs_holdlaunch_log(@"springboard didFinishLaunching");
    axs_holdlaunch_installSpringBoardHooks();
    axs_ring_engine_wake();
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
