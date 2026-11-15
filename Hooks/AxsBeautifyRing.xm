#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AxsHoldLaunchConfig.h"
#import "AxsHoldLaunchPreferences.h"

// ---------------------------------------------------------------------------
// 美化 · 光圈外框 (ring frame, beautify.19) — 稳定圆角矩形描边 + 整框 mask 半径
//
// beautify.18 lesson: reusing the region/overlay masks' local CGPath directly
// exploded (paths carry -21.59 offsets and local 52×105 geometries; multiple
// partial paths concatenated; attach enumeration raced to radius=-1).
//
// This version (beautify.16 stable structure + fixes):
//   - zero session hooks; the 0.5s scan + window notifications do membership
//     only (attach/detach); geometry syncs on a per-container displayLink;
//   - the stroke is a stable rounded rect: rect = container presentation
//     bounds inset lineWidth/2, radius = the SELECTED whole-frame mask's
//     radius (bbox == container + 43.18pt margins), re-read per frame from
//     the cached mask layer (it tracks the window size), config fallback;
//   - the overlay mask path's -21.59 offset is NOT borrowed - only its radius;
//   - one stroke = one whole-frame path; ring transform identity.
// ---------------------------------------------------------------------------

#define AXS_RING_LOG_PATH @"/var/mobile/Documents/sc-ring.log"
#define AXS_RING_LAYER_NAME @"axsRingFrame"
#define AXS_RING_GRADIENT_NAME @"axsRingGradient"
#define AXS_RING_MAX_ENTRIES 4

static void axs_ring_scanTick(void);

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
    AXSRingPathCtx ctx = { 0, CGPointZero, NO };
    CGPathApply(path, &ctx, axs_ring_pathApplier);
    return ctx.radius;
}

// --- 探测辅助（只读） --------------------------------------------------------

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

// 递归收集子树内所有 CAShapeLayer 遮罩（layer.mask + _interactiveMaskLayer）
static void axs_ring_collectMasks(UIView *view, int depth, NSMutableArray<CAShapeLayer *> *out) {
    if (view == nil || depth > 4) return;
    if ([view.layer.mask isKindOfClass:[CAShapeLayer class]]) {
        [out addObject:(CAShapeLayer *)view.layer.mask];
    }
    CAShapeLayer *im = axs_ring_ivarShape(view, "_interactiveMaskLayer");
    if (im != nil && im.path != nil) [out addObject:im];
    for (UIView *sub in view.subviews) {
        axs_ring_collectMasks(sub, depth + 1, out);
    }
}

// --- 每容器驱动（CADisplayLink 一对一；容器消失即停） -------------------------

@class AXSRingLinkDriver;
@class AXSRingHealthTarget;

static void axs_ring_syncDriver(AXSRingLinkDriver *driver);

@interface AXSRingLinkDriver : NSObject
@property (nonatomic, weak) UIView *container;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, strong) CALayer *ring;            // axsRingFrame
@property (nonatomic, strong) CAGradientLayer *gradient;
@property (nonatomic, strong) CAShapeLayer *shape;      // ring.mask
@property (nonatomic, weak) CAShapeLayer *radiusMask;   // 选中的整框 mask（半径来源）
@property (nonatomic, weak) UIView *overlay;            // SCFloatingInteractionOverlayView
@property (nonatomic, assign) CGRect lastBounds;        // 上帧应用的 presentation bounds
@property (nonatomic, assign) CGFloat lastRadius;
@property (nonatomic, assign) CGFloat lastLineWidth;
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

        // 弹簧进行中读 presentation（视觉矩形），静止时 presentation == model
        CALayer *pres = container.layer.presentationLayer;
        CGRect bounds = (pres != nil) ? pres.bounds : container.layer.bounds;
        if (bounds.size.width < 20 || bounds.size.height < 20) return;

        // 圆角：选中的整框 mask 半径，逐帧从该 mask 的当前 path 重读——
        // ScreenCore 随窗口尺寸更新它，环跟它走；取不到沿用上帧值
        CGFloat radius = driver.lastRadius;
        if (driver.radiusMask != nil && driver.radiusMask.path != nil) {
            CGFloat r = axs_ring_radiusFromPath(driver.radiusMask.path);
            if (r > 0.5) radius = r;
        }

        BOOL changed = !CGRectEqualToRect(bounds, driver.lastBounds)
                    || fabs(driver.lastRadius - radius) > 0.05
                    || driver.lastLineWidth != (CGFloat)lineWidth;
        if (!changed) return; // 静止状态：bounds/圆角未变就跳过本帧刷新

        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        driver.ring.frame = bounds;              // ringContainer.frame = 容器 bounds
        driver.shape.frame = driver.ring.bounds;
        CGRect r = CGRectInset(driver.ring.bounds, lineWidth / 2.0, lineWidth / 2.0);
        double pathRadius = axs_ring_clamp(radius, 1.0, MAX(MIN(r.size.width, r.size.height) / 2.0, 1.0));
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:pathRadius];
        driver.shape.path = p.CGPath;
        driver.shape.lineWidth = lineWidth;      // 描边宽度 = 配置值（固定屏幕点）
        driver.gradient.frame = driver.ring.bounds;
        [CATransaction commit];

        driver.lastBounds = bounds;
        driver.lastRadius = radius;
        driver.lastLineWidth = (CGFloat)lineWidth;
    } @catch (NSException *exception) {
        axs_ring_log(@"ring sync exception: %@", exception);
    }
}

// --- attach / detach（成员扫描触发） ------------------------------------------

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
    [ring addSublayer:grad];
    [container.layer addSublayer:ring];      // 宿主容器图层最上层

    AXSRingLinkDriver *driver = [AXSRingLinkDriver new];
    driver.container = container;
    driver.ring = ring;
    driver.shape = shape;
    driver.gradient = grad;
    driver.overlay = axs_ring_findOverlay(container);

    // TXT 二.2：掩码选择——只保留整框 mask（bbox = 容器 + 43.18pt 外边距），
    // 跳过角区/边条局部 mask；命中即缓存为半径来源（逐帧重读它的当前 path）
    UIView *overlay = driver.overlay;
    CGFloat expandedW = container.bounds.size.width + 43.18;
    CGFloat expandedH = container.bounds.size.height + 43.18;
    NSMutableArray<CAShapeLayer *> *masks = [NSMutableArray array];
    if (overlay != nil) axs_ring_collectMasks(overlay, 0, masks);
    axs_ring_collectMasks(container, 0, masks);
    for (CAShapeLayer *m in masks) {
        if (m.path == nil) continue;
        CGRect bb = CGPathGetBoundingBox(m.path);
        if (fabs(bb.size.width - expandedW) < 8 && fabs(bb.size.height - expandedH) < 8) {
            driver.radiusMask = m;
            break;
        }
    }

    driver.link = [CADisplayLink displayLinkWithTarget:driver selector:@selector(tick)];
    [driver.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    axs_ring_drivers[key] = driver;

    // 首帧即出几何（含一次性 probe 留档：候选类/bbox/半径）
    axs_ring_syncDriver(driver);

    axs_ring_log(@"ring probe: container class=%@ bounds=%@ masks=%lu",
                 NSStringFromClass(container.class), NSStringFromCGRect(container.bounds),
                 (unsigned long)masks.count);
    for (CAShapeLayer *m in masks) {
        if (m.path == nil) continue;
        axs_ring_log(@"ring probe: mask class=%@ bbox=%@ radius=%.1f",
                     NSStringFromClass(m.class), NSStringFromCGRect(CGPathGetBoundingBox(m.path)),
                     axs_ring_radiusFromPath(m.path));
    }

    if (!driver.loggedAttach) {
        driver.loggedAttach = YES;
        axs_ring_log(@"ring attach: scan container=%p containerLayer=%p bounds=%@ radiusSource=%@ radius=%.1f mask=%@",
                     container, container.layer, NSStringFromCGRect(container.layer.bounds),
                     driver.radiusSource ?: @"none", driver.lastRadius,
                     driver.radiusMask ? NSStringFromClass(driver.radiusMask.class) : @"none");
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
    if (view == nil || depth > 6) return;
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
