#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AxsHoldLaunchConfig.h"
#import "AxsHoldLaunchPreferences.h"
#import "AxsHoldLaunchPrivate.h"

// ---------------------------------------------------------------------------
// 美化 · 光圈外框 (ring frame, beautify.8) — 图层附着方案
//
// beautify.7 lesson: chasing the floating card from an overlay UIWindow with
// presentation frames cannot work - the card is scaled by a TRANSFORM spring
// on the container's layer, so bounds-based rects never match the visual
// rect, and the overlay window covers the card's gesture hot zones.
//
// This version has NO overlay window and NO display link:
//   - the ring is a sublayer of the container's own layer (the layer that
//     carries the transform spring), so drag/scale/spring move the ring
//     physically - it cannot detach or trail;
//   - CALayer does no hit testing, so the fullscreen/close/corner gesture
//     zones work immediately;
//   - ring corner radius = the host's own cornerRadius (container -> largest
//     content child -> config fallback), scaled by the same transform;
//   - KVO on the container layer's bounds/cornerRadius re-syncs frame+path;
//   - a 1s health check detaches rings whose host left the hierarchy and
//     re-attaches when it comes back; handover removes the old host's ring
//     before attaching the new one (never both).
//
//   container.layer
//     ├─ (existing content)
//     └─ ringContainer          frame = container bounds; mask = shapeLayer
//          ├─ gradientLayer     rotation animation only here (no mask),
//          │                    frame = circumscribed square of ringContainer
//          (shapeLayer          ringContainer.mask; not a rendered sublayer)
// ---------------------------------------------------------------------------

#define AXS_RING_LOG_PATH @"/var/mobile/Documents/sc-ring.log"

static void axs_ring_syncRing(id frame);
static void axs_ring_reconcile(void);

@class AXSRingFrame;
static void axs_ring_removeRing(AXSRingFrame *frame, NSString *reason);

@interface AXSRingHealthTarget : NSObject
- (void)axsRingTick;
@end
@implementation AXSRingHealthTarget
- (void)axsRingTick { axs_ring_reconcile(); }
@end

@interface AXSRingFrame : NSObject
@property (nonatomic, assign) void *session;
@property (nonatomic, weak) UIView *container;
@property (nonatomic, strong) CALayer *ringContainer;   // 挂在 container.layer 上的环
@property (nonatomic, strong) CAGradientLayer *gradient;
@property (nonatomic, strong) CAShapeLayer *shape;      // ringContainer.mask
@property (nonatomic, assign) BOOL kvoInstalled;
@property (nonatomic, assign) BOOL docked;
@property (nonatomic, assign) BOOL attachLogged;
@property (nonatomic, assign) BOOL inHierarchy;
@property (nonatomic, assign) CGFloat lastRadiusLogged;
@property (nonatomic, assign) CGFloat lastPathRadius;
@property (nonatomic, assign) double lastAliveAt;
@end
@implementation AXSRingFrame
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"bounds"] || [keyPath isEqualToString:@"cornerRadius"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ axs_ring_syncRing(self); });
    }
}
@end

static NSMutableDictionary<NSString *, AXSRingFrame *> *axs_ring_frames = nil;
static BOOL axs_ring_hooksInstalled = NO;
static int axs_ring_installAttempts = 0;
static NSTimer *axs_ring_healthTimer = nil;

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

// the visible rounded card = the container's largest child that stays INSIDE
// the container bounds (the gesture overlay pokes out on every side, so size
// alone would pick the wrong subview)
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

// TXT 三.1 圆角读取顺序：container.layer.cornerRadius -> 一级 subviews 的
// layer.cornerRadius 最大值 -> 配置 splitWindowCornerRadius 兜底。
// 禁止取 hostWindow.layer.cornerRadius（窗口层的圆角不是卡片的）。
static CGFloat axs_ring_resolveRadius(UIView *container) {
    CGFloat base = container.layer.cornerRadius;
    if (base < 0.5) {
        for (UIView *sub in container.subviews) {
            if (sub.layer.cornerRadius > base) base = sub.layer.cornerRadius;
        }
    }
    if (base < 0.5) base = (CGFloat)axs_ring_cornerRadius();
    return base;
}

// 仅供日志核对（TXT 三.3）：容器 presentation transform 的 a 值，
// 不参与圆角计算——圆角由容器层自己的 transform 物理缩放
static CGFloat axs_ring_presentScale(UIView *container) {
    CALayer *pres = container.layer.presentationLayer;
    CGAffineTransform t = pres ? pres.affineTransform : CGAffineTransformIdentity;
    CGFloat a = t.a;
    if (!(a > 0.01)) a = 1.0;
    return a;
}

// KVO / 体检共用的几何同步：ringContainer.frame 跟随容器 bounds，遮罩 path
// 与渐变外接正方形一并重算；圆角变化时打 ring radius 行
static void axs_ring_syncRing(id frameRef) {
    AXSRingFrame *f = frameRef;
    if (f == nil || f.ringContainer == nil || f.container == nil) return;
    @try {
        double lineWidth = axs_ring_thickness();
        if (lineWidth < 0.5) lineWidth = 0.5;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        f.ringContainer.frame = f.container.layer.bounds;
        f.shape.frame = f.ringContainer.bounds;
        CGFloat base = axs_ring_resolveRadius(f.container);
        CGRect r = CGRectInset(f.ringContainer.bounds, lineWidth / 2.0, lineWidth / 2.0);
        double pathRadius = axs_ring_clamp(base, 0.0, MIN(r.size.width, r.size.height) / 2.0);
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:pathRadius];
        f.shape.path = p.CGPath;
        f.shape.lineWidth = lineWidth;
        CGFloat side = hypot(f.ringContainer.bounds.size.width, f.ringContainer.bounds.size.height);
        if (side < 1.0) side = 1.0;
        f.gradient.frame = CGRectMake((f.ringContainer.bounds.size.width - side) / 2.0,
                                      (f.ringContainer.bounds.size.height - side) / 2.0, side, side);
        [CATransaction commit];
        f.lastPathRadius = (CGFloat)pathRadius;
        if (fabs(f.lastRadiusLogged - base) > 0.05) {
            f.lastRadiusLogged = base;
            axs_ring_log(@"ring radius: host=%.1f path=%.1f scale=%.3f",
                         base, pathRadius, (double)axs_ring_presentScale(f.container));
        }
    } @catch (NSException *exception) {
        axs_ring_log(@"ring sync exception: %@", exception);
    }
}

// --- attach / remove ---------------------------------------------------------

// attach 前先把别的会话身上的环摘掉（禁止两边同时存在），再挂到本会话容器上
static void axs_ring_attachRing(AXSRingFrame *f) {
    if (f == nil || f.ringContainer != nil || f.container == nil) return;
    AXSRingFrame *previous = nil;
    for (AXSRingFrame *cand in axs_ring_frames.allValues) {
        if (cand != f && cand.ringContainer != nil) {
            previous = cand;
            axs_ring_removeRing(cand, @"handover");
        }
    }
    if (!axs_ring_enabled()) return;

    CALayer *ring = [CALayer layer];
    ring.frame = f.container.layer.bounds;
    ring.masksToBounds = NO;
    ring.zPosition = 9999.0;                 // 加在最后 + zPosition：盖在内容之上

    CAShapeLayer *shape = [CAShapeLayer layer];
    shape.fillColor = nil;                   // 只当遮罩用
    shape.strokeColor = [UIColor whiteColor].CGColor;
    ring.mask = shape;

    CAGradientLayer *grad = axs_ring_makeGradient(axs_ring_customColor(), axs_ring_color());
    [ring addSublayer:grad];

    f.ringContainer = ring;
    f.shape = shape;
    f.gradient = grad;
    [f.container.layer addSublayer:ring];    // 宿主图层最上层

    @try {
        [f.container.layer addObserver:f forKeyPath:@"bounds" options:NSKeyValueObservingOptionNew context:nil];
        [f.container.layer addObserver:f forKeyPath:@"cornerRadius" options:NSKeyValueObservingOptionNew context:nil];
        f.kvoInstalled = YES;
    } @catch (NSException *exception) {
        axs_ring_log(@"ring kvo exception: %@", exception);
    }

    axs_ring_syncRing(f);
    f.ringContainer.hidden = NO;
    if (!f.attachLogged) {
        f.attachLogged = YES;
        // TXT 二.2：containerLayer 必须与 session begin 行的 layer 地址一致，
        // 且必须 != hostLayer；否则就是挂错层
        axs_ring_log(@"ring attach: session=%p container=%p containerLayer=%p hostWindow=%p hostLayer=%p bounds=%@ radius=host=%.1f path=%.1f scale=%.3f",
                     f.session, f.container, f.container.layer, f.container.window, f.container.window.layer,
                     NSStringFromCGRect(f.container.layer.bounds),
                     (double)axs_ring_resolveRadius(f.container),
                     (double)f.lastPathRadius,
                     (double)axs_ring_presentScale(f.container));
    }
    if (previous != nil) {
        axs_ring_log(@"ring handover: session=%p -> %p hostLayer=%p",
                     previous.session, f.session, f.container.layer);
    }
}

// TXT 二.6 / 三.1：从宿主移除 ringContainer 并把 mask 置 nil，完全无副作用
static void axs_ring_removeRing(AXSRingFrame *f, NSString *reason) {
    if (f == nil || f.ringContainer == nil) return;
    @try {
        if (f.kvoInstalled && f.container != nil) {
            [f.container.layer removeObserver:f forKeyPath:@"bounds"];
            [f.container.layer removeObserver:f forKeyPath:@"cornerRadius"];
        }
    } @catch (NSException *exception) { }
    f.kvoInstalled = NO;
    f.ringContainer.mask = nil;
    [f.ringContainer removeFromSuperlayer];
    f.ringContainer = nil;
    f.shape = nil;
    f.gradient = nil;
    f.attachLogged = NO;
    axs_ring_log(@"ring detach: session=%p reason=%@", f.session, reason);
}

static void axs_ring_detachFrame(AXSRingFrame *f, NSString *reason) {
    if (f == nil) return;
    axs_ring_removeRing(f, reason);
    NSString *key = nil;
    for (NSString *k in axs_ring_frames.allKeys) {
        if (axs_ring_frames[k] == f) { key = k; break; }
    }
    if (key != nil) [axs_ring_frames removeObjectForKey:key];
}

// register (or update) the mapping for a session; the ring attaches right
// here in the hosting hook (TXT 二.实施步骤1)
static void axs_ring_registerSession(void *session, UIView *container) {
    if (container == nil) return;
    axs_ring_ensureMaps();

    NSString *key = axs_ring_keyForSession(session) ?: axs_ring_keyForContainer(container);
    AXSRingFrame *f = axs_ring_frames[key];
    if (f == nil) {
        f = [AXSRingFrame new];
        f.session = session;
        f.container = container;
        f.lastAliveAt = [[NSDate date] timeIntervalSince1970];
        axs_ring_frames[key] = f;
    } else {
        if (f.session == NULL) f.session = session;
        f.container = container;
        f.lastAliveAt = [[NSDate date] timeIntervalSince1970];
    }

    if (f.docked) {
        if (f.ringContainer != nil) f.ringContainer.hidden = YES;
        return;
    }
    if (axs_ring_enabled()) {
        axs_ring_attachRing(f); // 内含 handover：先摘旧宿主的环再挂新的
    } else if (f.ringContainer != nil) {
        axs_ring_removeRing(f, @"disabled");
    }
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
                    f.lastAliveAt = [[NSDate date] timeIntervalSince1970];
                    axs_ring_frames[key] = f;
                }
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
            if (f != nil) axs_ring_detachFrame(f, @"closeSession");
            axs_ring_log(@"ring session close: class=%@ session=%p",
                         NSStringFromClass([self class]), s);
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
            if (hit != nil) {
                hit.docked = YES;
                if (hit.ringContainer != nil) hit.ringContainer.hidden = YES; // 挂起期间不画环
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
                    f.lastAliveAt = [[NSDate date] timeIntervalSince1970];
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

// --- health check (0.5s) + config reaction --------------------------------------

// TXT 五.2：有效性体检（0.5s，引擎内定时器，不是逐帧刷新）。
// 容器离层（window/superview/layer.superlayer 任一为空）→ 立即 detach 清环
// （reason=hostGone）并打 suspend；回到层级打 resume 并按完整 attach 流程
// 重挂（不复用旧 ring layer）；开关关闭时全摘（ringContainer 移除 + mask 置 nil）
static void axs_ring_reconcile(void) {
    if (!axs_ring_hooksInstalled) return;
    @try {
        axs_ring_ensureMaps();
        BOOL enabled = axs_ring_enabled();
        double now = [[NSDate date] timeIntervalSince1970];

        for (NSString *key in [axs_ring_frames.allKeys copy]) {
            AXSRingFrame *f = axs_ring_frames[key];

            if (f.container == nil) {
                // headless：会话已知、容器未解析
                if (f.lastAliveAt > 0.0 && now - f.lastAliveAt > 5.0) {
                    axs_ring_detachFrame(f, @"unresolved session");
                }
                continue;
            }

            BOOL inHierarchy = (f.container.window != nil
                                && f.container.superview != nil
                                && f.container.layer.superlayer != nil);
            if (!inHierarchy) {
                if (f.inHierarchy) {
                    f.inHierarchy = NO;
                    axs_ring_removeRing(f, @"hostGone"); // ring detach: reason=hostGone
                    axs_ring_log(@"ring suspend: session=%p", f.session);
                } else if (f.ringContainer != nil) {
                    axs_ring_removeRing(f, @"hostGone");
                }
                if (f.lastAliveAt > 0.0 && now - f.lastAliveAt > 5.0) {
                    axs_ring_detachFrame(f, @"hostGone");
                }
                continue;
            }
            if (!f.inHierarchy) {
                f.inHierarchy = YES;
                axs_ring_log(@"ring resume: session=%p container=%p", f.session, f.container);
            }
            f.lastAliveAt = now;

            if (!enabled) {
                if (f.ringContainer != nil) axs_ring_removeRing(f, @"disabled");
                continue;
            }
            if (f.docked) {
                if (f.ringContainer != nil && !f.ringContainer.hidden) f.ringContainer.hidden = YES;
                continue;
            }
            if (f.ringContainer == nil) {
                axs_ring_attachRing(f); // 回前台重建的容器：完整 attach，不复用旧 ring layer
            } else if (f.ringContainer.hidden) {
                f.ringContainer.hidden = NO;
            }
        }
    } @catch (NSException *exception) {
        axs_ring_log(@"ring reconcile exception: %@", exception);
    }
}

// Darwin 通知：设置保存后立即重查开关状态（0.5s 体检兜底）
static void axs_ring_prefsChanged(CFNotificationCenterRef center, void *observer,
                                  CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ axs_ring_reconcile(); });
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
        if (axs_ring_healthTimer == nil) {
            axs_ring_healthTimer = [NSTimer timerWithTimeInterval:0.5
                                                           target:[[AXSRingHealthTarget alloc] init]
                                                         selector:@selector(axsRingTick)
                                                         userInfo:nil
                                                          repeats:YES];
            [[NSRunLoop mainRunLoop] addTimer:axs_ring_healthTimer forMode:NSRunLoopCommonModes];
        }
        axs_ring_reconcile();
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

// --- entry: deferred install with 0.5s/1.0s/2.0s retries ----------------------

%ctor {
    @autoreleasepool {
        if (objc_getClass("SpringBoard") != nil) {
            axs_ring_ensureMaps();
            axs_ring_log(@"ring module loaded in SpringBoard");
            // 设置保存通知：开关变化立即生效（1s 体检兜底）
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            NULL, axs_ring_prefsChanged,
                                            (__bridge CFStringRef)AxsHoldLaunchTheirPrefsSaved,
                                            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            axs_ring_scheduleAttempt(0.5); // 不在 ctor 里直接装：等类注册完成
        }
    }
}
