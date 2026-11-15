#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AxsHoldLaunchConfig.h"
#import "AxsHoldLaunchPreferences.h"

// ---------------------------------------------------------------------------
// 美化 · 光圈外框 (ring frame, beautify.18) — 描边路径直接复用 mask 原始 CGPath
//
// beautify.17 lesson: even with the correct radius read from the overlay mask,
// redrawing the path with bezierPathWithRoundedRect: produces a circular-arc
// corner that differs from ScreenCore's original mask curve (continuous corner
// / squircle) - a small gap remained at the four corners.
//
// This version STOPS redrawing: the stroke layer's path IS the current
// overlay/region mask CGPath, transformed (translate + inset scale) into the
// ring layer's coordinate space. The corner curve character is preserved by
// the affine transform, so the ring's corners match the window exactly by
// construction.
//
//   container.layer
//     ├─ (existing content)
//     ├─ interaction overlay / regions (ScreenCore's own masks live here)
//     └─ axsRingFrame (CALayer; added last; no zPosition offset)
//          ├─ axsRingGradient (conic; marquee = colors keyframes)
//          └─ mask = axsRingShape (path = 复用的 mask CGPath, 内缩 lineWidth/2)
//
// Membership (attach/detach) comes from the 0.5s scan + window notifications
// (zero session hooks); geometry sync runs on a per-container displayLink.
// ---------------------------------------------------------------------------

#define AXS_RING_LOG_PATH @"/var/mobile/Documents/sc-ring.log"
#define AXS_RING_LAYER_NAME @"axsRingFrame"
#define AXS_RING_GRADIENT_NAME @"axsRingGradient"
#define AXS_RING_OVERLAY_MARGIN (43.18)   // 2 × 21.59pt 外边距
#define AXS_RING_MAX_DEPTH 6

@class AXSRingLinkDriver;

static void axs_ring_scanTick(void);
static void axs_ring_syncDriver(AXSRingLinkDriver *driver);
static NSTimer *axs_ring_scanTimer = nil;

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

// --- 跑马灯：conic 渐变 + colors 关键帧（不旋转任何层） ----------------------

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

        // 跑马灯只走 colors 关键帧：整组颜色逐段轮转，8 段 × 0.5s = 4s 一圈
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
        anim.duration = 4.0;
        anim.repeatCount = HUGE_VALF;
        anim.calculationMode = kCAAnimationLinear;
        anim.removedOnCompletion = NO;
        [grad addAnimation:anim forKey:@"axsRingMarquee"];
    }
    return grad;
}

// --- 圆角矩形 CGPath 半径提取（probe 日志用） --------------------------------

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
    AXSRingPathCtx ctx;
    ctx.radius = 0;
    ctx.from = CGPointZero;
    ctx.started = NO;
    CGPathApply(path, &ctx, axs_ring_pathApplier);
    return ctx.radius;
}

// --- mask 候选收集（只读；ring 模块零 addSubview/零 UIView） ------------------

@interface AXSRingMaskCandidate : NSObject
@property (nonatomic, strong) CAShapeLayer *maskLayer;  // 候选遮罩
@property (nonatomic, assign) CGRect rect;              // path bbox 映射到容器层坐标
@property (nonatomic, assign) CGFloat radius;           // 路径提取半径
@end
@implementation AXSRingMaskCandidate
@end

// mask 层的 path bbox 映射到容器层坐标（沿 superlayer 链累计 frame origin）
static CGRect axs_ring_maskRectInContainer(CALayer *maskLayer, CALayer *containerLayer) {
    CGPathRef p = ((CAShapeLayer *)maskLayer).path;
    CGRect rect = p ? CGPathGetBoundingBox(p) : CGRectZero;
    CALayer *l = maskLayer.superlayer;
    int hops = 0;
    while (l != nil && l != containerLayer && hops < 8) {
        rect.origin.x += l.frame.origin.x;
        rect.origin.y += l.frame.origin.y;
        l = l.superlayer;
        hops++;
    }
    return rect;
}

// 递归收集容器 layer 子树内全部 CAShapeLayer 遮罩候选（含 _UIScenePresentationView
// 及其子层；跳过环自己的子树）
static void axs_ring_collectMaskInfos(CALayer *layer, CALayer *containerLayer, int depth,
                                      NSMutableArray *out, CALayer *ownRing) {
    if (layer == nil || depth > AXS_RING_MAX_DEPTH) return;
    if (layer == ownRing) return; // 不收集自己的环
    if ([layer.mask isKindOfClass:[CAShapeLayer class]]) {
        CAShapeLayer *m = (CAShapeLayer *)layer.mask;
        if (m.path != nil) {
            AXSRingMaskCandidate *c = [AXSRingMaskCandidate new];
            c.maskLayer = m;
            c.rect = axs_ring_maskRectInContainer(m, containerLayer);
            c.radius = axs_ring_radiusFromPath(m.path);
            [out addObject:c];
        }
    }
    for (CALayer *sub in layer.sublayers) {
        axs_ring_collectMaskInfos(sub, containerLayer, depth + 1, out, ownRing);
    }
}

// 读 CAShapeLayer 类型的 ivar（SCFloatingCornerGestureRegionView 的
// _interactiveMaskLayer 等）
static CAShapeLayer *axs_ring_ivarShape(id obj, const char *name) {
    if (obj == nil) return nil;
    @try {
        Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
        if (ivar == nil) return nil;
        id v = object_getIvar(obj, ivar);
        return [v isKindOfClass:[CAShapeLayer class]] ? v : nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

// ivar 遮罩也并入候选（region 视图的 _interactiveMaskLayer）
static void axs_ring_collectIvarMasks(UIView *view, int depth, NSMutableArray *out,
                                      CALayer *containerLayer, CALayer *ownRing) {
    if (view == nil || depth > 3) return;
    CAShapeLayer *im = axs_ring_ivarShape(view, "_interactiveMaskLayer");
    if (im != nil && im.path != nil && im != ownRing) {
        AXSRingMaskCandidate *c = [AXSRingMaskCandidate new];
        c.maskLayer = im;
        c.rect = axs_ring_maskRectInContainer(im, containerLayer);
        c.radius = axs_ring_radiusFromPath(im.path);
        [out addObject:c];
    }
    for (UIView *sub in view.subviews) {
        axs_ring_collectIvarMasks(sub, depth + 1, out, containerLayer, ownRing);
    }
}

// --- 每容器驱动（CADisplayLink 一对一；容器消失即停） -------------------------

@interface AXSRingLinkDriver : NSObject
@property (nonatomic, weak) UIView *container;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, strong) CALayer *ring;            // axsRingFrame
@property (nonatomic, strong) CAGradientLayer *gradient;
@property (nonatomic, strong) CAShapeLayer *shape;      // ring.mask（路径 = 复用的 mask CGPath）
@property (nonatomic, weak) UIView *overlay;            // SCFloatingInteractionOverlayView
@property (nonatomic, assign) CGRect lastRect;          // 上帧应用的描边矩形（容器坐标）
@property (nonatomic, assign) CGRect lastRingBounds;    // 上帧环 bounds
@property (nonatomic, assign) CGFloat lastLineWidth;
@property (nonatomic, assign) CGFloat lastRadius;
@property (nonatomic, copy) NSString *radiusSource;     // overlayMask|config
@property (nonatomic, assign) BOOL loggedAttach;
- (void)tick;
@end

@implementation AXSRingLinkDriver
- (void)tick {
    axs_ring_syncDriver(self);
}
@end

static NSMutableDictionary<NSString *, AXSRingLinkDriver *> *axs_ring_drivers = nil;

// 容器子树里找 interaction overlay（一层即中，找不到再进一层）
static UIView *axs_ring_findOverlay(UIView *container) {
    Class cls = objc_getClass("SCFloatingInteractionOverlayView");
    if (cls == nil) return nil;
    for (UIView *sub in container.subviews) {
        if ([sub isKindOfClass:cls]) return sub;
        for (UIView *sub2 in sub.subviews) {
            if ([sub2 isKindOfClass:cls]) return sub2;
        }
    }
    return nil;
}

// --- 几何同步（displayLink 每帧调用；静止即跳过） -----------------------------

static void axs_ring_syncDriver(AXSRingLinkDriver *driver) {
    UIView *container = driver.container;
    if (container == nil || driver.ring == nil) return;
    if (container.window == nil) return; // 离层：等 0.5s 扫描 detach
    @try {
        double lineWidth = axs_ring_thickness();
        if (lineWidth < 0.5) lineWidth = 0.5;

        // 模型 bounds（真实尺寸变化时跟随；transform 弹簧不影响模型）
        CGRect ringBounds = container.layer.bounds;
        if (ringBounds.size.width < 20 || ringBounds.size.height < 20) return;

        // 1) 收集候选遮罩（每帧；子树小，含 _UIScenePresentationView 子层）
        NSMutableArray *candidates = [NSMutableArray array];
        axs_ring_collectMaskInfos(container.layer, container.layer, 0, candidates, driver.ring);
        if (driver.overlay != nil) {
            axs_ring_collectIvarMasks(driver.overlay, 0, candidates, container.layer, driver.ring);
        }

        // 2) 选择：优先 bbox 与容器 bounds 一致的 mask；外扩尺寸只作兜底
        CAShapeLayer *best = nil;
        CGRect bestRect = CGRectZero;
        CGFloat bestScore = 1e9;
        for (AXSRingMaskCandidate *c in candidates) {
            CGFloat score = fabs(c.rect.size.width - ringBounds.size.width)
                          + fabs(c.rect.size.height - ringBounds.size.height);
            if (score < bestScore && c.radius > 0.5) {
                bestScore = score;
                best = c.maskLayer;
                bestRect = c.rect;
            }
        }

        // 3) 描边路径 = 复用的 mask CGPath：按线宽一半内缩（仿射变换保留角曲线）
        CGRect insetRect = CGRectInset(bestRect, lineWidth / 2.0, lineWidth / 2.0);
        CGFloat kx = bestRect.size.width  > 0.5 ? insetRect.size.width  / bestRect.size.width  : 1.0;
        CGFloat ky = bestRect.size.height > 0.5 ? insetRect.size.height / bestRect.size.height : 1.0;
        CGPoint center = CGPointMake(bestRect.origin.x + bestRect.size.width / 2.0,
                                     bestRect.origin.y + bestRect.size.height / 2.0);
        CGPathRef maskPath = best.path;
        CGRect bbox = CGPathGetBoundingBox(maskPath);
        CGAffineTransform t = CGAffineTransformMakeTranslation(bestRect.origin.x - bbox.origin.x,
                                                               bestRect.origin.y - bbox.origin.y);
        t = CGAffineTransformTranslate(t, center.x, center.y);
        t = CGAffineTransformScale(t, kx, ky);
        t = CGAffineTransformTranslate(t, -center.x, -center.y);
        t = CGAffineTransformTranslate(t, -insetRect.origin.x, -insetRect.origin.y);
        CGPathRef local = CGPathCreateCopyByTransformingPath(maskPath, &t);

        BOOL changed = !CGRectEqualToRect(insetRect, driver.lastRect)
                    || !CGSizeEqualToSize(ringBounds.size, driver.lastRingBounds.size)
                    || driver.lastLineWidth != (CGFloat)lineWidth;

        if (!changed) { CGPathRelease(local); return; } // 静止：bounds/路径未变跳过本帧

        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        driver.ring.frame = ringBounds;
        driver.ring.bounds = (CGRect){0, 0, insetRect.size};
        driver.ring.position = insetRect.origin;
        driver.shape.frame = driver.ring.bounds;
        driver.shape.path = local;               // 复用 mask 原始几何
        driver.shape.lineWidth = lineWidth;
        driver.gradient.frame = driver.ring.bounds;
        [CATransaction commit];
        CGPathRelease(local);

        driver.lastRect = insetRect;
        driver.lastRingBounds = ringBounds;
        driver.lastLineWidth = (CGFloat)lineWidth;
    } @catch (NSException *exception) {
        axs_ring_log(@"ring sync exception: %@", exception);
    }
}

// --- 挂载 / 摘除（成员扫描触发） ----------------------------------------------

static void axs_ring_attachContainer(UIView *container) {
    NSString *key = [NSString stringWithFormat:@"%p", container];
    if (axs_ring_drivers[key] != nil) return;
    if (!axs_ring_enabled()) return;

    CALayer *ring = [CALayer layer];
    ring.name = AXS_RING_LAYER_NAME;
    ring.frame = container.layer.bounds;
    ring.masksToBounds = NO;
    // 环层位置随容器（addSublayer 即在最上层），不另设 zPosition 偏移

    CAShapeLayer *shape = [CAShapeLayer layer];
    shape.fillColor = nil;                   // 只当遮罩用
    shape.strokeColor = [UIColor whiteColor].CGColor;
    ring.mask = shape;

    CAGradientLayer *grad = axs_ring_makeGradient(axs_ring_customColor(), axs_ring_color());
    grad.name = AXS_RING_GRADIENT_NAME;
    [ring addSublayer:grad];
    [container.layer addSublayer:ring];      // 宿主容器图层最上层

    AXSRingLinkDriver *driver = [AXSRingLinkDriver new];
    driver.container = container;
    driver.ring = ring;
    driver.shape = shape;
    driver.gradient = grad;
    driver.overlay = axs_ring_findOverlay(container);
    driver.lastRect = CGRectZero;
    driver.lastRingBounds = CGRectZero;
    driver.lastLineWidth = -1;
    driver.lastRadius = -1;

    driver.link = [CADisplayLink displayLinkWithTarget:driver selector:@selector(tick)];
    [driver.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    axs_ring_drivers[key] = driver;

    // 首帧即出几何（含一次性层级/遮罩 probe 留档）
    axs_ring_syncDriver(driver);

    // 一次性 probe：容器 + 子树遮罩候选（TXT 七.1 诊断留档）
    axs_ring_log(@"ring probe: container class=%@ frame=%@ bounds=%@ layerCorner=%.2f masksToBounds=%d",
                 NSStringFromClass(container.class), NSStringFromCGRect(container.frame),
                 NSStringFromCGRect(container.bounds),
                 container.layer.cornerRadius, container.layer.masksToBounds ? 1 : 0);
    NSMutableArray *candidates = [NSMutableArray array];
    axs_ring_collectMaskInfos(container.layer, container.layer, 0, candidates, ring);
    if (driver.overlay != nil) {
        axs_ring_collectIvarMasks(driver.overlay, 0, candidates, container.layer, ring);
    }
    for (AXSRingMaskCandidate *c in candidates) {
        axs_ring_log(@"ring probe: mask class=%@ path=%@ radius=%.1f",
                     NSStringFromClass(c.maskLayer.class),
                     NSStringFromCGRect(c.rect), c.radius);
    }

    if (!driver.loggedAttach) {
        driver.loggedAttach = YES;
        axs_ring_log(@"ring attach: scan container=%p containerLayer=%p bounds=%@ radiusSource=%@ radius=%.1f",
                     container, container.layer, NSStringFromCGRect(container.layer.bounds),
                     driver.radiusSource ?: @"none", driver.lastRadius);
    }
}

static void axs_ring_detachDriver(NSString *key) {
    AXSRingLinkDriver *driver = axs_ring_drivers[key];
    if (driver == nil) return;
    [driver.link invalidate];                // displayLink 随容器生命周期停止
    driver.ring.mask = nil;
    [driver.ring removeFromSuperlayer];      // 摘环、清动画、释放图层
    [axs_ring_drivers removeObjectForKey:key];
    axs_ring_log(@"ring detach: scan container=%p", driver.container);
}

// --- 成员扫描（0.5s 定时器 + 窗口通知；只做集合对比，不做几何） ----------------

static void axs_ring_collectContainers(UIView *view, NSMutableArray *out, int depth) {
    if (view == nil || depth > AXS_RING_MAX_DEPTH) return;
    Class containerClass = objc_getClass("SCFloatingContainerView");
    if (containerClass != nil && [view isKindOfClass:containerClass]
        && view.window != nil && view.alpha > 0.01) {
        [out addObject:view];
    }
    for (UIView *sub in view.subviews) {
        axs_ring_collectContainers(sub, out, depth + 1);
    }
}

static void axs_ring_scanTick(void) {
    @try {
        NSMutableArray *live = [NSMutableArray array];
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                axs_ring_collectContainers(w, live, 0);
            }
        }

        // a) 已消失的容器 → detach（displayLink invalidate + 摘环）
        NSMutableArray *gone = [NSMutableArray array];
        for (NSString *key in axs_ring_drivers) {
            AXSRingLinkDriver *d = axs_ring_drivers[key];
            if (d.container == nil || ![live containsObject:d.container]) [gone addObject:key];
        }
        for (NSString *key in gone) {
            axs_ring_detachDriver(key);
        }

        if (!axs_ring_enabled()) {
            // TXT 二.6：开关关闭 → 全部摘除，完全无副作用
            for (NSString *key in [axs_ring_drivers.allKeys copy]) {
                axs_ring_detachDriver(key);
            }
            return;
        }

        // b) 新出现的容器 → attach；已在册的由各自 displayLink 驱动
        for (UIView *c in live) {
            axs_ring_attachContainer(c);
        }
    } @catch (NSException *exception) {
        axs_ring_log(@"ring scan exception: %@", exception);
    }
}

// --- 通知 / 定时器目标 ----------------------------------------------------------

@interface AXSRingHealthTarget : NSObject
- (void)axsRingTick;
- (void)axsRingWindowNote:(NSNotification *)note;
@end
@implementation AXSRingHealthTarget
- (void)axsRingTick { axs_ring_scanTick(); }
- (void)axsRingWindowNote:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{ axs_ring_scanTick(); });
}
@end
static AXSRingHealthTarget *axs_ring_healthTarget = nil;

// Darwin 通知：设置保存后立即重扫（0.5s 定时器兜底）
static void axs_ring_prefsChanged(CFNotificationCenterRef center, void *observer,
                                  CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ axs_ring_scanTick(); });
}

// --- entry: 启动即挂定时器与通知（无任何 hook） --------------------------------

%ctor {
    @autoreleasepool {
        if (objc_getClass("SpringBoard") != nil) {
            axs_ring_drivers = [NSMutableDictionary new];
            axs_ring_healthTarget = [AXSRingHealthTarget new];
            axs_ring_log(@"ring module loaded in SpringBoard");
            axs_ring_log(@"ring hooks ring=0 sessionHooks=0 holdPress=1");

            // 设置保存通知：开关变化立即生效
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            NULL, axs_ring_prefsChanged,
                                            (__bridge CFStringRef)AxsHoldLaunchTheirPrefsSaved,
                                            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            // 窗口可见性通知：降低扫描延迟（TXT 三.2）
            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            [nc addObserver:axs_ring_healthTarget selector:@selector(axsRingWindowNote:)
                       name:UIWindowDidBecomeVisibleNotification object:nil];
            [nc addObserver:axs_ring_healthTarget selector:@selector(axsRingWindowNote:)
                       name:UIWindowDidBecomeHiddenNotification object:nil];
            [nc addObserver:axs_ring_healthTarget selector:@selector(axsRingWindowNote:)
                       name:UIWindowDidResignKeyNotification object:nil];

            axs_ring_scanTimer = [NSTimer timerWithTimeInterval:0.5
                                                         target:axs_ring_healthTarget
                                                       selector:@selector(axsRingTick)
                                                       userInfo:nil
                                                        repeats:YES];
            [[NSRunLoop mainRunLoop] addTimer:axs_ring_scanTimer forMode:NSRunLoopCommonModes];
        }
    }
}
