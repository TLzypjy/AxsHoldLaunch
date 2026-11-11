#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AxsHoldLaunchConfig.h"

// ---------------------------------------------------------------------------
// 美化 · 光圈外框 (ring frame, beautify.2)
//
// One shared overlay UIWindow hosts every ring; each floating-window session
// gets a holder CALayer with a conic-gradient rainbow band masked by a
// CAShapeLayer stroke. Geometry is sampled from the presentation layer chain
// every display tick (compare-only: update path/frame only on change), so
// springs and gestures are followed without lag or residue.
//
//   overlay UIWindow (non-interactive, host level + 1)
//     └─ holder per session
//          ├─ mask = CAShapeLayer (stroke band, lineWidth = thickness)
//          └─ grad = CAGradientLayer (conic rainbow, 4s rotation marquee)
//
// Hooks: SCFloatingContainerView -didMoveToWindow builds the session map;
// sc_sessionDidBeginHosting: / sc_closeSession: / sc_dockSession:fromCorner:
// drive lifecycle (installed via runtime scan over all declaring classes).
// ---------------------------------------------------------------------------

#define AXS_RING_LOG_PATH @"/var/mobile/Documents/sc-ring.log"

static UIWindow *axs_ring_window = nil;
static CADisplayLink *axs_ring_link = nil;
static NSMutableDictionary<NSString *, AXSRingFrame *> *axs_ring_frames = nil;
static void *axs_ring_recentSession = NULL;
static double axs_ring_recentSessionAt = 0;
static BOOL axs_ring_hooksInstalled = NO;

static IMP axs_ring_origSessionBegin = NULL;
static IMP axs_ring_origClose = NULL;
static IMP axs_ring_origDock = NULL;
static IMP axs_ring_origSessionForContainer = NULL;

static void axs_ring_tick(void);

@interface AXSRingFrame : NSObject
@property (nonatomic, weak) UIView *container;
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, strong) CALayer *holder;
@property (nonatomic, strong) CAGradientLayer *gradient;
@property (nonatomic, strong) CAShapeLayer *mask;
@property (nonatomic, assign) CGRect lastRect;
@property (nonatomic, assign) CGFloat lastRadius;
@property (nonatomic, assign) CGFloat lastWidth;
@property (nonatomic, assign) NSInteger lastMode; // 0 = rainbow, 1 = custom
@property (nonatomic, assign) BOOL docked;
@property (nonatomic, assign) void *session;
@property (nonatomic, assign) double lastUpdateLoggedAt;
@property (nonatomic, assign) double lastVisibleAt;
@end
@implementation AXSRingFrame
@end

@interface AXSRingTickTarget : NSObject
- (void)axsRingTick;
@end
@implementation AXSRingTickTarget
- (void)axsRingTick { axs_ring_tick(); }
@end

// --- logging: single append-only file --------------------------------------

static void axs_ring_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void axs_ring_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[AxsHoldLaunch:Ring] %@", message);
    @try {
        NSString *line = [NSString stringWithFormat:@"%@\n", message];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:AXS_RING_LOG_PATH];
        if (handle == nil) {
            [line writeToFile:AXS_RING_LOG_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
    } @catch (NSException *exception) {
        // logging must never take SpringBoard down
    }
}

// --- config (com.susudear.screencoreprefs, live via cfprefsd snapshot) ------

static double axs_ring_clamp(double v, double lo, double hi) {
    if (!(v >= lo)) v = lo;
    if (v > hi) v = hi;
    return v;
}

static BOOL axs_ring_enabled(void) {
    id v = [[AxsHoldLaunchConfig axs_holdlaunch_shared] axs_holdlaunch_theirValueForKey:@"splitBeautifyRingFrameEnabled" defaultValue:@NO];
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : NO;
}

static double axs_ring_thickness(void) {
    id v = [[AxsHoldLaunchConfig axs_holdlaunch_shared] axs_holdlaunch_theirValueForKey:@"splitBeautifyRingThickness" defaultValue:@5.0];
    double t = [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : 5.0;
    return axs_ring_clamp(t, 0.5, 30.0);
}

static BOOL axs_ring_customColor(void) {
    id v = [[AxsHoldLaunchConfig axs_holdlaunch_shared] axs_holdlaunch_theirValueForKey:@"splitBeautifyRingCustomColorEnabled" defaultValue:@NO];
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : NO;
}

static double axs_ring_cornerRadius(void) {
    id v = [[AxsHoldLaunchConfig axs_holdlaunch_shared] axs_holdlaunch_theirValueForKey:@"splitWindowCornerRadius" defaultValue:@8.0];
    double r = [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : 8.0;
    return axs_ring_clamp(r, 0.0, 60.0);
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

static UIColor *axs_ring_color(void) {
    id v = [[AxsHoldLaunchConfig axs_holdlaunch_shared] axs_holdlaunch_theirValueForKey:@"splitBeautifyRingFrameColor" defaultValue:@"#93E3FD"];
    return axs_ring_parseHex([v isKindOfClass:[NSString class]] ? v : nil,
                             [UIColor colorWithRed:0.576 green:0.890 blue:0.992 alpha:1.0]);
}

// --- maps -------------------------------------------------------------------

static NSString *axs_ring_key(id object) {
    return [NSString stringWithFormat:@"%p", object];
}

static void axs_ring_ensureMaps(void) {
    if (axs_ring_frames != nil) return;
    axs_ring_frames = [NSMutableDictionary new];
}

// --- overlay window ----------------------------------------------------------

static UIWindow *axs_ring_ensureWindow(UIWindow *host) {
    if (!axs_ring_enabled()) return nil;
    if (host == nil) return nil;

    if (axs_ring_window == nil) {
        UIWindowScene *scene = nil;
        @try {
            scene = host.windowScene;
            if (scene == nil) {
                for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                    if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
                }
            }
        } @catch (NSException *exception) { }
        if (scene == nil) return nil;

        UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
        w.userInteractionEnabled = NO;   // 不拦截触摸、不参与手势判定
        w.opaque = NO;
        w.backgroundColor = [UIColor clearColor];
        w.clipsToBounds = NO;
        w.windowLevel = host.windowLevel + 1; // 浮窗之上、状态栏之下
        w.hidden = NO;
        axs_ring_window = w;
        axs_ring_log(@"ring engine start, level=%.0f", w.windowLevel);
    } else if (axs_ring_window.windowLevel != host.windowLevel + 1) {
        // host level changed across relayouts: keep the ring just above it
        axs_ring_window.windowLevel = host.windowLevel + 1;
    }
    return axs_ring_window;
}

static void axs_ring_releaseWindow(void) {
    if (axs_ring_window == nil) return;
    UIWindow *w = axs_ring_window;
    axs_ring_window = nil;
    w.hidden = YES;
    axs_ring_log(@"ring window released");
}

// --- ring layers -------------------------------------------------------------

static NSArray<UIColor *> *axs_ring_rainbow(void) {
    // 8 segments, first == last so the conic wrap is seamless
    return @[ [UIColor redColor], [UIColor orangeColor], [UIColor yellowColor],
              [UIColor greenColor], [UIColor cyanColor], [UIColor blueColor],
              [UIColor purpleColor], [UIColor redColor] ];
}

static void axs_ring_addMarquee(CAGradientLayer *grad) {
    CAKeyframeAnimation *rot = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
    rot.values = @[ @0.0, @(2.0 * M_PI) ];
    rot.duration = 4.0;                      // ~4s per revolution
    rot.repeatCount = HUGE_VALF;
    rot.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    rot.removedOnCompletion = NO;
    [grad addAnimation:rot forKey:@"axsRingMarquee"];
}

// 颜色模式切换 = 重建渐变层：不在旧动画上改颜色
static CAGradientLayer *axs_ring_makeGradient(BOOL custom, UIColor *color) {
    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.type = kCAGradientLayerConic;
    grad.startPoint = CGPointMake(0.5, 0.5);
    grad.endPoint = CGPointMake(0.5, 0.0);
    if (custom) {
        grad.colors = @[ (__bridge id)color.CGColor, (__bridge id)color.CGColor ];
        grad.locations = @[ @0.0, @1.0 ];
        // 静态单色细边框：不加旋转动画
    } else {
        NSArray<UIColor *> *rainbow = axs_ring_rainbow();
        NSMutableArray *colors = [NSMutableArray array];
        NSMutableArray *locations = [NSMutableArray array];
        for (NSUInteger i = 0; i < rainbow.count; i++) {
            [colors addObject:(__bridge id)rainbow[i].CGColor];
            [locations addObject:@((double)i / (double)(rainbow.count - 1))];
        }
        grad.colors = colors;
        grad.locations = locations;
        axs_ring_addMarquee(grad); // added once per gradient lifecycle
    }
    return grad;
}

static void axs_ring_rebuildGradient(AXSRingFrame *f, BOOL custom, UIColor *color) {
    CGRect frame = f.gradient.frame;
    [f.gradient removeFromSuperlayer];
    f.gradient = axs_ring_makeGradient(custom, color);
    f.gradient.frame = frame;
    [f.holder addSublayer:f.gradient];
}

static void axs_ring_buildLayers(AXSRingFrame *f, BOOL custom, UIColor *color) {
    CALayer *holder = [CALayer layer];
    holder.masksToBounds = NO;

    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.fillColor = nil;                    // 只用于遮罩
    mask.strokeColor = [UIColor whiteColor].CGColor;
    holder.mask = mask;

    f.holder = holder;
    f.mask = mask;
    f.gradient = nil;
    axs_ring_rebuildGradient(f, custom, color);
    [axs_ring_window.layer addSublayer:holder];
}

// --- geometry ----------------------------------------------------------------

// the visible rounded window = the container's largest child that stays
// INSIDE the container bounds (the gesture overlay pokes out on every side,
// so size alone would pick the wrong subview)
static UIView *axs_ring_contentChild(UIView *container) {
    UIView *best = nil;
    CGFloat bestArea = 0;
    CGFloat cw = container.bounds.size.width;
    CGFloat ch = container.bounds.size.height;
    for (UIView *sub in container.subviews) {
        if (sub.hidden || sub.alpha < 0.05) continue;
        CGRect f = sub.frame;
        if (f.origin.x < -1 || f.origin.y < -1) continue;
        if (f.size.width > cw + 1 || f.size.height > ch + 1) continue;
        CGFloat area = f.size.width * f.size.height;
        if (area > bestArea) { bestArea = area; best = sub; }
    }
    return best;
}

// presentation-accurate rect of the content child in its host window's
// coordinates: presentation frames along the whole superlayer chain (model
// values are already the animation END point mid-spring - taking them is
// exactly how a border "jumps ahead" and detaches)
static CGRect axs_ring_rectInHostWindow(UIView *content) {
    CALayer *pres = content.layer.presentationLayer ?: content.layer;
    CGRect rect = pres.frame;
    CALayer *p = pres.superlayer;
    while (p != nil) {
        CGRect pf = p.frame;
        rect.origin.x += pf.origin.x;
        rect.origin.y += pf.origin.y;
        p = p.superlayer;
    }
    return rect;
}

static void axs_ring_applyGeometry(AXSRingFrame *f, CGRect rect, double width, double radius) {
    double w = width;
    if (w < 0.5) w = 0.5;

    // gradient frame = window rect 外扩 thickness; path rect 内缩 lineWidth/2
    // (stroke straddles the path edge, so the band lies fully inside the edge)
    CGRect gradFrame = CGRectMake(rect.origin.x - w, rect.origin.y - w,
                                  rect.size.width + 2 * w, rect.size.height + 2 * w);
    CGRect bandRect = CGRectMake(w, w, rect.size.width, rect.size.height); // rect in gradFrame space
    CGRect pathRect = CGRectInset(bandRect, w / 2.0);
    double pathRadius = axs_ring_clamp(radius - w / 2.0, 0.0, MIN(pathRect.size.width, pathRect.size.height) / 2.0);

    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:pathRect cornerRadius:pathRadius];

    // path/frame changes must not pick up implicit 0.25s animations, or the
    // ring trails half a beat behind every resize
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    f.gradient.frame = gradFrame;
    f.mask.frame = gradFrame;
    f.mask.lineWidth = w;
    f.mask.path = path.CGPath;
    [CATransaction commit];
}

// --- lifecycle ---------------------------------------------------------------

static void axs_ring_detach(NSString *key, NSString *reason) {
    AXSRingFrame *f = axs_ring_frames[key];
    if (f == nil) return;
    [f.holder removeFromSuperlayer];
    [axs_ring_frames removeObjectForKey:key];
    axs_ring_log(@"ring detach: session=%p reason=%@", f.session, reason);
}

static void axs_ring_idleEngine(void) {
    if (axs_ring_link != nil) {
        [axs_ring_link invalidate];
        axs_ring_link = nil;
    }
    if (axs_ring_frames.count == 0) {
        axs_ring_releaseWindow(); // logs "ring window released"
    }
}

static void axs_ring_stopAll(void) {
    for (NSString *key in [NSArray arrayWithArray:axs_ring_frames]) {
        axs_ring_detach(key, @"disabled");
    }
    if (axs_ring_link != nil) {
        [axs_ring_link invalidate];
        axs_ring_link = nil;
    }
    axs_ring_releaseWindow(); // logs "ring window released"
}

static void axs_ring_wake(void) {
    if (axs_ring_link != nil) return;
    if (axs_ring_frames.count == 0) return;
    AXSRingTickTarget *target = [AXSRingTickTarget new];
    axs_ring_link = [CADisplayLink displayLinkWithTarget:target selector:@selector(axsRingTick)];
    [axs_ring_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

// attach is driven by -didMoveToWindow (after %orig): the container is in a
// window here, which gives us the scene and the host level
static void axs_ring_containerDidMove(UIView *container) {
    if (!axs_ring_hooksInstalled) return;
    if (container == nil) return;
    @try {
        axs_ring_ensureMaps();

        NSString *key = axs_ring_key(container);
        if (container.window == nil) {
            // left the screen: hide immediately so no orphan ring stays drawn;
            // the mapping stays (ScreenCore re-parents containers mid-drag)
            AXSRingFrame *f = axs_ring_frames[key];
            if (f != nil) f.holder.hidden = YES;
            return;
        }
        if (!axs_ring_enabled()) {
            if (axs_ring_frames.count > 0) axs_ring_stopAll();
            return;
        }

        AXSRingFrame *f = axs_ring_frames[key];
        if (f == nil) {
            UIWindow *overlay = axs_ring_ensureWindow(container.window);
            if (overlay == nil) return;
            double now = [[NSDate date] timeIntervalSince1970];
            BOOL custom = axs_ring_customColor();
            f = [AXSRingFrame new];
            f.container = container;
            f.hostWindow = container.window;
            if (axs_ring_recentSession != NULL && now - axs_ring_recentSessionAt < 2.0) {
                f.session = axs_ring_recentSession; // best-effort pairing
            }
            axs_ring_recentSession = NULL;
            axs_ring_buildLayers(f, custom, axs_ring_color());
            axs_ring_frames[key] = f;
            UIView *content = axs_ring_contentChild(container) ?: container;
            axs_ring_log(@"ring attach: session=%p host=%p rect=%@",
                         f.session, container.window,
                         NSStringFromCGRect(axs_ring_rectInHostWindow(content)));
        } else {
            f.hostWindow = container.window;
            if (f.session == NULL && axs_ring_recentSession != NULL
                && [[NSDate date] timeIntervalSince1970] - axs_ring_recentSessionAt < 2.0) {
                f.session = axs_ring_recentSession;
                axs_ring_recentSession = NULL;
            }
        }
        f.holder.hidden = NO;
        f.lastVisibleAt = [[NSDate date] timeIntervalSince1970];
        axs_ring_wake();
    } @catch (NSException *exception) {
        axs_ring_log(@"ring attach exception: %@", exception);
    }
}

// --- session hooks (runtime-scanned; see axs_ring_installSessionHooks) -------

static void axs_ring_pairFrame(void *session, UIView *container) {
    if (session == NULL || container == nil) return;
    AXSRingFrame *f = axs_ring_frames[axs_ring_key(container)];
    if (f != nil && f.session == NULL) {
        f.session = session;
        f.docked = NO; // (re)hosted: dock state is over
        f.holder.hidden = (f.container.window == nil);
        f.lastVisibleAt = [[NSDate date] timeIntervalSince1970];
    }
}

static void axs_ring_sessionBegin_imp(id self, SEL _cmd, id session) {
    if (axs_ring_origSessionBegin != NULL) {
        ((void(*)(id, SEL, id))axs_ring_origSessionBegin)(self, _cmd, session);
    }
    @try {
        dispatch_block_t work = ^{
            axs_ring_ensureMaps();
            Class containerClass = objc_getClass("SCFloatingContainerView");
            void *s = NULL;
            id container = nil;
            if (session != nil && (id)session != self) {
                s = (__bridge void *)session;
                if ([self isKindOfClass:containerClass]) container = self;
                else if ([session isKindOfClass:containerClass]) { container = session; s = (__bridge void *)self; }
            } else {
                s = (__bridge void *)self;
                if ([self isKindOfClass:containerClass]) container = self;
            }
            if (container != nil) {
                axs_ring_pairFrame(s, container);
            } else {
                axs_ring_recentSession = s;
                axs_ring_recentSessionAt = [[NSDate date] timeIntervalSince1970];
            }
            // un-dock any frame paired with this session pointer
            for (AXSRingFrame *f in axs_ring_frames.allValues) {
                if (f.session != NULL && f.session == s && f.docked) {
                    f.docked = NO;
                    f.holder.hidden = (f.container.window == nil);
                }
            }
            axs_ring_log(@"ring session begin: class=%@ session=%p", NSStringFromClass([self class]), s);
            axs_ring_wake();
        };
        if ([NSThread isMainThread]) work(); else dispatch_async(dispatch_get_main_queue(), work);
    } @catch (NSException *exception) {
        axs_ring_log(@"ring session begin exception: %@", exception);
    }
}

static void axs_ring_close_imp(id self, SEL _cmd, id session) {
    if (axs_ring_origClose != NULL) {
        ((void(*)(id, SEL, id))axs_ring_origClose)(self, _cmd, session);
    }
    @try {
        void *s = session != nil ? (__bridge void *)session : NULL;
        dispatch_block_t work = ^{
            axs_ring_ensureMaps();
            NSMutableArray<NSString *> *hits = [NSMutableArray array];
            if (s != NULL) {
                for (NSString *key in axs_ring_frames) {
                    AXSRingFrame *f = axs_ring_frames[key];
                    if (f.session != NULL && f.session == s) [hits addObject:key];
                }
            }
            for (NSString *key in hits) {
                axs_ring_detach(key, @"closeSession");
            }
            axs_ring_log(@"ring session close: class=%@ session=%p matched=%lu",
                         NSStringFromClass([self class]), s, (unsigned long)hits.count);
            if (axs_ring_frames.count == 0) axs_ring_idleEngine();
        };
        if ([NSThread isMainThread]) work(); else dispatch_async(dispatch_get_main_queue(), work);
    } @catch (NSException *exception) {
        axs_ring_log(@"ring session close exception: %@", exception);
    }
}

static void axs_ring_dock_imp(id self, SEL _cmd, id session, long corner) {
    if (axs_ring_origDock != NULL) {
        ((void(*)(id, SEL, id, long))axs_ring_origDock)(self, _cmd, session, corner);
    }
    @try {
        void *s = session != nil ? (__bridge void *)session : NULL;
        dispatch_block_t work = ^{
            axs_ring_ensureMaps();
            AXSRingFrame *hit = nil;
            if (s != NULL) {
                for (AXSRingFrame *f in axs_ring_frames.allValues) {
                    if (f.session != NULL && f.session == s) { hit = f; break; }
                }
            }
            if (hit == nil) {
                // fallback: single-active mode means the visible ring is the
                // one being docked
                for (AXSRingFrame *f in axs_ring_frames.allValues) {
                    if (!f.docked && f.container.window != nil) { hit = f; break; }
                }
            }
            if (hit != nil) {
                hit.docked = YES;
                hit.holder.hidden = YES; // 挂起期间不画环
                axs_ring_log(@"ring dock: session=%p corner=%ld", hit.session, corner);
            } else {
                axs_ring_log(@"ring dock ignored: session=%p corner=%ld (no ring)", s, corner);
            }
        };
        if ([NSThread isMainThread]) work(); else dispatch_async(dispatch_get_main_queue(), work);
    } @catch (NSException *exception) {
        axs_ring_log(@"ring dock exception: %@", exception);
    }
}

static id axs_ring_sessionForContainer_imp(id self, SEL _cmd, id container) {
    id result = axs_ring_origSessionForContainer != NULL
        ? ((id(*)(id, SEL, id))axs_ring_origSessionForContainer)(self, _cmd, container)
        : nil;
    @try {
        if ([container isKindOfClass:[UIView class]] && result != nil) {
            void *s = (__bridge void *)result;
            void *c = (__bridge void *)container;
            dispatch_async(dispatch_get_main_queue(), ^{
                axs_ring_ensureMaps();
                AXSRingFrame *f = axs_ring_frames[axs_ring_key((__bridge id)c)];
                if (f != nil && f.session == NULL) f.session = s;
            });
        }
    } @catch (NSException *exception) { }
    return result;
}

// hook every class that declares a sc_* session selector; the selectors are
// ScreenCore-private names, so the scan cannot reach unrelated classes. Type
// encodings are logged so device logs confirm signatures on first run.
static NSUInteger axs_ring_hookSelector(SEL selector, IMP replacement, IMP *original) {
    NSUInteger hooked = 0;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes == NULL) return 0;
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        BOOL declared = NO;
        for (unsigned int m = 0; m < methodCount; m++) {
            if (method_getName(methods[m]) == selector) { declared = YES; break; }
        }
        free(methods);
        if (!declared) continue;
        Method m = class_getInstanceMethod(cls, selector);
        const char *types = m ? method_getTypeEncoding(m) : "?";
        axs_ring_log(@"ring hook '%s' on %s types=%s", sel_getName(selector), class_getName(cls), types ?: "?");
        MSHookMessageEx(cls, selector, replacement, original);
        hooked++;
    }
    free(classes);
    return hooked;
}

static void axs_ring_installSessionHooks(void) {
    if (axs_ring_hooksInstalled) return;
    axs_ring_hooksInstalled = YES;
    NSUInteger a = axs_ring_hookSelector(@selector(sc_sessionDidBeginHosting:), (IMP)axs_ring_sessionBegin_imp, &axs_ring_origSessionBegin);
    NSUInteger b = axs_ring_hookSelector(@selector(sc_closeSession:), (IMP)axs_ring_close_imp, &axs_ring_origClose);
    NSUInteger c = axs_ring_hookSelector(@selector(sc_dockSession:fromCorner:), (IMP)axs_ring_dock_imp, &axs_ring_origDock);
    NSUInteger d = axs_ring_hookSelector(@selector(sc_sessionForContainerView:), (IMP)axs_ring_sessionForContainer_imp, &axs_ring_origSessionForContainer);
    axs_ring_log(@"ring hooks: begin=%lu close=%lu dock=%lu forContainer=%lu",
                 (unsigned long)a, (unsigned long)b, (unsigned long)c, (unsigned long)d);
}

// --- display tick: compare-only, no interpolation -----------------------------

static void axs_ring_tick(void) {
    @try {
        if (axs_ring_frames == nil) return;

        // prune containers that went away entirely
        for (NSString *key in [NSArray arrayWithArray:axs_ring_frames]) {
            AXSRingFrame *f = axs_ring_frames[key];
            if (f.container == nil) axs_ring_detach(key, @"container dealloc");
        }
        if (axs_ring_frames.count == 0) {
            axs_ring_idleEngine();
            return;
        }
        if (!axs_ring_enabled()) {
            axs_ring_stopAll();
            return;
        }

        BOOL custom = axs_ring_customColor();
        UIColor *color = axs_ring_color();
        double width = axs_ring_thickness();
        double radius = axs_ring_cornerRadius();
        double now = [[NSDate date] timeIntervalSince1970];

        for (NSString *key in [NSArray arrayWithArray:axs_ring_frames]) {
            AXSRingFrame *f = axs_ring_frames[key];
            UIView *container = f.container;

            BOOL visible = container.window != nil && !f.docked && container.alpha > 0.01;
            UIView *content = visible ? axs_ring_contentChild(container) : nil;
            if (content == nil) visible = NO;

            if (!visible) {
                if (!f.holder.hidden) f.holder.hidden = YES;
                // parked containers that never come back: clean up after 3s
                if (now - f.lastVisibleAt > 3.0) axs_ring_detach(key, @"dormant cleanup");
                continue;
            }
            f.lastVisibleAt = now;

            CGRect rect = axs_ring_rectInHostWindow(content); // host-window coords
            UIWindow *host = content.window;
            if (host == nil || axs_ring_window == nil) continue;
            // presentation-accurate rect converted into the overlay window's
            // coordinate system (UIKit handles cross-window + rotation)
            CGRect overlayRect = [host convertRect:rect toView:axs_ring_window];

            CGFloat cw = container.bounds.size.width;
            CGFloat ch = container.bounds.size.height;
            if (overlayRect.size.width < 20 || overlayRect.size.height < 20
                || overlayRect.size.width > cw * 3 + 200 || overlayRect.size.height > ch * 3 + 200) {
                continue; // transient morph frame: keep the previous band
            }

            NSInteger mode = custom ? 1 : 0;
            BOOL styleChanged = (f.lastMode != mode)
                             || (f.lastWidth != (CGFloat)width)
                             || (f.lastRadius != (CGFloat)radius);
            if (styleChanged) {
                if (f.lastMode != mode) {
                    axs_ring_rebuildGradient(f, custom, color); // rebuild, never mutate
                }
                f.lastMode = mode;
                f.lastWidth = (CGFloat)width;
                f.lastRadius = (CGFloat)radius;
            }
            if (!CGRectEqualToRect(overlayRect, f.lastRect) || styleChanged) {
                if (f.holder.hidden) f.holder.hidden = NO;
                axs_ring_applyGeometry(f, overlayRect, width, radius);
                f.lastRect = overlayRect;
                if (now - f.lastUpdateLoggedAt >= 0.5 || styleChanged) {
                    f.lastUpdateLoggedAt = now;
                    axs_ring_log(@"ring update: rect=%@ radius=%.1f width=%.1f mode=%d",
                                 NSStringFromCGRect(overlayRect), radius, width, (int)mode);
                }
            }
        }
    } @catch (NSException *exception) {
        axs_ring_log(@"ring tick exception: %@", exception);
    }
}

// --- Logos hooks ---------------------------------------------------------------

%group AxsRingSpringBoard

%hook SCFloatingContainerView

- (void)didMoveToWindow {
    %orig;
    axs_ring_containerDidMove(self);
}

%end

%end

%ctor {
    @autoreleasepool {
        if (objc_getClass("SpringBoard") != nil) {
            axs_ring_ensureMaps();
            %init(AxsRingSpringBoard);
            axs_ring_installSessionHooks();
            axs_ring_log(@"ring module loaded in SpringBoard");
        }
    }
}
