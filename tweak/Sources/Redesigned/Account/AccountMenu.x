// Account redesign: the trailing avatar opens a Music-style page sheet in place of Spotify's left
// SideDrawer. Spotify's drawer still presents so its rows stay live; it is hidden from the first
// layout frame, the sheet is read off its profile header and SideDrawerListCollectionView, and each
// tap fires Spotify's own ListRow (or dismisses and opens Mod Settings). Friend activity and recent
// chats are left out of the sheet. A drawer that cannot be claimed, or whose rows never arrive, is
// shown again as Spotify draws it.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Account.h"

static const NSTimeInterval kAvatarAfterTap = 3;
static const NSTimeInterval kRowsWait = 4;
static const NSTimeInterval kRowsPoll = 1.0 / 30.0;
static const NSTimeInterval kSettle = 0.8;
static NSString *const kLastRowsKey = @"spotifyglass.redesign.account.menuRows";

static NSTimeInterval sgr_avatarTappedAt;
static char kWatchedKey, kButtonFindKey, kClaimKey, kMaskKey, kSavedMaskKey, kHiddenDimmingsKey, kTakeoverKey;

#pragma mark - avatar tap

@interface SGRAccountAvatarWatcher : NSObject <UIGestureRecognizerDelegate>
@end

@implementation SGRAccountAvatarWatcher
- (void)tapped:(id)sender {
    sgr_avatarTappedAt = CACurrentMediaTime();
    SGLog(@"redesign account: avatar tapped");
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
@end

static BOOL avatarTappedRecently(void) {
    return sgr_avatarTappedAt > 0 && CACurrentMediaTime() - sgr_avatarTappedAt < kAvatarAfterTap;
}

static void watchButton(UIView *button) {
    if (!button || objc_getAssociatedObject(button, &kWatchedKey)) return;
    static SGRAccountAvatarWatcher *watcher;
    if (!watcher) watcher = [SGRAccountAvatarWatcher new];
    objc_setAssociatedObject(button, &kWatchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([button isKindOfClass:UIControl.class]) {
        [(UIControl *)button addTarget:watcher action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside | UIControlEventPrimaryActionTriggered];
    }
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:watcher action:@selector(tapped:)];
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesEnded = NO;
    tap.delegate = watcher;
    [button addGestureRecognizer:tap];
}

static void watchFace(UIView *face) {
    if (!face) return;
    UIView *button = SGRFindByIdentifier(face, @"Components.UI.SideDrawerButton", &kButtonFindKey);
    if (button) watchButton(button);
    else watchButton(face);
}

#pragma mark - hide / show presentation

static UIViewController *presentedHost(UIViewController *list) {
    UIViewController *top = list;
    while (top.parentViewController) top = top.parentViewController;
    return top.presentingViewController ? top : nil;
}

static UIView *sheetViewOf(UIViewController *host) {
    return host.presentationController.presentedView ?: host.viewIfLoaded;
}

static void hideSystemDimming(UIView *container) {
    static Class dimmingClass;
    if (!dimmingClass) dimmingClass = NSClassFromString(@"UIDimmingView");
    UIWindow *window = container.window;
    if (!dimmingClass || !window) return;
    NSHashTable *hidden = objc_getAssociatedObject(container, &kHiddenDimmingsKey);
    NSMutableArray<UIView *> *level = [window.subviews mutableCopy];
    for (int depth = 0; depth < 3 && level.count; depth++) {
        NSMutableArray<UIView *> *next = [NSMutableArray array];
        for (UIView *view in level) {
            if ([view isKindOfClass:dimmingClass]) {
                if (view.hidden) continue;
                view.hidden = YES;
                if (view.superview != container) {
                    if (!hidden) {
                        hidden = [NSHashTable weakObjectsHashTable];
                        objc_setAssociatedObject(container, &kHiddenDimmingsKey, hidden, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    }
                    [hidden addObject:view];
                }
            } else {
                [next addObjectsFromArray:view.subviews];
            }
        }
        level = next;
    }
}

static void showSystemDimming(UIView *container) {
    NSHashTable *hidden = objc_getAssociatedObject(container, &kHiddenDimmingsKey);
    for (UIView *view in hidden) view.hidden = NO;
    objc_setAssociatedObject(container, &kHiddenDimmingsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void hidePresentation(UIView *sheet, UIView *container) {
    // Touches stay on: the account sheet is presented from the drawer host, so its container sits
    // in this hierarchy. Dropping touches here (as the player menu does for a menu outside the sheet)
    // would leave the account sheet unable to take them.
    if (!sheet) {
        if (container) hideSystemDimming(container);
        return;
    }
    CALayer *mask = objc_getAssociatedObject(sheet, &kMaskKey);
    if (!mask) {
        mask = [CALayer layer];
        mask.frame = CGRectMake(0, 0, 1, 1);
        mask.backgroundColor = UIColor.clearColor.CGColor;
        objc_setAssociatedObject(sheet, &kMaskKey, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sheet, &kSavedMaskKey, sheet.layer.mask ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (sheet.layer.mask != mask) sheet.layer.mask = mask;
    if (!sheet.hidden) sheet.hidden = YES;
    if (sheet.userInteractionEnabled) sheet.userInteractionEnabled = NO;
    sheet.accessibilityElementsHidden = YES;
    hideSystemDimming(container);
}

static void showPresentation(UIView *sheet, UIView *container) {
    showSystemDimming(container);
    if (!sheet) return;
    id saved = objc_getAssociatedObject(sheet, &kSavedMaskKey);
    sheet.alpha = 0;
    sheet.hidden = NO;
    sheet.layer.mask = saved == NSNull.null ? nil : saved;
    objc_setAssociatedObject(sheet, &kMaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(sheet, &kSavedMaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sheet.userInteractionEnabled = YES;
    sheet.accessibilityElementsHidden = NO;
    [UIView animateWithDuration:0.25 animations:^{ sheet.alpha = 1; }];
}

#pragma mark - scrape

static BOOL keepIdentifier(NSString *identifier) {
    if (!identifier.length) return NO;
    return [identifier isEqualToString:@"AccountSwitching.AddAccountRow"]
        || [identifier isEqualToString:@"Components.UI.YourPlanRowSideDrawer"]
        || [identifier isEqualToString:@"Components.UI.NavigationRowSideDrawer"];
}

static BOOL shown(UIView *view, UIView *within) {
    for (UIView *v = view; v && v != within; v = v.superview) {
        if (v.hidden || v.alpha < 0.01) return NO;
    }
    return YES;
}

static UICollectionView *drawerList(UIView *root) {
    __block UICollectionView *found = nil;
    SGForEachView(root, ^(UIView *v) {
        if (found) return;
        if ([v isKindOfClass:UICollectionView.class] && [NSStringFromClass(v.class) containsString:@"SideDrawerListCollectionView"])
            found = (UICollectionView *)v;
    });
    return found;
}

static UIView *listRowIn(UIView *cell) {
    __block UIView *found = nil;
    SGForEachView(cell, ^(UIView *v) {
        if (found) return;
        NSString *ident = v.accessibilityIdentifier;
        if (ident.length && keepIdentifier(ident)) found = v;
    });
    if (found) return found;
    SGForEachView(cell, ^(UIView *v) {
        if (found) return;
        if ([v isKindOfClass:UIControl.class] && v.accessibilityIdentifier.length && keepIdentifier(v.accessibilityIdentifier))
            found = v;
    });
    return found;
}

static SGRAccountRow *readCell(UIView *cell) {
    UIView *control = listRowIn(cell);
    if (!control) return nil;
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    __block UIImageView *glyph = nil;
    SGForEachView(control, ^(UIView *v) {
        if ([v isKindOfClass:UILabel.class] && ((UILabel *)v).text.length && shown(v, control))
            [labels addObject:(UILabel *)v];
        if (!glyph && [v isKindOfClass:UIImageView.class] && ((UIImageView *)v).image && v.bounds.size.width <= 40 && shown(v, control))
            glyph = (UIImageView *)v;
    });
    [labels sortUsingComparator:^NSComparisonResult(UILabel *a, UILabel *b) {
        CGPoint pa = [a convertPoint:CGPointZero toView:control], pb = [b convertPoint:CGPointZero toView:control];
        if (fabs(pa.y - pb.y) > 1) return pa.y < pb.y ? NSOrderedAscending : NSOrderedDescending;
        return pa.x < pb.x ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSString *title = labels.count ? labels.firstObject.text : control.accessibilityLabel;
    if (!title.length) {
        // ListRow often puts the title only on accessibilityLabel ("Name, subtitle").
        NSString *label = control.accessibilityLabel;
        NSRange comma = [label rangeOfString:@", "];
        if (comma.location != NSNotFound) title = [label substringToIndex:comma.location];
        else title = label;
    }
    if (!title.length) return nil;
    // Drop the Mod Settings overlay row App injects into the drawer.
    if ([title isEqualToString:@"Mod Settings"]) return nil;

    SGRAccountRow *row = [SGRAccountRow new];
    row.identifier = control.accessibilityIdentifier;
    row.title = title;
    if (labels.count > 1) row.subtitle = labels[1].text;
    else if (control.accessibilityValue.length) row.subtitle = control.accessibilityValue;
    else {
        NSString *label = control.accessibilityLabel;
        NSRange comma = [label rangeOfString:@", "];
        if (comma.location != NSNotFound && comma.location < title.length + 2)
            row.subtitle = [label substringFromIndex:NSMaxRange(comma)];
    }
    row.image = glyph.image;
    row.control = control;
    return row;
}

static NSArray<SGRAccountRow *> *readRows(UIView *root) {
    UICollectionView *list = drawerList(root);
    if (!list) return @[];
    [list layoutIfNeeded];
    NSMutableArray<SGRAccountRow *> *rows = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (UICollectionViewCell *cell in list.visibleCells) {
        SGRAccountRow *row = readCell(cell);
        if (!row) continue;
        NSString *key = [NSString stringWithFormat:@"%@|%@", row.identifier, row.title];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        [rows addObject:row];
    }
    // Grow the collection so off-screen account rows exist, then read again.
    CGRect saved = list.bounds;
    CGFloat content = list.contentSize.height;
    if (content > saved.size.height + 1) {
        list.bounds = CGRectMake(saved.origin.x, saved.origin.y, saved.size.width, content);
        [list layoutIfNeeded];
        for (UICollectionViewCell *cell in list.visibleCells) {
            SGRAccountRow *row = readCell(cell);
            if (!row) continue;
            NSString *key = [NSString stringWithFormat:@"%@|%@", row.identifier, row.title];
            if ([seen containsObject:key]) continue;
            [seen addObject:key];
            [rows addObject:row];
        }
        list.bounds = saved;
        [list layoutIfNeeded];
    }
    // Keep document order: sort by cell origin y.
    [rows sortUsingComparator:^NSComparisonResult(SGRAccountRow *a, SGRAccountRow *b) {
        CGRect fa = a.control ? [a.control convertRect:a.control.bounds toView:list] : CGRectZero;
        CGRect fb = b.control ? [b.control convertRect:b.control.bounds toView:list] : CGRectZero;
        if (fa.origin.y < fb.origin.y) return NSOrderedAscending;
        if (fa.origin.y > fb.origin.y) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return rows;
}

static void readProfile(UIView *root, NSString **nameOut, NSString **subtitleOut, UIImage **avatarOut) {
    __block UIView *profile = nil;
    SGForEachView(root, ^(UIView *v) {
        if (profile) return;
        NSString *cls = NSStringFromClass(v.class);
        if ([cls containsString:@"SideDrawerProfile"]) profile = v;
    });
    if (!profile) return;
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    __block UIImageView *picture = nil;
    SGForEachView(profile, ^(UIView *v) {
        if ([v isKindOfClass:UILabel.class] && ((UILabel *)v).text.length && shown(v, profile))
            [labels addObject:(UILabel *)v];
        if ([v isKindOfClass:UIImageView.class] && ((UIImageView *)v).image && v.bounds.size.width >= 32 && shown(v, profile)) {
            if (!picture || v.bounds.size.width > picture.bounds.size.width) picture = (UIImageView *)v;
        }
    });
    [labels sortUsingComparator:^NSComparisonResult(UILabel *a, UILabel *b) {
        CGPoint pa = [a convertPoint:CGPointZero toView:profile], pb = [b convertPoint:CGPointZero toView:profile];
        if (fabs(pa.y - pb.y) > 1) return pa.y < pb.y ? NSOrderedAscending : NSOrderedDescending;
        return pa.x < pb.x ? NSOrderedAscending : NSOrderedDescending;
    }];
    // Skip the single-letter avatar initial if it is the first label.
    NSUInteger start = 0;
    if (labels.count && labels[0].text.length <= 2 && labels[0].bounds.size.width < 40) start = 1;
    if (labels.count > start) *nameOut = labels[start].text;
    if (labels.count > start + 1) *subtitleOut = labels[start + 1].text;
    if (picture.image) *avatarOut = picture.image;
    if (!*nameOut && profile.accessibilityLabel.length) {
        NSString *label = profile.accessibilityLabel;
        NSRange comma = [label rangeOfString:@", "];
        if (comma.location != NSNotFound) {
            *nameOut = [label substringToIndex:comma.location];
            if (!*subtitleOut) *subtitleOut = [label substringFromIndex:NSMaxRange(comma)];
        } else {
            *nameOut = label;
        }
    }
}

static UIView *profileControl(UIView *root) {
    __block UIView *found = nil;
    SGForEachView(root, ^(UIView *v) {
        if (found) return;
        NSString *cls = NSStringFromClass(v.class);
        if ([cls containsString:@"SideDrawerProfile"] && [v isKindOfClass:UIControl.class]) found = v;
    });
    if (found) return found;
    SGForEachView(root, ^(UIView *v) {
        if (found) return;
        if ([NSStringFromClass(v.class) containsString:@"SideDrawerProfile"]) {
            // Prefer the Encore ListRow under the profile element.
            SGForEachView(v, ^(UIView *inner) {
                if (found) return;
                if ([inner isKindOfClass:UIControl.class] && [inner.accessibilityLabel containsString:@","]) found = inner;
            });
            if (!found) found = v;
        }
    });
    return found;
}

#pragma mark - last rows cache

static NSArray<SGRAccountRow *> *sgr_lastRows;

static NSArray<SGRAccountRow *> *lastRows(void) {
    if (sgr_lastRows) return sgr_lastRows;
    NSData *data = [NSUserDefaults.standardUserDefaults dataForKey:kLastRowsKey];
    if (!data) return nil;
    NSSet *classes = [NSSet setWithObjects:NSArray.class, NSDictionary.class, NSString.class, UIImage.class, nil];
    id stored = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:data error:nil];
    NSMutableArray<SGRAccountRow *> *rows = [NSMutableArray array];
    for (NSDictionary *entry in [stored isKindOfClass:NSArray.class] ? stored : @[]) {
        if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"id"] isKindOfClass:NSString.class] || ![entry[@"title"] isKindOfClass:NSString.class]) continue;
        SGRAccountRow *row = [SGRAccountRow new];
        row.identifier = entry[@"id"];
        row.title = entry[@"title"];
        row.subtitle = [entry[@"subtitle"] isKindOfClass:NSString.class] ? entry[@"subtitle"] : nil;
        row.image = [entry[@"image"] isKindOfClass:UIImage.class] ? entry[@"image"] : nil;
        [rows addObject:row];
    }
    sgr_lastRows = rows.count ? rows : nil;
    return sgr_lastRows;
}

static void keepRows(NSArray<SGRAccountRow *> *rows) {
    sgr_lastRows = rows;
    NSMutableArray *stored = [NSMutableArray array];
    for (SGRAccountRow *row in rows) {
        NSMutableDictionary *entry = [@{@"id": row.identifier ?: @"", @"title": row.title ?: @""} mutableCopy];
        if (row.subtitle) entry[@"subtitle"] = row.subtitle;
        if (row.image) entry[@"image"] = row.image;
        [stored addObject:entry];
    }
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:stored requiringSecureCoding:YES error:nil];
    if (data) [NSUserDefaults.standardUserDefaults setObject:data forKey:kLastRowsKey];
}

#pragma mark - takeover

@interface SGRAccountTakeover : NSObject
@property (nonatomic, weak) UIViewController *list;
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, weak) SGRAccountSheet *sheet;
@property (nonatomic, weak) UIView *profileControl;
@property (nonatomic, strong) NSArray<SGRAccountRow *> *rows;
@property (nonatomic, strong) NSTimer *poll;
@property (nonatomic) NSTimeInterval startedAt;
@property (nonatomic) BOOL finished;
@property (nonatomic) BOOL revealed;
@property (nonatomic) BOOL sheetShown;
@end

@implementation SGRAccountTakeover
@end

static __weak SGRAccountTakeover *sgr_active;

static void revealDrawer(SGRAccountTakeover *t, NSString *why) {
    if (!t || t.revealed || t.finished) return;
    t.revealed = YES;
    [t.poll invalidate];
    t.poll = nil;
    SGLog(@"redesign account: Spotify's drawer shown, %@", why);
    objc_setAssociatedObject(t.host, &kClaimKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIViewController *sheet = t.sheet;
    if (sheet.presentingViewController && !sheet.isBeingDismissed) {
        [sheet dismissViewControllerAnimated:YES completion:^{
            showPresentation(sheetViewOf(t.host), t.host.presentationController.containerView);
        }];
    } else {
        showPresentation(sheetViewOf(t.host), t.host.presentationController.containerView);
    }
}

static void finishDrawer(SGRAccountTakeover *t, NSString *why, void (^then)(void)) {
    if (!t || t.finished || t.revealed) return;
    t.finished = YES;
    [t.poll invalidate];
    t.poll = nil;
    UIViewController *host = t.host;
    SGLog(@"redesign account: drawer taken away, %@", why);
    if (!host.presentingViewController || host.isBeingDismissed) {
        if (then) then();
        return;
    }
    [host dismissViewControllerAnimated:YES completion:then];
}

static void dismissSheetThen(SGRAccountTakeover *t, void (^then)(void)) {
    SGRAccountSheet *sheet = t.sheet;
    if (!sheet.presentingViewController || sheet.isBeingDismissed) {
        if (then) then();
        return;
    }
    [sheet dismissViewControllerAnimated:YES completion:then];
}

static void fireControl(UIView *control) {
    if (!control) return;
    SGRActivate(control);
}

static void settle(SGRAccountTakeover *t) {
    __weak SGRAccountTakeover *weak = t;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSettle * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SGRAccountTakeover *strong = weak;
        if (!strong || strong.revealed || strong.finished) return;
        UIViewController *host = strong.host;
        if (!host.presentingViewController || host.isBeingDismissed) return;
        if (host.presentedViewController && host.presentedViewController != strong.sheet) {
            // Spotify pushed a page onto the drawer; leave it.
            strong.finished = YES;
            return;
        }
        finishDrawer(strong, @"the row left it up", nil);
    });
}

static void applyScrape(SGRAccountTakeover *t) {
    UIView *root = t.list.viewIfLoaded;
    if (!root) return;
    NSString *name = nil, *subtitle = nil;
    UIImage *avatar = nil;
    readProfile(root, &name, &subtitle, &avatar);
    NSArray<SGRAccountRow *> *rows = readRows(root);
    t.profileControl = profileControl(root);
    if (rows.count) {
        t.rows = rows;
        keepRows(rows);
        [t.sheet setRows:rows];
    }
    if (name.length || avatar) [t.sheet setProfileName:name subtitle:subtitle avatar:avatar];
}

static void openSheet(SGRAccountTakeover *t) {
    if (t.sheetShown || t.finished || t.revealed) return;
    UIViewController *host = t.host;
    if (!host || host.presentedViewController) return;

    SGRAccountSheet *sheet = [SGRAccountSheet new];
    t.sheet = sheet;
    t.sheetShown = YES;

    NSArray<SGRAccountRow *> *cached = lastRows();
    if (cached.count) [sheet setRows:cached];
    applyScrape(t);

    __weak SGRAccountTakeover *weak = t;
    sheet.onProfile = ^{
        SGRAccountTakeover *strong = weak;
        dismissSheetThen(strong, ^{
            if (!strong.profileControl) {
                applyScrape(strong);
            }
            if (!strong.profileControl) {
                revealDrawer(strong, @"the profile row could not be fired");
                return;
            }
            fireControl(strong.profileControl);
            settle(strong);
        });
    };
    sheet.onModSettings = ^{
        SGRAccountTakeover *strong = weak;
        UIViewController *presenting = strong.host.presentingViewController;
        dismissSheetThen(strong, ^{
            finishDrawer(strong, @"Mod Settings", ^{
                UIView *source = presenting.viewIfLoaded ?: SGTopController().view;
                SGOpenModSettings(source);
            });
        });
    };
    sheet.onRow = ^(SGRAccountRow *row) {
        SGRAccountTakeover *strong = weak;
        dismissSheetThen(strong, ^{
            UIView *control = row.control;
            if (!control) {
                for (SGRAccountRow *live in strong.rows) {
                    if ([live.title isEqualToString:row.title] && [live.identifier isEqualToString:row.identifier]) {
                        control = live.control;
                        break;
                    }
                }
            }
            if (!control) {
                applyScrape(strong);
                for (SGRAccountRow *live in strong.rows) {
                    if ([live.title isEqualToString:row.title]) { control = live.control; break; }
                }
            }
            if (!control) {
                revealDrawer(strong, @"a row could not be fired");
                return;
            }
            SGLog(@"redesign account: \"%@\" (%@) fired", row.title, row.identifier);
            fireControl(control);
            settle(strong);
        });
    };
    sheet.onDismissed = ^{
        SGRAccountTakeover *strong = weak;
        finishDrawer(strong, @"the sheet was dismissed", nil);
    };

    [host presentViewController:sheet animated:YES completion:nil];
    SGLog(@"redesign account: sheet presented over the drawer");
}

static void pollRows(SGRAccountTakeover *t) {
    if (t.finished || t.revealed) return;
    applyScrape(t);
    if (t.rows.count) {
        [t.poll invalidate];
        t.poll = nil;
        return;
    }
    if (CACurrentMediaTime() - t.startedAt >= kRowsWait) {
        revealDrawer(t, @"no rows within the wait");
    }
}

static void claimDrawer(UIViewController *list) {
    UIViewController *host = presentedHost(list);
    if (!host) return;
    if ([objc_getAssociatedObject(host, &kClaimKey) boolValue]) {
        hidePresentation(sheetViewOf(host), host.presentationController.containerView);
        return;
    }
    if (!avatarTappedRecently()) return;

    SGRAccountTakeover *t = [SGRAccountTakeover new];
    t.list = list;
    t.host = host;
    t.startedAt = CACurrentMediaTime();
    sgr_active = t;
    objc_setAssociatedObject(host, &kClaimKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(host, &kTakeoverKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    hidePresentation(sheetViewOf(host), host.presentationController.containerView);
    SGLog(@"redesign account: drawer claimed");

    openSheet(t);

    __weak SGRAccountTakeover *weak = t;
    t.poll = [NSTimer scheduledTimerWithTimeInterval:kRowsPoll repeats:YES block:^(NSTimer *timer) {
        pollRows(weak);
    }];
    [[NSRunLoop mainRunLoop] addTimer:t.poll forMode:NSRunLoopCommonModes];
}

#pragma mark - hooks

%hook _TtC29ListeningActivity_ElementsKit21AdaptiveFaceContainer
- (void)layoutSubviews {
    %orig;
    watchFace((UIView *)self);
}
%end

%hook _TtC23SideDrawer_ListPageImpl18ListViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (avatarTappedRecently() || [objc_getAssociatedObject(presentedHost((UIViewController *)self), &kClaimKey) boolValue])
        claimDrawer((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    UIViewController *list = (UIViewController *)self;
    UIViewController *host = presentedHost(list);
    if (![objc_getAssociatedObject(host, &kClaimKey) boolValue]) return;
    hidePresentation(sheetViewOf(host), host.presentationController.containerView);
    SGRAccountTakeover *t = objc_getAssociatedObject(host, &kTakeoverKey);
    if (t && !t.sheetShown) openSheet(t);
    if (t && !t.finished && !t.revealed) applyScrape(t);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    UIViewController *host = presentedHost((UIViewController *)self);
    SGRAccountTakeover *t = objc_getAssociatedObject(host, &kTakeoverKey);
    if (t && !t.finished && !t.revealed) {
        t.finished = YES;
        [t.poll invalidate];
    }
}
%end

static UIViewController *sideDrawerListIn(UIViewController *root) {
    if (!root) return nil;
    if ([NSStringFromClass(root.class) containsString:@"SideDrawer_ListPageImpl"]) return root;
    for (UIViewController *child in root.childViewControllers) {
        UIViewController *found = sideDrawerListIn(child);
        if (found) return found;
    }
    return nil;
}

// Catch a present that wraps the drawer in MusicAppPageHostingViewController before ListViewController appears.
%hook UIViewController
- (void)presentViewController:(UIViewController *)viewController animated:(BOOL)animated completion:(void (^)(void))completion {
    BOOL claim = avatarTappedRecently();
    %orig;
    if (!claim || !viewController) return;
    __weak UIViewController *weak = viewController;
    void (^tryClaim)(void) = ^{
        UIViewController *list = sideDrawerListIn(weak);
        if (list) claimDrawer(list);
    };
    dispatch_async(dispatch_get_main_queue(), tryClaim);
    for (NSNumber *delay in @[@0.05, @0.16, @0.4]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), tryClaim);
    }
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC29ListeningActivity_ElementsKit21AdaptiveFaceContainer",
        @"_TtC23SideDrawer_ListPageImpl18ListViewController",
    ]);
}
