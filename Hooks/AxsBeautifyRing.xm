#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AxsHoldLaunchConfig.h"
#import "AxsHoldLaunchPrivate.h"

// ---------------------------------------------------------------------------
// 美化 · 光圈外框 (ring frame, beautify.3)
//
// beautify.2 lesson: installing at %ctor time races ScreenCore's class
// registration (substrate loads our dylib first) -> 0 hooks, engine dead;
// and a -didMoveToWindow hook on SCFloatingContainerView is not reliable
// (inherited from UIView). This version:
//   - installs the four sc_* hooks with deferred retries (0.5s/1.0s/2.0s),
//     gated on objc_getClass("SCFloatingContainerView"), per-hook result logs
//   - NO didMoveToWindow hook; the session map is keyed by the session
//     pointer, built inside sc_sessionDidBeginHosting: (container resolved
//     from the receiver/argument/probes + sc_sessionForContainerView:)
//   - one shared overlay UIWindow whose frame FOLLOWS the floating card's
//     screen rect (never full screen), level = host window level + 1
//   - displayLink ticks are compare-only over the presentation layer chain
// ---------------------------------------------------------------------------

#define AXS_RING_LOG_PATH @"/var/mobile/Documents/sc-ring.log"

static void axs_ring_tick(void);

@interface AXSRingFrame : NSObject
@property (nonatomic, assign) void *session;
@property (nonatomic, weak) UIView *container;
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, strong) CALayer *holder;      // nil until the container is in a window
@property (nonatomic, strong) CAGradientLayer *gradient;
@property (nonatomic, strong) CAShapeLayer *mask;
@property (nonatomic, assign) CGSize lastSize;      // card size in overlay coords
@property (nonatomic, assign) CGFloat lastRadius;
@property (nonatomic, assign) CGFloat lastWidth;
@property (nonatomic, assign) NSInteger lastMode;   // 0 = rainbow, 1 = custom
@property (nonatomic, assign) BOOL docked;
@property (nonatomic, assign) BOOL attachLogged;
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

// overlay 窗口子类：hitTest/pointInside 一律拒绝，杜绝吞掉浮窗的触摸。
// 只设 userInteractionEnabled=NO 在 UIWindow 层级不够稳，两个都必须覆写。
@interface AXSRingOverlayWindow : UIWindow
@end
@implementation AXSRingOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { return NO; }
@end

static UIWindow *axs_ring_window = nil;
static CADisplayLink *axs_ring_link = nil;
static NSMutableDictionary<NSString *, AXSRingFrame *> *axs_ring_frames = nil;
static BOOL axs_ring_hooksInstalled = NO;
static int axs_ring_installAttempts = 0;

static IMP axs_ring_origSessionBegin = NULL;
static IMP axs_ring_origClose = NULL;
static IMP axs_ring_origDock = NULL;
static IMP axs_ring_origSessionForContainer = NULL;

// 防重入闸：每个钩子独立的线程局部标志。钩子内发的任何消息都可能再次进入
// 钩子（尤其是 orig 被错误地指回自己时）；重入直接 return，不再调 orig，
// 同一钩子被拦满 50 次写一条 ring reentry blocked。
static __thread BOOL axs_ring_reenter_begin = NO;
static __thread BOOL axs_ring_reenter_close = NO;
static __thread BOOL axs_ring_reenter_dock = NO;
static __thread BOOL axs_ring_reenter_forContainer = NO;
static int axs_ring_reenter_blocked[4] = {0, 0, 0, 0};

// 安装幂等：已装过的选择子绝不重复 hook（重试只补漏，防止 MSHookMessageEx
// 把我们自己的 IMP 存成 orig，造成 orig -> 自己的无限递归）
static BOOL axs_ring_hookDone[4] = {NO, NO, NO, NO};

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
    // 面板默认 YES：域里还没写入时按面板默认走，不能按 NO 静默关闭
    id v = [[AxsHoldLaunchConfig axs_holdlaunch_shared] axs_holdlaunch_theirValueForKey:@"splitBeautifyRingFrameEnabled" defaultValue:@YES];
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : YES;
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

static NSString *axs_ring_keyForSession(void *session) {
    if (session != NULL) return [NSString stringWithFormat:@"s:%p", session];
    return nil;
}

static NSString *axs_ring_keyForContainer(UIView *container) {
    return [NSString stringWithFormat:@"c:%p", container];
}

static void axs_ring_ensureMaps(void) {
    if (axs_ring_frames != nil) return;
    axs_ring_frames = [NSMutableDictionary new];
}

// --- overlay window: frame follows the floating card, never full screen -----

static UIWindow *axs_ring_ensureWindow(UIWindow *hostWindow, CGRect cardRect) {
    if (!axs_ring_enabled()) return nil;
    if (hostWindow == nil) return nil;

    if (axs_ring_window == nil) {
        UIWindowScene *scene = nil;
        @try {
            scene = hostWindow.windowScene;
            if (scene == nil) {
                for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                    if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
                }
            }
        } @catch (NSException *exception) { }
        if (scene == nil) return nil;

        AXSRingOverlayWindow *w = [[AXSRingOverlayWindow alloc] initWithWindowScene:scene];
        w.backgroundColor = [UIColor clearColor]; // 立即清掉默认背景，防露白
        w.opaque = NO;
        w.userInteractionEnabled = NO;   // 不拦截触摸、不参与手势判定
        w.clipsToBounds = NO;
        w.frame = cardRect;              // = 浮窗 rect，不许全屏
        w.windowLevel = hostWindow.windowLevel + 1; // 只比宿主高 1
        w.hidden = NO;                   // 绝不 makeKeyAndVisible
        axs_ring_window = w;
        axs_ring_log(@"ring engine start, level=%.0f", w.windowLevel);
        axs_ring_log(@"ring window frame=%@ level=%.0f", NSStringFromCGRect(w.frame), w.windowLevel);
    } else if (axs_ring_window.windowLevel != hostWindow.windowLevel + 1) {
        axs_ring_window.windowLevel = hostWindow.windowLevel + 1;
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

// 颜色模式切换 = 重建渐变层；渐变层只作遮罩用，整个环只有这一层描边
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
    // 渐变层要旋转：frame 取容器 bounds 的外接正方形（边长 = hypot(w,h)，居中），
    // 旋转时四角不裁、颜色无断层；渐变层自身不带遮罩（遮罩在容器上，不随旋转）
    CGFloat side = hypot(f.holder.bounds.size.width, f.holder.bounds.size.height);
    if (side < 1.0) side = 1.0;
    [f.gradient removeFromSuperlayer];
    f.gradient = axs_ring_makeGradient(custom, color);
    f.gradient.frame = CGRectMake((f.holder.bounds.size.width - side) / 2.0,
                                  (f.holder.bounds.size.height - side) / 2.0, side, side);
    [f.holder addSublayer:f.gradient];
}

static void axs_ring_buildLayers(AXSRingFrame *f, BOOL custom, UIColor *color) {
    // 三层结构：
    //   containerLayer      矩形 = ringRect，不旋转；mask 设在它身上
    //   ├─ gradientLayer    旋转动画只加在这里（无遮罩），frame = 外接正方形
    //   maskShapeLayer      不旋转，frame = containerLayer.bounds，圆角矩形描边
    CALayer *holder = [CALayer layer];
    holder.masksToBounds = NO;
    holder.backgroundColor = [UIColor clearColor].CGColor;

    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.fillColor = nil;                    // 只用于遮罩
    mask.strokeColor = [UIColor whiteColor].CGColor;
    holder.mask = mask;                      // 遮罩设在容器上，不在渐变层上

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

// presentation-accurate rect of the content child in SCREEN coordinates:
// presentation frames along the whole superlayer chain (model values are
// already the animation END point mid-spring - taking them is exactly how a
// border "jumps ahead" and detaches), then host window frame -> screen
static CGRect axs_ring_cardScreenRect(UIView *content, UIWindow *host) {
    CALayer *pres = content.layer.presentationLayer ?: content.layer;
    CGRect rect = pres.frame;
    CALayer *p = pres.superlayer;
    while (p != nil) {
        CGRect pf = p.frame;
        rect.origin.x += pf.origin.x;
        rect.origin.y += pf.origin.y;
        p = p.superlayer;
    }
    if (host != nil) {
        rect.origin.x += host.frame.origin.x;
        rect.origin.y += host.frame.origin.y;
    }
    return rect; // screen coords
}

// 当前视觉缩放系数：沿 presentation 链累乘各层 frame/bounds 比。
// 浮窗缩放是容器 layer 上的 transform 弹簧，视觉圆角 = 配置圆角 × 缩放系数。
static CGFloat axs_ring_totalScale(UIView *content) {
    CALayer *pres = content.layer.presentationLayer ?: content.layer;
    CGFloat scale = 1.0;
    CALayer *l = pres;
    while (l != nil) {
        CGFloat bw = l.bounds.size.width;
        if (bw > 0.5) scale *= l.frame.size.width / bw;
        l = l.superlayer;
    }
    if (!(scale > 0.01)) scale = 1.0;
    return scale;
}

static void axs_ring_applyGeometry(AXSRingFrame *f, CGSize cardSize, double width, double radius) {
    // 一套坐标系：containerLayer.frame = ringRect（卡片本地 (0,0,W,H)），
    // mask.frame = containerLayer.bounds，path 只用容器内部坐标（无绝对坐标）。
    double lineWidth = width;
    if (lineWidth < 0.5) lineWidth = 0.5;
    CGRect ringRect = CGRectMake(0, 0, cardSize.width, cardSize.height);

    // path/frame 变化必须禁掉隐式动画，否则环在缩放时慢半拍拖在后面
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    f.holder.frame = ringRect;                     // 容器矩形，圆角不参与旋转
    f.mask.frame = f.holder.bounds;                // 遮罩不旋转，永远水平垂直
    CGRect r = CGRectInset(f.holder.bounds, lineWidth / 2.0, lineWidth / 2.0);
    double pathRadius = axs_ring_clamp(radius, 0.0, MIN(r.size.width, r.size.height) / 2.0);
    UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:pathRadius];
    f.mask.path = p.CGPath;
    f.mask.lineWidth = lineWidth;                  // 描边粗细固定屏幕点值，不随缩放
    // 渐变层只更新 frame（容器 bounds 的外接正方形，居中），不动它的旋转动画
    CGFloat side = hypot(cardSize.width, cardSize.height);
    f.gradient.frame = CGRectMake((cardSize.width - side) / 2.0,
                                  (cardSize.height - side) / 2.0, side, side);
    [CATransaction commit];
}

// --- lifecycle ---------------------------------------------------------------

static void axs_ring_detach(AXSRingFrame *f, NSString *reason) {
    if (f == nil) return;
    NSString *key = nil;
    for (NSString *k in axs_ring_frames.allKeys) {
        if (axs_ring_frames[k] == f) { key = k; break; }
    }
    if (f.holder != nil) [f.holder removeFromSuperlayer];
    if (key != nil) [axs_ring_frames removeObjectForKey:key];
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
    for (AXSRingFrame *f in [NSArray arrayWithArray:axs_ring_frames.allValues]) {
        axs_ring_detach(f, @"disabled");
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

// register (or update) the mapping for a session; the ring itself attaches
// on the first tick where the container sits in a window
static void axs_ring_registerSession(void *session, UIView *container) {
    if (container == nil) return;
    axs_ring_ensureMaps();

    NSString *key = axs_ring_keyForSession(session) ?: axs_ring_keyForContainer(container);
    AXSRingFrame *f = axs_ring_frames[key];
    if (f == nil) {
        f = [AXSRingFrame new];
        f.session = session;
        f.container = container;
        f.hostWindow = container.window;
        f.lastVisibleAt = [[NSDate date] timeIntervalSince1970];
        axs_ring_frames[key] = f;
    } else {
        if (f.session == NULL) f.session = session;
        f.container = container;
        f.hostWindow = container.window;
        f.lastVisibleAt = [[NSDate date] timeIntervalSince1970];
    }
    axs_ring_wake();
}

// --- session hooks (installed deferred; see axs_ring_attemptInstall) ---------

// the visible container for a session: the receiver/argument may already be
// the container; otherwise probe the session's container-ish properties
static UIView *axs_ring_containerFromObjects(id receiver, id session, NSString **howOut) {
    Class containerClass = objc_getClass("SCFloatingContainerView");
    if (containerClass != nil && [receiver isKindOfClass:containerClass]) {
        *howOut = @"receiver";
        return (UIView *)receiver;
    }
    if (session != nil && containerClass != nil && [session isKindOfClass:containerClass]) {
        *howOut = @"argument";
        return (UIView *)session;
    }
    id probeTarget = (session != nil) ? session : receiver;
    if (probeTarget == nil) return nil;
    NSArray<NSString *> *names = @[@"containerView", @"container", @"hostContainerView",
                                   @"hostingContainerView", @"contentView"];
    for (NSString *name in names) {
        SEL sel = NSSelectorFromString(name);
        if (![probeTarget respondsToSelector:sel]) continue;
        NSMethodSignature *sig = [probeTarget methodSignatureForSelector:sel];
        if (sig.numberOfArguments != 2) continue; // self + _cmd only (a getter)
        if (strcmp([sig getArgumentTypeAtIndex:0], "@") != 0) continue; // returns object
        id v = ((id(*)(id, SEL))[probeTarget methodForSelector:sel])(probeTarget, sel);
        if ([v isKindOfClass:[UIView class]]) {
            *howOut = [NSString stringWithFormat:@"probe:%@", name];
            return (UIView *)v;
        }
    }
    return nil;
}

static void axs_ring_sessionBegin_imp(id self, SEL _cmd, id session) {
    if (axs_ring_reenter_begin) {
        if (++axs_ring_reenter_blocked[0] == 50) {
            axs_ring_log(@"ring reentry blocked: %s", "sc_sessionDidBeginHosting:");
        }
        return;
    }
    axs_ring_reenter_begin = YES;
    @try {
        if (axs_ring_origSessionBegin != NULL) {
            ((void(*)(id, SEL, id))axs_ring_origSessionBegin)(self, _cmd, session);
        }
        dispatch_block_t work = ^{
            if (!axs_ring_hooksInstalled) return;
            axs_ring_ensureMaps();
            void *s = NULL;
            id container = nil;
            NSString *how = nil;
            if (session != nil && (id)session != self) {
                s = (__bridge void *)session;
                container = axs_ring_containerFromObjects(self, session, &how);
            } else {
                s = (__bridge void *)self;
                container = axs_ring_containerFromObjects(self, nil, &how);
            }
            axs_ring_log(@"ring session begin: class=%@ session=%p container=%@ via=%@",
                         NSStringFromClass([self class]), s, container, how ?: @"none");
            if (container != nil) {
                axs_ring_registerSession(s, container);
            } else if (s != NULL) {
                // container unknown yet: headless frame keyed by session;
                // sc_sessionForContainerView: may fill it in later
                NSString *key = axs_ring_keyForSession(s);
                if (axs_ring_frames[key] == nil) {
                    AXSRingFrame *f = [AXSRingFrame new];
                    f.session = s;
                    f.lastVisibleAt = [[NSDate date] timeIntervalSince1970];
                    axs_ring_frames[key] = f;
                }
                axs_ring_wake();
            }
        };
        if ([NSThread isMainThread]) work(); else dispatch_async(dispatch_get_main_queue(), work);
    } @catch (NSException *exception) {
        axs_ring_log(@"ring session begin exception: %@", exception);
    } @finally {
        axs_ring_reenter_begin = NO;
    }
}

static void axs_ring_close_imp(id self, SEL _cmd, id session) {
    if (axs_ring_reenter_close) {
        if (++axs_ring_reenter_blocked[1] == 50) {
            axs_ring_log(@"ring reentry blocked: %s", "sc_closeSession:");
        }
        return;
    }
    axs_ring_reenter_close = YES;
    @try {
        if (axs_ring_origClose != NULL) {
            ((void(*)(id, SEL, id))axs_ring_origClose)(self, _cmd, session);
        }
        void *s = session != nil ? (__bridge void *)session : NULL;
        dispatch_block_t work = ^{
            if (!axs_ring_hooksInstalled) return;
            axs_ring_ensureMaps();
            AXSRingFrame *f = nil;
            if (s != NULL) f = axs_ring_frames[axs_ring_keyForSession(s)];
            if (f == nil && s != NULL) {
                for (AXSRingFrame *cand in axs_ring_frames.allValues) {
                    if (cand.session == s) { f = cand; break; }
                }
            }
            if (f != nil) axs_ring_detach(f, @"closeSession");
            axs_ring_log(@"ring session close: class=%@ session=%p",
                         NSStringFromClass([self class]), s);
            axs_ring_idleEngine();
        };
        if ([NSThread isMainThread]) work(); else dispatch_async(dispatch_get_main_queue(), work);
    } @catch (NSException *exception) {
        axs_ring_log(@"ring session close exception: %@", exception);
    } @finally {
        axs_ring_reenter_close = NO;
    }
}

static void axs_ring_dock_imp(id self, SEL _cmd, id session, long corner) {
    if (axs_ring_reenter_dock) {
        if (++axs_ring_reenter_blocked[2] == 50) {
            axs_ring_log(@"ring reentry blocked: %s", "sc_dockSession:fromCorner:");
        }
        return;
    }
    axs_ring_reenter_dock = YES;
    @try {
        if (axs_ring_origDock != NULL) {
            ((void(*)(id, SEL, id, long))axs_ring_origDock)(self, _cmd, session, corner);
        }
        void *s = session != nil ? (__bridge void *)session : NULL;
        dispatch_block_t work = ^{
            if (!axs_ring_hooksInstalled) return;
            axs_ring_ensureMaps();
            AXSRingFrame *hit = nil;
            if (s != NULL) hit = axs_ring_frames[axs_ring_keyForSession(s)];
            if (hit == nil && s != NULL) {
                for (AXSRingFrame *cand in axs_ring_frames.allValues) {
                    if (cand.session == s) { hit = cand; break; }
                }
            }
            if (hit == nil) {
                // fallback: single-active mode means the visible ring is the
                // one being docked
                for (AXSRingFrame *cand in axs_ring_frames.allValues) {
                    if (!cand.docked && cand.container.window != nil) { hit = cand; break; }
                }
            }
            if (hit != nil) {
                hit.docked = YES;
                if (hit.holder != nil) hit.holder.hidden = YES; // 挂起期间不画环
                axs_ring_log(@"ring dock: session=%p corner=%ld", hit.session, corner);
            } else {
                axs_ring_log(@"ring dock ignored: session=%p corner=%ld (no ring)", s, corner);
            }
        };
        if ([NSThread isMainThread]) work(); else dispatch_async(dispatch_get_main_queue(), work);
    } @catch (NSException *exception) {
        axs_ring_log(@"ring dock exception: %@", exception);
    } @finally {
        axs_ring_reenter_dock = NO;
    }
}

static id axs_ring_sessionForContainer_imp(id self, SEL _cmd, id container) {
    if (axs_ring_reenter_forContainer) {
        if (++axs_ring_reenter_blocked[3] == 50) {
            axs_ring_log(@"ring reentry blocked: %s", "sc_sessionForContainerView:");
        }
        return nil;
    }
    axs_ring_reenter_forContainer = YES;
    @try {
        id result = axs_ring_origSessionForContainer != NULL
            ? ((id(*)(id, SEL, id))axs_ring_origSessionForContainer)(self, _cmd, container)
            : nil;
        if ([container isKindOfClass:[UIView class]] && result != nil) {
            void *s = (__bridge void *)result;
            UIView *v = (UIView *)container;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!axs_ring_hooksInstalled) return;
                axs_ring_ensureMaps();
                AXSRingFrame *f = axs_ring_frames[axs_ring_keyForSession(s)];
                if (f != nil && f.container == nil) {
                    f.container = v;
                    if (v.window != nil) f.hostWindow = v.window;
                    f.lastVisibleAt = [[NSDate date] timeIntervalSince1970];
                }
            });
        }
        return result;
    } @catch (NSException *exception) {
        return nil;
    } @finally {
        axs_ring_reenter_forContainer = NO;
    }
}

// --- deferred hook installation ----------------------------------------------

// hook every class declaring the selector; the sc_* names are ScreenCore
// private, so the scan cannot reach unrelated classes. Classes whose current
// IMP is already our replacement are skipped - a second MSHookMessageEx would
// store our own IMP as orig and make the orig call recurse into itself.
static NSUInteger axs_ring_hookSelector(SEL selector, IMP replacement, IMP *original) {
    NSUInteger hooked = 0;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes == NULL) return 0;
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        Method m = class_getInstanceMethod(cls, selector);
        if (m == nil) continue;
        if (method_getImplementation(m) == replacement) continue; // already hooked here
        MSHookMessageEx(cls, selector, replacement, original);
        hooked++;
    }
    free(classes);
    return hooked;
}

// ring hook name=%s class_exists=%d selector_exists=%d installed=%d
static int axs_ring_tryHook(int slot, const char *name, SEL selector, IMP replacement, IMP *original) {
    if (axs_ring_hookDone[slot]) return 1; // 已装过：重试只补漏，绝不重复 hook
    int classExists = (objc_getClass("SCFloatingContainerView") != nil) ? 1 : 0;
    int selectorExists = 0;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes != NULL) {
        for (unsigned int i = 0; i < count; i++) {
            if (class_getInstanceMethod(classes[i], selector) != nil) { selectorExists = 1; break; }
        }
        free(classes);
    }
    int installed = 0;
    if (selectorExists) {
        if (axs_ring_hookSelector(selector, replacement, original) > 0) {
            axs_ring_hookDone[slot] = YES;
            installed = 1;
        }
    }
    axs_ring_log(@"ring hook name=%s class_exists=%d selector_exists=%d installed=%d",
                 name, classExists, selectorExists, installed);
    return installed;
}

static void axs_ring_scheduleAttempt(double delay);

static void axs_ring_attemptInstall(void) {
    if (axs_ring_hooksInstalled) return;
    axs_ring_installAttempts++;
    axs_ring_ensureMaps();

    int begin = axs_ring_tryHook(0, "sc_sessionDidBeginHosting:", @selector(sc_sessionDidBeginHosting:), (IMP)axs_ring_sessionBegin_imp, &axs_ring_origSessionBegin);
    int close = axs_ring_tryHook(1, "sc_closeSession:", @selector(sc_closeSession:), (IMP)axs_ring_close_imp, &axs_ring_origClose);
    int dock = axs_ring_tryHook(2, "sc_dockSession:fromCorner:", @selector(sc_dockSession:fromCorner:), (IMP)axs_ring_dock_imp, &axs_ring_origDock);
    int forContainer = axs_ring_tryHook(3, "sc_sessionForContainerView:", @selector(sc_sessionForContainerView:), (IMP)axs_ring_sessionForContainer_imp, &axs_ring_origSessionForContainer);

    if (begin && close && dock && forContainer) {
        axs_ring_hooksInstalled = YES;
        axs_ring_log(@"ring hooks: begin=%d close=%d dock=%d forContainer=%d", begin, close, dock, forContainer);
        return;
    }
    if (axs_ring_installAttempts < 3) {
        double delay = (axs_ring_installAttempts == 1) ? 1.0 : 2.0;
        axs_ring_log(@"ring hooks retry: attempt=%d begin=%d close=%d dock=%d forContainer=%d",
                     axs_ring_installAttempts, begin, close, dock, forContainer);
        axs_ring_scheduleAttempt(delay);
        return;
    }
    axs_ring_log(@"ring hooks FAILED: begin=%d close=%d dock=%d forContainer=%d (attempts=%d)",
                 begin, close, dock, forContainer, axs_ring_installAttempts);
}

static void axs_ring_scheduleAttempt(double delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ axs_ring_attemptInstall(); });
}

// --- display tick: compare-only, no interpolation -----------------------------

static void axs_ring_tick(void) {
    @try {
        if (axs_ring_frames == nil) return;
        if (!axs_ring_enabled()) {
            axs_ring_stopAll();
            return;
        }

        double now = [[NSDate date] timeIntervalSince1970];

        for (NSString *key in [axs_ring_frames.allKeys copy]) {
            AXSRingFrame *f = axs_ring_frames[key];

            // headless frame: session known, container not resolved yet
            if (f.container == nil) {
                if (f.lastVisibleAt > 0.0 && now - f.lastVisibleAt > 5.0) {
                    axs_ring_detach(f, @"unresolved session");
                }
                continue;
            }
            // container gone or off-screen: hide immediately (no orphan ring)
            if (f.container.window == nil) {
                if (f.holder != nil && !f.holder.hidden) f.holder.hidden = YES;
                if (f.lastVisibleAt > 0.0 && now - f.lastVisibleAt > 3.0) {
                    axs_ring_detach(f, @"dormant cleanup");
                }
                continue;
            }

            UIView *content = axs_ring_contentChild(f.container) ?: f.container;
            CGRect cardRect = axs_ring_cardScreenRect(content, f.container.window);
            if (cardRect.size.width < 20 || cardRect.size.height < 20) {
                if (f.holder != nil) f.holder.hidden = YES;
                continue;
            }
            f.lastVisibleAt = now;
            f.hostWindow = f.container.window;

            // 挂起的会话不画环，也绝不参与环的认领（ring dock ignored 正常）
            if (f.docked) {
                if (f.holder != nil && !f.holder.hidden) f.holder.hidden = YES;
                continue;
            }

            BOOL custom = axs_ring_customColor();
            UIColor *color = axs_ring_color();
            double width = axs_ring_thickness();     // 每帧重读（固定屏幕点值，不随缩放）
            double radius = axs_ring_cornerRadius()  // 每帧重读
                          * (double)axs_ring_totalScale(content); // 视觉圆角 = 配置圆角 × 当前缩放
            NSInteger mode = custom ? 1 : 0;

            if (f.holder == nil) {
                // 一个宿主窗口只允许一个环：attach 前先看环是否已在别的会话
                // 手上，有就转移复用并更新（旧会话通常是刚挂起/被顶掉的），
                // 绝不新建第二层描边
                AXSRingFrame *owner = nil;
                for (AXSRingFrame *cand in axs_ring_frames.allValues) {
                    if (cand != f && cand.holder != nil) { owner = cand; break; }
                }
                if (owner != nil) {
                    f.holder = owner.holder;
                    f.gradient = owner.gradient;
                    f.mask = owner.mask;
                    owner.holder = nil; owner.gradient = nil; owner.mask = nil;
                    owner.lastSize = CGSizeZero;
                    owner.attachLogged = NO;
                    f.attachLogged = NO;
                    f.lastSize = CGSizeZero;
                    f.lastMode = -1; // 强制按当前模式重刷渐变与几何
                    axs_ring_log(@"ring handover: session=%p -> %p host=%p",
                                 owner.session, f.session, f.hostWindow);
                }
                if (axs_ring_window == nil
                    && axs_ring_ensureWindow(f.container.window, cardRect) == nil) {
                    continue;
                }
                if (f.holder == nil) {
                    axs_ring_buildLayers(f, custom, color);
                    f.lastSize = CGSizeZero;
                    f.lastMode = mode;
                    f.lastWidth = (CGFloat)width;
                    f.lastRadius = (CGFloat)radius;
                }
                if (!f.attachLogged) {
                    f.attachLogged = YES;
                    axs_ring_log(@"ring attach: session=%p host=%p rect=%@",
                                 f.session, f.container.window, NSStringFromCGRect(cardRect));
                }
            }

            if (f.holder.hidden) f.holder.hidden = NO;

            // overlay frame 只跟随持有环的这张卡片；环在窗口内即卡片本地坐标
            if (!CGRectEqualToRect(axs_ring_window.frame, cardRect)) {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                axs_ring_window.frame = cardRect;
                [CATransaction commit];
            }

            BOOL styleChanged = (f.lastMode != mode)
                             || (f.lastWidth != (CGFloat)width)
                             || (f.lastRadius != (CGFloat)radius);
            if (styleChanged) {
                if (f.lastMode != mode) {
                    axs_ring_rebuildGradient(f, custom, color);
                }
                f.lastMode = mode;
                f.lastWidth = (CGFloat)width;
                f.lastRadius = (CGFloat)radius;
            }
            if (!CGSizeEqualToSize(cardRect.size, f.lastSize) || styleChanged) {
                axs_ring_applyGeometry(f, cardRect.size, width, radius);
                f.lastSize = cardRect.size;
                if (now - f.lastUpdateLoggedAt >= 0.5 || styleChanged) {
                    f.lastUpdateLoggedAt = now;
                    axs_ring_log(@"ring update: rect=%@ radius=%.1f width=%.1f mode=%d",
                                 NSStringFromCGRect(cardRect), radius, width, (int)mode);
                }
            }
        }

        if (axs_ring_frames.count == 0) {
            axs_ring_idleEngine();
        }
    } @catch (NSException *exception) {
        axs_ring_log(@"ring tick exception: %@", exception);
    }
}

// --- entry: deferred install with 0.5s/1.0s/2.0s retries ----------------------

%ctor {
    @autoreleasepool {
        if (objc_getClass("SpringBoard") != nil) {
            axs_ring_ensureMaps();
            axs_ring_log(@"ring module loaded in SpringBoard");
            axs_ring_scheduleAttempt(0.5); // 不在 ctor 里直接装：等类注册完成
        }
    }
}
