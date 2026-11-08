#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AxsHoldLaunchConfig.h"

// ---------------------------------------------------------------------------
// Ring/glow engine (event-driven, LingDong-style rendering).
//
// Registry: floating containers and docked mini items register themselves via
// -didMoveToWindow hooks; sessions pair up through sc_sessionForContainerView:,
// sc_sessionDidBeginHosting: and the bundle setter; sc_closeSession: tears
// entries down. The tick walks ONLY the registry - no view-tree scanning, no
// per-frame plist reads.
//
// Rendering (this is the part that makes the ring actually visible): the ring
// layers are injected as sublayers of the floating window's OWN layer tree,
// exactly like LingDong injects into the Dynamic Island's window. No overlay
// UIWindow: same-window layers are always composited above the content they
// cover, cannot be hidden by a level mismatch, and CALayers never intercept
// touches.
// ---------------------------------------------------------------------------

@interface AXSRingEngineTarget : NSObject
+ (instancetype)shared;
- (void)axsRingTick;
@end

static CADisplayLink *axs_ringLink = nil;

// registry (keys are pointer strings, object values are weak)
static NSMapTable<NSString *, UIView *> *axs_views = nil;   // entryKey -> weak view
static NSMapTable<NSString *, UIWindow *> *axs_hosts = nil; // entryKey -> weak host window
// entryKey -> { kind, session, sessionPtr, bundle, excluded, docked }
static NSMutableDictionary<NSString *, NSMutableDictionary *> *axs_meta = nil;
static NSMutableDictionary<NSString *, NSString *> *axs_sessionBundles = nil;

// rendering state per entry
static NSMutableDictionary<NSString *, NSMutableArray<CALayer *> *> *axs_layers = nil;
static NSMutableDictionary<NSString *, NSString *> *axs_styleSig = nil;
static NSMutableDictionary<NSString *, NSString *> *axs_frameSig = nil;

static NSString *axs_ring_keyFor(id object) {
    return [NSString stringWithFormat:@"%p", object];
}

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

static UIColor *axs_ring_randomColor(void) {
    return [UIColor colorWithHue:(arc4random_uniform(1000) / 1000.0)
                      saturation:0.85 brightness:1.0 alpha:1.0];
}

static void axs_ring_ensureMaps(void) {
    if (axs_meta != nil) return;
    axs_views = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory
                                      valueOptions:NSMapTableWeakMemory];
    axs_hosts = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory
                                      valueOptions:NSMapTableWeakMemory];
    axs_meta = [NSMutableDictionary new];
    axs_sessionBundles = [NSMutableDictionary new];
    axs_layers = [NSMutableDictionary new];
    axs_styleSig = [NSMutableDictionary new];
    axs_frameSig = [NSMutableDictionary new];
}

// total number of live ring layers; log whenever it changes
static void axs_ring_logLayerCount(void) {
    NSUInteger total = 0;
    for (NSMutableArray<CALayer *> *ls in axs_layers.allValues) { total += ls.count; }
    axs_ring_engine_log(@"ring layer attach: count=%lu", (unsigned long)total);
}

static void axs_ring_detachLayers(NSString *key) {
    NSMutableArray<CALayer *> *layers = axs_layers[key];
    if (layers.count > 0) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (CALayer *l in layers) { [l removeFromSuperlayer]; }
        [CATransaction commit];
    }
    BOOL had = (axs_layers[key] != nil);
    [axs_layers removeObjectForKey:key];
    [axs_styleSig removeObjectForKey:key];
    [axs_frameSig removeObjectForKey:key];
    if (had) axs_ring_logLayerCount();
}

// --- C API fed by AxsHoldLaunchMain.xm hooks ---
// .xm compiles as ObjC++; keep C linkage so Config.m (plain ObjC) can call in.
// Every entry point validates its arguments: hook signatures are discovered at
// runtime and a primitive sneaking through as `id` must not crash here.

extern "C" {

void axs_ring_engine_wake(void);

// didMoveToWindow: container (docked=NO) or docked mini item (docked=YES)
void axs_ring_noteContainer(id view, id hostWindow, BOOL docked) {
    if (![view isKindOfClass:[UIView class]]) return;
    if (hostWindow != nil && ![hostWindow isKindOfClass:[UIWindow class]]) return;
    axs_ring_ensureMaps();
    NSString *key = [NSString stringWithFormat:@"%c%@", docked ? 'd' : 'c', axs_ring_keyFor(view)];
    [axs_views setObject:view forKey:key];
    UIWindow *window = hostWindow ?: [(UIView *)view window];
    if (window != nil) [axs_hosts setObject:window forKey:key];

    NSMutableDictionary *m = axs_meta[key];
    if (m == nil) {
        m = [NSMutableDictionary new];
        axs_meta[key] = m;
        m[@"kind"] = docked ? @"docked" : @"float";
    }
    if (!docked) m[@"docked"] = @NO; // a floating container back in a window is hosting again
    UIWindow *host = [axs_hosts objectForKey:key];
    id sessionPtr = m[@"sessionPtr"];
    axs_ring_engine_log(@"ring container noted: session=%p host=%p bounds=%@",
                        sessionPtr ? (void *)[sessionPtr pointerValue] : NULL,
                        host, NSStringFromCGRect([(UIView *)view bounds]));
    axs_ring_engine_wake();
}

// sc_sessionForContainerView: - the authoritative container<->session pairing
// Session-taking C APIs take raw words: callers gate on the hooked method's
// runtime type encoding, and bridging here would let ARC retain a primitive.
void axs_ring_noteContainerForSession(void *container, void *session) {
    if (container == NULL || session == NULL) return;
    id containerView = (__bridge id)container;
    id sessionObject = (__bridge id)session;
    if (![containerView isKindOfClass:[UIView class]]) return;
    axs_ring_ensureMaps();
    NSString *key = [NSString stringWithFormat:@"c%@", axs_ring_keyFor(containerView)];
    NSMutableDictionary *m = axs_meta[key];
    if (m == nil) {
        m = [NSMutableDictionary new];
        axs_meta[key] = m;
        m[@"kind"] = @"float";
    }
    NSString *sessionKey = axs_ring_keyFor(sessionObject);
    m[@"session"] = sessionKey;
    m[@"sessionPtr"] = [NSValue valueWithPointer:session];
    m[@"docked"] = @NO;
    NSString *bundle = axs_sessionBundles[sessionKey];
    if (bundle != nil && ![m[@"bundle"] isEqualToString:bundle]) {
        m[@"bundle"] = bundle;
        m[@"excluded"] = nil; // re-evaluate exclusion for the new app
    }
    UIWindow *host = [(UIView *)containerView window] ?: [axs_hosts objectForKey:key];
    if (host != nil) [axs_hosts setObject:host forKey:key];
    axs_ring_engine_log(@"ring container noted: session=%p host=%p bounds=%@",
                        session, host, NSStringFromCGRect([(UIView *)containerView bounds]));
    axs_ring_engine_wake();
}

// sessionForBundleIdentifier: / setSelectedBundleIdentifier: feed
void axs_ring_setSessionBundle(void *session, void *bundle) {
    if (session == NULL || bundle == NULL) return;
    NSString *bundleString = (__bridge id)bundle;
    if (![bundleString isKindOfClass:[NSString class]]) return;
    axs_ring_ensureMaps();
    NSString *sessionKey = axs_ring_keyFor((__bridge id)session);
    if ([axs_sessionBundles[sessionKey] isEqualToString:bundleString]) return;
    axs_sessionBundles[sessionKey] = bundleString;
    for (NSString *key in [axs_meta allKeys]) {
        NSMutableDictionary *m = axs_meta[key];
        if (![m[@"session"] isEqualToString:sessionKey]) continue;
        if (![m[@"bundle"] isEqualToString:bundleString]) {
            m[@"bundle"] = bundleString;
            m[@"excluded"] = nil;
        }
    }
    axs_ring_engine_wake();
}

// sc_sessionDidBeginHosting: - try to bind the session's own container view
void axs_ring_sessionHostingBegan(void *session) {
    if (session == NULL) return;
    id sessionObject = (__bridge id)session;
    if (![sessionObject isKindOfClass:[NSObject class]]) return;
    id container = nil;
    @try { container = [sessionObject valueForKey:@"containerView"]; } @catch (NSException *e) { }
    if ([container isKindOfClass:[UIView class]]) {
        axs_ring_noteContainerForSession((__bridge void *)container, session);
    }
    axs_ring_engine_wake();
}

// sc_closeSession: - drop the session's entries
void axs_ring_sessionClosed(void *session) {
    if (session == NULL || axs_meta == nil) return;
    NSString *sessionKey = axs_ring_keyFor((__bridge id)session);
    NSUInteger removed = 0;
    for (NSString *key in [axs_meta allKeys]) {
        NSMutableDictionary *m = axs_meta[key];
        if (![m[@"session"] isEqualToString:sessionKey]) continue;
        axs_ring_detachLayers(key);
        [axs_meta removeObjectForKey:key];
        [axs_views removeObjectForKey:key];
        [axs_hosts removeObjectForKey:key];
        removed++;
    }
    [axs_sessionBundles removeObjectForKey:sessionKey];
    if (removed > 0) {
        axs_ring_engine_log(@"ring session closed: session=%p entries=%lu", session, (unsigned long)removed);
    }
}

// sc_dockSession:fromCorner: fires on every layout pass, not only when the
// user docks - so this must NOT mark floating entries as docked (that made
// the ring detach/rebuild in a loop and never show). The only useful thing
// here is registering the docked mini item view when the session exposes one;
// docked minis otherwise register themselves via -didMoveToWindow.
void axs_ring_sessionDocked(void *session) {
    if (session == NULL) return;
    axs_ring_ensureMaps();
    NSString *sessionKey = axs_ring_keyFor((__bridge id)session);
    id item = nil;
    @try { item = [(__bridge id)session valueForKey:@"dockedItemView"]; } @catch (NSException *e) { }
    if (![item isKindOfClass:[UIView class]]) {
        @try { item = [(__bridge id)session valueForKey:@"dockedItem"]; } @catch (NSException *e) { }
    }
    if ([item isKindOfClass:[UIView class]]) {
        NSString *key = [NSString stringWithFormat:@"d%@", axs_ring_keyFor(item)];
        [axs_views setObject:item forKey:key];
        UIWindow *itemWindow = [item window];
        if (itemWindow != nil) [axs_hosts setObject:itemWindow forKey:key];
        NSMutableDictionary *m = axs_meta[key];
        if (m == nil) {
            m = [NSMutableDictionary new];
            axs_meta[key] = m;
            m[@"kind"] = @"docked";
        }
        m[@"session"] = sessionKey;
        m[@"sessionPtr"] = [NSValue valueWithPointer:session];
        NSString *bundle = axs_sessionBundles[sessionKey];
        if (bundle != nil && ![m[@"bundle"] isEqualToString:bundle]) {
            m[@"bundle"] = bundle;
            m[@"excluded"] = nil;
        }
    }
    axs_ring_engine_wake();
}

// config change from AxsHoldLaunchConfig: drop caches so the next tick rebuilds
void axs_ring_configChanged(void) {
    if (axs_meta == nil) return;
    for (NSString *key in axs_meta) {
        NSMutableDictionary *m = axs_meta[key];
        m[@"excluded"] = nil;
    }
    [axs_styleSig removeAllObjects];
}

void axs_ring_engine_wake(void) {
    if (axs_ringLink != nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (axs_ringLink != nil) return;
        axs_ring_ensureMaps();
        axs_ringLink = [CADisplayLink displayLinkWithTarget:[AXSRingEngineTarget shared]
                                                   selector:@selector(axsRingTick)];
        [axs_ringLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        axs_ring_engine_log(@"ring engine display link started");
    });
}

} // extern "C"

// --- rendering internals ---

static BOOL axs_ring_bundleExcluded(NSString *bundle, AxsHoldLaunchConfig *config) {
    if (bundle.length == 0) return NO;
    NSArray *list = [config axs_holdlaunch_ringExcludedApplications];
    for (NSString *b in list) {
        if ([b isKindOfClass:[NSString class]] && [b isEqualToString:bundle]) return YES;
    }
    return NO;
}

static UIBezierPath *axs_ring_path(CGRect frame, CGFloat radius) {
    if (radius < 1) radius = 0;
    if (radius * 2 > frame.size.width) radius = frame.size.width / 2;
    if (radius * 2 > frame.size.height) radius = frame.size.height / 2;
    return [UIBezierPath bezierPathWithRoundedRect:frame
                                 byRoundingCorners:UIRectCornerAllCorners
                                       cornerRadii:CGSizeMake(radius, radius)];
}

// rebuild all layers for one entry (style/params changed, or first attach).
// Layers go straight into the floating window's own layer tree.
static void axs_ring_buildLayers(NSString *key, UIView *view, UIWindow *host,
                                 BOOL docked, AxsHoldLaunchConfig *config) {
    axs_ring_detachLayers(key);

    BOOL miniOn = [config axs_holdlaunch_isTheirMiniRingEnabled];
    BOOL drawThis = docked ? miniOn : [config axs_holdlaunch_isTheirRingEnabled];
    if (!drawThis || host == nil) return;

    CGRect frame = [view convertRect:view.bounds toView:host];
    CGFloat radius = view.layer.cornerRadius;
    if (radius < 1) radius = docked ? 14.0 : [config axs_holdlaunch_splitWindowCornerRadius];

    NSMutableArray<CALayer *> *layers = [NSMutableArray array];
    CGFloat z = 9999.0; // above the floating content inside its own window

    // one color drives both the frame and its glow (LingDong behaviour):
    // random > custom > default blue
    UIColor *ringColor;
    if ([config axs_holdlaunch_ringFrameRandomColor]) {
        ringColor = axs_ring_randomColor();
    } else if ([config axs_holdlaunch_ringFrameCustomEnabled]) {
        ringColor = axs_ring_parseHex([config axs_holdlaunch_ringFrameColor],
                                      axs_ring_parseHex(@"#34A1FF", nil));
    } else {
        ringColor = axs_ring_parseHex(@"#34A1FF", nil);
    }
    CGFloat frameAlpha = [config axs_holdlaunch_ringFrameAlpha];

    // 外框 + 泛光 in ONE layer: the stroke is the ring, the layer's Gaussian
    // shadow is the glow (a real blur - the previous separate thick stroke
    // read as a fat band, not a glow). shadowRadius = 泛光范围, shadowOffset
    // = 泛光偏移.
    {
        CAShapeLayer *ring = [CAShapeLayer layer];
        ring.path = axs_ring_path(frame, radius).CGPath;
        ring.strokeColor = ringColor.CGColor;
        ring.fillColor = nil;
        ring.lineWidth = [config axs_holdlaunch_ringFrameWidth];
        ring.opacity = (float)frameAlpha;
        ring.zPosition = z;
        if ([config axs_holdlaunch_ringGlowEnabled]) {
            ring.shadowColor = ringColor.CGColor;
            ring.shadowOpacity = 0.85;
            ring.shadowRadius = [config axs_holdlaunch_ringGlowRange];
            ring.shadowOffset = CGSizeMake([config axs_holdlaunch_ringGlowOffsetX],
                                           -[config axs_holdlaunch_ringGlowOffsetY]);
        }
        [host.layer addSublayer:ring];
        [layers addObject:ring];
    }

    // 内圈: switch, width 1-30 (default 2), custom color, random
    if ([config axs_holdlaunch_ringInnerEnabled]) {
        UIColor *color;
        if ([config axs_holdlaunch_ringInnerRandomColor]) {
            color = axs_ring_randomColor();
        } else if ([config axs_holdlaunch_ringInnerCustomEnabled]) {
            color = axs_ring_parseHex([config axs_holdlaunch_ringInnerColor],
                                      axs_ring_parseHex(@"#CBD0FF", nil));
        } else {
            color = axs_ring_parseHex(@"#CBD0FF", nil);
        }
        CGFloat inset = [config axs_holdlaunch_ringFrameWidth] / 2
                      + [config axs_holdlaunch_ringInnerWidth] / 2 + 2;
        CGRect innerFrame = CGRectInset(frame, inset, inset);
        CAShapeLayer *inner = [CAShapeLayer layer];
        inner.path = axs_ring_path(innerFrame, radius).CGPath;
        inner.strokeColor = color.CGColor;
        inner.fillColor = nil;
        inner.lineWidth = [config axs_holdlaunch_ringInnerWidth];
        inner.opacity = 1.0;
        inner.zPosition = z;
        [host.layer addSublayer:inner];
        [layers addObject:inner];
    }

    axs_layers[key] = layers;
    axs_ring_logLayerCount();
}

static void axs_ring_tick(void) {
    @try {
        axs_ring_ensureMaps();
        AxsHoldLaunchConfig *config = [AxsHoldLaunchConfig axs_holdlaunch_shared];
        BOOL floatOn = [config axs_holdlaunch_isTheirRingEnabled];
        BOOL miniOn = [config axs_holdlaunch_isTheirMiniRingEnabled];

        int drawn = 0;

        for (NSString *key in [axs_meta allKeys]) {
            UIView *view = [axs_views objectForKey:key];
            UIWindow *host = [axs_hosts objectForKey:key];
            NSMutableDictionary *m = axs_meta[key];

            // stale entry: view or host window died
            if (m == nil || view == nil || host == nil || view.window == nil
                || view.hidden || view.alpha < 0.01) {
                axs_ring_engine_log(@"ring entry dropped: key=%@ view=%@ host=%@ window=%p alpha=%.2f",
                                    key, view, host, view.window, view.alpha);
                axs_ring_detachLayers(key);
                [axs_meta removeObjectForKey:key];
                [axs_views removeObjectForKey:key];
                [axs_hosts removeObjectForKey:key];
                continue;
            }

            BOOL docked = [m[@"kind"] isEqualToString:@"docked"] || [m[@"docked"] boolValue];
            if (docked ? !miniOn : !floatOn) {
                axs_ring_detachLayers(key);
                continue;
            }

            // exclusion, cached per container until the bundle changes
            NSString *bundle = m[@"bundle"] ?: @"";
            if (m[@"excluded"] == nil && m[@"session"] != nil) {
                BOOL excluded = axs_ring_bundleExcluded(bundle, config);
                m[@"excluded"] = @(excluded);
                axs_ring_engine_log(@"ring exclusion cached: bundle=%@ excluded=%d",
                                    bundle, (int)excluded);
            }
            if ([m[@"excluded"] boolValue]) {
                axs_ring_detachLayers(key);
                continue;
            }

            CGRect frame = [view convertRect:view.bounds toView:host];
            CGFloat minWidth = docked ? 16.0 : 40.0;
            if (frame.size.width <= minWidth) continue;

            // style signature: rebuild only when a style parameter changed
            NSString *styleSig = [NSString stringWithFormat:
                @"%@|%.1f|f=%.2f,%.2f,%d,%@,%d|g=%d,%.1f,%.1f,%.1f|i=%d,%d,%.1f,%@,%d|b=%@",
                docked ? @"d" : @"f",
                docked ? view.layer.cornerRadius : [config axs_holdlaunch_splitWindowCornerRadius],
                [config axs_holdlaunch_ringFrameWidth],
                [config axs_holdlaunch_ringFrameAlpha],
                (int)[config axs_holdlaunch_ringFrameCustomEnabled],
                [config axs_holdlaunch_ringFrameColor],
                (int)[config axs_holdlaunch_ringFrameRandomColor],
                (int)[config axs_holdlaunch_ringGlowEnabled],
                [config axs_holdlaunch_ringGlowRange],
                [config axs_holdlaunch_ringGlowOffsetX],
                [config axs_holdlaunch_ringGlowOffsetY],
                (int)[config axs_holdlaunch_ringInnerEnabled],
                (int)[config axs_holdlaunch_ringInnerCustomEnabled],
                [config axs_holdlaunch_ringInnerWidth],
                [config axs_holdlaunch_ringInnerColor],
                (int)[config axs_holdlaunch_ringInnerRandomColor],
                bundle];

            if (![axs_styleSig[key] isEqualToString:styleSig]) {
                axs_ring_buildLayers(key, view, host, docked, config);
                axs_styleSig[key] = styleSig;
                axs_frameSig[key] = @"";
                if (axs_layers[key] == nil) continue; // switch turned off mid-build
            }

            // geometry: path-only update when the on-screen frame changed
            NSString *frameSig = [NSString stringWithFormat:@"%.1f,%.1f,%.1f,%.1f",
                                  frame.origin.x, frame.origin.y,
                                  frame.size.width, frame.size.height];
            if (![axs_frameSig[key] isEqualToString:frameSig]) {
                CGFloat radius = docked ? view.layer.cornerRadius
                                        : [config axs_holdlaunch_splitWindowCornerRadius];
                if (docked && radius < 1) radius = 14.0;
                UIBezierPath *path = axs_ring_path(frame, radius);
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                for (CALayer *l in axs_layers[key]) {
                    if ([l isKindOfClass:[CAShapeLayer class]]) ((CAShapeLayer *)l).path = path.CGPath;
                    l.zPosition = 9999.0;
                }
                [CATransaction commit];
                axs_frameSig[key] = frameSig;
            }

            drawn++;
        }

        if (drawn == 0) {
            // nothing to draw: detach everything
            for (NSString *key in [axs_layers allKeys]) { axs_ring_detachLayers(key); }
        }

        // mapping empty or nothing drawn -> stop the display link entirely
        if (axs_ringLink != nil && (drawn == 0 || axs_meta.count == 0)) {
            axs_ring_engine_log(@"ring engine idle, display link stopped (drawn=%d meta=%lu)",
                                drawn, (unsigned long)axs_meta.count);
            [axs_ringLink invalidate];
            axs_ringLink = nil;
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
