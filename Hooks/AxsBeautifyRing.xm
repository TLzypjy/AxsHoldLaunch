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
static void axs_ring_installLayoutHook(void);           // 定义在扫描节之后
static BOOL axs_ring_layoutHookInstalled = NO;          // scanTick / %ctor 共用

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
@property (nonatomic, weak) CAShapeLayer *radiusMask;   // 整框 overlay mask（兜底半径来源）
@property (nonatomic, weak) UIView *overlay;            // SCFloatingInteractionOverlayView
@property (nonatomic, weak) CALayer *realLayer;         // 真实裁剪层（bbox≈容器 bounds，几何源）
@property (nonatomic, weak) CALayer *mountLayer;        // 挂载层（非裁剪祖先，masksToBounds=0）
@property (nonatomic, assign) CGFloat overlayR;         // overlay mask 当前半径（对照日志）
@property (nonatomic, assign) CGRect lastBounds;        // 上帧应用的 presentation bounds
@property (nonatomic, assign) CGFloat lastRadius;       // 上帧应用的环圆角
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

// 掩码选择（TXT beautify.21 三.1.c）：整框 overlay mask——bbox 原点≈(0,0) 且
// 尺寸≈容器宽高+43.18pt；原点带负坐标的是角区/边条局部 mask，一律跳过。
// 它是手势命中区裁剪，半径只作兜底与对照，不再做任何缩放换算。
static BOOL axs_ring_selectMask(AXSRingLinkDriver *driver, UIView *container) {
    CGFloat expandedW = container.bounds.size.width + 43.18;
    CGFloat expandedH = container.bounds.size.height + 43.18;
    NSMutableArray<CAShapeLayer *> *masks = [NSMutableArray array];
    if (driver.overlay != nil) axs_ring_collectMasks(driver.overlay, 0, masks);
    axs_ring_collectMasks(container, 0, masks);
    for (CAShapeLayer *m in masks) {
        if (m.path == nil) continue;
        CGRect bb = CGPathGetBoundingBox(m.path);
        if (fabs(bb.origin.x) < 0.5 && fabs(bb.origin.y) < 0.5
            && fabs(bb.size.width - expandedW) < 8 && fabs(bb.size.height - expandedH) < 8) {
            driver.radiusMask = m;
            driver.overlayR = axs_ring_radiusFromPath(m.path);
            return YES;
        }
    }
    return NO;
}

// 真实裁剪层查找（TXT beautify.21 二.2）：在容器 layer 子树里找 bounds ≈
// 容器 bounds 的裁剪层（masksToBounds / 挂 mask / cornerRadius>0.5），
// 它的 cornerRadius 或自身 mask 半径才是黑窗真实圆角；跳过环自己的子树；
// 容器子树找不到再看一层 superview 子树。
static void axs_ring_walkClip(CALayer *layer, CGRect target, CALayer *ownRing, int depth,
                              CALayer **best, CGFloat *bestScore) {
    if (layer == nil || depth > 6) return;
    if (layer != ownRing) {
        CGRect b = layer.bounds;
        if (b.size.width > 20 && fabs(b.size.width - target.size.width) < 2
            && fabs(b.size.height - target.size.height) < 2) {
            BOOL clipper = layer.masksToBounds || layer.mask != nil || layer.cornerRadius > 0.5;
            if (clipper) {
                CGFloat score = (layer.cornerRadius > 0.5 ? 0.0 : 10.0)
                              + (layer.masksToBounds ? 0.0 : 5.0) + (CGFloat)depth * 0.1;
                if (score < *bestScore) { *bestScore = score; *best = layer; }
            }
        }
    }
    for (CALayer *sub in layer.sublayers) {
        axs_ring_walkClip(sub, target, ownRing, depth + 1, best, bestScore);
    }
}

static BOOL axs_ring_findRealClip(AXSRingLinkDriver *driver, UIView *container) {
    CALayer *best = nil;
    CGFloat bestScore = 1e9;
    axs_ring_walkClip(container.layer, container.bounds, driver.ring, 0, &best, &bestScore);
    if (best == nil && container.superview != nil) {
        bestScore = 1e9;
        axs_ring_walkClip(container.superview.layer, container.bounds, driver.ring, 0, &best, &bestScore);
    }
    driver.realLayer = best;
    return (best != nil);
}

// 挂载层查找（TXT beautify.23 二.1）：容器层自身优先；它也 clips=1 就沿
// superlayer 链向上找第一个 masksToBounds=0 的层，兜底回容器层。
// 裁剪层只提供圆角与几何，不能当环的父层（贴边描边会被切掉）。
static CALayer *axs_ring_findMount(UIView *container) {
    CALayer *l = container.layer;
    int hops = 0;
    while (l != nil && l.masksToBounds && hops < 8) {
        l = l.superlayer;
        hops++;
    }
    return l ?: container.layer;
}

// 全树一次性探针（TXT beautify.21 二）：从容器所在 window 的 layer 树递归
// 遍历，记录 SC*/_UI*/裁剪层的几何、cornerRadius、mask bbox/半径，定位
// 真实圆角来源；进程内只跑一次，不每帧写日志。
static int axs_ring_treeLines = 0;

static void axs_ring_treeWalk(CALayer *layer, int depth) {
    if (layer == nil || depth > 10 || axs_ring_treeLines > 140) return;
    NSString *cls = NSStringFromClass(layer.class);
    CAShapeLayer *m = [layer.mask isKindOfClass:[CAShapeLayer class]] ? (CAShapeLayer *)layer.mask : nil;
    BOOL interesting = [cls hasPrefix:@"SC"] || [cls hasPrefix:@"_UI"]
                       || layer.cornerRadius > 0.5 || layer.masksToBounds
                       || (m != nil && m.path != nil);
    if (interesting) {
        axs_ring_treeLines++;
        NSMutableString *line = [NSMutableString string];
        for (int i = 0; i < depth; i++) [line appendString:@" "];
        id del = layer.delegate;
        NSString *name = [del isKindOfClass:[UIView class]] ? NSStringFromClass([del class]) : cls;
        [line appendFormat:@"%@ frame=%@ bounds=%@ corner=%.2f clips=%d",
             name, NSStringFromCGRect(layer.frame), NSStringFromCGRect(layer.bounds),
             layer.cornerRadius, layer.masksToBounds ? 1 : 0];
        if (m != nil && m.path != nil) {
            [line appendFormat:@" maskBbox=%@ maskR=%.1f",
                 NSStringFromCGRect(CGPathGetBoundingBox(m.path)), axs_ring_radiusFromPath(m.path)];
        } else if (layer.mask != nil) {
            [line appendFormat:@" mask=%@", NSStringFromClass(layer.mask.class)];
        }
        axs_ring_log(@"ring tree: %@", line);
    }
    for (CALayer *sub in layer.sublayers) {
        axs_ring_treeWalk(sub, depth + 1);
    }
}

static BOOL axs_ring_treeProbed = NO;

static void axs_ring_treeProbe(UIView *container) {
    if (axs_ring_treeProbed) return;
    axs_ring_treeProbed = YES;
    UIWindow *w = container.window;
    if (w == nil) return;
    axs_ring_treeLines = 0;
    axs_ring_log(@"ring tree: window=%@ frame=%@ bounds=%@",
                 NSStringFromClass(w.class), NSStringFromCGRect(w.frame), NSStringFromCGRect(w.bounds));
    axs_ring_treeWalk(w.layer, 0);
}

// --- 几何同步（displayLink 每帧 + layoutSubviews 钩子共用） --------------------

// preferModel=YES（布局钩子路径）：手势直改模型后布局未提交，模型即最新值，
// 环用模型尺寸可与卡片同一个 commit 生效——右/下边（origin+size）不再滞后一帧
// （TXT beautify.22 三.3）；bounds 正被 CA 动画驱动时跳过，交 displayLink。
// displayLink 路径一律 presentation 优先（TXT 三.1/三.2）。
static void axs_ring_syncDriver2(AXSRingLinkDriver *driver, BOOL preferModel) {
    UIView *container = driver.container;
    if (container == nil || driver.ring == nil) return;
    if (container.window == nil) return; // 离层：等扫描/布局钩子 detach
    @try {
        double lineWidth = axs_ring_thickness();
        if (lineWidth < 0.5) lineWidth = 0.5;

        // 挂载层：非裁剪祖先（masksToBounds=0）——环挂进裁剪层会被自身圆角
        // mask 切到不可见（TXT beautify.23 二.1）；addSublayer 即置最上层（二.3）
        CALayer *mount = axs_ring_findMount(container);
        driver.mountLayer = mount;
        if (driver.ring.superlayer != mount) {
            [driver.ring removeFromSuperlayer];
            [mount addSublayer:driver.ring];
        }

        // 几何源仍是真实裁剪层：presentation frame 经 convertRect:fromLayer:
        // 换算到挂载层坐标（TXT beautify.23 二.2）；右/下终点 = 换算后 origin+size
        CALayer *src = driver.realLayer ?: mount;
        CGRect bounds;
        if (preferModel) {
            if ([src animationForKey:@"bounds"] != nil
                || [src animationForKey:@"position"] != nil) {
                return;                          // 弹簧动画进行中：displayLink 按 presentation 跟
            }
            bounds = [mount convertRect:src.frame fromLayer:src];
        } else {
            CALayer *pres = src.presentationLayer;     // 视觉矩形，静止时 == model
            CALayer *mp = mount.presentationLayer;
            if (pres != nil && mp != nil) {
                bounds = [mp convertRect:pres.frame fromLayer:pres];
            } else {
                bounds = [mount convertRect:src.frame fromLayer:src];
            }
        }
        if (bounds.size.width < 20 || bounds.size.height < 20) return;

        // 圆角取值（TXT beautify.21 三）：overlay mask 是手势命中区裁剪，
        // 不是黑窗内容的真实圆角（外扩矩形缩半径方向错了）——优先级改为：
        //   a) 真实裁剪层 layer.cornerRadius；
        //   b) 该层自身 mask 的圆角（按其自身 bbox 换算）；
        //   c) overlay 整框 mask 半径原值（不做 mw/mh 缩放）；
        //   d) 配置圆角。逐帧重读，静止由 changed 检查跳过。
        CGFloat radius = 0;
        NSString *source = @"config";
        if (driver.realLayer == nil) axs_ring_findRealClip(driver, container);
        if (driver.realLayer != nil && driver.realLayer.cornerRadius > 0.5) {
            radius = driver.realLayer.cornerRadius;
            source = @"realCorner";
        }
        if (radius <= 0.5 && driver.realLayer != nil) {
            CAShapeLayer *rm = [driver.realLayer.mask isKindOfClass:[CAShapeLayer class]]
                                   ? (CAShapeLayer *)driver.realLayer.mask : nil;
            if (rm != nil && rm.path != nil) {
                CGRect bb = CGPathGetBoundingBox(rm.path);
                CGRect lb = driver.realLayer.bounds;
                CGFloat rMask = axs_ring_radiusFromPath(rm.path);
                if (rMask > 0.5 && bb.size.width > 1.0 && bb.size.height > 1.0
                    && lb.size.width > 1.0 && lb.size.height > 1.0) {
                    CGFloat kx = lb.size.width / bb.size.width;
                    CGFloat ky = lb.size.height / bb.size.height;
                    CGFloat rr = (CGFloat)MIN(rMask * kx, rMask * ky);
                    if (rr > 0.5) { radius = rr; source = @"realMask"; }
                }
            }
        }
        if (radius <= 0.5) {
            if (driver.radiusMask == nil || driver.radiusMask.path == nil) {
                axs_ring_selectMask(driver, container);
            }
            if (driver.radiusMask != nil && driver.radiusMask.path != nil) {
                CGFloat rMask = axs_ring_radiusFromPath(driver.radiusMask.path);
                if (rMask > 0.5) {
                    radius = rMask;             // 原值直用，不再缩放（TXT 三.1.c）
                    source = @"overlayMask";
                    driver.overlayR = rMask;
                }
            }
        }
        if (radius <= 0.5) {
            radius = (CGFloat)axs_ring_configRadius();
            source = @"config";
        }
        driver.radiusSource = source;

        BOOL changed = !CGRectEqualToRect(bounds, driver.lastBounds)
                    || fabs(driver.lastRadius - radius) > 0.05
                    || driver.lastLineWidth != (CGFloat)lineWidth;
        if (!changed) return; // 静止状态：bounds/圆角未变就跳过本帧刷新

        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        driver.ring.frame = bounds;              // ringContainer.frame = 容器 bounds
        driver.shape.frame = driver.ring.bounds;
        // 路径矩形 = 容器 bounds，不整边内缩（TXT beautify.20 三.4）：
        // 描边中心线贴窗口边，外半覆盖接缝，四角不再留空隙
        CGRect r = driver.ring.bounds;
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

// displayLink 路径：presentation 优先（TXT beautify.22 三.1）
static void axs_ring_syncDriver(AXSRingLinkDriver *driver) {
    axs_ring_syncDriver2(driver, NO);
}

// --- attach / detach（成员扫描触发） ------------------------------------------

static void axs_ring_attachContainer(UIView *container) {
    NSString *key = [NSString stringWithFormat:@"%p", container];
    if (axs_ring_drivers[key] != nil) return;
    if (!axs_ring_enabled()) return;

    AXSRingLinkDriver *driver = [AXSRingLinkDriver new];
    driver.container = container;
    driver.overlay = axs_ring_findOverlay(container);

    // 先定位真实裁剪层（几何源+圆角来源）与非裁剪挂载层，再选整框 overlay
    // mask 作兜底/对照（此刻环尚未入树，无需跳过 ownRing）；未命中不落 -1
    axs_ring_selectMask(driver, container);
    axs_ring_findRealClip(driver, container);
    CALayer *mount = axs_ring_findMount(container);
    driver.mountLayer = mount;
    CALayer *src = driver.realLayer;

    CALayer *ring = [CALayer layer];
    ring.name = AXS_RING_LAYER_NAME;
    // 初始矩形 = 真实裁剪层换算到挂载层坐标（TXT beautify.23 二.2）
    ring.frame = (src != nil) ? [mount convertRect:src.frame fromLayer:src] : mount.bounds;
    ring.masksToBounds = NO;

    CAShapeLayer *shape = [CAShapeLayer layer];
    shape.fillColor = nil;                   // 只当遮罩用
    shape.strokeColor = [UIColor whiteColor].CGColor;
    ring.mask = shape;

    CAGradientLayer *grad = axs_ring_makeGradient(axs_ring_customColor(), axs_ring_color());
    [ring addSublayer:grad];
    [mount addSublayer:ring];                // 挂非裁剪祖先层，置最上层（TXT 二.1/二.3）

    driver.ring = ring;
    driver.shape = shape;
    driver.gradient = grad;

    driver.link = [CADisplayLink displayLinkWithTarget:driver selector:@selector(tick)];
    [driver.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    axs_ring_drivers[key] = driver;

    // 全树一次性探针（进程内仅首次 attach）：定位真实圆角来源
    axs_ring_treeProbe(container);

    // 首帧即出几何
    axs_ring_syncDriver(driver);

    axs_ring_log(@"ring probe: container class=%@ bounds=%@ realLayer=%@ corner=%.2f",
                 NSStringFromClass(container.class), NSStringFromCGRect(container.bounds),
                 driver.realLayer ? NSStringFromClass(driver.realLayer.class) : @"none",
                 driver.realLayer ? driver.realLayer.cornerRadius : 0.0);
    CAShapeLayer *probeMask = nil;
    if (driver.realLayer != nil && [driver.realLayer.mask isKindOfClass:[CAShapeLayer class]]) {
        probeMask = (CAShapeLayer *)driver.realLayer.mask;
    }
    if (probeMask == nil || probeMask.path == nil) probeMask = driver.radiusMask;
    if (probeMask != nil && probeMask.path != nil) {
        axs_ring_log(@"ring probe: mask class=%@ bbox=%@ radius=%.1f",
                     NSStringFromClass(probeMask.class),
                     NSStringFromCGRect(CGPathGetBoundingBox(probeMask.path)),
                     axs_ring_radiusFromPath(probeMask.path));
    }

    if (!driver.loggedAttach) {
        driver.loggedAttach = YES;
        NSString *curve = @"n/a";
        if (src != nil && [src respondsToSelector:@selector(cornerCurve)]) {
            NSString *c = [(id)src cornerCurve];
            if ([c isKindOfClass:[NSString class]]) curve = c;
        }
        axs_ring_log(@"ring attach: scan container=%p mount=%@ mountClips=%d realFrame=%@ convRect=%@ corner=%.1f overlayR=%.1f rRing=%.1f source=%@ curve=%@",
                     container, NSStringFromClass(mount.class),
                     mount.masksToBounds ? 1 : 0,
                     NSStringFromCGRect(src ? src.frame : CGRectZero),
                     NSStringFromCGRect(driver.lastBounds),
                     (src != nil) ? src.cornerRadius : 0.0,
                     driver.overlayR, driver.lastRadius,
                     driver.radiusSource ?: @"config", curve);
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
        if (!axs_ring_layoutHookInstalled) axs_ring_installLayoutHook(); // 类可能晚于 %ctor 注册
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

// --- resize 加速（TXT beautify.21 四.1）：hook SCFloatingContainerView 的
// layoutSubviews（UIKit 方法，不 hook 任何 sc_ 会话选择子）——resize 中
// ScreenCore 反复重建容器，新容器首次布局时立即挂环，不再等 0.5s 扫描；
// 在册容器照旧由各自 displayLink 驱动。

static void (*axs_ring_orig_layoutSubviews)(id, SEL);

static void axs_ring_hook_layoutSubviews(id self, SEL _cmd) {
    axs_ring_orig_layoutSubviews(self, _cmd);
    @try {
        if (axs_ring_drivers == nil) return;
        UIView *container = (UIView *)self;
        if (container.window == nil) return;
        NSString *key = [NSString stringWithFormat:@"%p", container];
        AXSRingLinkDriver *d = axs_ring_drivers[key];
        if (d == nil) {
            axs_ring_attachContainer(container);   // 重建的新容器立即挂环
        } else {
            // 手势改 bounds 触发的布局：模型即最新值，环与卡片同 commit 生效，
            // 右/下边（origin+size）不再滞后一帧（TXT beautify.22 三.3）
            axs_ring_syncDriver2(d, YES);
        }
    } @catch (NSException *exception) {
        // 布局路径上绝不抛异常
    }
}

static void axs_ring_installLayoutHook(void) {
    if (axs_ring_layoutHookInstalled) return;
    Class cls = objc_getClass("SCFloatingContainerView");
    if (cls == nil) return;
    SEL sel = @selector(layoutSubviews);
    Method m = class_getInstanceMethod(cls, sel);
    if (m == nil) return;
    // 先记原 IMP（可能是父类实现），再给本类加覆盖或替换本类 IMP——
    // 只影响 SCFloatingContainerView，不动 UIView
    axs_ring_orig_layoutSubviews = (void (*)(id, SEL))method_getImplementation(m);
    if (class_addMethod(cls, sel, (IMP)axs_ring_hook_layoutSubviews, method_getTypeEncoding(m))) {
        axs_ring_layoutHookInstalled = YES;
    } else {
        method_setImplementation(m, (IMP)axs_ring_hook_layoutSubviews);
        axs_ring_layoutHookInstalled = YES;
    }
    axs_ring_log(@"ring layout hook installed on SCFloatingContainerView");
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
static NSTimer *axs_ring_scanTimer = nil;

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
            axs_ring_installLayoutHook();        // 类已注册则立即装钩，未注册由扫描重试
            axs_ring_log(@"ring module loaded in SpringBoard");
            axs_ring_log(@"ring hooks ring=0 sessionHooks=0 layout=%d holdPress=1",
                         axs_ring_layoutHookInstalled ? 1 : 0);

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
