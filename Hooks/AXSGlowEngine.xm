#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AxsHoldLaunchConfig.h"

// ---------------------------------------------------------------------------
// 窗口光圈/光晕引擎 (port of TrollOpen's glow feature)
//
// 定时扫描 SpringBoard 的视图层级，找到 ScreenCore 的浮窗容器
// (SCFloatingContainerView)，在其图层上维护两圈渐变环:
//   - 光圈外框: 紧贴浮窗边缘的渐变环 (彩虹或自定义色)
//   - 窗口光晕: 向外扩散的柔和光晕带
// 颜色/开关设置变化时下一次 tick 自动生效；浮窗关闭时自动摘除。
// ---------------------------------------------------------------------------

static NSTimer *axs_glowTimer = nil;
static NSMutableDictionary<NSString *, NSMutableArray<CALayer *> *> *axs_glowLayers = nil;
static NSMutableDictionary<NSString *, NSString *> *axs_glowSignature = nil;

static UIColor *axs_glow_parseHex(NSString *hex, UIColor *fallback) {
    if (![hex isKindOfClass:[NSString class]] || hex.length == 0) return fallback;
    NSString *h = [[hex stringByReplacingOccurrencesOfString:@"#" withString:@""] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (h.length == 6 || h.length == 8) {
        unsigned int v = 0;
        NSScanner *scanner = [NSScanner scannerWithString:h];
        [scanner scanHexInt:&v];
        if (h.length == 6) v = (v << 8) | 0xFF;
        return [UIColor colorWithRed:((v >> 24) & 0xFF) / 255.0
                               green:((v >> 16) & 0xFF) / 255.0
                                blue:((v >> 8) & 0xFF) / 255.0
                               alpha:(v & 0xFF) / 255.0];
    }
    return fallback;
}

static NSArray<UIColor *> *axs_glow_rainbow(void) {
    return @[ [UIColor redColor], [UIColor orangeColor], [UIColor yellowColor],
              [UIColor greenColor], [UIColor cyanColor], [UIColor blueColor],
              [UIColor purpleColor], [UIColor redColor] ];
}

// 在视图层级里递归找第一个类名匹配的视图
static UIView *axs_glow_findView(UIView *root, NSString *prefix, int depth) {
    if (depth > 12) return nil;
    if ([NSStringFromClass(root.class) hasPrefix:prefix]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = axs_glow_findView(sub, prefix, depth + 1);
        if (found) return found;
    }
    return nil;
}

static CALayer *axs_glow_ringLayer(CGRect bounds, CGFloat radius, CGFloat outerGrow,
                                   NSArray<UIColor *> *colors, BOOL fadeOut) {
    // 渐变环: 外扩 outerGrow 的圆角矩形 与 原圆角矩形 之间的环带 (奇偶填充遮罩)
    CGRect outerRect = CGRectInset(bounds, -outerGrow, -outerGrow);
    UIBezierPath *outerPath = [UIBezierPath bezierPathWithRoundedRect:outerRect
                                         byRoundingCorners:UIRectCornerAllCorners
                                               cornerRadii:CGSizeMake(radius + outerGrow, radius + outerGrow)];
    UIBezierPath *innerPath = [UIBezierPath bezierPathWithRoundedRect:bounds
                                         byRoundingCorners:UIRectCornerAllCorners
                                               cornerRadii:CGSizeMake(radius, radius)];
    [outerPath appendPath:innerPath];

    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.path = outerPath.CGPath;
    mask.fillRule = kCAFillRuleEvenOdd;

    CAGradientLayer *ring = [CAGradientLayer layer];
    ring.frame = outerRect;
    ring.type = kCAGradientLayerConic;
    ring.startPoint = CGPointMake(0.5, 0.5);
    ring.endPoint = CGPointMake(0.5, 0.0);
    ring.mask = mask;

    NSMutableArray *c = [NSMutableArray array];
    NSMutableArray *loc = [NSMutableArray array];
    NSUInteger n = colors.count;
    for (NSUInteger i = 0; i <= n; i++) {
        UIColor *col = colors[i % n];
        CGFloat alpha = 1.0;
        if (fadeOut && n > 0) {
            CGFloat t = (CGFloat)i / n;
            alpha = 0.55 * (1.0 - t * t);
        }
        CGFloat r = 0, g = 0, b = 0, a = 0;
        [col getRed:&r green:&g blue:&b alpha:&a];
        [c addObject:(id)[UIColor colorWithRed:r green:g blue:b alpha:alpha].CGColor];
        [loc addObject:@((CGFloat)i / n)];
    }
    ring.colors = c;
    ring.locations = loc;
    return ring;
}

static void axs_glow_applyToContainer(UIView *container, AxsHoldLaunchConfig *config) {
    NSString *key = [NSString stringWithFormat:@"%p", container];
    CGRect bounds = container.bounds;
    CGFloat radius = container.layer.cornerRadius;
    if (radius < 1) radius = 47.0;

    BOOL frameOn = [config axs_holdlaunch_glowFrameEnabled];
    BOOL haloOn = [config axs_holdlaunch_glowHaloEnabled];

    if (!frameOn && !haloOn) {
        for (CALayer *l in axs_glowLayers[key]) { [l removeFromSuperlayer]; }
        [axs_glowLayers removeObjectForKey:key];
        [axs_glowSignature removeObjectForKey:key];
        return;
    }

    UIColor *frameCol = [config axs_holdlaunch_glowFrameCustom]
        ? axs_glow_parseHex([config axs_holdlaunch_glowFrameColor], [UIColor colorWithRed:0.2 green:0.63 blue:1.0 alpha:1.0])
        : nil;
    UIColor *haloCol = [config axs_holdlaunch_glowHaloCustom]
        ? axs_glow_parseHex([config axs_holdlaunch_glowHaloColor], [UIColor whiteColor])
        : nil;
    NSString *sig = [NSString stringWithFormat:@"%.0f,%.0f,%.0f,%.0f,%.0f,%d,%d,%@,%d,%@",
                     bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height,
                     radius, frameOn, [config axs_holdlaunch_glowFrameCustom],
                     frameCol ?: @"", [config axs_holdlaunch_glowHaloCustom], haloCol ?: @""];
    if ([axs_glowSignature[key] isEqualToString:sig]) return;
    axs_glowSignature[key] = sig;

    for (CALayer *l in axs_glowLayers[key]) { [l removeFromSuperlayer]; }
    NSMutableArray<CALayer *> *layers = [NSMutableArray array];

    if (haloOn) {
        NSArray<UIColor *> *haloColors = haloCol ? @[haloCol, haloCol] : @[[UIColor whiteColor], [UIColor whiteColor]];
        CALayer *halo = axs_glow_ringLayer(bounds, radius, 16.0, haloColors, YES);
        [container.layer addSublayer:halo];
        [layers addObject:halo];
    }
    if (frameOn) {
        NSArray<UIColor *> *frameColors = frameCol ? @[frameCol, frameCol]
                                                   : axs_glow_rainbow();
        CALayer *ring = axs_glow_ringLayer(bounds, radius, 3.0, frameColors, NO);
        [container.layer addSublayer:ring];
        [layers addObject:ring];
    }

    [axs_glowLayers setObject:layers forKey:key];
    objc_setAssociatedObject(container, @selector(axsGlowLayersKey), layers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void axs_glow_tick(void) {
    @try {
        AxsHoldLaunchConfig *config = [AxsHoldLaunchConfig axs_holdlaunch_shared];
        if (axs_glowLayers == nil) {
            axs_glowLayers = [NSMutableDictionary new];
            axs_glowSignature = [NSMutableDictionary new];
        }

        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        NSArray<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes.allObjects;
        for (UIScene *scene in scenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                UIView *container = axs_glow_findView(window.rootViewController.view ?: window, @"SCFloatingContainerView", 0);
                if (container == nil || container.window == nil || container.hidden ||
                    container.frame.size.width < 40 || container.frame.size.height < 40) continue;
                NSString *key = [NSString stringWithFormat:@"%p", container];
                [seen addObject:key];
                axs_glow_applyToContainer(container, config);
            }
        }

        // 清理已消失容器的图层
        for (NSString *key in axs_glowLayers.allKeys.copy) {
            if (![seen containsObject:key]) {
                for (CALayer *l in axs_glowLayers[key]) { [l removeFromSuperlayer]; }
                [axs_glowLayers removeObjectForKey:key];
                [axs_glowSignature removeObjectForKey:key];
            }
        }
    } @catch (NSException *exception) {
        // 引擎异常不能拖垮 SpringBoard
    }
}

static void axs_glow_start(void) {
    if (axs_glowTimer) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (axs_glowTimer) return;
        axs_glowTimer = [NSTimer timerWithTimeInterval:0.5
                                                target:[AXSGlowEngineTarget shared]
                                              selector:@selector(axsGlowTick)
                                              userInfo:nil
                                               repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:axs_glowTimer forMode:NSRunLoopCommonModes];
    });
}

@interface AXSGlowEngineTarget : NSObject
+ (instancetype)shared;
- (void)axsGlowTick;
@end

@implementation AXSGlowEngineTarget
+ (instancetype)shared {
    static AXSGlowEngineTarget *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}
- (void)axsGlowTick { axs_glow_tick(); }
@end

// expose to Main.xm via C symbol
void axs_glow_engine_start(void) {
    axs_glow_start();
}
