// The redesign's search page: the white search field becomes a glass capsule with white text.
//
// Tree (trees/search.txt): SearchHeaderFind.SearchBar, a 370x48 Encore tertiary button painted
// white, r=6, holding SearchHeaderFind.SearchBarIcon and the placeholder label. The button class is
// shared app-wide, so the identifier names the one instance the page owns, with a wide light button
// as the fallback for a build that stops setting it.
//
// Two things about the colours. The glyph is an SPTEncoreIconView, which bakes its colour into what
// it draws, so tintColor never reaches it and setForegroundColor: is the way in. And coming back
// from the full screen search (trees/search opened.txt, a page of its own that this leaves alone)
// Spotify configures the field for a white background again, black glyph and black text, after the
// layout pass that styled it: both are then invisible on the glass until the next pass, a second or
// so later. So the two setters are refused for as long as the field is a capsule.
#import "Core/SGCore.h"
#import "Diagnostics/Diagnostics.h"
#import "Redesigned/Kit/SGRRestyle.h"

// Spotify's glyph view, resolved at runtime; declared on UIView so the call and the hook below
// share one declaration.
@interface UIView (SGEncoreIcon)
- (void)setForegroundColor:(UIColor *)color;
@end

static char kStyledKey;
static __weak UIView *sg_searchField;

static BOOL isSearchField(UIView *button) {
    if ([button.accessibilityIdentifier isEqualToString:@"SearchHeaderFind.SearchBar"]) return YES;
    return SGIsLightColor(button.layer.backgroundColor);
}

static void whiten(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) {
        ((UILabel *)view).textColor = UIColor.whiteColor;
    } else if ([NSStringFromClass(view.class) containsString:@"IconView"]) {
        if ([view respondsToSelector:@selector(setForegroundColor:)]) [view setForegroundColor:UIColor.whiteColor];
        else view.tintColor = UIColor.whiteColor;
    }
}

// Debug builds only. The second the field stays invisible after the full screen search closes is
// too short to catch in a tree, so every pass over the field says what it looked like, and the
// silence before the first line says the field did not exist yet.
static void traceField(UIView *button, NSString *when) {
    if (!SGIsDebugBuild()) return;
    UIView *pane = nil, *dim = nil;
    for (UIView *sub in button.subviews) {
        if ([sub isKindOfClass:UIVisualEffectView.class]) pane = sub;
    }
    for (UIView *v = button; v && !dim; v = v.superview) {
        if (v.hidden || v.alpha < 0.99) dim = v;
    }
    SGLog(@"search field %@: window %d, %@, pane %@, hidden by %@", when, button.window != nil,
          NSStringFromCGSize(button.bounds.size), pane ? @"attached" : @"missing",
          dim ? NSStringFromClass(dim.class) : @"nothing");
}

// traceField only says what the field looked like at a layout pass, and the second it is invisible
// for holds no layout pass at all: coming back from the full screen search the last pass before it
// lands is 1077ms earlier (a log of three trips in and out). So the field is put on a clock of its
// own as well, sampled every 50ms for the two seconds after it comes back into a window, which is
// the window the glitch lives in. Debug builds only, like the rest of the tracing.
static void sampleField(__weak UIView *weakButton, int step) {
    UIView *button = weakButton;
    if (!button || step > 40) return;
    UIWindow *window = button.window;
    UIView *dim = nil;
    for (UIView *v = button; v && !dim; v = v.superview) {
        if (v.hidden || v.alpha < 0.99) dim = v;
    }
    UIView *pane = nil;
    for (UIView *sub in button.subviews) {
        if ([sub isKindOfClass:UIVisualEffectView.class]) pane = sub;
    }
    CGColorRef fill = button.layer.backgroundColor;
    SGLog(@"search field +%4dms: window %d, in window %@, alpha %.2f hidden %d, dimmed by %@, pane %@ alpha %.2f, fill alpha %.2f, radius %.1f",
          step * 50, window != nil,
          NSStringFromCGRect([button convertRect:button.bounds toView:window]),
          button.alpha, button.hidden, dim ? NSStringFromClass(dim.class) : @"nothing",
          pane ? @"attached" : @"missing", pane ? pane.alpha : -1,
          fill ? CGColorGetAlpha(fill) : -1, button.layer.cornerRadius);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        sampleField(weakButton, step + 1);
    });
}

// One burst per arrival, so three trips in and out read as three bursts rather than three overlaid.
static void traceFieldArriving(UIView *button) {
    if (!SGIsDebugBuild() || !button.window) return;
    static NSTimeInterval last;
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - last < 2.5) return;
    last = now;
    sampleField(button, 0);
}

// The Search header's field is 48pt (trees/search.txt). The row it shares with Cancel once search is
// open is shorter than that, so both grow to the header's height. Anything already there is left.
static const CGFloat kSearchChromeHeight = 52;
static NSInteger sgr_focusGeneration;

static NSString *cancelWord(void) {
    static NSString *word;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UISearchBar *bar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, 320, 56)];
        bar.showsCancelButton = YES;
        [bar layoutIfNeeded];
        __block NSString *title = nil;
        SGForEachView(bar, ^(UIView *v) {
            if (title || ![v isKindOfClass:UIButton.class]) return;
            NSString *text = [(UIButton *)v currentTitle];
            if (text.length) title = text;
        });
        word = title.length ? [title copy] : @"Cancel";
    });
    return word;
}

static BOOL isCancelControl(UIView *view) {
    if (view.bounds.size.width < 24 || view.bounds.size.width > 160 || view.bounds.size.height < 16) return NO;
    NSString *ident = view.accessibilityIdentifier ?: @"";
    if ([ident rangeOfString:@"cancel" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    NSString *word = cancelWord();
    NSString *label = view.accessibilityLabel;
    if (label.length && [label rangeOfString:word options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([view isKindOfClass:UIButton.class]) {
        NSString *title = [(UIButton *)view currentTitle];
        if (title.length && [title rangeOfString:word options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL isField(UIView *view) {
    if ([view isKindOfClass:UITextField.class] || [view isKindOfClass:UISearchBar.class]) return YES;
    NSString *ident = view.accessibilityIdentifier ?: @"";
    return [ident isEqualToString:@"SearchHeaderFind.SearchBar"] || [ident rangeOfString:@"SearchField" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL insideSettings(UIView *view) {
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class] && [NSStringFromClass(responder.class) containsString:@"SGPage"]) return YES;
    }
    return NO;
}

static void growToChrome(UIView *view) {
    if (!view || view.bounds.size.height < 16 || view.bounds.size.height >= kSearchChromeHeight - 0.5) return;
    for (NSLayoutConstraint *constraint in view.constraints) {
        if (constraint.firstItem == view && constraint.firstAttribute == NSLayoutAttributeHeight && !constraint.secondItem
            && constraint.constant > 0 && constraint.constant < kSearchChromeHeight) {
            constraint.constant = kSearchChromeHeight;
        }
    }
    CGRect frame = view.frame;
    CGFloat delta = kSearchChromeHeight - frame.size.height;
    frame.origin.y -= delta / 2.0;
    frame.size.height = kSearchChromeHeight;
    view.frame = frame;
    if (view.layer.cornerRadius > 0 && view.layer.cornerRadius < kSearchChromeHeight / 2.0) {
        view.layer.cornerRadius = kSearchChromeHeight / 2.0;
        view.layer.cornerCurve = kCACornerCurveContinuous;
    }
}

static void raiseRow(UIView *row) {
    growToChrome(row);
    SGForEachView(row, ^(UIView *view) {
        if (view != row && (isField(view) || isCancelControl(view))) growToChrome(view);
    });
}

static BOOL rowIsSearchChrome(UIView *view) {
    if (view.bounds.size.width < 200 || view.bounds.size.height < 16 || view.bounds.size.height >= kSearchChromeHeight - 0.5) return NO;
    if (insideSettings(view)) return NO;
    __block BOOL field = NO, cancel = NO;
    SGForEachView(view, ^(UIView *sub) {
        if (sub != view && isField(sub)) field = YES;
        if (sub != view && isCancelControl(sub)) cancel = YES;
    });
    return field && cancel;
}

static void raiseSearchChrome(UIView *root, BOOL force) {
    if (!root) return;
    static CFTimeInterval last;
    CFTimeInterval now = CACurrentMediaTime();
    if (!force && now - last < 0.1) return;
    last = now;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger seen = 0;
    while (queue.count && seen < 500) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        seen++;
        if (view.hidden || view.alpha < 0.01) continue;
        if ([view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UITableView.class]) continue;
        if ([view isKindOfClass:UISearchBar.class] && !insideSettings(view)) {
            UISearchBar *bar = (UISearchBar *)view;
            growToChrome(bar);
            growToChrome(bar.searchTextField);
            for (UIView *sub in bar.subviews) {
                SGForEachView(sub, ^(UIView *candidate) {
                    if (isCancelControl(candidate)) growToChrome(candidate);
                });
            }
        }
        if (rowIsSearchChrome(view)) raiseRow(view);
        [queue addObjectsFromArray:view.subviews];
    }
}

void SGRRaiseSearchChrome(UIView *root) {
    raiseSearchChrome(root, NO);
}

static UIView *searchButtonIn(UIView *root) {
    __block UIView *found = nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count && !found) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (view != root && ([view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UITableView.class])) continue;
        if ([view.accessibilityIdentifier isEqualToString:@"SearchHeaderFind.SearchBar"] && view.window && !view.hidden && view.alpha > 0.01)
            found = view;
        else [queue addObjectsFromArray:view.subviews];
    }
    return found;
}

static BOOL searchFieldEditing(UIView *root) {
    __block BOOL editing = NO;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger seen = 0;
    while (queue.count && !editing && seen < 500) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        seen++;
        if ([view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UITableView.class]) continue;
        if ([view isKindOfClass:UITextField.class] && ((UITextField *)view).isFirstResponder) editing = YES;
        else [queue addObjectsFromArray:view.subviews];
    }
    return editing;
}

static void focusAttempt(NSInteger generation, int attempt) {
    if (generation != sgr_focusGeneration) return;
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (!candidate.hidden && candidate.windowLevel == UIWindowLevelNormal) window = candidate;
        }
    }
    if (!window) {
        if (attempt >= 12) {
            SGLog(@"search tab: result field not on screen");
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            focusAttempt(generation, attempt + 1);
        });
        return;
    }
    if (searchFieldEditing(window)) {
        raiseSearchChrome(window, YES);
        SGLog(@"search tab: result field is editing");
        return;
    }
    UIView *button = searchButtonIn(window);
    static NSInteger activationsFor;
    static int activations;
    if (activationsFor != generation) {
        activationsFor = generation;
        activations = 0;
    }
    // The header button is often missing on the first turns. Activate when it appears, and twice
    // more if that did not leave a field editing: one shot used to be the end of the attempt.
    if (button && activations < 3 && (activations == 0 || attempt == 4 || attempt == 8)) {
        activations++;
        SGLog(@"search tab: field focus attempted (%d) %@", attempt, button.accessibilityIdentifier);
        SGRActivate(button);
        raiseSearchChrome(window, YES);
    }
    if (attempt >= 12) {
        SGLog(@"search tab: result %@", button ? @"field did not focus" : @"field not on screen");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        focusAttempt(generation, attempt + 1);
    });
}

void SGRFocusSearchPage(void) {
    NSInteger generation = ++sgr_focusGeneration;
    SGLog(@"search tab: field focus attempted");
    dispatch_async(dispatch_get_main_queue(), ^{ focusAttempt(generation, 0); });
}

void SGRCancelSearchFocus(void) {
    sgr_focusGeneration++;
}

static void styleSearchField(UIView *button) {
    CGSize size = button.bounds.size;
    if (size.width < 200 || size.height < 40 || size.height > 60) return;
    BOOL styled = [objc_getAssociatedObject(button, &kStyledKey) boolValue];
    if (!styled && !isSearchField(button)) return;
    objc_setAssociatedObject(button, &kStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (sg_searchField != button) sg_searchField = button;

    button.layer.backgroundColor = NULL;
    button.layer.cornerRadius = size.height / 2;
    button.layer.cornerCurve = kCACornerCurveContinuous;

    UIVisualEffectView *glass = SGGlassAt(button, 0);
    // Dark like every glass of the redesign's, rather than by grace of the navigation stack Spotify hosts
    // the page in (TabBar.x).
    if (glass.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) glass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    glass.frame = button.bounds;
    SGShapeGlass(glass, size.height / 2, YES);

    SGForEachView(button, ^(UIView *v) { whiten(v); });
    traceField(button, @"styled");
}

%hook _TtCCE16Encore_ButtonKitO16EncoreFoundation6Encore6Button8Tertiary
- (void)layoutSubviews {
    %orig;
    styleSearchField((UIView *)self);
}
// Back from the full screen search the field is styled before it draws, not a layout pass later.
- (void)didMoveToWindow {
    %orig;
    if (isSearchField((UIView *)self)) {
        traceField((UIView *)self, @"moved");
        traceFieldArriving((UIView *)self);
    }
    styleSearchField((UIView *)self);
}
// Spotify builds the field's content again when the page comes back, which can take the pane out
// with it; waiting for the next layout pass to put it back would leave the capsule blank.
- (void)didAddSubview:(UIView *)subview {
    %orig;
    if (![subview isKindOfClass:UIVisualEffectView.class]) styleSearchField((UIView *)self);
}
%end

%hook UILabel
- (void)setTextColor:(UIColor *)color {
    %orig(SGIsInside((UIView *)self, sg_searchField) ? UIColor.whiteColor : color);
}
%end

%hook SPTEncoreIconView
- (void)setForegroundColor:(UIColor *)color {
    %orig(SGIsInside((UIView *)self, sg_searchField) ? UIColor.whiteColor : color);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtCCE16Encore_ButtonKitO16EncoreFoundation6Encore6Button8Tertiary", @"SPTEncoreIconView"]);
}
