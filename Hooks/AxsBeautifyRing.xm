#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AxsHoldLaunchConfig.h"
#import "AxsHoldLaunchPreferences.h"
#import "AxsHoldLaunchPrivate.h"

// ---------------------------------------------------------------------------
// 美化 · 光圈外框 (ring frame, beautify.14) — 零会话 hook，扫描发现浮窗
//
// beautify.9–.12 的结论：环本身已是纯 CALayer 子层，但四个 sc_ 会话钩子与
// 手势失效/白屏在时间上始终相关，无法彻底排除环模块的嫌疑。本版对齐
// TrollOpen 的做法：ring 模块不再 hook 任何 ScreenCore 会话选择子，浮窗的
// 发现/挂载/跟随/清理全部由「运行时扫描 + 窗口通知」完成：
//
//   - 0.5s 定时器遍历所有可见 window 的视图层级，收集 SCFloatingContainerView；
//   - 与上一轮集合对比：新容器 → attach；消失 → 摘环；仍在 → bounds 变化时刷新；
//   - UIWindow 可见性通知 → 立即扫描（降低轮询延迟）；
//   - 环是纯 CALayer 子层（不参与命中测试），不创建任何 UIView / UIWindow；
//   - 圆角取 overlay/region 视图的 CAShapeLayer mask 半径（TXT 四：与容器
//     几何 + 21.59pt 外边距一致的 mask），bounds 变化时重读；config 兜底；
//   - 跑马灯 = conic 渐变 + colors 关键帧，不旋转任何层。
//
//   container.layer
//     ├─ (existing content)
//     └─ axsRingFrame (CALayer, name 标记，扫描发现/复用)
//          ├─ gradientLayer   conic 彩虹；跑马灯 = colors 关键帧
//          └─ mask = shapeLayer  圆角矩形描边（按边框厚度内缩）
// ---------------------------------------------------------------------------

#define AXS_RING_LOG_PATH @"/var/mobile/Documents/sc-ring.log"
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

// --- 圆角矩形 CGPath 半径提取（用于 probe 与 mask 来源） ----------------------

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

// --- 探测辅助（只读，不改任何属性） ------------------------------------------

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

// TXT 四.1：圆角取值——枚举 overlay/region 视图的 CAShapeLayer mask，
// 选与容器几何（含 21.59pt 外边距）一致的 mask 取 cornerRadius；
// 兜底：其他 mask 半径 -> config。禁止读 layer.cornerRadius。
static CGFloat axs_ring_discoverRadius(UIView *container, NSString **sourceOut) {
    NSMutableArray<CAShapeLayer *> *masks = [NSMutableArray array];
    axs_ring_collectMasks(container, 0, masks);
    CGFloat expandedW = container.bounds.size.width + 43.18;  // 2 × 21.59 外边距
    CGFloat expandedH = container.bounds.size.height + 43.18;
    for (CAShapeLayer *m in masks) {
        if (m.path == nil) continue;
        CGRect bb = CGPathGetBoundingBox(m.path);
        if (fabs(bb.size.width - expandedW) < 24 && fabs(bb.size.height - expandedH) < 24) {
            CGFloat r = axs_ring_radiusFromPath(m.path);
            if (r > 0.5) {
                *sourceOut = @"overlayMask";
                return r;
            }
        }
    }
    for (CAShapeLayer *m in masks) {
        if (m.path == nil) continue;
        CGFloat r = axs_ring_radiusFromPath(m.path);
        if (r > 0.5) {
            *sourceOut = @"otherMask";
            return r;
        }
    }
    *sourceOut = @"config";
    return (CGFloat)axs_ring_configRadius();
}

// --- 环条目（纯 C，无状态类；container 用 weak，图层按 name 找回） ------------

typedef struct {
    __weak UIView *container;
    CGRect lastBounds;
    CGFloat radius;
    CGFloat lineWidth;
    char source[16];
    BOOL loggedAttach;
} AXSRingEntry;

static AXSRingEntry axs_ring_entries[AXS_RING_MAX_ENTRIES];
static int axs_ring_entryCount = 0;
static NSTimer *axs_ring_scanTimer = nil;

static NSString * const axs_ring_layerName = @"axsRingFrame";
static NSString * const axs_ring_gradientName = @"axsRingGradient";

static AXSRingEntry *axs_ring_entryFor(UIView *container) {
    for (int i = 0; i < axs_ring_entryCount; i++) {
        if (axs_ring_entries[i].container == container) return &axs_ring_entries[i];
    }
    return nil;
}

static CALayer *axs_ring_findRingLayer(UIView *container) {
    for (CALayer *sub in container.layer.sublayers) {
        if ([sub.name isEqualToString:axs_ring_layerName]) return sub;
    }
    return nil;
}

static void axs_ring_removeEntryAt(int index) {
    UIView *container = axs_ring_entries[index].container;
    if (container != nil) {
        CALayer *ring = axs_ring_findRingLayer(container);
        if (ring != nil) {
            ring.mask = nil;
            [ring removeFromSuperlayer];
        }
    }
    axs_ring_log(@"ring detach: scan container=%p", axs_ring_entries[index].container);
    for (int i = index; i < axs_ring_entryCount - 1; i++) {
        axs_ring_entries[i] = axs_ring_entries[i + 1];
    }
    axs_ring_entryCount--;
}

static int axs_ring_indexOfContainer(UIView *container) {
    for (int i = 0; i < axs_ring_entryCount; i++) {
        if (axs_ring_entries[i].container == container) return i;
    }
    return -1;
}

// TXT 四.2：回前台探测启动封面与 scene presentation 状态（白屏归因）
static NSString *axs_ring_describeView(UIView *v) {
    if (v == nil) return @"nil";
    return [NSString stringWithFormat:@"%@ hidden=%d alpha=%.2f subviews=%u frame=%@",
            NSStringFromClass(v.class), v.hidden ? 1 : 0, v.alpha,
            (unsigned)v.subviews.count, NSStringFromCGRect(v.frame)];
}

// --- attach / refresh / detach（全部由扫描触发） ------------------------------

static void axs_ring_attachEntry(UIView *container) {
    if (axs_ring_entryCount >= AXS_RING_MAX_ENTRIES) {
        axs_ring_log(@"ring attach skipped: entries full (container=%p)", container);
        return;
    }
    if (!axs_ring_enabled()) return;

    CALayer *ring = [CALayer layer];
    ring.name = axs_ring_layerName;
    ring.frame = container.layer.bounds;
    ring.masksToBounds = NO;
    ring.zPosition = 9999.0;             // 盖在内容之上（CALayer 不参与命中测试）

    CAShapeLayer *shape = [CAShapeLayer layer];
    shape.fillColor = nil;               // 只当遮罩用
    shape.strokeColor = [UIColor whiteColor].CGColor;
    ring.mask = shape;

    CAGradientLayer *grad = axs_ring_makeGradient(axs_ring_customColor(), axs_ring_color());
    grad.name = axs_ring_gradientName;
    [ring addSublayer:grad];
    [container.layer addSublayer:ring];  // 宿主容器图层最上层

    AXSRingEntry *e = &axs_ring_entries[axs_ring_entryCount++];
    e->container = container;
    e->lastBounds = CGRectZero;
    e->radius = 0;
    e->source[0] = 0;
    e->loggedAttach = NO;

    // 首次 attach 即做一次层级/手势/圆角 probe（TXT 七.1 诊断留档）
    NSString *source = nil;
    e->radius = axs_ring_discoverRadius(container, &source);
    strlcpy(e->source, source.UTF8String, sizeof(e->source));

    axs_ring_log(@"ring probe: container class=%@ frame=%@ bounds=%@ layerCorner=%.2f masksToBounds=%d",
                 NSStringFromClass(container.class), NSStringFromCGRect(container.frame),
                 NSStringFromCGRect(container.bounds),
                 container.layer.cornerRadius, container.layer.masksToBounds ? 1 : 0);
    NSMutableArray<CAShapeLayer *> *masks = [NSMutableArray array];
    axs_ring_collectMasks(container, 0, masks);
    for (CAShapeLayer *m in masks) {
        if (m.path == nil) continue;
        axs_ring_log(@"ring probe: mask class=%@ path=%@ radius=%.1f",
                     NSStringFromClass(m.class),
                     NSStringFromCGRect(CGPathGetBoundingBox(m.path)),
                     axs_ring_radiusFromPath(m.path));
    }
    axs_ring_log(@"ring attach: scan container=%p containerLayer=%p bounds=%@ radiusSource=%@ radius=%.1f",
                 container, container.layer, NSStringFromCGRect(container.layer.bounds),
                 source, e->radius);
}

static void axs_ring_refreshEntry(AXSRingEntry *e) {
    UIView *container = e->container;
    CALayer *ring = axs_ring_findRingLayer(container);
    if (ring == nil) {
        // 环层丢了（宿主重建等）：按新容器完整重挂
        axs_ring_log(@"ring re-attach: scan container=%p", container);
        axs_ring_attachEntry(container);
        return;
    }
    double lineWidth = axs_ring_thickness();
    if (lineWidth < 0.5) lineWidth = 0.5;

    BOOL boundsChanged = !CGRectEqualToRect(container.layer.bounds, e->lastBounds);
    if (boundsChanged) {
        // 边界变化：重读圆角（TXT 四：bounds 变化时重读）并重建路径
        NSString *source = nil;
        e->radius = axs_ring_discoverRadius(container, &source);
        strlcpy(e->source, source.UTF8String, sizeof(e->source));
    }

    // 环是容器层子层：拖动/缩放/弹簧由同一 transform 物理作用，无需逐帧同步
    CAShapeLayer *shape = nil;
    CAGradientLayer *grad = nil;
    for (CALayer *sub in ring.sublayers) {
        if ([sub isKindOfClass:[CAGradientLayer class]]) grad = (CAGradientLayer *)sub;
    }
    if ([ring.mask isKindOfClass:[CAShapeLayer class]]) shape = (CAShapeLayer *)ring.mask;
    if (shape == nil || grad == nil) return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    ring.frame = container.layer.bounds;
    shape.frame = ring.bounds;
    if (boundsChanged || e->lineWidth != (CGFloat)lineWidth) {
        CGRect r = CGRectInset(ring.bounds, lineWidth / 2.0, lineWidth / 2.0);
        double pathRadius = axs_ring_clamp(e->radius, 0.0, MIN(r.size.width, r.size.height) / 2.0);
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:pathRadius];
        shape.path = p.CGPath;
        shape.lineWidth = lineWidth;
        grad.frame = ring.bounds;
    }
    [CATransaction commit];
    e->lastBounds = container.layer.bounds;
    e->lineWidth = (CGFloat)lineWidth;
    if (boundsChanged) {
        axs_ring_log(@"ring update: scan container=%p bounds=%@ radiusSource=%s radius=%.1f width=%.1f",
                     container, NSStringFromCGRect(container.layer.bounds), e->source,
                     e->radius, lineWidth);
    }
}

// --- 扫描（0.5s 定时器 + 窗口通知触发） ---------------------------------------

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

        // a) 已消失的容器 → 摘环（倒序遍历便于移除条目）
        for (int i = axs_ring_entryCount - 1; i >= 0; i--) {
            UIView *c = axs_ring_entries[i].container;
            BOOL found = (c != nil);
            if (found) {
                for (UIView *lvc in live) {
                    if (lvc == c) { found = YES; break; }
                }
            }
            if (!found) axs_ring_removeEntryAt(i);
        }

        if (!axs_ring_enabled()) {
            // TXT 二.6：开关关闭 → 全部摘除，完全无副作用
            for (int i = axs_ring_entryCount - 1; i >= 0; i--) {
                UIView *c = axs_ring_entries[i].container;
                axs_ring_log(@"ring detach: scan container=%p reason=disabled", c);
                if (c != nil) {
                    CALayer *ring = axs_ring_findRingLayer(c);
                    if (ring != nil) {
                        ring.mask = nil;
                        [ring removeFromSuperlayer];
                    }
                }
            }
            axs_ring_entryCount = 0;
            return;
        }

        // b) 新出现的容器 → attach；仍在的 → bounds 变化时刷新
        for (UIView *c in live) {
            AXSRingEntry *e = axs_ring_entryFor(c);
            if (e == nil) {
                axs_ring_attachEntry(c);
            } else {
                axs_ring_refreshEntry(e);
            }
        }
    } @catch (NSException *exception) {
        axs_ring_log(@"ring scan exception: %@", exception);
    }
}

// Darwin 通知：设置保存后立即重扫（0.5s 定时器兜底）
static void axs_ring_prefsChanged(CFNotificationCenterRef center, void *observer,
                                  CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ axs_ring_scanTick(); });
}

// --- health target（0.5s 定时器 + 窗口通知共用） --------------------------------

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

// --- entry: 启动即挂定时器与通知（无任何 hook） --------------------------------

%ctor {
    @autoreleasepool {
        if (objc_getClass("SpringBoard") != nil) {
            axs_ring_log(@"ring module loaded in SpringBoard");
            axs_ring_log(@"ring hooks ring=0 sessionHooks=0 holdPress=1");
            axs_ring_healthTarget = [AXSRingHealthTarget new];

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
