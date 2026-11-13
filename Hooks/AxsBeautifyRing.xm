#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AxsHoldLaunchConfig.h"
#import "AxsHoldLaunchPreferences.h"
#import "AxsHoldLaunchPrivate.h"

// ---------------------------------------------------------------------------
// 美化 · 光圈外框 (ring frame, beautify.10) — 纯图层 + ScreenCore 真实圆角
//
// beautify.9 lesson: ScreenCore animates the container's model cornerRadius
// continuously (sc_updateCornerRadiusAndShadowPath), so re-reading it per KVO
// fire made the ring's corners oscillate (503 log lines) and never match the
// card. Also, the real corner radius does NOT live on layer.cornerRadius:
//
//   preferredCornerRadius -> sc_effectiveCornerRadius -> interactiveMaskLayer
//   -> splitWindowCornerRadius fallback   (resolved ONCE at attach, KVO kept
//   for preferredCornerRadius / bounds changes only)
//
// The ring is a pure CALayer subtree attached to container.layer (the layer
// carrying the transform spring): drag/scale/spring move it physically. No
// overlay window, no display link, no UIView, no transform animations - the
// marquee runs as a colors keyframe animation on the conic gradient.
//
//   container.layer
//     ├─ (existing content)
//     └─ ringContainer           frame = container bounds; mask = shapeLayer
//          ├─ gradientLayer      conic rainbow; marquee = colors keyframes
//          (shapeLayer           ringContainer.mask; not a rendered sublayer)
// ---------------------------------------------------------------------------

#define AXS_RING_LOG_PATH @"/var/mobile/Documents/sc-ring.log"

static void axs_ring_syncRing(void);
static void axs_ring_reconcile(void);
static void axs_ring_removeRing(NSString *reason);
static void axs_ring_attachRing(void);

// 活跃环状态：全局单环（attach 前先摘别的宿主上的环，禁止两边同时存在）。
// 不设任何 UIView、不设状态类——纯 C 静态量 + 图层。
static void *axs_ring_activeSession = NULL;
static __weak UIView *axs_ring_container = nil;
static CALayer *axs_ring_ring = nil;              // ringContainer
static CAGradientLayer *axs_ring_gradient = nil;
static CAShapeLayer *axs_ring_shape = nil;        // ringContainer.mask
static CGFloat axs_ring_baseRadius = 0;           // attach 时解析一次
static NSString *axs_ring_radiusSource = nil;     // preferred/effective/mask/config
static CGPathRef axs_ring_hostMaskPath = nil;     // mask 来源时复用的宿主几何
static BOOL axs_ring_kvoInstalled = NO;
static BOOL axs_ring_docked = NO;
static BOOL axs_ring_attachLogged = NO;
static BOOL axs_ring_suspended = NO;
static void *axs_ring_handoverFrom = NULL; // attach 时如有旧环，打 handover 行
static CGFloat axs_ring_lastLoggedRadius = -1;
static NSTimer *axs_ring_healthTimer = nil;

// pending：sessionBegin 没解析出容器时挂起，等 sc_sessionForContainerView:
// 的被动配对填充（0.5s 体检里认领，5s 过期）
static void *axs_ring_pendingSession = NULL;
static __weak UIView *axs_ring_pendingContainer = nil;
static double axs_ring_pendingAt = 0;

// manager（sc_sessionDidBeginHosting: 的接收者，日志确认是
// SCFloatingSceneManager）：sc_effectiveCornerRadius 圆角来源的候选对象
static __weak id axs_ring_managerRef = nil;
static double axs_ring_lastAliveAt = 0;

// 容器解析（沿用 beautify.6 起验证过的三级探测）
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

static IMP axs_ring_origSessionBegin = NULL;
static IMP axs_ring_origClose = NULL;
static IMP axs_ring_origDock = NULL;
static IMP axs_ring_origSessionForContainer = NULL;

static BOOL axs_ring_hooksInstalled = NO;
static int axs_ring_installAttempts = 0;

// 防重入闸：每个钩子独立的线程局部标志。钩子内发的任何消息都可能再次进入
// 钩子；重入直接 return，不再调 orig，同一钩子被拦满 50 次写一条日志。
static __thread BOOL axs_ring_reenter_begin = NO;
static __thread BOOL axs_ring_reenter_close = NO;
static __thread BOOL axs_ring_reenter_dock = NO;
static __thread BOOL axs_ring_reenter_forContainer = NO;
static int axs_ring_reenter_blocked[4] = {0, 0, 0, 0};

// 安装幂等：已装过的选择子绝不重复 hook（防止 MSHookMessageEx 把自己的
// IMP 存成 orig，造成 orig -> 自己的无限递归）
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

static double axs_ring_configRadius(void) {
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

// --- KVO observer（单例；环状态在全局静态量里，不设状态类） ------------------

@interface AXSRingKVOObserver : NSObject
@end
@implementation AXSRingKVOObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    // 仅 preferredCornerRadius / bounds 两个 keyPath 会挂进来（TXT 四：
    // 禁止每帧重读圆角；只在 attach 与这些变化时更新）
    dispatch_async(dispatch_get_main_queue(), ^{ axs_ring_syncRing(); });
}
@end
static AXSRingKVOObserver *axs_ring_kvoObserver = nil;

// --- marquee: colors keyframes only（TXT 六.1：删除 transform.rotation.z） ----

static NSArray<UIColor *> *axs_ring_rainbow(void) {
    // 8 段、首尾同色（conic 收口无缝）
    return @[ [UIColor redColor], [UIColor orangeColor], [UIColor yellowColor],
              [UIColor greenColor], [UIColor cyanColor], [UIColor blueColor],
              [UIColor purpleColor], [UIColor redColor] ];
}

static CAGradientLayer *axs_ring_makeGradient(BOOL custom, UIColor *color) {
    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.type = kCAGradientLayerConic;
    grad.startPoint = CGPointMake(0.5, 0.5);
    grad.endPoint = CGPointMake(0.5, 0.0);
    if (custom) {
        grad.colors = @[ (__bridge id)color.CGColor, (__bridge id)color.CGColor ];
        grad.locations = @[ @0.0, @1.0 ];
        // 静态单色细边框：不加任何动画
    } else {
        NSArray<UIColor *> *rainbow = axs_ring_rainbow();
        NSUInteger n = rainbow.count;
        NSMutableArray *colors = [NSMutableArray array];
        NSMutableArray *locations = [NSMutableArray array];
        for (NSUInteger i = 0; i < n; i++) {
            [colors addObject:(__bridge id)rainbow[i].CGColor];
            [locations addObject:@((double)i / (double)(n - 1))];
        }
        grad.colors = colors;
        grad.locations = locations;

        // 跑马灯只走 colors 关键帧：整组颜色逐段轮转，4s 一圈，
        // 不旋转任何层（dylib 里不出现 transform.rotation.z）
        CAKeyframeAnimation *anim = [CAKeyframeAnimation animationWithKeyPath:@"colors"];
        NSMutableArray *values = [NSMutableArray array];
        for (NSUInteger shift = 0; shift < n; shift++) {
            NSMutableArray *shifted = [NSMutableArray array];
            for (NSUInteger j = 0; j < n; j++) {
                [shifted addObject:(__bridge id)rainbow[(j + shift) % n].CGColor];
            }
            [values addObject:shifted];
        }
        anim.values = values;
        anim.duration = 4.0;                 // 8 段 × 0.5s = 4s 一圈
        anim.repeatCount = HUGE_VALF;
        anim.calculationMode = kCAAnimationLinear;
        anim.removedOnCompletion = NO;
        [grad addAnimation:anim forKey:@"axsRingMarquee"];
    }
    return grad;
}

// --- 圆角来源（TXT 四：逐级回退，每级 respondsToSelector 校验） ---------------

// 从圆角矩形 CGPath 提取半径（取第一条曲线的控制点偏移）
typedef struct {
    CGFloat radius;
    CGPoint from;
    BOOL started;
} AXSRingPathCtx;

static void axs_ring_pathApplier(void *info, const CGPathElement *element) {
    AXSRingPathCtx *ctx = (AXSRingPathCtx *)info;
    switch (element->type) {
        case kCGPathElementMoveToPoint:
            ctx->from = element->points[0];
            ctx->started = YES;
            break;
        case kCGPathElementAddLineToPoint:
            ctx->from = element->points[0];
            break;
        case kCGPathElementAddCurveToPoint: {
            CGPoint cp1 = element->points[0];
            CGFloat dr = fabs(cp1.y - ctx->from.y);
            if (dr < 0.01) dr = fabs(cp1.x - ctx->from.x);
            if (ctx->radius < 0.01 && dr > 0.5) ctx->radius = dr;
            ctx->from = element->points[3];
            break;
        }
        default: break;
    }
}

static CGFloat axs_ring_radiusFromPath(CGPathRef path) {
    if (path == nil) return 0;
    AXSRingPathCtx ctx = { 0, CGPointZero, NO };
    CGPathApply(path, &ctx, axs_ring_pathApplier);
    return ctx.radius;
}

// 读 ObjC ivar（仅接受 UIView 值）：_interactionOverlayView 等私有 ivar 的安全读取
static UIView *axs_ring_ivarView(id obj, const char *name) {
    if (obj == nil) return nil;
    @try {
        Ivar ivar = class_getInstanceVariable(obj_getClass(obj), name);
        if (ivar == nil) return nil;
        id v = object_getIvar(obj, ivar);
        return [v isKindOfClass:[UIView class]] ? v : nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

// TXT 五.1 圆角归属链：容器 → interactionOverlayView（ivar）→ UIView 祖先链。
// 对链上每个对象依次探测三个 selector（均做 respondsToSelector + 签名校验）。
// log=YES 时打 ring probe: radiusOwner 行（只在 attach / resume 传 YES）。
static NSArray *axs_ring_radiusChain(UIView *container) {
    NSMutableArray *chain = [NSMutableArray array];
    [chain addObject:container];
    UIView *overlay = axs_ring_ivarView(container, "_interactionOverlayView");
    if (overlay != nil) [chain addObject:overlay];
    UIView *ancestor = container.superview;
    int hops = 0;
    while (ancestor != nil && hops < 8) {
        [chain addObject:ancestor];
        ancestor = ancestor.superview;
        hops++;
    }
    return chain;
}

static CGFloat axs_ring_resolveRadiusChain(UIView *container, NSString **sourceOut, CGPathRef *pathOut, BOOL log) {
    if (pathOut != nil) *pathOut = nil;
    SEL selPreferred = @selector(preferredCornerRadius);
    SEL selEffective = @selector(sc_effectiveCornerRadius);
    SEL selMask = @selector(interactiveMaskLayer);

    NSArray *chain = axs_ring_radiusChain(container);
    for (id obj in chain) {
        if (obj == nil || obj == [NSNull null]) continue;

        // a) preferredCornerRadius（基础类型返回值才调用，防 ARC 错 retain）
        if ([obj respondsToSelector:selPreferred]) {
            NSMethodSignature *sig = [obj methodSignatureForSelector:selPreferred];
            const char *rt = sig ? [sig getArgumentTypeAtIndex:0] : "";
            if (strcmp(rt, "d") == 0 || strcmp(rt, "f") == 0) {
                double v = ((double(*)(id, SEL))[obj methodForSelector:selPreferred])(obj, selPreferred);
                if (v > 0.5) {
                    if (log) axs_ring_log(@"ring probe: radiusOwner class=%@ selector=%@ value=%.2f",
                                          NSStringFromClass([obj class]), "preferredCornerRadius", v);
                    *sourceOut = @"preferred";
                    return (CGFloat)v;
                }
            }
        }
        // b) sc_effectiveCornerRadius
        if ([obj respondsToSelector:selEffective]) {
            NSMethodSignature *sig = [obj methodSignatureForSelector:selEffective];
            const char *rt = sig ? [sig getArgumentTypeAtIndex:0] : "";
            if (strcmp(rt, "d") == 0 || strcmp(rt, "f") == 0) {
                double v = ((double(*)(id, SEL))[obj methodForSelector:selEffective])(obj, selEffective);
                if (v > 0.5) {
                    if (log) axs_ring_log(@"ring probe: radiusOwner class=%@ selector=%@ value=%.2f",
                                          NSStringFromClass([obj class]), "sc_effectiveCornerRadius", v);
                    *sourceOut = @"effective";
                    return (CGFloat)v;
                }
            }
        }
        // c) interactiveMaskLayer（返回 CAShapeLayer 且带 path）
        if ([obj respondsToSelector:selMask]) {
            NSMethodSignature *sig = [obj methodSignatureForSelector:selMask];
            if (sig.numberOfArguments == 2 && strcmp([sig getArgumentTypeAtIndex:0], "@") == 0) {
                id v = ((id(*)(id, SEL))[obj methodForSelector:selMask])(obj, selMask);
                if ([v isKindOfClass:[CAShapeLayer class]] && ((CAShapeLayer *)v).path != nil) {
                    CGPathRef p = ((CAShapeLayer *)v).path;
                    if (log) {
                        CGRect bb = CGPathGetBoundingBox(p);
                        axs_ring_log(@"ring probe: radiusOwner class=%@ selector=%@ value=%.2f path=%@",
                                     NSStringFromClass([obj class]), "interactiveMaskLayer",
                                     axs_ring_radiusFromPath(p), NSStringFromCGRect(bb));
                    }
                    if (pathOut != nil) *pathOut = CGPathRetain(p);
                    *sourceOut = @"mask";
                    return axs_ring_radiusFromPath(p);
                }
            }
        }
    }
    // 都取不到：配置兜底
    if (log) axs_ring_log(@"ring probe: radiusOwner none (config fallback)");
    *sourceOut = @"config";
    return (CGFloat)axs_ring_configRadius();
}

// attach / resume 时一次性运行时体检（TXT 三）：容器本体、两层视图层级、
// 手势统计、圆角归属。禁止在每帧/DisplayLink 里调用。
static void axs_ring_probeContainer(UIView *container) {
    @try {
        // 1) 容器本体
        axs_ring_log(@"ring probe: container class=%@ frame=%@ bounds=%@ layerCorner=%.2f masksToBounds=%d",
                     NSStringFromClass(container.class), NSStringFromCGRect(container.frame),
                     NSStringFromCGRect(container.bounds),
                     container.layer.cornerRadius, container.layer.masksToBounds ? 1 : 0);

        // 2) 视图层级（两层）+ 手势统计
        UIView *overlay = axs_ring_ivarView(container, "_interactionOverlayView");
        NSMutableArray *views = [NSMutableArray array];
        if (overlay != nil) [views addObject:overlay];
        for (UIView *sub in container.subviews) {
            [views addObject:sub];
            for (UIView *sub2 in sub.subviews) [views addObject:sub2];
        }
        for (UIView *v in views) {
            axs_ring_log(@"ring probe: view class=%@ frame=%@ userInteraction=%d subviews=%d",
                         NSStringFromClass(v.class), NSStringFromCGRect(v.frame),
                         v.userInteractionEnabled ? 1 : 0, (unsigned)v.subviews.count);
        }
        axs_ring_log(@"ring probe: gestures class=%@ count=%lu",
                     NSStringFromClass(container.class), (unsigned long)container.gestureRecognizers.count);
        for (UIView *v in views) {
            axs_ring_log(@"ring probe: gestures class=%@ count=%lu",
                         NSStringFromClass(v.class), (unsigned long)v.gestureRecognizers.count);
        }

        // 3) 圆角归属（带日志）
        NSString *source = nil;
        axs_ring_resolveRadiusChain(container, &source, nil, YES);
    } @catch (NSException *exception) {
        axs_ring_log(@"ring probe exception: %@", exception);
    }
}

// --- KVO / 体检共用的几何同步（圆角用 attach 时解析的值，不重读） -------------

static void axs_ring_syncRing(void) {
    if (axs_ring_ring == nil || axs_ring_container == nil) return;
    @try {
        double lineWidth = axs_ring_thickness();
        if (lineWidth < 0.5) lineWidth = 0.5;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        axs_ring_ring.frame = axs_ring_container.layer.bounds;
        axs_ring_shape.frame = axs_ring_ring.bounds;
        if (axs_ring_hostMaskPath != nil) {
            // mask 来源（TXT 五.4）：由宿主 CGPath 按边框厚度内缩生成，
            // 四角几何与窗口一致
            CGRect bb = CGPathGetBoundingBox(axs_ring_hostMaskPath);
            CGRect r = CGRectInset(bb, lineWidth, lineWidth);
            CGFloat pr = axs_ring_radiusFromPath(axs_ring_hostMaskPath);
            double pathRadius = axs_ring_clamp(pr, 0.0, MIN(r.size.width, r.size.height) / 2.0);
            UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:pathRadius];
            axs_ring_shape.path = p.CGPath;
            axs_ring_shape.lineWidth = lineWidth;
        } else {
            CGRect r = CGRectInset(axs_ring_ring.bounds, lineWidth / 2.0, lineWidth / 2.0);
            double pathRadius = axs_ring_clamp(axs_ring_baseRadius, 0.0, MIN(r.size.width, r.size.height) / 2.0);
            UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:pathRadius];
            axs_ring_shape.path = p.CGPath;
            axs_ring_shape.lineWidth = lineWidth;
        }
        // 无旋转：渐变不需要外接正方形，直接铺 ring
        axs_ring_gradient.frame = axs_ring_ring.bounds;
        [CATransaction commit];
        if (fabs(axs_ring_lastLoggedRadius - axs_ring_baseRadius) > 0.05) {
            axs_ring_lastLoggedRadius = axs_ring_baseRadius;
            axs_ring_log(@"ring radius: source=%@ host=%.1f", axs_ring_radiusSource, axs_ring_baseRadius);
        }
    } @catch (NSException *exception) {
        axs_ring_log(@"ring sync exception: %@", exception);
    }
}

// --- attach / remove ---------------------------------------------------------

// TXT 三.1：attach 前先把旧宿主上的环摘干净（禁止两边同时存在）
static void axs_ring_attachRing(void) {
    if (axs_ring_container == nil) return;
    BOOL handover = (axs_ring_ring != nil
                     && axs_ring_ring.superlayer != nil
                     && axs_ring_ring.superlayer != axs_ring_container.layer);
    if (handover) {
        axs_ring_removeRing(@"handover"); // 先移除旧宿主上的 ringContainer
    }
    if (!axs_ring_enabled()) return;

    if (axs_ring_ring == nil) {
        CALayer *ring = [CALayer layer];
        ring.frame = axs_ring_container.layer.bounds;
        ring.masksToBounds = NO;
        ring.zPosition = 9999.0;             // 盖在内容之上（CALayer 不参与命中测试）

        CAShapeLayer *shape = [CAShapeLayer layer];
        shape.fillColor = nil;               // 只当遮罩用
        shape.strokeColor = [UIColor whiteColor].CGColor;
        ring.mask = shape;

        CAGradientLayer *grad = axs_ring_makeGradient(axs_ring_customColor(), axs_ring_color());
        [ring addSublayer:grad];

        axs_ring_ring = ring;
        axs_ring_shape = shape;
        axs_ring_gradient = grad;
        [axs_ring_container.layer addSublayer:ring];

        // TXT 三：attach/resume 时一次性运行时体检（层级 + 手势 + 圆角归属）
        axs_ring_probeContainer(axs_ring_container);

        NSString *source = nil;
        axs_ring_baseRadius = axs_ring_resolveRadiusChain(axs_ring_container, &source, &axs_ring_hostMaskPath, YES);
        axs_ring_radiusSource = source;

        @try {
            [axs_ring_container.layer addObserver:axs_ring_kvoObserver
                                       forKeyPath:@"bounds" options:NSKeyValueObservingOptionNew context:nil];
            if ([axs_ring_container respondsToSelector:@selector(preferredCornerRadius)]) {
                [axs_ring_container addObserver:axs_ring_kvoObserver
                                     forKeyPath:@"preferredCornerRadius" options:NSKeyValueObservingOptionNew context:nil];
            }
            axs_ring_kvoInstalled = YES;
        } @catch (NSException *exception) {
            axs_ring_log(@"ring kvo exception: %@", exception);
        }
    }

    axs_ring_syncRing();
    axs_ring_ring.hidden = NO;
    if (!axs_ring_attachLogged) {
        axs_ring_attachLogged = YES;
        axs_ring_log(@"ring attach: session=%p containerLayer=%p bounds=%@ radiusSource=%@ radius=%.1f",
                     axs_ring_activeSession, axs_ring_container.layer,
                     NSStringFromCGRect(axs_ring_container.layer.bounds),
                     axs_ring_radiusSource, axs_ring_baseRadius);
    }
    if (handover) {
        axs_ring_log(@"ring handover: session=%p -> %p hostLayer=%p",
                     axs_ring_handoverFrom, axs_ring_activeSession, axs_ring_container.layer);
    }
}

// TXT 二.6 / 三.1：从宿主移除 ringContainer 并把 mask 置 nil，完全无副作用
static void axs_ring_removeRing(NSString *reason) {
    if (axs_ring_ring == nil) return;
    @try {
        if (axs_ring_kvoInstalled && axs_ring_container != nil) {
            [axs_ring_container.layer removeObserver:axs_ring_kvoObserver forKeyPath:@"bounds"];
            if ([axs_ring_container respondsToSelector:@selector(preferredCornerRadius)]) {
                [axs_ring_container removeObserver:axs_ring_kvoObserver forKeyPath:@"preferredCornerRadius"];
            }
        }
    } @catch (NSException *exception) { }
    axs_ring_kvoInstalled = NO;
    axs_ring_ring.mask = nil;
    [axs_ring_ring removeFromSuperlayer];
    axs_ring_ring = nil;
    axs_ring_shape = nil;
    axs_ring_gradient = nil;
    if (axs_ring_hostMaskPath != nil) { CGPathRelease(axs_ring_hostMaskPath); axs_ring_hostMaskPath = nil; }
    axs_ring_attachLogged = NO;
    axs_ring_lastLoggedRadius = -1;
    axs_ring_log(@"ring detach: session=%p reason=%@", axs_ring_activeSession, reason);
}

// --- session hooks（延迟安装；防重入闸 + 安装幂等沿用 beautify.4 的教训） -----

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
            // manager（sc_effectiveCornerRadius 的候选来源）：接收者通常就是
            // SCFloatingSceneManager，记下来供圆角解析用
            if ([self isKindOfClass:objc_getClass("SCFloatingSceneManager")]) {
                axs_ring_managerRef = self;
            }
            if (container != nil) {
                axs_ring_pendingSession = NULL;
                axs_ring_pendingContainer = nil;
                // handover 记录：旧会话的环即将转移到新会话（attachRing 里打日志）
                axs_ring_handoverFrom = (axs_ring_ring != nil && axs_ring_activeSession != NULL
                                         && axs_ring_activeSession != s) ? axs_ring_activeSession : NULL;
                axs_ring_activeSession = s;
                axs_ring_container = container;
                axs_ring_docked = NO;
                axs_ring_lastAliveAt = [[NSDate date] timeIntervalSince1970];
                if (axs_ring_enabled()) {
                    axs_ring_attachRing();
                } else if (axs_ring_ring != nil) {
                    axs_ring_removeRing(@"disabled");
                }
            } else if (s != NULL) {
                // 容器未解析：挂起等待 sc_sessionForContainerView: 被动配对
                axs_ring_pendingSession = s;
                axs_ring_pendingContainer = nil;
                axs_ring_pendingAt = [[NSDate date] timeIntervalSince1970];
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
            if (s != NULL && s == axs_ring_activeSession) {
                axs_ring_removeRing(@"closeSession");
                axs_ring_activeSession = NULL;
                axs_ring_container = nil;
                axs_ring_docked = NO;
            }
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
            if (s != NULL && s == axs_ring_activeSession) {
                axs_ring_docked = YES;
                if (axs_ring_ring != nil) axs_ring_ring.hidden = YES; // 挂起期间不画环
                axs_ring_log(@"ring dock: session=%p corner=%ld", s, corner);
            } else {
                axs_ring_log(@"ring dock ignored: session=%p corner=%ld (not active)", s, corner);
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
                if (axs_ring_pendingSession == s && axs_ring_pendingContainer == nil) {
                    axs_ring_pendingContainer = v; // 0.5s 体检里认领
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

// --- 0.5s 体检 + 开关反应 ------------------------------------------------------

// TXT 五.2：有效性体检（0.5s，引擎定时器，非逐帧）。容器离层 → 立即摘环
// （reason=hostGone）并打 suspend；回来打 resume 并完整重挂；开关关闭全摘
static void axs_ring_reconcile(void) {
    if (!axs_ring_hooksInstalled) return;
    @try {
        double now = [[NSDate date] timeIntervalSince1970];
        BOOL enabled = axs_ring_enabled();

        // pending 认领：sc_sessionForContainerView: 配对到的容器
        if (axs_ring_pendingSession != NULL && axs_ring_pendingContainer != nil) {
            UIView *pc = axs_ring_pendingContainer;
            if (pc.window != nil && pc.superview != nil && now - axs_ring_pendingAt < 5.0
                && axs_ring_activeSession == NULL) {
                axs_ring_activeSession = axs_ring_pendingSession;
                axs_ring_container = pc;
                axs_ring_docked = NO;
                axs_ring_pendingSession = NULL;
                axs_ring_pendingContainer = nil;
                if (enabled) axs_ring_attachRing();
            } else if (now - axs_ring_pendingAt >= 5.0) {
                axs_ring_pendingSession = NULL;
                axs_ring_pendingContainer = nil;
            }
        }

        if (axs_ring_activeSession == NULL) return;

        UIView *container = axs_ring_container;
        BOOL inHierarchy = (container != nil
                            && container.window != nil
                            && container.superview != nil
                            && container.layer.superlayer != nil);

        if (!enabled) {
            if (axs_ring_ring != nil) axs_ring_removeRing(@"disabled");
            return;
        }
        if (!inHierarchy) {
            if (!axs_ring_suspended) {
                axs_ring_suspended = YES;
                axs_ring_removeRing(@"hostGone"); // ring detach: reason=hostGone
                axs_ring_log(@"ring suspend: session=%p", axs_ring_activeSession);
            }
            if (now - axs_ring_lastAliveAt > 30.0) {
                // 宿主长时间不回来：清状态，等新 session 走完整 attach
                axs_ring_activeSession = NULL;
                axs_ring_container = nil;
                axs_ring_suspended = NO;
                axs_ring_log(@"ring suspend cleanup: session cleared");
            }
            return;
        }
        if (axs_ring_suspended) {
            axs_ring_suspended = NO;
            axs_ring_lastAliveAt = now;
            // enabled 归因（TXT 六.4）：回前台时环是否处于启用状态一并落日志
            axs_ring_log(@"ring resume: session=%p container=%p enabled=%d",
                         axs_ring_activeSession, container, enabled ? 1 : 0);
        }
        axs_ring_lastAliveAt = now;

        if (axs_ring_docked) {
            if (axs_ring_ring != nil && !axs_ring_ring.hidden) axs_ring_ring.hidden = YES;
            return;
        }
        if (axs_ring_ring == nil) {
            axs_ring_attachRing(); // 回前台重建的容器：完整 attach（含体检），不复用旧 layer
        } else if (axs_ring_ring.hidden) {
            axs_ring_ring.hidden = NO;
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

// --- health-check timer target -------------------------------------------------

@interface AXSRingHealthTarget : NSObject
- (void)axsRingTick;
@end
@implementation AXSRingHealthTarget
- (void)axsRingTick { axs_ring_reconcile(); }
@end

static void axs_ring_attemptInstall(void) {
    if (axs_ring_hooksInstalled) return;
    axs_ring_installAttempts++;

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
            axs_ring_kvoObserver = [AXSRingKVOObserver new];
            axs_ring_log(@"ring module loaded in SpringBoard");
            // 设置保存通知：开关变化立即生效（0.5s 体检兜底）
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            NULL, axs_ring_prefsChanged,
                                            (__bridge CFStringRef)AxsHoldLaunchTheirPrefsSaved,
                                            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            axs_ring_scheduleAttempt(0.5); // 不在 ctor 里直接装：等类注册完成
        }
    }
}
