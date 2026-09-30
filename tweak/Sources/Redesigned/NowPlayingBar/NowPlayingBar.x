// The redesign's now playing bar: the album-coloured card becomes a glass card with round artwork and the
// progress line under the text. Spotify's own labels, buttons and gestures stay in place.
//
// The full screen player morphs the bar's own card and artwork into the cover art. The bar was
// written to hand itself back to Spotify for that animation, from NowPlaying_ViewPageImpl's
// Show/CloseFullscreenAnimatedTransitioning, but Spotify 9.1.78 never runs the player through those,
// so the handback never happened and is gone; if the morph ever reads as a cut, the place to start is
// Shared/Player/PlayerEvents.h, which does fire. What does move with the player is a stand-in of the
// bar, which BarTransition.x keeps glass behind.
//
// Tree (trees/home.txt): NowPlayingBarContainerViewController.view 402x56 > NowPlayingBarViewController.view
//   at {8,0} 386x56 > UIView 386x56 (the painted card) > artwork 40x40 r=4, title stack,
//   progress line 370x2 at the bottom. The glass pane goes on the container's view.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRRepaint.h"
#import "Redesigned/Navbar/Navbar.h"
#import "Shared/Player/PlayerEvents.h"
#import "NowPlayingBar.h"

static const CGFloat kCardRadius = 24;
static char kGlassKey;
static __weak UIVisualEffectView *sg_cardGlass;
static __weak UIView *sg_cardArtwork;
static __weak UIView *sg_barContainer;

BOOL SGRInlinePlayer(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGRedesignedUI() && SGHidden(SGRKeyInlinePlayer); });
    return on;
}

CGRect SGRNowPlayingCardFrameIn(UIView *host, CGFloat *radius) {
    if (SGRInlinePlayer()) return SGRMiniPlayerFrameIn(host, radius);
    UIVisualEffectView *glass = sg_cardGlass;
    if (!glass.superview || !glass.window || !host) return CGRectNull;
    if (radius) *radius = MIN(kCardRadius, glass.bounds.size.height / 2);
    return [host convertRect:glass.bounds fromView:glass];
}

CGRect SGRNowPlayingArtworkFrameIn(UIView *host) {
    if (SGRInlinePlayer()) return SGRMiniPlayerArtworkFrameIn(host);
    UIView *artwork = sg_cardArtwork;
    if (!artwork.window || !host) return CGRectNull;
    return [host convertRect:artwork.bounds fromView:artwork];
}

// The image view inside the artwork restyleCardContent found, or else the bar's first square picture.
UIImageView *SGRNowPlayingArtworkView(void) {
    __block UIImageView *found = nil;
    void (^look)(UIView *) = ^(UIView *root) {
        if (!root) return;
        SGForEachView(root, ^(UIView *v) {
            if (found || ![v isKindOfClass:UIImageView.class]) return;
            CGSize size = v.bounds.size;
            if (size.width >= 30 && size.width <= 64 && fabs(size.width - size.height) < 1) found = (UIImageView *)v;
        });
    };
    UIView *artwork = sg_cardArtwork;
    if ([artwork isKindOfClass:UIImageView.class]) return (UIImageView *)artwork;
    look(artwork);
    if (!found) look(sgr_nowPlayingRoot);
    return found;
}

UIImage *SGRNowPlayingArtworkImage(void) {
    return SGRNowPlayingArtworkView().image;
}

// Spotify's bar opens the player from a tap recognizer on the card. The card is the wide view
// (trees/home.txt: the bar is 386pt, its buttons are not). A narrower recognizer is a control: firing
// it used to count as success and the player never presented. Recognizers above the bar are not the
// card either, so the walk stays inside the bar's container.
static const CGFloat kOpenTapWidth = 120;
static const CGFloat kOpenTapFraction = 0.75;

static BOOL hasOpenTap(UIView *view) {
    for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
        if ([recognizer isKindOfClass:UITapGestureRecognizer.class] && recognizer.enabled) return YES;
    }
    return NO;
}

static BOOL wideEnough(UIView *view, CGFloat barWidth) {
    CGFloat width = view.bounds.size.width;
    if (barWidth >= 100) return width >= barWidth * kOpenTapFraction;
    return width >= kOpenTapWidth;
}

// Fires only the widest card-sized tap. YES when a recognizer was invoked, which is not the same as
// the player being on screen: the caller checks that and tries again.
static BOOL fireOpen(UIView *container) {
    if (!container) return NO;
    CGFloat barWidth = container.bounds.size.width;
    UIView *best = nil;
    CGFloat bestWidth = 0;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:container];
    while (queue.count) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        [queue addObjectsFromArray:view.subviews];
        if (!wideEnough(view, barWidth) || !hasOpenTap(view)) continue;
        CGFloat width = view.bounds.size.width;
        if (width <= bestWidth) continue;
        bestWidth = width;
        best = view;
    }
    if (!best) return NO;
    // The bar is left untouchable so it cannot sit over the mini player. Spotify's handler is invoked
    // directly; interaction is put back for that call in case the handler checks it.
    BOOL was = container.userInteractionEnabled;
    BOOL bestWas = best.userInteractionEnabled;
    container.userInteractionEnabled = YES;
    best.userInteractionEnabled = YES;
    BOOL fired = SGRFireTapRecognizers(best);
    best.userInteractionEnabled = bestWas;
    container.userInteractionEnabled = was;
    if (fired) SGLog(@"mini player: tap passed to %@ (%.0fpt of %.0f)", NSStringFromClass(best.class), bestWidth, barWidth);
    return fired;
}

static void logMissingOpen(UIView *container) {
    NSMutableString *out = [NSMutableString stringWithString:@"mini player: no card-sized tap recognizer on Spotify's bar"];
    SGForEachView(container, ^(UIView *v) {
        for (UIGestureRecognizer *r in v.gestureRecognizers) {
            [out appendFormat:@"\n  %@ on %@ %.0fpt", r, NSStringFromClass(v.class), v.bounds.size.width];
        }
    });
    SGLogLong(@"mini player", out);
}

static NSUInteger sg_openToken;
static CFTimeInterval sg_openBegan;
static BOOL sg_pursuing;
static const NSUInteger kOpenTries = 4;

// Retries never postpone the first fire. A leftover close, or a present that never reached
// viewDidAppear, used to sit in this function for up to a second (the stuck-transition watchdog)
// before Spotify's tap ran, which is the open that feels late. A transition that began with this
// tap is the present itself: firing again would toggle the player, so that one is given a moment.
static void pursueOpen(NSUInteger token, NSUInteger fires) {
    if (token != sg_openToken) return;
    if (SGPlayerIsOnScreen()) {
        sg_pursuing = NO;
        SGLog(@"mini player: open succeeded");
        return;
    }
    if (fires >= kOpenTries) {
        sg_pursuing = NO;
        SGLog(@"mini player: open gave up after %lu tries", (unsigned long)fires);
        logMissingOpen(sg_barContainer);
        return;
    }
    CFTimeInterval began = SGPlayerTransitionBegan();
    BOOL fromThisTap = fires > 0 && began >= sg_openBegan - 0.02 && (SGPlayerIsAppearing() || SGPlayerTransitionEnds() > 0);
    if (fromThisTap && CACurrentMediaTime() - began < 0.8) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            pursueOpen(token, fires);
        });
        return;
    }
    if (fromThisTap) {
        SGLog(@"mini player: open retry, the transition did not put the player up");
        SGPlayerTransitionResetStuck();
    }
    BOOL fired = fireOpen(sg_barContainer);
    SGLog(@"mini player: open try %lu %@", (unsigned long)(fires + 1), fired ? @"fired Spotify's tap" : @"no wide tap");
    // A tap that ran is given time to present before another, which would toggle the player.
    // A missing recognizer is tried again on the next layout, without waiting out the watchdog.
    NSTimeInterval delay = fired ? 0.45 : 0.05;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        pursueOpen(token, fires + 1);
    });
}

BOOL SGROpenPlayerFromBar(void) {
    SGLog(@"mini player: open requested");
    if (SGPlayerIsOnScreen()) {
        SGLog(@"mini player: the player is already on screen");
        return YES;
    }
    // A second tap while the present from this one is in flight would toggle the player shut.
    // The window is the present, not the old one-second wait that also blocked the first fire.
    if (sg_pursuing && CACurrentMediaTime() - sg_openBegan < 0.45
        && SGPlayerTransitionBegan() >= sg_openBegan - 0.02
        && (SGPlayerIsAppearing() || SGPlayerTransitionEnds() > 0)) {
        SGLog(@"mini player: open already in flight");
        return YES;
    }
    NSUInteger token = ++sg_openToken;
    sg_openBegan = CACurrentMediaTime();
    sg_pursuing = YES;
    pursueOpen(token, 0);
    return YES;
}

static UIView *detectColoredCard(UIView *bar) {
    __block UIView *best = nil;
    __block CGFloat bestArea = 0;
    SGForEachView(bar, ^(UIView *v) {
        if ([v isKindOfClass:UIVisualEffectView.class] || SGKeepsColor(v) || !SGLooksLikeCard(v, v.layer.backgroundColor)) return;
        CGFloat area = v.bounds.size.width * v.bounds.size.height;
        if (area > bestArea) { bestArea = area; best = v; }
    });
    return best;
}

// Fallback when nothing is painted: the box around artwork, text and the small buttons.
static CGRect contentBounds(UIView *bar, UIView *target) {
    __block CGRect box = CGRectNull;
    SGForEachView(bar, ^(UIView *v) {
        if (v.hidden || v.alpha == 0) return;
        CGFloat width = v.bounds.size.width;
        BOOL content = ([v isKindOfClass:UIImageView.class] && width >= 20 && width <= 120)
            || [v isKindOfClass:UILabel.class]
            || ([v isKindOfClass:UIControl.class] && width <= 100);
        if (content) box = CGRectUnion(box, SGFrameIn(v, target));
    });
    return CGRectIsNull(box) ? box : CGRectInset(box, -10, -8);
}

static void roundView(UIView *view, CGFloat radius) {
    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
}

static void restyleCardContent(UIView *card) {
    SGForEachView(card, ^(UIView *v) {
        CGSize size = v.bounds.size;
        BOOL square = size.width >= 36 && size.width <= 48 && fabs(size.width - size.height) < 1;
        if (!square || v.layer.cornerRadius <= 0) return;
        if (v.layer.cornerRadius >= size.width / 2) {
            if (!sg_cardArtwork) sg_cardArtwork = v;
            return;
        }
        UIView *outer = v;
        for (UIView *u = v; u && u != card && CGSizeEqualToSize(u.bounds.size, size); u = u.superview) {
            roundView(u, size.width / 2);
            u.clipsToBounds = YES;
            outer = u;
        }
        sg_cardArtwork = outer;
    });
    SGForEachView(card, ^(UIView *v) {
        CGRect f = v.frame;
        if (f.size.height > 3 || f.size.width < 200 || v.superview.bounds.size.height < 40) return;
        CGRect target = CGRectMake(52, card.bounds.size.height - 6, 226, 2);
        if (CGRectEqualToRect(f, target)) return;
        v.frame = target;
        [v setNeedsLayout];
        [v layoutIfNeeded];
    });
}

static void styleNowPlayingBar(UIViewController *container) {
    UIViewController *barVC = container.childViewControllers.firstObject;
    UIView *bar = barVC.viewIfLoaded ?: container.view;
    sgr_nowPlayingRoot = bar;
    sg_barContainer = container.view;
    // The mini player in the tab bar takes the bar's place: Spotify's bar stays, laid out and loading its
    // artwork for the mini player, but nobody sees or touches it.
    // The bar's page (NowPlaying_BarPageImpl's TouchPassthroughView) stands over the tab bar container
    // where the expanded mini player is, and took its touches (harness/tabbar), so it takes none either;
    // the bar is all it holds.
    if (SGRInlinePlayer()) {
        if (container.view.alpha != 0) container.view.alpha = 0;
        if (container.view.userInteractionEnabled) container.view.userInteractionEnabled = NO;
        for (UIView *v = container.view.superview; v && ![v isKindOfClass:UIWindow.class]; v = v.superview) {
            if (![NSStringFromClass(v.class) containsString:@"TouchPassthroughView"]) continue;
            if (v.userInteractionEnabled) v.userInteractionEnabled = NO;
            break;
        }
    }

    UIView *card = sgr_nowPlayingCard;
    if (!card || !SGIsInside(card, bar)) card = sgr_nowPlayingCard = detectColoredCard(bar);

    container.view.layer.backgroundColor = NULL;
    SGStripBackgrounds(bar);

    CGRect frame = card ? SGFrameIn(card, container.view) : contentBounds(bar, container.view);
    if (CGRectIsNull(frame)) return;
    frame.size.height = MIN(frame.size.height, 80);
    if (frame.size.height < 30 || frame.size.width < 100) return;

    CGFloat radius = MIN(kCardRadius, frame.size.height / 2);
    if (card) {
        roundView(card, radius);
        restyleCardContent(card);
    }

    UIVisualEffectView *glass = SGGlassFor(container.view, &kGlassKey);
    // Dark whatever the system is set to: the bar is outside the navigation stacks Spotify makes dark, and
    // took the system's light glass on a phone in light mode (TabBar.x).
    if (glass.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) glass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    sg_cardGlass = glass;
    glass.frame = frame;
    SGShapeGlass(glass, radius, NO);

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGLog(@"now playing card %@ at %@ (bar %@, container %@)", card.class, NSStringFromCGRect(frame),
              NSStringFromCGRect(bar.frame), NSStringFromCGRect(container.view.bounds));
    });
}

%hook _TtC18NowPlaying_BarImpl36NowPlayingBarContainerViewController
- (void)viewDidLayoutSubviews {
    %orig;
    styleNowPlayingBar((UIViewController *)self);
}
%end

%hook _TtC18NowPlaying_BarImpl27NowPlayingBarViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIViewController *parent = ((UIViewController *)self).parentViewController;
    if ([NSStringFromClass(parent.class) containsString:@"NowPlayingBarContainer"]) styleNowPlayingBar(parent);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC18NowPlaying_BarImpl36NowPlayingBarContainerViewController",
        @"_TtC18NowPlaying_BarImpl27NowPlayingBarViewController",
    ]);
}
