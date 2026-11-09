#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AxsHoldLaunchConfig.h"

@interface AxsBFEngineTarget : NSObject
+ (instancetype)shared;
- (void)axsBFTick;
@end

// ---------------------------------------------------------------------------
// 美化 · 光圈外框 (marquee border fused with the floating window)
//
// Layers live INSIDE the floating container's own layer tree, so the border
// moves / scales / animates together with the window - no overlay window, no
// cross-window coordinate math:
//
//   container.layer
//     └─ holder (static, frame = bounds expanded by half diagonal)
//          ├─ mask = CAShapeLayer (the border band path, static)
//          └─ grad (CAGradientLayer conic rainbow, rotation animation)
//
// The gradient child spins (Core Animation, render-server driven) while the
// holder's mask keeps only the border band visible -> colors flow around the
// window like a marquee with zero per-frame CPU.
// ---------------------------------------------------------------------------

static CADisplayLink *axs_bfLink = nil;
static NSMapTable<NSString *, UIView *> *axs_bfViews = nil;       // key -> weak container
static NSMutableDictionary<NSString *, NSMutableArray<CALayer *> *> *axs_bfHolders = nil;
static NSMutableDictionary<NSString *, NSString *> *axs_bfStyleSig = nil;
static NSMutableDictionary<NSString *, NSString *> *axs_bfBoundsSig = nil;
static int axs_bfIdleFrames = 0;

static void axs_bf_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void axs_bf_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[AxsHoldLaunch:BF] %@", message);
    @try {
        NSString *path = @"/var/mobile/Library/Caches/AxsHoldLaunch.log";
        NSString *line = [NSString stringWithFormat:@"%@\n", message];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle == nil) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
    } @catch (NSException *exception) { }
}

static NSString *axs_bf_keyFor(id object) {
    return [NSString stringWithFormat:@"%p", object];
}

static UIColor *axs_bf_parseHex(NSString *hex, UIColor *fallback) {
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

static void axs_bf_ensureMaps(void) {
    if (axs_bfViews != nil) return;
    axs_bfViews = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory
                                        valueOptions:NSMapTableWeakMemory];
    axs_bfHolders = [NSMutableDictionary new];
    axs_bfStyleSig = [NSMutableDictionary new];
    axs_bfBoundsSig = [NSMutableDictionary new];
}

static void axs_bf_logCount(void) {
    axs_bf_log(@"frame layers attached: count=%lu", (unsigned long)axs_bfHolders.count);
}

static void axs_bf_detach(NSString *key) {
    NSMutableArray<CALayer *> *holders = axs_bfHolders[key];
    for (CALayer *l in holders) { [l removeFromSuperlayer]; }
    if (axs_bfHolders[key] != nil) {
        [axs_bfHolders removeObjectForKey:key];
        [axs_bfStyleSig removeObjectForKey:key];
        [axs_bfBoundsSig removeObjectForKey:key];
        axs_bf_logCount();
    }
}

static NSArray<UIColor *> *axs_bf_rainbow(void) {
    return @[ [UIColor redColor], [UIColor orangeColor], [UIColor yellowColor],
              [UIColor greenColor], [UIColor cyanColor], [UIColor blueColor],
              [UIColor purpleColor], [UIColor redColor] ];
}

// the visible rounded window = the container's largest child (the app
// content view); ScreenCore animates the CHILD on resize while the container
// itself follows at the end - so geometry must be sampled from the child
static UIView *axs_bf_contentChild(UIView *container) {
    UIView *best = nil;
    CGFloat bestArea = 0;
    for (UIView *sub in container.subviews) {
        if (sub.hidden || sub.alpha < 0.05) continue;
        CGFloat area = sub.bounds.size.width * sub.bounds.size.height;
        if (area > bestArea) { bestArea = area; best = sub; }
    }
    return best;
}

// band geometry: everything reads the content child's PRESENTATION layer so
// the border follows resize/corner animations frame by frame (the model
// bounds jump to the final value at animation start, which is what made the
// border lag and shift)
static void axs_bf_updateGeometry(CALayer *holder, UIView *view, AxsHoldLaunchConfig *config) {
    CGFloat lineWidth = [config axs_holdlaunch_bfFrameWidth];

    UIView *content = axs_bf_contentChild(view) ?: view;
    CALayer *pres = content.layer.presentationLayer;

    CGFloat w, h, radius;
    if (pres != nil) {
        w = pres.bounds.size.width;
        h = pres.bounds.size.height;
        radius = pres.cornerRadius;
    } else {
        w = content.bounds.size.width;
        h = content.bounds.size.height;
        radius = content.layer.cornerRadius;
    }
    if (w < 40 || h < 40) { w = view.bounds.size.width; h = view.bounds.size.height; }
    if (radius < 1) radius = [config axs_holdlaunch_splitWindowCornerRadius];
    if (radius < 1) radius = 47.0;

    // band origin: the child's animated frame in container coords (fallback centered)
    CGFloat bx, by;
    if (pres != nil) {
        CGRect pf = pres.frame;
        bx = pf.origin.x;
        by = pf.origin.y;
    } else {
        bx = (view.bounds.size.width - w) / 2.0;
        by = (view.bounds.size.height - h) / 2.0;
    }

    // expand the holder by half the diagonal so any rotation still covers the band
    CGFloat diag = hypot(w, h) / 2.0;
    CGFloat holderW = w + diag * 2;
    CGFloat holderH = h + diag * 2;
    CGFloat dx = (holderW - w) / 2.0;
    CGFloat dy = (holderH - h) / 2.0;
    holder.frame = CGRectMake(bx - dx, by - dy, holderW, holderH);

    CGRect band = CGRectInset(CGRectMake(dx, dy, w, h), lineWidth / 2.0, lineWidth / 2.0);
    CGFloat bandRadius = radius - lineWidth / 2.0;
    if (bandRadius < 0) bandRadius = 0;
    if (bandRadius * 2 > band.size.width) bandRadius = band.size.width / 2;
    if (bandRadius * 2 > band.size.height) bandRadius = band.size.height / 2;
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:band
                                               byRoundingCorners:UIRectCornerAllCorners
                                                     cornerRadii:CGSizeMake(bandRadius, bandRadius)];
    CAShapeLayer *mask = (CAShapeLayer *)holder.mask;
    mask.path = path.CGPath;
    mask.lineWidth = lineWidth;

    for (CALayer *sub in holder.sublayers) {
        if ([sub isKindOfClass:[CAGradientLayer class]]) sub.frame = holder.bounds;
    }
}

// rebuild the holder + gradient + mask for one container
static void axs_bf_build(NSString *key, UIView *view, AxsHoldLaunchConfig *config) {
    axs_bf_detach(key);

    BOOL custom = [config axs_holdlaunch_bfCustomEnabled];
    UIColor *color = axs_bf_parseHex([config axs_holdlaunch_bfFrameColor], [UIColor cyanColor]);

    CGFloat w = view.bounds.size.width;
    CGFloat h = view.bounds.size.height;
    if (w < 40 || h < 40) return;

    CALayer *holder = [CALayer layer];
    holder.backgroundColor = [UIColor clearColor].CGColor;

    // border band mask (path/lineWidth filled in by updateGeometry)
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.strokeColor = [UIColor whiteColor].CGColor;
    mask.fillColor = nil;
    holder.mask = mask;

    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.type = kCAGradientLayerConic;
    grad.startPoint = CGPointMake(0.5, 0.5);
    grad.endPoint = CGPointMake(0.5, 0.0);
    if (custom) {
        UIColor *c = color;
        grad.colors = @[ (__bridge id)c.CGColor, (__bridge id)c.CGColor ];
    } else {
        NSArray<UIColor *> *rainbow = axs_bf_rainbow();
        NSMutableArray *colors = [NSMutableArray array];
        for (UIColor *c in rainbow) { [colors addObject:(__bridge id)c.CGColor]; }
        grad.colors = colors;
        NSMutableArray *locations = [NSMutableArray array];
        for (NSUInteger i = 0; i < rainbow.count; i++) {
            [locations addObject:@((double)i / (double)(rainbow.count - 1))];
        }
        grad.locations = locations;
    }
    [holder addSublayer:grad];

    if (!custom) {
        // 跑马灯: colors sweep around the border continuously
        CABasicAnimation *rot = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        rot.fromValue = @(0.0);
        rot.toValue = @(2.0 * M_PI);
        rot.duration = 4.0;
        rot.repeatCount = HUGE_VALF;
        rot.removedOnCompletion = NO;
        [grad addAnimation:rot forKey:@"marquee"];
    }

    [view.layer addSublayer:holder];
    axs_bfHolders[key] = [NSMutableArray arrayWithObject:holder];
    axs_bf_updateGeometry(holder, view, config);
    axs_bf_logCount();
}

static void axs_bf_tick(void) {
    @try {
        axs_bf_ensureMaps();
        AxsHoldLaunchConfig *config = [AxsHoldLaunchConfig axs_holdlaunch_shared];
        BOOL enabled = [config axs_holdlaunch_bfFrameEnabled];

        NSMutableArray<NSString *> *keys = [NSMutableArray array];
        for (NSString *k in axs_bfViews) { [keys addObject:k]; }
        for (NSString *key in keys) {
            UIView *view = [axs_bfViews objectForKey:key];

            if (view == nil || view.window == nil || view.hidden || view.alpha < 0.01
                || view.bounds.size.width < 40) {
                axs_bf_detach(key);
                [axs_bfViews removeObjectForKey:key];
                continue;
            }

            if (!enabled) {
                axs_bf_detach(key);
                continue;
            }

            BOOL custom = [config axs_holdlaunch_bfCustomEnabled];
            NSString *styleSig = [NSString stringWithFormat:@"custom=%d,color=%@,width=%.1f",
                                  (int)custom,
                                  custom ? [config axs_holdlaunch_bfFrameColor] : @"",
                                  [config axs_holdlaunch_bfFrameWidth]];
            if (![axs_bfStyleSig[key] isEqualToString:styleSig]) {
                axs_bf_build(key, view, config);
                axs_bfStyleSig[key] = styleSig;
                axs_bfBoundsSig[key] = @"";
                if (axs_bfHolders[key] == nil) continue;
            }

            // visual geometry incl. animated resizes: sample the CONTENT
            // child's presentation frame + radius (the child is what the user
            // sees; the container itself follows at the end)
            UIView *content = axs_bf_contentChild(view) ?: view;
            CALayer *pres = content.layer.presentationLayer;
            CGRect vf = pres != nil ? pres.frame : content.frame;
            CGFloat vr = pres != nil ? pres.cornerRadius : content.layer.cornerRadius;
            NSString *boundsSig = [NSString stringWithFormat:@"%p|%@|r=%.1f",
                                   content, NSStringFromCGRect(vf), vr];
            if (![axs_bfBoundsSig[key] isEqualToString:boundsSig]) {
                // window resized/rounded (possibly mid-animation): update in place
                CALayer *holder = axs_bfHolders[key].firstObject;
                if (holder != nil) axs_bf_updateGeometry(holder, view, config);
                axs_bfBoundsSig[key] = boundsSig;
            }
        }

        // keep the tick alive while windows are registered: resizes happen
        // without didMoveToWindow, so stopping here would leave stale borders
        if (axs_bfLink != nil && axs_bfViews.count == 0) {
            axs_bf_log(@"frame tick idle, display link stopped");
            [axs_bfLink invalidate];
            axs_bfLink = nil;
            axs_bfIdleFrames = 0;
        }
    } @catch (NSException *exception) {
        axs_bf_log(@"frame tick exception: %@", exception);
    }
}

@implementation AxsBFEngineTarget
+ (instancetype)shared {
    static AxsBFEngineTarget *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [self new]; });
    return shared;
}
- (void)axsBFTick { axs_bf_tick(); }
@end

// --- C API (Main.xm hooks + Config) ---

extern "C" {

void axs_bf_engine_wake(void) {
    if (axs_bfLink != nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (axs_bfLink != nil) return;
        axs_bf_ensureMaps();
        axs_bfLink = [CADisplayLink displayLinkWithTarget:[AxsBFEngineTarget shared]
                                                 selector:@selector(axsBFTick)];
        [axs_bfLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        axs_bf_log(@"frame display link started");
    });
}

void axs_bf_noteContainer(void *view) {
    if (view == NULL) return;
    id v = (__bridge id)view;
    if (![v isKindOfClass:[UIView class]]) return;
    axs_bf_ensureMaps();
    NSString *key = axs_bf_keyFor(v);
    if ([axs_bfViews objectForKey:key] == v) return; // already tracked
    [axs_bfViews setObject:v forKey:key];
    axs_bf_log(@"frame container noted: %p bounds=%@", view, NSStringFromCGRect(((UIView *)v).bounds));
    axs_bf_engine_wake();
}

void axs_bf_configChanged(void) {
    if (axs_bfStyleSig != nil) [axs_bfStyleSig removeAllObjects];
    axs_bf_engine_wake();
}

} // extern "C"
