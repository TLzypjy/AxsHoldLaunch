#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AxsHoldLaunchConfig.h"
#import "AxsHoldLaunchPreferences.h"
#import "AxsHoldLaunchPrivate.h"

// ---------------------------------------------------------------------------
// Hold-to-launch: ARC menu hold-release trigger
//
// SpringBoard side:
//   1. setSelectedBundleIdentifier: records when the finger lands on a menu
//      icon (dwell start)
//   2. the open-mode getter is consulted at decision time; the return value is
//      overridden by dwell >= threshold (one-shot)
//
// Settings side:
//   1. SCSplitSettingsController: threshold slider quantize hooks
//   2. the 美化 rows live flat in SplitSettings.plist (LAUNCH<->APPEARANCE);
//      rendering hooks add -/+ steppers with 2-decimal values on sliders,
//      #RRGGBB + swatch on color rows, and gray inline notes where a row
//      carries a "note" property
// ---------------------------------------------------------------------------

static NSTimeInterval axs_holdlaunch_now(void) {
    return [[NSDate date] timeIntervalSince1970];
}

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

// ---------------------------------------------------------------------------
// SpringBoard: hold-launch gesture
// ---------------------------------------------------------------------------

static IMP axs_origSetSelectedBundle = NULL;
static IMP axs_origGestureMode = NULL;
static IMP axs_origArcGestureMode = NULL;

// Main-thread gesture state; the hooks all run on the main thread.
static NSTimeInterval axs_arrivalTime = 0;
static NSString *axs_arrivalBundle = nil;
static NSString *axs_lastSeenBundle = nil;

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
        Method m = class_getInstanceMethod(cls, selector);
        // log the true signature: an id-typed parameter on a method whose
        // actual argument is a primitive gets ARC-retained and crashes
        const char *types = m ? method_getTypeEncoding(m) : "?";
        axs_holdlaunch_log(@"hook '%s' on %s types=%s",
                           sel_getName(selector), class_getName(cls), types ?: "?");
        MSHookMessageEx(cls, selector, replacement, original);
        hooked++;
    }
    return hooked;
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

    axs_holdlaunch_log(@"springboard hooks: setBundle=%lu mode=%lu arcMode=%lu",
                       (unsigned long)setBundleCount,
                       (unsigned long)modeCount, (unsigned long)arcModeCount);
}

// ---------------------------------------------------------------------------
// Settings: threshold quantize + 美化 rows (hooks on SCSplitSettingsController)
// ---------------------------------------------------------------------------

static NSString * const AxsHoldLaunchKeyThreshold = @"HoldPressThreshold";

static IMP axs_origReadPrefValue = NULL;
static IMP axs_origSetPrefValue = NULL;
static BOOL axs_settingsInstalled = NO;

static double axs_holdlaunch_quantizeThreshold(double value) {
    double v = round(value / 0.05) * 0.05;
    if (v < 0.2) v = 0.2;
    if (v > 5.0) v = 5.0;
    return v;
}

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

// --- color picker (shared by the ring page color rows) ---

static void axs_holdlaunch_presentColorPicker(id self, NSString *title, NSString *key) {
    if (!objc_getClass("UIColorPickerViewController")) return;
    UIViewController *picker = [[objc_getClass("UIColorPickerViewController") alloc] init];
    if ([picker respondsToSelector:@selector(setSupportsAlpha:)]) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(picker, @selector(setSupportsAlpha:), NO);
    }
    if ([picker respondsToSelector:@selector(setInitialColor:)]) {
        // ring/glow colors live in ScreenCore's own domain
        UIColor *initial = axs_holdlaunch_hexToColor(
            [[AxsHoldLaunchConfig axs_holdlaunch_shared] axs_holdlaunch_theirValueForKey:key defaultValue:nil],
            [UIColor colorWithRed:0.2 green:0.63 blue:1.0 alpha:1.0]);
        ((void(*)(id, SEL, id))objc_msgSend)(picker, @selector(setInitialColor:), initial);
    }
    if ([picker respondsToSelector:@selector(setTitle:)]) {
        ((void(*)(id, SEL, id))objc_msgSend)(picker, @selector(setTitle:), title);
    }
    objc_setAssociatedObject(picker, @selector(axsRingColorKey), key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    NSString *key = objc_getAssociatedObject(picker, @selector(axsRingColorKey));
    if (color && key.length > 0) {
        NSString *hex = axs_holdlaunch_colorToHex(color);
        axs_holdlaunch_writeTheirPreference(key, hex);
        if ([self respondsToSelector:@selector(reloadSpecifiers)]) {
            [self reloadSpecifiers];
        }
    }
    [picker dismissViewControllerAnimated:YES completion:nil];
}

// --- ring rows: rendering hooks on SCSplitSettingsController ----------------
// The ring rows sit flat in SplitSettings.plist between LAUNCH and APPEARANCE.
// The hooks only customise rendering and interactions; every other row passes
// through untouched. Labels/footers localize from SplitSettings.strings (PS
// handles most lookups; this is a fallback for footerText).

static NSString * const AxsHoldLaunchKeyRingColor = @"splitWindowRingFrameColor";
static NSString * const AxsHoldLaunchKeyGlowColor = @"splitWindowGlowColor";
static NSString * const AxsHoldLaunchKeyInnerColor = @"splitWindowRingInnerColor";
static NSString * const AxsHoldLaunchKeyExclude = @"splitWindowRingExcludedApplications";
static NSString * const AxsHoldLaunchKeyBeautifyRingColor = @"splitBeautifyRingFrameColor";
static NSString * const AxsHoldLaunchKeyBeautifyGlowColor = @"splitBeautifyGlowColor";

static IMP axs_ringPage_origSpecifiers = NULL;
static IMP axs_ringPage_origCellForRow = NULL;
static IMP axs_ringPage_origDidSelect = NULL;
static IMP axs_ringPage_origHeight = NULL;
static NSBundle *axs_ringPage_bundle = nil;

static NSBundle *axs_ring_page_bundle(id controller) {
    if (axs_ringPage_bundle != nil) return axs_ringPage_bundle;
    if ([controller respondsToSelector:@selector(bundle)]) {
        axs_ringPage_bundle = [(PSListController *)controller bundle];
    }
    if (axs_ringPage_bundle == nil) {
        axs_ringPage_bundle = [NSBundle bundleWithPath:
            axs_holdlaunch_resourcePath(@"Library/PreferenceBundles/ScreenCorePrefs.bundle")];
    }
    return axs_ringPage_bundle;
}

static NSString *axs_ring_page_localized(id controller, NSString *text) {
    if (text.length == 0) return text;
    NSBundle *bundle = axs_ring_page_bundle(controller);
    if (bundle == nil) return text;
    NSString *result = [bundle localizedStringForKey:text value:nil table:@"SplitSettings"];
    if (result.length == 0 || [result isEqualToString:text]) return text;
    return result;
}

static NSUInteger axs_ring_page_excludeCount(void) {
    id value = [[AxsHoldLaunchConfig axs_holdlaunch_shared] axs_holdlaunch_theirValueForKey:AxsHoldLaunchKeyExclude defaultValue:nil];
    if ([value isKindOfClass:[NSArray class]]) return [value count];
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSUInteger count = 0;
        for (NSString *bundle in value) {
            NSNumber *on = value[bundle];
            if ([on isKindOfClass:[NSNumber class]] && [on boolValue]) count++;
        }
        return count;
    }
    return 0;
}

static BOOL axs_ring_page_isColorKey(NSString *key) {
    return [key isEqualToString:AxsHoldLaunchKeyRingColor]
        || [key isEqualToString:AxsHoldLaunchKeyGlowColor]
        || [key isEqualToString:AxsHoldLaunchKeyInnerColor]
        || [key isEqualToString:AxsHoldLaunchKeyBeautifyRingColor]
        || [key isEqualToString:AxsHoldLaunchKeyBeautifyGlowColor];
}

// 美化分组的颜色行本轮只做显示：点按弹提示，不接颜色选择器、不写配置。
static BOOL axs_ring_page_isBeautifyColorKey(NSString *key) {
    return [key isEqualToString:AxsHoldLaunchKeyBeautifyRingColor]
        || [key isEqualToString:AxsHoldLaunchKeyBeautifyGlowColor];
}

static void axs_holdlaunch_presentNotImplementedAlert(id self) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示"
                                                                   message:@"该功能尚未实现"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

static NSString *axs_ring_page_colorTitle(id self, NSString *key) {
    NSString *labelKey = nil;
    if ([key isEqualToString:AxsHoldLaunchKeyRingColor]) labelKey = @"RING_FRAME_COLOR";
    else if ([key isEqualToString:AxsHoldLaunchKeyGlowColor]) labelKey = @"RING_GLOW_COLOR";
    else if ([key isEqualToString:AxsHoldLaunchKeyInnerColor]) labelKey = @"RING_INNER_COLOR";
    NSString *title = axs_ring_page_localized(self, labelKey);
    if ([title isEqualToString:labelKey]) title = key;
    return title;
}

static double axs_ring_page_stepFor(double min, double max) {
    return (max - min) <= 1.0 ? 0.01 : 1.0;
}

static double axs_ring_page_snap(double value, double min, double max, double step) {
    double v = min + round((value - min) / step) * step;
    if (v < min) v = min;
    if (v > max) v = max;
    return v;
}

// rows may carry an explicit "step" property (e.g. 0.5 for the border-width
// slider); otherwise the range decides (<=1 -> 0.01, else 1.0)
static double axs_ring_page_stepForSpec(PSSpecifier *spec, double min, double max) {
    id stepValue = [spec propertyForKey:@"step"];
    if ([stepValue isKindOfClass:[NSNumber class]]) {
        double s = [stepValue doubleValue];
        if (s > 0.0 && s <= (max - min)) return s;
    }
    return axs_ring_page_stepFor(min, max);
}

static NSArray *axs_ringPage_specifiers_imp(id self, SEL _cmd) {
    NSArray *specs = ((NSArray *(*)(id, SEL))axs_ringPage_origSpecifiers)(self, _cmd);
    for (PSSpecifier *spec in specs) {
        NSString *label = [spec propertyForKey:@"label"];
        NSString *localizedLabel = axs_ring_page_localized(self, label);
        if (label != nil && ![localizedLabel isEqualToString:label]) {
            [spec setProperty:localizedLabel forKey:@"label"];
        }
        NSString *footer = [spec propertyForKey:@"footerText"];
        NSString *localizedFooter = axs_ring_page_localized(self, footer);
        if (footer != nil && ![localizedFooter isEqualToString:footer]) {
            [spec setProperty:localizedFooter forKey:@"footerText"];
        }
    }
    return specs;
}

static NSString *axs_ringPage_subtitle_imp(id self, SEL _cmd, PSSpecifier *spec) {
    NSString *key = [spec propertyForKey:@"key"];
    if (![key isEqualToString:AxsHoldLaunchKeyExclude]) return nil;
    NSString *format = axs_ring_page_localized(self, @"RING_EXCLUDE_COUNT");
    if ([format isEqualToString:@"RING_EXCLUDE_COUNT"]) format = @"已选 %lu 个";
    return [NSString stringWithFormat:format, (unsigned long)axs_ring_page_excludeCount()];
}

static UITableViewCell *axs_ringPage_sliderCell(id self, UITableView *tableView, PSSpecifier *spec) {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AXSRingSlider"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:@"AXSRingSlider"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UILabel *title = [UILabel new];
        title.tag = 101;
        title.font = [UIFont systemFontOfSize:17];
        title.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:title];

        UIButton *minus = [UIButton buttonWithType:UIButtonTypeSystem];
        minus.tag = 102;
        minus.titleLabel.font = [UIFont systemFontOfSize:20];
        [minus setTitle:@"−" forState:UIControlStateNormal];
        minus.translatesAutoresizingMaskIntoConstraints = NO;
        [minus addTarget:self action:@selector(axs_ringMinus:) forControlEvents:UIControlEventTouchUpInside];
        [cell.contentView addSubview:minus];

        UISlider *slider = [UISlider new];
        slider.tag = 103;
        slider.translatesAutoresizingMaskIntoConstraints = NO;
        [slider addTarget:self action:@selector(axs_ringSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [cell.contentView addSubview:slider];

        UIButton *plus = [UIButton buttonWithType:UIButtonTypeSystem];
        plus.tag = 104;
        plus.titleLabel.font = [UIFont systemFontOfSize:20];
        [plus setTitle:@"+" forState:UIControlStateNormal];
        plus.translatesAutoresizingMaskIntoConstraints = NO;
        [plus addTarget:self action:@selector(axs_ringPlus:) forControlEvents:UIControlEventTouchUpInside];
        [cell.contentView addSubview:plus];

        UILabel *value = [UILabel new];
        value.tag = 105;
        value.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
        value.textColor = [UIColor secondaryLabelColor];
        value.textAlignment = NSTextAlignmentRight;
        value.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:value];

        UILayoutGuide *margin = cell.contentView.layoutMarginsGuide;
        NSLayoutConstraint *titleWidth = [title.widthAnchor constraintLessThanOrEqualToConstant:118];
        titleWidth.priority = UILayoutPriorityDefaultHigh;
        [NSLayoutConstraint activateConstraints:@[
            [title.leadingAnchor constraintEqualToAnchor:margin.leadingAnchor],
            [title.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            titleWidth,
            [minus.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:4],
            [minus.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [minus.widthAnchor constraintEqualToConstant:26],
            [slider.leadingAnchor constraintEqualToAnchor:minus.trailingAnchor constant:2],
            [slider.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [plus.leadingAnchor constraintEqualToAnchor:slider.trailingAnchor constant:2],
            [plus.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [plus.widthAnchor constraintEqualToConstant:26],
            [value.leadingAnchor constraintEqualToAnchor:plus.trailingAnchor constant:4],
            [value.trailingAnchor constraintEqualToAnchor:margin.trailingAnchor],
            [value.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [value.widthAnchor constraintEqualToConstant:50],
        ]];
    }

    UILabel *title = (UILabel *)[cell viewWithTag:101];
    title.text = axs_ring_page_localized(self, [spec propertyForKey:@"label"]);

    double min = [[spec propertyForKey:@"min"] doubleValue];
    double max = [[spec propertyForKey:@"max"] doubleValue];
    if (max <= min) max = min + 1;
    double step = axs_ring_page_stepForSpec(spec, min, max);

    id read = [self respondsToSelector:@selector(readPreferenceValue:)]
        ? [self readPreferenceValue:spec] : nil;
    double value = [read isKindOfClass:[NSNumber class]] ? [read doubleValue]
                 : [[spec propertyForKey:@"default"] doubleValue];
    value = axs_ring_page_snap(value, min, max, step);

    UISlider *slider = (UISlider *)[cell viewWithTag:103];
    slider.minimumValue = min;
    slider.maximumValue = max;
    slider.value = value;
    objc_setAssociatedObject(slider, @selector(axsRingSpec), spec, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject([cell viewWithTag:102], @selector(axsRingSpec), spec, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject([cell viewWithTag:104], @selector(axsRingSpec), spec, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((UILabel *)[cell viewWithTag:105]).text = [NSString stringWithFormat:@"%.2f", value];
    return cell;
}

// Color row in the base package's own layout: plain row, gray "#RRGGBB"
// text plus a round swatch on the right; tapping opens the color picker.
static UITableViewCell *axs_ringPage_colorCell(id self, SEL _cmd, id tableView, id indexPath, PSSpecifier *spec) {
    UITableViewCell *cell = ((UITableViewCell *(*)(id, SEL, id, id))axs_ringPage_origCellForRow)(self, _cmd, tableView, indexPath);
    NSString *key = [spec propertyForKey:@"key"];
    NSString *hex = [[AxsHoldLaunchConfig axs_holdlaunch_shared] axs_holdlaunch_theirValueForKey:key defaultValue:nil];
    NSString *fallback = [spec propertyForKey:@"default"] ?: @"#FFFFFF";
    UIColor *color = axs_holdlaunch_hexToColor(hex, axs_holdlaunch_hexToColor(fallback, [UIColor blueColor]));

    UIView *accessory = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 112, 30)];
    UILabel *hexLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 4, 66, 22)];
    hexLabel.text = (hex.length > 0) ? hex : fallback;
    hexLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    hexLabel.textColor = [UIColor secondaryLabelColor];
    hexLabel.textAlignment = NSTextAlignmentRight;
    [accessory addSubview:hexLabel];

    UIButton *dot = [UIButton buttonWithType:UIButtonTypeCustom];
    dot.frame = CGRectMake(74, 0, 30, 30);
    dot.backgroundColor = color;
    dot.layer.cornerRadius = 15;
    dot.layer.borderWidth = 1.5;
    dot.layer.borderColor = [UIColor colorWithWhite:0.75 alpha:1.0].CGColor;
    dot.userInteractionEnabled = YES;
    objc_setAssociatedObject(dot, @selector(axsRingColorKey), key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [dot addTarget:self action:@selector(axs_ringColorTapped:) forControlEvents:UIControlEventTouchUpInside];
    [accessory addSubview:dot];
    cell.accessoryView = accessory;
    return cell;
}

// Switch row with an inline gray note under the label (KTV mode / random
// color rows in the LingDong layout).
static UITableViewCell *axs_ringPage_noteSwitchCell(id self, UITableView *tableView, PSSpecifier *spec) {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AXSRingNoteSwitch"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:@"AXSRingNoteSwitch"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UILabel *title = [UILabel new];
        title.tag = 211;
        title.font = [UIFont systemFontOfSize:17];
        title.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:title];

        UILabel *note = [UILabel new];
        note.tag = 212;
        note.font = [UIFont systemFontOfSize:11];
        note.textColor = [UIColor secondaryLabelColor];
        note.numberOfLines = 0;
        note.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:note];

        UISwitch *toggle = [UISwitch new];
        toggle.tag = 213;
        toggle.translatesAutoresizingMaskIntoConstraints = NO;
        [toggle addTarget:self action:@selector(axs_ringSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        [cell.contentView addSubview:toggle];

        UILayoutGuide *margin = cell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [title.leadingAnchor constraintEqualToAnchor:margin.leadingAnchor],
            [title.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:9],
            [note.leadingAnchor constraintEqualToAnchor:margin.leadingAnchor],
            [note.trailingAnchor constraintLessThanOrEqualToAnchor:toggle.leadingAnchor constant:-12],
            [note.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:1],
            [note.bottomAnchor constraintLessThanOrEqualToAnchor:cell.contentView.bottomAnchor constant:-9],
            [toggle.trailingAnchor constraintEqualToAnchor:margin.trailingAnchor],
            [toggle.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        ]];
    }

    UILabel *title = (UILabel *)[cell viewWithTag:211];
    title.text = axs_ring_page_localized(self, [spec propertyForKey:@"label"]);
    UILabel *note = (UILabel *)[cell viewWithTag:212];
    note.text = axs_ring_page_localized(self, [spec propertyForKey:@"note"]);

    UISwitch *toggle = (UISwitch *)[cell viewWithTag:213];
    id read = [self respondsToSelector:@selector(readPreferenceValue:)]
        ? [self readPreferenceValue:spec] : nil;
    toggle.on = [read isKindOfClass:[NSNumber class]] ? [read boolValue] : NO;
    objc_setAssociatedObject(toggle, @selector(axsRingSpec), spec, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return cell;
}

static void axs_ringPage_switchChanged_imp(id self, SEL _cmd, UISwitch *sender) {
    PSSpecifier *spec = objc_getAssociatedObject(sender, @selector(axsRingSpec));
    if (spec == nil) return;
    [self setPreferenceValue:@(sender.on) specifier:spec];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.susudear.screencoreprefs/saved"), NULL, NULL, true);
}

// note rows grow with their inline gray text
static CGFloat axs_ringPage_height_imp(id self, SEL _cmd, id tableView, id indexPath) {
    @try {
        PSSpecifier *spec = nil;
        if ([self respondsToSelector:@selector(specifierAtIndexPath:)]) {
            spec = [self specifierAtIndexPath:indexPath];
        }
        NSString *note = [spec propertyForKey:@"note"];
        if (note != nil) {
            NSString *text = axs_ring_page_localized(self, note);
            CGRect bounds = [text boundingRectWithSize:CGSizeMake(300, CGFLOAT_MAX)
                                               options:NSStringDrawingUsesLineFragmentOrigin
                                            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:11]}
                                               context:nil];
            return ceil(bounds.size.height) + 30.0;
        }
    } @catch (NSException *exception) { }
    return ((CGFloat(*)(id, SEL, id, id))axs_ringPage_origHeight)(self, _cmd, tableView, indexPath);
}

static id axs_ringPage_cellForRow_imp(id self, SEL _cmd, id tableView, id indexPath) {
    @try {
        PSSpecifier *spec = nil;
        if ([self respondsToSelector:@selector(specifierAtIndexPath:)]) {
            spec = [self specifierAtIndexPath:indexPath];
        }
        NSString *cellType = [spec propertyForKey:@"cell"];
        if ([cellType isEqualToString:@"PSSliderCell"]) {
            return axs_ringPage_sliderCell(self, tableView, spec);
        }
        NSString *key = [spec propertyForKey:@"key"];
        if (axs_ring_page_isColorKey(key)) {
            return axs_ringPage_colorCell(self, _cmd, tableView, indexPath, spec);
        }
        if ([spec propertyForKey:@"note"] != nil) {
            return axs_ringPage_noteSwitchCell(self, tableView, spec);
        }

        UITableViewCell *cell = ((UITableViewCell *(*)(id, SEL, id, id))axs_ringPage_origCellForRow)(self, _cmd, tableView, indexPath);

        if ([key isEqualToString:AxsHoldLaunchKeyExclude]) {
            NSString *subtitle = axs_ringPage_subtitle_imp(self, _cmd, spec);
            if (subtitle != nil && cell.detailTextLabel != nil) {
                cell.detailTextLabel.text = subtitle;
            }
        }
        return cell;
    } @catch (NSException *exception) {
        return ((UITableViewCell *(*)(id, SEL, id, id))axs_ringPage_origCellForRow)(self, _cmd, tableView, indexPath);
    }
}

static void axs_ringPage_didSelect_imp(id self, SEL _cmd, id tableView, id indexPath) {
    @try {
        PSSpecifier *spec = nil;
        if ([self respondsToSelector:@selector(specifierAtIndexPath:)]) {
            spec = [self specifierAtIndexPath:indexPath];
        }
        NSString *key = [spec propertyForKey:@"key"];
        if (axs_ring_page_isColorKey(key)) {
            if (axs_ring_page_isBeautifyColorKey(key)) {
                axs_holdlaunch_presentNotImplementedAlert(self);
                return;
            }
            axs_holdlaunch_presentColorPicker(self, axs_ring_page_colorTitle(self, key), key);
            return;
        }
    } @catch (NSException *exception) { }
    ((void(*)(id, SEL, id, id))axs_ringPage_origDidSelect)(self, _cmd, tableView, indexPath);
}

static void axs_ringPage_applySliderValue(id self, UISlider *slider, double value) {
    PSSpecifier *spec = objc_getAssociatedObject(slider, @selector(axsRingSpec));
    if (spec == nil) return;
    double step = axs_ring_page_stepForSpec(spec, slider.minimumValue, slider.maximumValue);
    value = axs_ring_page_snap(value, slider.minimumValue, slider.maximumValue, step);
    slider.value = value;

    // PSListController writes the specifier's own domain and handles the
    // plist save; re-post the ScreenCore save ping so the ring engine reloads
    [self setPreferenceValue:@(value) specifier:spec];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.susudear.screencoreprefs/saved"), NULL, NULL, true);

    UILabel *valueLabel = (UILabel *)[(UIView *)slider.superview viewWithTag:105];
    valueLabel.text = [NSString stringWithFormat:@"%.2f", value];
}

static void axs_ringPage_sliderChanged_imp(id self, SEL _cmd, UISlider *sender) {
    axs_ringPage_applySliderValue(self, sender, sender.value);
}

static void axs_ringPage_minus_imp(id self, SEL _cmd, UIButton *sender) {
    UISlider *slider = (UISlider *)[(UIView *)sender.superview viewWithTag:103];
    if (slider == nil) return;
    PSSpecifier *spec = objc_getAssociatedObject(sender, @selector(axsRingSpec));
    double step = axs_ring_page_stepForSpec(spec, slider.minimumValue, slider.maximumValue);
    axs_ringPage_applySliderValue(self, slider, slider.value - step);
}

static void axs_ringPage_plus_imp(id self, SEL _cmd, UIButton *sender) {
    UISlider *slider = (UISlider *)[(UIView *)sender.superview viewWithTag:103];
    if (slider == nil) return;
    PSSpecifier *spec = objc_getAssociatedObject(sender, @selector(axsRingSpec));
    double step = axs_ring_page_stepForSpec(spec, slider.minimumValue, slider.maximumValue);
    axs_ringPage_applySliderValue(self, slider, slider.value + step);
}

static void axs_ringPage_colorTapped_imp(id self, SEL _cmd, UIButton *sender) {
    NSString *key = objc_getAssociatedObject(sender, @selector(axsRingColorKey));
    if (key.length == 0) return;
    if (axs_ring_page_isBeautifyColorKey(key)) {
        axs_holdlaunch_presentNotImplementedAlert(self);
        return;
    }
    axs_holdlaunch_presentColorPicker(self, axs_ring_page_colorTitle(self, key), key);
}

// SCSplitSettingsController: threshold quantize + ring row rendering hooks.
// The ring rows sit flat in SplitSettings.plist; every other row is
// declarative and passes through untouched.
static void axs_holdlaunch_installSettingsHooks(void) {
    if (axs_settingsInstalled) return;
    Class cls = objc_getClass("SCSplitSettingsController");
    if (!cls) return;

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

    struct { SEL sel; IMP imp; IMP *orig; } methodHooks[] = {
        { @selector(specifiers), (IMP)axs_ringPage_specifiers_imp, &axs_ringPage_origSpecifiers },
        { @selector(tableView:cellForRowAtIndexPath:), (IMP)axs_ringPage_cellForRow_imp, &axs_ringPage_origCellForRow },
        { @selector(tableView:didSelectRowAtIndexPath:), (IMP)axs_ringPage_didSelect_imp, &axs_ringPage_origDidSelect },
        { @selector(tableView:heightForRowAtIndexPath:), (IMP)axs_ringPage_height_imp, &axs_ringPage_origHeight },
    };
    for (NSUInteger i = 0; i < sizeof(methodHooks) / sizeof(methodHooks[0]); i++) {
        Method m = class_getInstanceMethod(cls, methodHooks[i].sel);
        if (!m) continue;
        IMP orig = method_getImplementation(m);
        if (class_addMethod(cls, methodHooks[i].sel, methodHooks[i].imp, method_getTypeEncoding(m))) {
            *methodHooks[i].orig = orig;
        } else {
            MSHookMessageEx(cls, methodHooks[i].sel, methodHooks[i].imp, methodHooks[i].orig);
        }
    }
    class_addMethod(cls, @selector(getSubtitleForSpecifier:), (IMP)axs_ringPage_subtitle_imp, "@@:@");
    class_addMethod(cls, @selector(axs_ringMinus:), (IMP)axs_ringPage_minus_imp, "v@:@");
    class_addMethod(cls, @selector(axs_ringPlus:), (IMP)axs_ringPage_plus_imp, "v@:@");
    class_addMethod(cls, @selector(axs_ringSliderChanged:), (IMP)axs_ringPage_sliderChanged_imp, "v@:@");
    class_addMethod(cls, @selector(axs_ringSwitchChanged:), (IMP)axs_ringPage_switchChanged_imp, "v@:@");
    class_addMethod(cls, @selector(axs_ringColorTapped:), (IMP)axs_ringPage_colorTapped_imp, "v@:@");
    class_addMethod(cls, @selector(colorPickerControllerDidFinish:), (IMP)axs_holdlaunch_colorPickerDidFinish_imp, "v@:@");

    axs_settingsInstalled = YES;
    axs_holdlaunch_log(@"settings hooks installed (quantize + ring rows)");
}

// ---------------------------------------------------------------------------

%group AxsHoldLaunchSettingsTrigger

%hook PSListController

- (void)loadView {
    axs_holdlaunch_log(@"PSListController loadView: %@",
                       NSStringFromClass([self class]));
    axs_holdlaunch_installSettingsHooks();
    %orig;
}

%end

%end

// ---------------------------------------------------------------------------

%group AxsHoldLaunchSpringBoardTrigger

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    axs_holdlaunch_log(@"springboard didFinishLaunching");
    axs_holdlaunch_installSpringBoardHooks();
    %orig;
}

%end

%end

// ---------------------------------------------------------------------------

%ctor {
    @autoreleasepool {
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
