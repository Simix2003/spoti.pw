// The player's open and close, told from the appearance callbacks of a controller inside the player,
// which UIKit sends as the presentation or the dismissal begins, whatever animates it; the transition
// coordinator says when it is over, a cancelled swipe included. Spotify 9.1.78 presents the player
// through SPTBarInteractivePresentationController, never through NowPlaying_ViewPageImpl's
// Show/CloseFullscreenAnimatedTransitioning animators, whose hooks never once fired.
#import "Core/SGCore.h"
#import "PlayerEvents.h"

NSString *const SGPlayerTransitionNotification = @"spotifyglass.playerTransition";
NSString *const SGPlayerTransitionEndedNotification = @"spotifyglass.playerTransitionEnded";
static CFTimeInterval sg_transitionEnds;
static CFTimeInterval sg_transitionBegan;
static NSUInteger sg_transitionGeneration;
static NSUInteger sg_appearGeneration;
static BOOL sg_onScreen;
static BOOL sg_appearing;

CFTimeInterval SGPlayerTransitionEnds(void) {
    return sg_transitionEnds > CACurrentMediaTime() ? sg_transitionEnds : 0;
}

BOOL SGPlayerIsOnScreen(void) {
    return sg_onScreen;
}

BOOL SGPlayerIsAppearing(void) {
    return sg_appearing;
}

static void postTransitionEnded(void) {
    [NSNotificationCenter.defaultCenter postNotificationName:SGPlayerTransitionEndedNotification object:nil];
}

void SGPlayerTransitionResetStuck(void) {
    if (sg_onScreen) return;
    BOOL pending = sg_transitionEnds != 0 || sg_appearing;
    if (!pending) return;
    CFTimeInterval age = sg_transitionBegan > 0 ? CACurrentMediaTime() - sg_transitionBegan : 1;
    // The call arrives from a 1s timer. The begin time is stamped again as the coordinator is read,
    // so the age can sit a frame under a second.
    if (age < 0.95) return;
    SGLog(@"player transition: stuck %.2fs in (appearing %d), clearing", age, sg_appearing);
    sg_transitionGeneration++;
    sg_appearGeneration++;
    sg_transitionEnds = 0;
    sg_transitionBegan = 0;
    sg_appearing = NO;
    postTransitionEnded();
}

static void announceTransition(UIViewController *unit, BOOL animated, NSString *what) {
    id<UIViewControllerTransitionCoordinator> coordinator = unit.transitionCoordinator;
    if (!animated || !coordinator) return;
    NSTimeInterval duration = MAX(0.1, coordinator.transitionDuration);
    NSUInteger generation = ++sg_transitionGeneration;
    sg_transitionBegan = CACurrentMediaTime();
    sg_transitionEnds = sg_transitionBegan + duration;
    [NSNotificationCenter.defaultCenter postNotificationName:SGPlayerTransitionNotification object:nil];
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (generation != sg_transitionGeneration) return;
        sg_transitionEnds = 0;
        postTransitionEnded();
        SGLog(@"player transition: %@ finished (cancelled %d)", what, context.isCancelled);
    }];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"player %@ over %.2fs, by its appearance callbacks", what, duration); });
}

%hook _TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    sg_appearing = YES;
    sg_transitionBegan = CACurrentMediaTime();
    NSUInteger generation = ++sg_appearGeneration;
    announceTransition((UIViewController *)self, animated, @"opens");
    // A present that never reaches viewDidAppear used to leave the open path believing a
    // transition was still running, so later taps were not tried again.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != sg_appearGeneration || sg_onScreen || !sg_appearing) return;
        SGPlayerTransitionResetStuck();
    });
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    sg_onScreen = YES;
    sg_appearing = NO;
    sg_appearGeneration++;
    SGLog(@"player transition: on screen");
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    sg_onScreen = NO;
    sg_appearing = NO;
    sg_appearGeneration++;
    announceTransition((UIViewController *)self, animated, @"closes");
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    sg_onScreen = NO;
    sg_appearing = NO;
    SGLog(@"player transition: off screen");
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController"]);
}
