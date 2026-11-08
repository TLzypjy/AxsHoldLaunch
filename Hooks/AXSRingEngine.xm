#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AxsHoldLaunchConfig.h"

// ---------------------------------------------------------------------------
// Ring/glow engine: one shared overlay UIWindow, one ring (+ optional glow)
// layer pair per floating container / docked mini window.
//  - Excluded apps: cached per container (no per-frame plist reads).
//  - Style (colors/radius/glow switches): rebuilt only when styleSig changes.
//  - Geometry: path-only update every display-link tick inside a disabled-
//    actions CATransaction -> no implicit animations, zero visible lag.
//  - Idle: display link stops itself after 10 consecutive empty frames.
// ---------------------------------------------------------------------------

@interface AXSRingEngineTarget : NSObject
+ (instancetype)shared;
- (void)axsRingTick;
@end

static UIWindow *axs_ringWindow = nil;
static BOOL axs_ringWindowLoggedGone = NO;
static CADisplayLink *axs_ringLink = nil;
static int axs_ringIdleFrames = 0;

// layer storage keyed by "ptr" for containers, "docked-ptr" for mini windows
static NSMutableDictionary<NSString *, NSMutableArray<CALayer *> *> *axs_ringLayers = nil;
static NSMutableDictionary<NSString *, NSString *> *axs_ringStyleSig = nil;   // colors/radius/glow
static NSMutableDictionary<NSString *, NSString *> *axs_ringFrameSig = nil;   // screen-frame
static NSMutableDictionary<NSString *, NSNumber *> *axs_ringExcludedCache = nil;
static NSMutableDictionary<NSString *, NSString *> *axs_containerBundle = nil; // container ptr -> bundle
static NSMutableDictionary<NSString *, NSString *> *axs_sessionBundle = nil;   // session ptr  -> bundle

static void axs_ring_engine_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void axs_ring_engine_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[AxsHoldLaunch:Ring] %@", message);
    @try {
        NSString *path = @"/var/mobile/Library/Caches/AxsHoldLaunch.log";
        NSString *line = [NSString stringWithFormat:@"%@\n", message];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle == nil) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
    } @catch (NSException *exception) { }
}

static UIColor *axs_ring_parseHex(NSString *hex, UIColor *fallback) {
    if (![hex isKindOfClass:[NSString class]] || hex.length == 0) return fallback;
    NSString *h = [[hex stringByReplacingOccurrencesOfString:@"#" withString:@""]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (h.length == 6 || h.length == 8) {
        unsigned int v = 0;
        NSScanner *scanner = [NSScanner scannerWithString:h];
        [scanner scanHexInt:&v];
        if (h.length == 6) v = (v << 8) | 0xFFu;
        return [UIColor colorWithRed:((v >> 24) & 0xFF) / 255.0
                               green:((v >> 16) & 0xFF) / 255.0
                                blue:((v >> 8) & 0xFF) / 255.0
                               alpha:(v & 0xFF) / 255.0];
    }
    return fallback;
}

static NSString *axs_ring_keyFor(id object) {
    return [NSString stringWithFormat:@"%p", object];
}

// --- C API fed by AxsHoldLaunchMain.xm hooks ---

void axs_ring_engine_wake(void);

void axs_ring_setSessionBundle(id session, NSString *bundle) {
    if (session == nil || ![bundle isKindOfClass:[NSString class]]) return;
    if (axs_sessionBundle == nil) axs_sessionBundle = [NSMutableDictionary new];
    NSString *key = axs_ring_keyFor(session);
    NSString *old = axs_sessionBundle[key];
    if ([old isEqualToString:bundle]) return;
    axs_sessionBundle[key] = bundle;
    // a session was created -> a floating window may appear; if the display
    // link stopped itself while idle, bring it back
    axs_ring_engine_wake();
}

void axs_ring_noteContainerForSession(id container, id session) {
    if (container == nil || session == nil) return;
    if (axs_sessionBundle == nil || axs_containerBundle == nil) {
        if (axs_containerBundle == nil) axs_containerBundle = [NSMutableDictionary new];
        if (axs_sessionBundle == nil) axs_sessionBundle = [NSMutableDictionary new];
    }
    NSString *bundle = axs_sessionBundle[axs_ring_keyFor(session)];
    if (bundle.length == 0) return;
    NSString *ck = axs_ring_keyFor(container);
    NSString *old = axs_containerBundle[ck];
    if ([old isEqualToString:bundle]) return;
    axs_containerBundle[ck] = bundle;
    [axs_ringExcludedCache removeObjectForKey:ck];
}

void axs_ring_sessionClosed(id session) {
    if (session == nil) return;
    if (axs_sessionBundle == nil) return;
    NSString *sk = axs_ring_keyFor(session);
    NSString *bundle = axs_sessionBundle[sk];
    if (axs_containerBundle != nil) {
        for (NSString *ck in [axs_containerBundle allKeys]) {
            if (bundle != nil && ![axs_containerBundle[ck] isEqualToString:bundle]) continue;
            NSMutableArray<CALayer *> *layers = axs_ringLayers[ck];
            if (layers.count > 0) {
                [CATransaction begin];
                [CATransaction setAnimationDuration:0.25];
                for (CALayer *l in layers) { l.opacity = 0.0; }
                [CATransaction setCompletionBlock:^{
                    for (CALayer *l in layers) { [l removeFromSuperlayer]; }
                }];
                [CATransaction commit];
            }
            [axs_ringLayers removeObjectForKey:ck];
            [axs_ringStyleSig removeObjectForKey:ck];
            [axs_ringFrameSig removeObjectForKey:ck];
            [axs_ringExcludedCache removeObjectForKey:ck];
            [axs_containerBundle removeObjectForKey:ck];
        }
    }
    [axs_sessionBundle removeObjectForKey:sk];
}

void axs_ring_sessionDocked(id session) { }

void axs_ring_configChanged(void) {
    if (axs_ringExcludedCache != nil) [axs_ringExcludedCache removeAllObjects];
    if (axs_ringStyleSig != nil) [axs_ringStyleSig removeAllObjects];
}

void axs_ring_engine_wake(void) {
    if (axs_ringLink != nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (axs_ringLink != nil) return;
        axs_ringLink = [CADisplayLink displayLinkWithTarget:[AXSRingEngineTarget shared]
                                                   selector:@selector(axsRingTick)];
        [axs_ringLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        axs_ring_engine_log(@"ring engine display link started");
    });
}

// --- internals ---

static UIWindow *axs_ring_ensureOverlayWindow(CGFloat hostLevel) {
    if (axs_ringWindow != nil) {
        if (axs_ringWindow.windowLevel != hostLevel + 1) axs_ringWindow.windowLevel = hostLevel + 1;
        return axs_ringWindow;
    }
    axs_ringWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    axs_ringWindow.windowLevel = hostLevel + 1;
    axs_ringWindow.userInteractionEnabled = NO;
    axs_ringWindow.opaque = NO;
    axs_ringWindow.backgroundColor = [UIColor clearColor];
    axs_ringWindow.rootViewController = [UIViewController new];
    axs_ringWindow.hidden = NO;
    axs_ring_engine_log(@"ring overlay window created, level=%.0f", axs_ringWindow.windowLevel);
    return axs_ringWindow;
}

static UIView *axs_ring_findContainer(UIView *root, int depth) {
    if (root == nil || depth > 14) return nil;
    if ([NSStringFromClass(root.class) isEqualToString:@"SCFloatingContainerView"]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = axs_ring_findContainer(sub, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

static UIView *axs_ring_findDockedItem(UIView *root, int depth) {
    if (root == nil || depth > 14) return nil;
    if ([NSStringFromClass(root.class) isEqualToString:@"SCDockedFloatingItemView"]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = axs_ring_findDockedItem(sub, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

static BOOL axs_ring_bundleExcluded(NSString *bundle, AxsHoldLaunchConfig *config) {
    if (bundle.length == 0) return NO;
    NSArray *list = [config axs_holdlaunch_ringExcludedApplications];
    for (NSString *b in list) {
        if ([b isKindOfClass:[NSString class]] && [b isEqualToString:bundle]) return YES;
    }
    return NO;
}

static void axs_ring_removeLayers(NSMutableArray<CALayer *> *layers) {
    if (layers == nil || layers.count == 0) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *l in layers) { [l removeFromSuperlayer]; }
    [CATransaction commit];
}

static void axs_ring_syncContainer(UIView *container, UIWindow *hostWindow, AxsHoldLaunchConfig *config) {
    NSString *ck = axs_ring_keyFor(container);
    CGFloat level = hostWindow ? hostWindow.windowLevel : 1000.0;

    // exclusion check, cached per container
    NSString *bundle = axs_containerBundle[ck] ?: @"";
    NSNumber *cachedExcluded = axs_ringExcludedCache[ck];
    BOOL excluded;
    if (cachedExcluded != nil) {
        excluded = [cachedExcluded boolValue];
    } else {
        excluded = axs_ring_bundleExcluded(bundle, config);
        axs_ringExcludedCache[ck] = @(excluded);
        axs_ring_engine_log(@"ring exclusion cached: bundle=%@ excluded=%d", bundle, (int)excluded);
    }

    BOOL wantRings = [config axs_holdlaunch_isTheirRingEnabled] && !excluded;
    NSMutableArray<CALayer *> *layers = axs_ringLayers[ck];

    if (!wantRings) {
        axs_ring_removeLayers(layers);
        [axs_ringLayers removeObjectForKey:ck];
        [axs_ringStyleSig removeObjectForKey:ck];
        [axs_ringFrameSig removeObjectForKey:ck];
        return;
    }

    // style signature (no geometry) - rebuild only on style/config changes
    BOOL custom = [config axs_holdlaunch_isTheirRingCustomEnabled];
    UIColor *ringColor = custom
        ? axs_ring_parseHex([config axs_holdlaunch_isTheirRingColor],
                            [UIColor colorWithRed:0.2 green:0.63 blue:1.0 alpha:1.0])
        : [UIColor colorWithRed:0.2 green:0.63 blue:1.0 alpha:1.0];
    BOOL glowOn = [config axs_holdlaunch_isTheirGlowEnabled];
    BOOL glowCustom = [config axs_holdlaunch_isTheirGlowCustomEnabled];
    UIColor *glowColor = glowCustom
        ? axs_ring_parseHex([config axs_holdlaunch_isTheirGlowColor], [UIColor whiteColor])
        : [UIColor whiteColor];
    CGFloat radius = [config axs_holdlaunch_splitWindowCornerRadius];

    NSString *styleSig = [NSString stringWithFormat:@"r=%.0f,%@,%d,%@,g=%d,%d,%@",
                          radius, bundle, (int)custom,
                          custom ? [config axs_holdlaunch_isTheirRingColor] : @"",
                          (int)glowOn, (int)glowCustom,
                          glowCustom ? [config axs_holdlaunch_isTheirGlowColor] : @""];

    if (layers == nil || ![axs_ringStyleSig[ck] isEqualToString:styleSig]) {
        axs_ring_removeLayers(layers);
        layers = [NSMutableArray array];

        UIWindow *overlay = axs_ring_ensureOverlayWindow(level);
        UIView *overlayRoot = overlay.rootViewController.view;
        CGRect screenFrame = [container convertRect:container.bounds toView:overlayRoot];
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:screenFrame
                                                   byRoundingCorners:UIRectCornerAllCorners
                                                         cornerRadii:CGSizeMake(radius, radius)];

        CAShapeLayer *ring = [CAShapeLayer layer];
        ring.path = path.CGPath;
        ring.strokeColor = ringColor.CGColor;
        ring.fillColor = nil;
        ring.lineWidth = 1.0;
        ring.opacity = 1.0;
        ring.zPosition = level;
        [overlayRoot.layer addSublayer:ring];
        [layers addObject:ring];

        if (glowOn) {
            CAShapeLayer *glow = [CAShapeLayer layer];
            glow.path = path.CGPath;
            glow.strokeColor = glowColor.CGColor;
            glow.fillColor = nil;
            glow.lineWidth = 6.0;
            glow.opacity = 0.35;
            glow.zPosition = level;
            [overlayRoot.layer addSublayer:glow];
            [layers addObject:glow];
        }

        axs_ringLayers[ck] = layers;
        axs_ringStyleSig[ck] = styleSig;
        axs_ringFrameSig[ck] = @""; // force one geometry pass
    }

    // geometry sync every tick: path-only, no implicit animation
    UIWindow *overlay = axs_ring_ensureOverlayWindow(level);
    UIView *overlayRoot = overlay.rootViewController.view;
    CGRect screenFrame = [container convertRect:container.bounds toView:overlayRoot];
    NSString *frameSig = [NSString stringWithFormat:@"%.1f,%.1f,%.1f,%.1f",
                          screenFrame.origin.x, screenFrame.origin.y,
                          screenFrame.size.width, screenFrame.size.height];
    if (![axs_ringFrameSig[ck] isEqualToString:frameSig]) {
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:screenFrame
                                                   byRoundingCorners:UIRectCornerAllCorners
                                                         cornerRadii:CGSizeMake(radius, radius)];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (CALayer *l in layers) {
            if ([l isKindOfClass:[CAShapeLayer class]]) ((CAShapeLayer *)l).path = path.CGPath;
            l.zPosition = level;
        }
        [CATransaction commit];
        axs_ringFrameSig[ck] = frameSig;
    }
}

static void axs_ring_syncMiniRing(UIView *docked, AxsHoldLaunchConfig *config) {
    NSString *dk = [NSString stringWithFormat:@"docked-%@", axs_ring_keyFor(docked)];

    BOOL miniOn = [config axs_holdlaunch_isTheirMiniRingEnabled];
    NSMutableArray<CALayer *> *layers = axs_ringLayers[dk];

    if (!miniOn) {
        axs_ring_removeLayers(layers);
        [axs_ringLayers removeObjectForKey:dk];
        [axs_ringStyleSig removeObjectForKey:dk];
        [axs_ringFrameSig removeObjectForKey:dk];
        return;
    }

    BOOL custom = [config axs_holdlaunch_isTheirRingCustomEnabled];
    UIColor *ringColor = custom
        ? axs_ring_parseHex([config axs_holdlaunch_isTheirRingColor],
                            [UIColor colorWithRed:0.2 green:0.63 blue:1.0 alpha:1.0])
        : [UIColor colorWithRed:0.2 green:0.63 blue:1.0 alpha:1.0];

    CGFloat radius = docked.layer.cornerRadius;
    if (radius < 1) radius = 14.0;
    NSString *styleSig = [NSString stringWithFormat:@"mini,r=%.0f,%d", radius, (int)custom];

    if (layers == nil || ![axs_ringStyleSig[dk] isEqualToString:styleSig]) {
        axs_ring_removeLayers(layers);
        layers = [NSMutableArray array];

        UIWindow *overlay = axs_ring_ensureOverlayWindow(1000);
        UIView *overlayRoot = overlay.rootViewController.view;
        CGRect screenFrame = [docked convertRect:docked.bounds toView:overlayRoot];
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:screenFrame
                                                   byRoundingCorners:UIRectCornerAllCorners
                                                         cornerRadii:CGSizeMake(radius, radius)];
        CAShapeLayer *ring = [CAShapeLayer layer];
        ring.path = path.CGPath;
        ring.strokeColor = ringColor.CGColor;
        ring.fillColor = nil;
        ring.lineWidth = 1.0;
        ring.zPosition = 1000;
        [overlayRoot.layer addSublayer:ring];
        [layers addObject:ring];

        axs_ringLayers[dk] = layers;
        axs_ringStyleSig[dk] = styleSig;
        axs_ringFrameSig[dk] = @"";
    }

    UIWindow *overlay = axs_ring_ensureOverlayWindow(1000);
    UIView *overlayRoot = overlay.rootViewController.view;
    CGRect screenFrame = [docked convertRect:docked.bounds toView:overlayRoot];
    NSString *frameSig = [NSString stringWithFormat:@"%.1f,%.1f,%.1f,%.1f",
                          screenFrame.origin.x, screenFrame.origin.y,
                          screenFrame.size.width, screenFrame.size.height];
    if (![axs_ringFrameSig[dk] isEqualToString:frameSig]) {
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:screenFrame
                                                   byRoundingCorners:UIRectCornerAllCorners
                                                         cornerRadii:CGSizeMake(radius, radius)];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (CALayer *l in layers) {
            if ([l isKindOfClass:[CAShapeLayer class]]) ((CAShapeLayer *)l).path = path.CGPath;
            l.zPosition = 1000;
        }
        [CATransaction commit];
        axs_ringFrameSig[dk] = frameSig;
    }
}

static void axs_ring_tick(void) {
    @try {
        AxsHoldLaunchConfig *config = [AxsHoldLaunchConfig axs_holdlaunch_shared];
        if (axs_ringLayers == nil) {
            axs_ringLayers = [NSMutableDictionary new];
            axs_ringStyleSig = [NSMutableDictionary new];
            axs_ringFrameSig = [NSMutableDictionary new];
            axs_ringExcludedCache = [NSMutableDictionary new];
            axs_containerBundle = [NSMutableDictionary new];
            axs_sessionBundle = [NSMutableDictionary new];
        }

        BOOL floatingOn = [config axs_holdlaunch_isTheirRingEnabled];
        BOOL miniOn = [config axs_holdlaunch_isTheirMiniRingEnabled];

        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        CGFloat hostLevel = 1000.0;
        int ringCount = 0;

        if (floatingOn || miniOn) {
            NSArray<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes.allObjects;
            for (UIScene *scene in scenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *window in ws.windows) {
                    if (window == axs_ringWindow) continue;
                    if (window.hidden) continue;
                    if (window.windowLevel > hostLevel) hostLevel = window.windowLevel;

                    UIView *baseView = window.rootViewController.view ?: window;

                    UIView *container = axs_ring_findContainer(baseView, 0);
                    if (container != nil && container.window != nil && !container.hidden
                        && container.alpha > 0.01 && container.frame.size.width > 60) {
                        NSString *ck = axs_ring_keyFor(container);
                        [seen addObject:ck];
                        if (floatingOn) {
                            ringCount++;
                            axs_ring_syncContainer(container, window, config);
                        }
                    }

                    if (miniOn) {
                        UIView *docked = axs_ring_findDockedItem(baseView, 0);
                        if (docked != nil && docked.window != nil && !docked.hidden
                            && docked.frame.size.width > 20) {
                            NSString *dk = [NSString stringWithFormat:@"docked-%@", axs_ring_keyFor(docked)];
                            [seen addObject:dk];
                            ringCount++;
                            axs_ring_syncMiniRing(docked, config);
                        }
                    }
                }
            }
        }

        // drop layers for views that disappeared this tick
        for (NSString *key in [axs_ringLayers allKeys]) {
            if (![seen containsObject:key]) {
                axs_ring_removeLayers(axs_ringLayers[key]);
                [axs_ringLayers removeObjectForKey:key];
                [axs_ringStyleSig removeObjectForKey:key];
                [axs_ringFrameSig removeObjectForKey:key];
                [axs_ringExcludedCache removeObjectForKey:key];
            }
        }

        if (ringCount > 0) {
            axs_ring_ensureOverlayWindow(hostLevel);
            if (axs_ringWindow.hidden) axs_ringWindow.hidden = NO;
            axs_ringWindowLoggedGone = NO;
        } else if (axs_ringWindow != nil && !axs_ringWindow.hidden) {
            axs_ringWindow.hidden = YES;
            axs_ringWindowLoggedGone = YES;
            axs_ring_engine_log(@"ring overlay window count = 0");
        }

        // idle: stop the display link when nothing has been drawn for 10 frames
        if (ringCount == 0 && axs_ringLayers.count == 0) {
            axs_ringIdleFrames++;
            if (axs_ringIdleFrames >= 10 && axs_ringLink != nil) {
                axs_ring_engine_log(@"ring engine idle, display link stopped");
                [axs_ringLink invalidate];
                axs_ringLink = nil;
                axs_ringIdleFrames = 0;
            }
        } else {
            axs_ringIdleFrames = 0;
        }
    } @catch (NSException *exception) {
        axs_ring_engine_log(@"ring tick exception: %@", exception);
    }
}

@implementation AXSRingEngineTarget
+ (instancetype)shared {
    static AXSRingEngineTarget *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [self new]; });
    return shared;
}
- (void)axsRingTick { axs_ring_tick(); }
@end
