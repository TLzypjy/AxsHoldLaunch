#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AxsHoldLaunchConfig.h"

// ---------------------------------------------------------------------------
// 窗口光圈/光晕引擎 (port of TrollOpen's glow feature)
//
// CADisplayLink 逐帧同步: 找到 ScreenCore 浮窗里真正带圆角的内容视图，
// 把渐变环挂在它的父层上，逐帧同步 frame 与遮罩路径 —— 移动/缩放零延迟。
// ---------------------------------------------------------------------------

static CADisplayLink *axs_glowLink = nil;
static NSMutableDictionary<NSString *, NSMutableArray<CALayer *> *> *axs_glowLayers = nil;
static NSMutableDictionary<NSString *, NSString *> *axs_glowSignature = nil;
static NSMutableDictionary<NSString *, NSString *> *axs_glowFrameSig = nil;

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

static BOOL axs_glow_isRealAppBundle(NSString *bundle) {
    return [bundle isKindOfClass:[NSString class]]
        && bundle.length > 0
        && ![bundle hasPrefix:@"system-tool:"];
}

// 找到浮窗里真正带圆角的内容视图 (类名 SC 前缀 + 圆角 >= 16 + 尺寸合理)
static UIView *axs_glow_findRoundedView(UIView *root, int depth) {
    if (depth > 14) return nil;
    CGFloat w = root.bounds.size.width, h = root.bounds.size.height;
    if (w >= 150 && h >= 150 && root.layer.cornerRadius >= 16
        && [NSStringFromClass(root.class) hasPrefix:@"SC"]) {
        return root;
    }
    for (UIView *sub in root.subviews) {
        UIView *found = axs_glow_findRoundedView(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

static CALayer *axs_glow_buildRing(CGRect bounds, CGFloat radius, CGFloat outerGrow,
                                   NSArray<UIColor *> *colors, BOOL fadeOut) {
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

// 重建 (颜色/开关/尺寸变化时才调用)
static void axs_glow_rebuild(UIView *hostView, AxsHoldLaunchConfig *config) {
    NSString *key = [NSString stringWithFormat:@"%p", hostView];
    CGFloat radius = hostView.layer.cornerRadius;
    if (radius < 1) radius = 47.0;

    BOOL frameOn = [config axs_holdlaunch_glowFrameEnabled];
    BOOL haloOn = [config axs_holdlaunch_glowHaloEnabled];

    for (CALayer *l in axs_glowLayers[key]) { [l removeFromSuperlayer]; }

    if (!frameOn && !haloOn) {
        [axs_glowLayers removeObjectForKey:key];
        [axs_glowSignature removeObjectForKey:key];
        [axs_glowFrameSig removeObjectForKey:key];
        return;
    }

    UIColor *frameCol = [config axs_holdlaunch_glowFrameCustom]
        ? axs_glow_parseHex([config axs_holdlaunch_glowFrameColor], [UIColor colorWithRed:0.2 green:0.63 blue:1.0 alpha:1.0])
        : nil;
    UIColor *haloCol = [config axs_holdlaunch_glowHaloCustom]
        ? axs_glow_parseHex([config axs_holdlaunch_glowHaloColor], [UIColor whiteColor])
        : nil;
    NSString *sig = [NSString stringWithFormat:@"%d,%d,%@,%d,%@",
                     frameOn, [config axs_holdlaunch_glowFrameCustom],
                     frameCol ?: @"", [config axs_holdlaunch_glowHaloCustom], haloCol ?: @""];
    axs_glowSignature[key] = sig;

    NSMutableArray<CALayer *> *layers = [NSMutableArray array];
    // 挂到父层: 内容视图可能裁剪子层，父层不裁剪，光环才能画到边缘外
    CALayer *hostLayer = hostView.layer.superlayer ?: hostView.layer;
    CGRect hostFrame = hostView.frame;

    if (haloOn) {
        NSArray<UIColor *> *haloColors = haloCol ? @[haloCol, haloCol] : @[[UIColor whiteColor], [UIColor whiteColor]];
        CALayer *halo = axs_glow_buildRing(hostFrame, radius, 16.0, haloColors, YES);
        [hostLayer addSublayer:halo];
        [layers addObject:halo];
    }
    if (frameOn) {
        NSArray<UIColor *> *frameColors = frameCol ? @[frameCol, frameCol]
                                                   : axs_glow_rainbow();
        CALayer *ring = axs_glow_buildRing(hostFrame, radius, 3.0, frameColors, NO);
        [hostLayer addSublayer:ring];
        [layers addObject:ring];
    }

    [axs_glowLayers setObject:layers forKey:key];
    objc_setAssociatedObject(hostView, @selector(axsGlowLayersKey), layers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void axs_glow_sync(UIView *hostView) {
    NSString *key = [NSString stringWithFormat:@"%p", hostView];
    NSMutableArray<CALayer *> *layers = axs_glowLayers[key];
    if (layers.count == 0) return;
    CGRect hostFrame = hostView.frame;
    NSString *fsig = [NSString stringWithFormat:@"%.0f,%.0f,%.0f,%.0f",
                      hostFrame.origin.x, hostFrame.origin.y,
                      hostFrame.size.width, hostFrame.size.height];
    if ([axs_glowFrameSig[key] isEqualToString:fsig]) return;
    axs_glowFrameSig[key] = fsig;
    CGFloat radius = hostView.layer.cornerRadius;
    if (radius < 1) radius = 47.0;
    BOOL halo = YES; // 两层都同步: 索引 0 = 光晕(外扩16), 索引 1 = 外框(外扩3)
    CGFloat grows[2] = {16.0, 3.0};
    NSUInteger idx = 0;
    for (CALayer *l in layers) {
        if (![l isKindOfClass:[CAGradientLayer class]]) continue;
        CGRect outerRect = CGRectInset(hostFrame, -grows[idx], -grows[idx]);
        l.frame = outerRect;
        CAShapeLayer *mask = (CAShapeLayer *)l.mask;
        if ([mask isKindOfClass:[CAShapeLayer class]]) {
            UIBezierPath *outerPath = [UIBezierPath bezierPathWithRoundedRect:outerRect
                                                 byRoundingCorners:UIRectCornerAllCorners
                                                       cornerRadii:CGSizeMake(radius + grows[idx], radius + grows[idx])];
            UIBezierPath *innerPath = [UIBezierPath bezierPathWithRoundedRect:hostFrame
                                                 byRoundingCorners:UIRectCornerAllCorners
                                                       cornerRadii:CGSizeMake(radius, radius)];
            [outerPath appendPath:innerPath];
            mask.path = outerPath.CGPath;
        }
        idx++;
        if (idx >= 2 && !halo) break;
    }
}

static void axs_glow_tick(void) {
    @try {
        AxsHoldLaunchConfig *config = [AxsHoldLaunchConfig axs_holdlaunch_shared];
        if (axs_glowLayers == nil) {
            axs_glowLayers = [NSMutableDictionary new];
            axs_glowSignature = [NSMutableDictionary new];
            axs_glowFrameSig = [NSMutableDictionary new];
        }

        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        NSArray<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes.allObjects;
        for (UIScene *scene in scenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                UIView *rounded = axs_glow_findRoundedView(window.rootViewController.view ?: window, 0);
                if (rounded == nil || rounded.window == nil || rounded.hidden ||
                    rounded.frame.size.width < 100 || rounded.frame.size.height < 100) continue;
                if (rounded.layer.superlayer == nil) continue;
                NSString *key = [NSString stringWithFormat:@"%p", rounded];
                [seen addObject:key];

                BOOL frameOn = [config axs_holdlaunch_glowFrameEnabled];
                BOOL haloOn = [config axs_holdlaunch_glowHaloEnabled];
                if (!frameOn && !haloOn) {
                    for (CALayer *l in axs_glowLayers[key]) { [l removeFromSuperlayer]; }
                    [axs_glowLayers removeObjectForKey:key];
                    [axs_glowSignature removeObjectForKey:key];
                    continue;
                }

                // 颜色/开关签名变化 → 重建; 否则逐帧同步几何
                NSString *colorSig = [NSString stringWithFormat:@"%d,%d,%@,%d,%@",
                                      frameOn, [config axs_holdlaunch_glowFrameCustom],
                                      [config axs_holdlaunch_glowFrameCustom] ? [config axs_holdlaunch_glowFrameColor] : @"",
                                      [config axs_holdlaunch_glowHaloCustom],
                                      [config axs_holdlaunch_glowHaloCustom] ? [config axs_holdlaunch_glowHaloColor] : @""];
                if (axs_glowLayers[key] == nil
                    || ![axs_glowSignature[key] isEqualToString:colorSig]) {
                    axs_glow_rebuild(rounded, config);
                } else {
                    axs_glow_sync(rounded);
                }
            }
        }

        for (NSString *key in axs_glowLayers.allKeys.copy) {
            if (![seen containsObject:key]) {
                for (CALayer *l in axs_glowLayers[key]) { [l removeFromSuperlayer]; }
                [axs_glowLayers removeObjectForKey:key];
                [axs_glowSignature removeObjectForKey:key];
                [axs_glowFrameSig removeObjectForKey:key];
            }
        }
    } @catch (NSException *exception) {
        // 引擎异常不能拖垮 SpringBoard
    }
}

@interface AXSGlowEngineTarget : NSObject
+ (instancetype)shared;
- (void)axsGlowTick;
@end

static void axs_glow_start(void) {
    if (axs_glowLink) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (axs_glowLink) return;
        axs_glowLink = [CADisplayLink displayLinkWithTarget:[AXSGlowEngineTarget shared]
                                                   selector:@selector(axsGlowTick)];
        [axs_glowLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    });
}

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
