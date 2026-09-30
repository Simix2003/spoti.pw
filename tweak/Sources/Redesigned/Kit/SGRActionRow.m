// The action row's controls: the Play capsule and the button that stands in for one of Spotify's.
//
// Both are drawn from what Spotify's own button shows, and neither keeps state of its own. The glyph is
// looked for past what is hidden behind it -- a play button's glow ring is a hidden view holding an image
// of its own, and taken for the glyph it put a soft green ring in the capsule (device, 2026-09-17) -- and
// it is watched afterwards, because Spotify swaps play for pause without laying the header out again.
#import "Core/SGCore.h"
#import "SGRActionRow.h"
#import "SGRGlass.h"
#import "SGRRestyle.h"
#import "SGRTokens.h"
#import "SGRAccent.h"
#import "SGRDownload.h"
#import "SGRReveal.h"
#import <math.h>

// The capsule: the glyph is Spotify's own 48pt canvas with the triangle small in the middle of it, so the
// lead is short and the gap to the word comes out of the canvas itself.
static const CGFloat kGlyphSide = 44, kCapsuleLead = 4, kCapsuleTrail = 20;
// The mirrored glyph, the size Spotify draws one inside a 48pt round button.
static const CGFloat kMirrorGlyph = 24;

static char kCapsuleGlassKey, kMirrorGlassKey;

// The glyph Spotify's button draws: an image view of the button's own size that nothing hidden is in the
// way of. `side` is the size to match, 0 for any image view that is showing.
static UIImageView *glyphIn(UIView *button, CGFloat side) {
    __block UIImageView *glyph = nil;
    SGForEachView(button, ^(UIView *v) {
        if (glyph || ![v isKindOfClass:UIImageView.class] || !((UIImageView *)v).image) return;
        if (side > 0 && (fabs(v.bounds.size.width - side) > 2 || fabs(v.bounds.size.height - side) > 2)) return;
        for (UIView *up = v; up && up != button; up = up.superview) {
            if (up.hidden || up.alpha <= 0.01) return;
        }
        glyph = (UIImageView *)v;
    });
    return glyph;
}

static NSString *wordIn(UIView *button) {
    __block NSString *word = nil;
    SGForEachView(button, ^(UIView *v) {
        if (!word && v.accessibilityLabel.length) word = v.accessibilityLabel;
    });
    return word;
}

#pragma mark - the Play capsule

// How far the halo reaches past the capsule. The action row leaves 16pt between buttons.
static const CGFloat kGlowSpread = 14;

static UIColor *sgr_shiftHue(UIColor *color, CGFloat turn) {
    CGFloat h = 0, s = 0, b = 0, a = 1;
    if (![color getHue:&h saturation:&s brightness:&b alpha:&a]) return color;
    return [UIColor colorWithHue:fmod(h + turn, 1) saturation:MIN(1, s) brightness:b alpha:a];
}

static CGFloat sgr_seedTurn(NSString *seed) {
    if (!seed.length) return 0;
    NSUInteger hash = 2166136261u;
    for (NSUInteger i = 0; i < seed.length; i++) hash = (hash ^ [seed characterAtIndex:i]) * 16777619u;
    return (hash % 360) / 360.0;
}

static NSArray<UIColor *> *sgr_defaultGlow(CGFloat turn) {
    NSArray<UIColor *> *base = @[
        [UIColor colorWithRed:0.49 green:0.36 blue:1 alpha:1],
        [UIColor colorWithRed:0.35 green:0.78 blue:0.98 alpha:1],
        [UIColor colorWithRed:1 green:0.42 blue:0.60 alpha:1],
        [UIColor colorWithRed:0.37 green:0.55 blue:1 alpha:1],
    ];
    if (turn < 0.001) return base;
    NSMutableArray<UIColor *> *shifted = [NSMutableArray arrayWithCapacity:base.count];
    for (UIColor *color in base) [shifted addObject:sgr_shiftHue(color, turn)];
    return shifted;
}

// A few vivid hues from the cover, or nil when the picture is grey. One small bitmap, off the main thread.
static void sgr_colorsFromCover(UIImage *image, void (^done)(NSArray<UIColor *> *colors)) {
    CGImageRef cg = image.CGImage;
    if (!cg || !done) {
        if (done) done(nil);
        return;
    }
    CGImageRetain(cg);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const size_t n = 24;
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        uint8_t *px = calloc(n * n * 4, 1);
        CGContextRef ctx = CGBitmapContextCreate(px, n, n, 8, n * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(space);
        NSArray<UIColor *> *colors = nil;
        if (ctx) {
            CGContextDrawImage(ctx, CGRectMake(0, 0, n, n), cg);
            CGContextRelease(ctx);
            double score[12] = {0};
            for (size_t i = 0; i < n * n; i++) {
                CGFloat r = px[i * 4] / 255.0, g = px[i * 4 + 1] / 255.0, b = px[i * 4 + 2] / 255.0;
                if (px[i * 4 + 3] < 128) continue;
                CGFloat maxC = MAX(r, MAX(g, b)), minC = MIN(r, MIN(g, b));
                CGFloat sat = maxC > 0 ? (maxC - minC) / maxC : 0;
                if (sat < 0.28 || maxC < 0.18 || maxC > 0.97) continue;
                CGFloat hue = 0;
                CGFloat span = maxC - minC;
                if (maxC == r) hue = (g - b) / span;
                else if (maxC == g) hue = 2 + (b - r) / span;
                else hue = 4 + (r - g) / span;
                hue = fmod(hue / 6.0 + 1, 1);
                int bin = (int)(hue * 12) % 12;
                score[bin] += sat;
            }
            int best[3] = {-1, -1, -1};
            for (int pick = 0; pick < 3; pick++) {
                int found = -1;
                for (int bin = 0; bin < 12; bin++) {
                    if (score[bin] < 0.8) continue;
                    if (found < 0 || score[bin] > score[found]) found = bin;
                }
                if (found < 0) break;
                best[pick] = found;
                score[found] = 0;
            }
            if (best[1] >= 0) {
                NSMutableArray<UIColor *> *picked = [NSMutableArray array];
                for (int pick = 0; pick < 3 && best[pick] >= 0; pick++) {
                    CGFloat hue = (best[pick] + 0.5) / 12.0;
                    [picked addObject:[UIColor colorWithHue:hue saturation:0.72 brightness:1 alpha:1]];
                }
                if (picked.count >= 2) colors = picked;
            }
        }
        free(px);
        CGImageRelease(cg);
        dispatch_async(dispatch_get_main_queue(), ^{ done(colors); });
    });
}

static UIImage *sgr_glowRing(CGSize capsule, CGFloat spread) {
    CGSize size = CGSizeMake(capsule.width + spread * 2, capsule.height + spread * 2);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect edge = CGRectInset(CGRectMake(0, 0, size.width, size.height), spread, spread);
    edge = CGRectInset(edge, 1.5, 1.5);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:edge cornerRadius:edge.size.height / 2];
    CGContextSetShadowWithColor(ctx, CGSizeZero, 8, [UIColor colorWithWhite:1 alpha:0.95].CGColor);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.85].CGColor);
    CGContextSetLineWidth(ctx, 4);
    CGContextAddPath(ctx, path.CGPath);
    CGContextStrokePath(ctx);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

@implementation SGRPlayCapsule {
    UIImageView *_glyph;
    UILabel *_title;
    __weak UIImageView *_watchedGlyph;
    UIView *_glowHost;
    CALayer *_spin;
    CAGradientLayer *_glow;
    CALayer *_glowMask;
    NSString *_seed;
    UIImage *_glowImage;
    NSArray<UIColor *> *_glowColors;
    NSString *_glowWhy;
    NSUInteger _glowGeneration;
    CGFloat _maskW, _maskH;
    BOOL _mixGlow;
}

- (void)setMixGlow:(BOOL)on seed:(NSString *)seed image:(UIImage *)image {
    BOOL seedChanged = seed.length && ![seed isEqualToString:_seed];
    BOOL imageChanged = image && image != _glowImage;
    BOOL onChanged = on != _mixGlow;
    if (seedChanged) _seed = [seed copy];
    if (imageChanged) _glowImage = image;
    _mixGlow = on;
    if (onChanged || seedChanged || imageChanged) [self sgr_resolveGlowColors];
    [self sgr_updateGlow];
}

- (BOOL)mixGlow {
    return _mixGlow;
}

- (void)sgr_applyGlowColors:(NSArray<UIColor *> *)colors why:(NSString *)why {
    if (!colors.count) return;
    _glowColors = colors;
    _glowWhy = why;
    NSMutableArray *cg = [NSMutableArray arrayWithCapacity:colors.count + 1];
    for (UIColor *color in colors) [cg addObject:(id)color.CGColor];
    [cg addObject:(id)colors.firstObject.CGColor];
    _glow.colors = cg;
    SGLog(@"redesign playlist: play glow colours from %@ (%lu)", why, (unsigned long)colors.count);
}

- (void)sgr_resolveGlowColors {
    if (!_mixGlow) return;
    NSArray<UIColor *> *fallback = sgr_defaultGlow(sgr_seedTurn(_seed));
    NSString *why = _seed.length ? @"playlist id" : @"default";
    [self sgr_applyGlowColors:fallback why:why];
    UIImage *image = _glowImage;
    if (!image) return;
    NSUInteger generation = ++_glowGeneration;
    __weak SGRPlayCapsule *weakSelf = self;
    sgr_colorsFromCover(image, ^(NSArray<UIColor *> *colors) {
        SGRPlayCapsule *capsule = weakSelf;
        if (!capsule || generation != capsule->_glowGeneration || !colors.count) return;
        [capsule sgr_applyGlowColors:colors why:@"cover"];
    });
}

// The halo is a conic gradient spinning under a soft ring mask. The mask does not spin, so the
// capsule's shape stays put. No display link: both motions are CABasicAnimation.
- (void)sgr_updateGlow {
    BOOL reduce = UIAccessibilityIsReduceMotionEnabled();
    BOOL empty = self.bounds.size.width < 8 || self.bounds.size.height < 8;
    BOOL onScreen = NO;
    if (_mixGlow && self.window && !self.hidden && self.alpha > 0.01 && !empty) {
        CGRect shown = [self convertRect:self.bounds toView:self.window];
        onScreen = CGRectIntersectsRect(self.window.bounds, CGRectInset(shown, -8, -8));
    }
    NSString *why = !_mixGlow ? @"off" : !self.window ? @"no window" : empty ? @"empty bounds" : !onScreen ? @"off screen" : reduce ? @"reduce motion" : @"on";
    static NSString *lastWhy;
    if (![why isEqualToString:lastWhy]) {
        lastWhy = why;
        SGLog(@"redesign playlist: play glow %@ (bounds %@)", why, NSStringFromCGRect(self.bounds));
    }
    if (!_mixGlow || empty) {
        [_spin removeAllAnimations];
        [_glowHost removeFromSuperview];
        _glowHost = nil;
        _spin = nil;
        _glow = nil;
        _glowMask = nil;
        self.clipsToBounds = NO;
        return;
    }
    self.clipsToBounds = NO;
    if (!_glowHost) {
        _glowHost = [UIView new];
        _glowHost.userInteractionEnabled = NO;
        _glowHost.backgroundColor = UIColor.clearColor;
        _glowHost.accessibilityElementsHidden = YES;
        [self insertSubview:_glowHost atIndex:0];
        _spin = [CALayer layer];
        _glow = [CAGradientLayer layer];
        _glow.type = kCAGradientLayerConic;
        _glow.startPoint = CGPointMake(0.5, 0.5);
        _glow.endPoint = CGPointMake(0.5, 0);
        [_spin addSublayer:_glow];
        [_glowHost.layer addSublayer:_spin];
        _glowMask = [CALayer layer];
        _glowHost.layer.mask = _glowMask;
        if (!_glowColors) [self sgr_resolveGlowColors];
        else [self sgr_applyGlowColors:_glowColors why:_glowWhy ?: @"default"];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _glowHost.frame = CGRectInset(self.bounds, -kGlowSpread, -kGlowSpread);
    _glowHost.hidden = !onScreen;
    CGFloat side = hypot(_glowHost.bounds.size.width, _glowHost.bounds.size.height);
    _spin.bounds = CGRectMake(0, 0, side, side);
    _spin.position = CGPointMake(CGRectGetMidX(_glowHost.bounds), CGRectGetMidY(_glowHost.bounds));
    _glow.frame = _spin.bounds;
    _glowMask.frame = _glowHost.bounds;
    if (fabs(_maskW - self.bounds.size.width) > 0.5 || fabs(_maskH - self.bounds.size.height) > 0.5) {
        _maskW = self.bounds.size.width;
        _maskH = self.bounds.size.height;
        UIImage *ring = sgr_glowRing(self.bounds.size, kGlowSpread);
        _glowMask.contents = (__bridge id)ring.CGImage;
        _glowMask.contentsScale = ring.scale;
    }
    [CATransaction commit];
    if (!onScreen) {
        [_spin removeAnimationForKey:@"spin"];
        [_spin removeAnimationForKey:@"breathe"];
        return;
    }
    if (reduce) {
        [_spin removeAnimationForKey:@"spin"];
        [_spin removeAnimationForKey:@"breathe"];
        _spin.opacity = 0.9;
        return;
    }
    if (![_spin animationForKey:@"spin"]) {
        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @0;
        spin.toValue = @(6.283185307179586);
        spin.duration = 3.8;
        spin.repeatCount = HUGE_VALF;
        spin.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [_spin addAnimation:spin forKey:@"spin"];
    }
    if (![_spin animationForKey:@"breathe"]) {
        CABasicAnimation *breathe = [CABasicAnimation animationWithKeyPath:@"opacity"];
        breathe.fromValue = @0.72;
        breathe.toValue = @1;
        breathe.duration = 2.6;
        breathe.autoreverses = YES;
        breathe.repeatCount = HUGE_VALF;
        breathe.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_spin addAnimation:breathe forKey:@"breathe"];
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self sgr_updateGlow];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _glyph = [UIImageView new];
    _glyph.contentMode = UIViewContentModeScaleAspectFit;
    _glyph.userInteractionEnabled = NO;
    [self addSubview:_glyph];

    _title = [UILabel new];
    _title.userInteractionEnabled = NO;
    [self addSubview:_title];

    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    [self addTarget:self action:@selector(sgr_down) forControlEvents:UIControlEventTouchDown];
    [self addTarget:self action:@selector(sgr_up) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self addTarget:self action:@selector(sgr_tap) forControlEvents:UIControlEventTouchUpInside];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sgr_updateGlow)
                                               name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
    return self;
}

- (CGFloat)sgr_width {
    [_title sizeToFit];
    return kCapsuleLead + kGlyphSide + ceil(_title.bounds.size.width) + kCapsuleTrail;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    if (self.fillColor) {
        if (![self.backgroundColor isEqual:self.fillColor]) self.backgroundColor = self.fillColor;
        self.layer.cornerRadius = bounds.size.height / 2;
        self.layer.cornerCurve = kCACornerCurveContinuous;
    } else {
        SGRGlassCapsuleInside(self, &kCapsuleGlassKey, bounds.size, YES);
    }
    // Given more room than the word asks for, the glyph and the word stay together in the middle.
    CGFloat lead = kCapsuleLead + MAX(0, round((bounds.size.width - [self sgr_width]) / 2));
    _glyph.frame = CGRectMake(lead, round((bounds.size.height - kGlyphSide) / 2), kGlyphSide, kGlyphSide);
    // Spotify's glyph comes on a 48pt canvas and is scaled down into the frame; one drawn tight is shown at
    // its own size instead of blown up to fill it.
    CGSize image = _glyph.image.size;
    UIViewContentMode mode = image.width <= kGlyphSide && image.height <= kGlyphSide ? UIViewContentModeCenter : UIViewContentModeScaleAspectFit;
    if (_glyph.contentMode != mode) _glyph.contentMode = mode;
    [_title sizeToFit];
    CGSize text = _title.bounds.size;
    _title.frame = CGRectMake(CGRectGetMaxX(_glyph.frame), round((bounds.size.height - text.height) / 2),
                              MAX(0, bounds.size.width - kCapsuleTrail - CGRectGetMaxX(_glyph.frame)), text.height);
    if (_mixGlow) [self sgr_updateGlow];
}

- (void)feedFrom:(UIView *)source {
    if (!source) return;
    _source = source;

    NSString *word = wordIn(source);
    // The disc is as tall as the button, not always as wide: Liked Songs' is 80x48 with the 48pt disc at
    // x=16 (trees/continuous/1.txt, 2026-09-18), and matched by width the capsule drew no glyph at all.
    CGSize size = source.bounds.size;
    UIImageView *glyph = glyphIn(source, MIN(size.width, size.height));

    UIFont *font = SGRFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, UIContentSizeCategoryLarge);
    if (![_title.font isEqual:font]) _title.font = font;
    UIColor *content = self.contentColor ?: SGRAccent();
    if (![_title.textColor isEqual:content]) _title.textColor = content;
    if (word && ![_title.text isEqualToString:word]) {
        _title.text = word;
        self.accessibilityLabel = word;
        [self setNeedsLayout];
    }
    if (![_glyph.tintColor isEqual:content]) _glyph.tintColor = content;

    if (glyph.image && _glyph.image != glyph.image) {
        _glyph.image = [glyph.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            SGLog(@"redesign kit: play glyph %@ from %@, word \"%@\"", NSStringFromCGSize(glyph.image.size),
                  NSStringFromClass(glyph.class), word);
        });
    }
    // Play becomes pause without the header laying out again. Watched per glyph view rather than once for
    // good, so a glyph Spotify hands to another button reports to the button it is in now.
    if (glyph && glyph != _watchedGlyph) {
        _watchedGlyph = glyph;
        __weak SGRPlayCapsule *weakSelf = self;
        __weak UIView *weakSource = source;
        SGRObserveImage(glyph, ^(UIImageView *view) {
            if (weakSelf && weakSource) [weakSelf feedFrom:weakSource];
        });
    }
}

- (void)sgr_down {
    SGRAnimate(SGRMotionPress, ^{ self.transform = CGAffineTransformMakeScale(0.94, 0.94); }, nil);
}

- (void)sgr_up {
    SGRAnimate(SGRMotionPress, ^{ self.transform = CGAffineTransformIdentity; }, nil);
}

- (void)sgr_tap {
    SGRActivate(self.source);
}

@end

#pragma mark - a button standing in for Spotify's

// Whether a button that marks "on" with a small dot under its glyph (Encore's shuffle, a 4pt round view it
// hides while off) is on. `found` says whether the button has such a dot at all.
static BOOL indicatorOn(UIView *button, BOOL *found) {
    __block UIView *dot = nil;
    SGForEachView(button, ^(UIView *v) {
        if (dot || v == button || [v isKindOfClass:UIImageView.class] || [v isKindOfClass:UILabel.class]) return;
        CGSize size = v.bounds.size;
        if (size.width < 2 || size.width > 8 || size.height < 2 || size.height > 8) return;
        CGColorRef paint = v.layer.backgroundColor;
        if (paint && CGColorGetAlpha(paint) > 0.5) dot = v;
    });
    if (found) *found = dot != nil;
    for (UIView *up = dot; up && up != button; up = up.superview) {
        if (up.hidden || up.alpha <= 0.01) return NO;
    }
    return dot != nil;
}

@implementation SGRMirrorButton {
    UIImageView *_glyph;
    __weak UIImageView *_watchedGlyph;
    // Spotify's own image, as it was taken: what the copy is compared against, since a copy re-rendered as
    // a template is no longer the same object.
    UIImage *_takenGlyph;
    // Standing in for Spotify's download button: its state drawn, and read again while on screen.
    SGRDownloadGlyph *_download;
    NSTimer *_downloadTimer;
    // A two-state glyph drawn for Spotify (add-to, readState): 1 on, 0 off, -1 none drawn.
    NSInteger _stateShown;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _glyph = [UIImageView new];
    _glyph.contentMode = UIViewContentModeScaleAspectFit;
    _glyph.userInteractionEnabled = NO;
    [self addSubview:_glyph];
    _stateShown = -1;

    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    [self addTarget:self action:@selector(sgr_down) forControlEvents:UIControlEventTouchDown];
    [self addTarget:self action:@selector(sgr_up) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self addTarget:self action:@selector(sgr_tap) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    // Until its state is known the button draws nothing: a guess would flash the wrong glyph first.
    if (self.readState && _stateShown < 0) {
        ((UIView *)objc_getAssociatedObject(self, &kMirrorGlassKey)).hidden = YES;
        return;
    }
    SGRGlassInside(self, &kMirrorGlassKey, SGRGlassCircleSize);
    _glyph.frame = CGRectMake(round((bounds.size.width - kMirrorGlyph) / 2), round((bounds.size.height - kMirrorGlyph) / 2),
                              kMirrorGlyph, kMirrorGlyph);
    _download.frame = _glyph.frame;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!_download && _stateShown < 0 && !self.readState) return;
    // Read again on the way in -- the state may have moved on while the page was away -- and not at all
    // while out of the window.
    if (self.window && self.source) [self feedFrom:self.source];
    else [self sgr_followDownload:0];
}

- (void)dealloc {
    [_downloadTimer invalidate];
}

// Shows Spotify's download state; YES when `source` is a download button.
- (BOOL)sgr_feedDownloadFrom:(UIView *)source {
    SGRDownloadState state;
    CGFloat progress;
    if (!SGRReadDownload(source, &state, &progress)) {
        if (_download && !_download.hidden) {
            _download.hidden = YES;
            _glyph.hidden = NO;
            [self sgr_followDownload:0];
        }
        return NO;
    }
    if (!_download) {
        _download = [[SGRDownloadGlyph alloc] initWithFrame:_glyph.frame];
        [self addSubview:_download];
    }
    _download.hidden = NO;
    _glyph.hidden = YES;
    [_download showState:state progress:progress animated:YES];

    NSString *word = source.accessibilityLabel ?: wordIn(source);
    if (word && ![self.accessibilityLabel isEqualToString:word]) self.accessibilityLabel = word;
    NSString *value = state == SGRDownloadDownloading && progress >= 0
        ? [NSNumberFormatter localizedStringFromNumber:@(progress) numberStyle:NSNumberFormatterPercentStyle] : nil;
    if (![self.accessibilityValue ?: @"" isEqualToString:value ?: @""]) self.accessibilityValue = value;

    // Spotify lays nothing out that the page hears as a download moves on, so the state is read again:
    // twice a second while one runs, for the ring, and now and then otherwise, for one started or removed
    // from elsewhere (the ⋯ sheet). Only while the button is on screen.
    BOOL running = state == SGRDownloadWaiting || state == SGRDownloadDownloading;
    [self sgr_followDownload:self.window ? (running ? 0.5 : 2) : 0];
    return YES;
}

// Draws `offSymbol`, or `onSymbol` in the accent colour, switching between them in place.
- (void)sgr_showOn:(BOOL)on off:(NSString *)offSymbol on:(NSString *)onSymbol source:(UIView *)source {
    if (_stateShown != on) {
        UIImage *image = [UIImage systemImageNamed:on ? onSymbol : offSymbol];
        BOOL animated = _stateShown >= 0 && self.window && !SGRReduceMotion();
        BOOL first = _stateShown < 0;
        _stateShown = on;
        _takenGlyph = nil;
        _glyph.hidden = NO;
        if (@available(iOS 17.0, *)) {
            if (animated) [_glyph setSymbolImage:image withContentTransition:[NSSymbolReplaceContentTransition replaceDownUpTransition]];
            else _glyph.image = image;
        } else {
            _glyph.image = image;
        }
        // On is saved or followed, in the accent colour, as downloaded is.
        _glyph.tintColor = on ? SGRAccent() : SGRPrimary();
        if (first) [self setNeedsLayout];
    }
    NSString *word = source.accessibilityLabel ?: wordIn(source);
    if (word && ![self.accessibilityLabel isEqualToString:word]) self.accessibilityLabel = word;
    // Nothing is laid out when it changes from elsewhere (the ⋯ sheet), so it is read again as download is.
    [self sgr_followDownload:self.window ? 2 : 0];
}

// Shows whether Spotify's add-to button has its album or playlist saved; YES when `source` is one.
- (BOOL)sgr_feedAddToFrom:(UIView *)source {
    BOOL added;
    if (!SGRReadAddTo(source, &added)) {
        _stateShown = -1;
        return NO;
    }
    [self sgr_showOn:added off:@"plus" on:@"checkmark" source:source];
    return YES;
}

// Reads the state again every `interval` seconds; 0 stops.
- (void)sgr_followDownload:(NSTimeInterval)interval {
    if (interval <= 0) {
        [_downloadTimer invalidate];
        _downloadTimer = nil;
        return;
    }
    if (_downloadTimer.valid && fabs(_downloadTimer.timeInterval - interval) < 0.01) return;
    [_downloadTimer invalidate];
    __weak SGRMirrorButton *weakSelf = self;
    _downloadTimer = [NSTimer scheduledTimerWithTimeInterval:interval repeats:YES block:^(NSTimer *timer) {
        SGRMirrorButton *button = weakSelf;
        if (!button || !button.window || !button.source) {
            [timer invalidate];
            return;
        }
        [button feedFrom:button.source];
    }];
    _downloadTimer.tolerance = interval * 0.2;
}

// The glyph is taken as Spotify drew it, colour and all: the shuffle button turns its own glyph the accent
// colour while shuffle is on, and a copy rendered as a template would lose that.
- (void)feedFrom:(UIView *)source {
    if (!source) return;
    _source = source;

    if (self.readState) {
        BOOL on = NO;
        if (self.readState(&on)) [self sgr_showOn:on off:self.stateOffSymbol on:self.stateOnSymbol source:source];
        else [self sgr_followDownload:self.window ? 2 : 0];
        BOOL known = _stateShown >= 0;
        if (_glyph.hidden == known) _glyph.hidden = !known;
        if (self.userInteractionEnabled != known) {
            self.userInteractionEnabled = known;
            self.isAccessibilityElement = known;
        }
        return;
    }

    if ([self sgr_feedDownloadFrom:source]) return;
    if ([self sgr_feedAddToFrom:source]) return;

    UIImageView *glyph = glyphIn(source, 0);
    NSString *word = source.accessibilityLabel ?: wordIn(source);
    if (word && ![self.accessibilityLabel isEqualToString:word]) self.accessibilityLabel = word;
    // A button that says "on" with its dot is drawn in our colours, on and off. One expected to have a dot
    // and found without keeps Spotify's colours, which are then all that tells on from off.
    BOOL hasDot = NO;
    BOOL on = self.onGlyphColor && indicatorOn(source, &hasDot);
    UIColor *ownColor = !self.onGlyphColor ? self.glyphColor
                      : hasDot ? (on ? self.onGlyphColor : self.glyphColor ?: SGRPrimary()) : nil;
    if (glyph.image && (_takenGlyph != glyph.image || (ownColor != nil) != (_glyph.image.renderingMode == UIImageRenderingModeAlwaysTemplate))) {
        _takenGlyph = glyph.image;
        _glyph.image = ownColor ? [glyph.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] : glyph.image;
    }
    if (!glyph && self.fallbackGlyph && _glyph.image != self.fallbackGlyph) {
        _takenGlyph = nil;
        _glyph.image = self.fallbackGlyph;
    }
    UIColor *tint = ownColor ?: (glyph ? glyph.tintColor : SGRPrimary());
    if (tint && ![_glyph.tintColor isEqual:tint]) {
        // Turning on or off is a moment of its own: the colour fades across rather than jumping.
        BOOL fade = self.window && _glyph.tintColor && hasDot;
        if (fade) {
            [UIView transitionWithView:_glyph duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve
                            animations:^{ self->_glyph.tintColor = tint; } completion:nil];
        } else {
            _glyph.tintColor = tint;
        }
    }

    // As the capsule does: watched per glyph view, so a reused one reports where it is now.
    if (glyph && glyph != _watchedGlyph) {
        _watchedGlyph = glyph;
        __weak SGRMirrorButton *weakSelf = self;
        __weak UIView *weakSource = source;
        SGRObserveImage(glyph, ^(UIImageView *view) {
            if (weakSelf && weakSource) [weakSelf feedFrom:weakSource];
        });
    }
}

- (void)sgr_down {
    SGRAnimate(SGRMotionPress, ^{ self.transform = CGAffineTransformMakeScale(0.92, 0.92); }, nil);
}

- (void)sgr_up {
    SGRAnimate(SGRMotionPress, ^{ self.transform = CGAffineTransformIdentity; }, nil);
}

- (void)sgr_tap {
    SGRDownloadState download = SGRDownloadNone;
    CGFloat progress = -1;
    if (self.source && SGRReadDownload(self.source, &download, &progress) && download == SGRDownloadDownloaded) {
        SGLog(@"redesign kit: download tap ignored, already downloaded (%@)", self.source.accessibilityIdentifier);
        return;
    }
    SGRActivate(self.source);
    // The word is watched where Spotify writes it, but a button that rebuilds its content on the state it
    // just took writes the new word into a label the watch has never seen. So a tap, and only a tap, asks
    // the button again a moment later, which also moves the watch onto whatever label it ended up with. The
    // same goes for shuffle's dot and a download's state, which change with no image or word to watch.
    __weak SGRMirrorButton *weakSelf = self;
    for (NSNumber *delay in @[@0.3, @1.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SGRMirrorButton *button = weakSelf;
            if (button.source) [button feedFrom:button.source];
        });
    }
}

@end

#pragma mark - the page's pinned ⋯

// A mirror of the back button, which UIKit draws as a 44pt glass circle at the top of the safe area, 16pt
// in from the leading edge (trees/continuous/1.txt:2554: the navigation bar's own glass at {16, 0} 44x44,
// the bar itself at the safe area's top). ⋯ takes the same size and the same insets on the other side, so
// the two read as one row on every page (issue #57).
static const CGFloat kCornerSide = 16;

// The page whose pinned ⋯ was last tapped, and when: what tells the sheet that opens a moment later which
// page's menu it is. The same trick Shared/Player/SpeedPitchMenu.x plays on the player's more button, but
// from this side of it, since this button is the redesign's own and knows its own page.
//
// Recorded on touch down rather than on touch up: the button's own -sgr_tap is registered first and fires
// Spotify's ⋯ from the same event, so a sheet Spotify puts up in that same turn would ask which page it
// belonged to before a target added after -sgr_tap had answered.
static __weak UIView *sg_morePage;
static NSTimeInterval sg_moreTappedAt;
static char kRecorderKey;

UIView *SGRPinnedMoreRecentPage(void) {
    if (!sg_morePage || CACurrentMediaTime() - sg_moreTappedAt > SGRPinnedMoreWindow) return nil;
    return sg_morePage;
}

@interface SGRPinnedMoreRecorder : NSObject
@end
@implementation SGRPinnedMoreRecorder
- (void)sgr_moreTapped:(SGRMirrorButton *)button {
    sg_morePage = button.superview;
    sg_moreTappedAt = CACurrentMediaTime();
}
@end

SGRMirrorButton *SGRPinnedMore(UIView *page, const void *key, UIView *source) {
    if (!page) return nil;
    SGRMirrorButton *button = objc_getAssociatedObject(page, key);
    if (!button) {
        button = [[SGRMirrorButton alloc] initWithFrame:CGRectZero];
        button.fallbackGlyph = [UIImage systemImageNamed:@"ellipsis"];
        // ⋯ sits in an Encore Tertiary button in Spotify's own row, which draws it grey; in the corner of
        // the page it is the one control there and reads white, like the back button opposite it.
        button.glyphColor = SGRPrimary();
        // Held by the button, which is held by the page, so the recorder lives exactly as long as both.
        SGRPinnedMoreRecorder *recorder = [SGRPinnedMoreRecorder new];
        objc_setAssociatedObject(button, &kRecorderKey, recorder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [button addTarget:recorder action:@selector(sgr_moreTapped:) forControlEvents:UIControlEventTouchDown];
        objc_setAssociatedObject(page, key, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Over the page's list and its header both, and put back on top whenever Spotify adds to the page -- under
    // the curtain while the page has one, so it comes in with the rest of the page.
    if (button.superview != page) [page addSubview:button];
    SGRRevealBringToFront(page, button);
    if (source) [button feedFrom:source];
    if (button.hidden != (source == nil)) button.hidden = source == nil;

    // Measured in the window and converted back, never from the page's own safe area: a page under a
    // navigation bar counts the bar into its inset, so the playlist's read 116 where the window's reads 62
    // and the button sat a bar's height below the back button (device, trees/continuous/1.txt 2026-09-20).
    UIWindow *window = page.window;
    CGFloat side = SGRGlassCircleSize;
    CGRect frame;
    if (window) {
        CGRect inWindow = CGRectMake(window.bounds.size.width - kCornerSide - side, window.safeAreaInsets.top, side, side);
        frame = [page convertRect:inWindow fromView:nil];
    } else {
        frame = CGRectMake(page.bounds.size.width - kCornerSide - side, page.safeAreaInsets.top, side, side);
    }
    if (!CGRectIsEmpty(frame) && !CGRectEqualToRect(button.frame, frame)) button.frame = frame;
    return button;
}
