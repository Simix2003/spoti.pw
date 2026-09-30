// What a running Spotify already has loaded for Statistiche di ascolto, written down without
// asking it for more. No request is sent and no setter, reload, or cell-for-index is called.
//
// The pill is off until Mod → Debug → Stats probe turns SGKeyStatsProbe on and Spotify restarts.
// While on, the pill stays on every screen: Statistiche di ascolto is hosted without a matching
// class/title, so page detection alone never finds it. The dump writes the file as it goes and
// only reads UIView / UIViewController properties (text, frames, accessibility, image size).
// It does not walk arbitrary ivars.
#import "StatsProbe.h"
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"

#ifndef SG_BUILD
#define SG_BUILD "unknown"
#endif
#ifndef SG_BUILD_BRANCH
#define SG_BUILD_BRANCH "unknown"
#endif

static const NSUInteger kMaxFile = 400 * 1024;
static const NSUInteger kMaxViews = 350;
static const NSUInteger kMaxDepth = 12;
static const NSUInteger kMaxString = 180;
static NSString *const kProbeID = @"spotifyplus.stats-probe";

static BOOL sg_busy = NO;
static BOOL sg_installed = NO;
static NSString *sg_lastPath;
static NSString *sg_loggedPage;
static NSUInteger sg_toastGen;
static __weak UILabel *sg_toast;
static __weak UIButton *sg_probeButton;

#pragma mark - detection

static NSArray<NSString *> *statsPhrases(void) {
    return @[
        @"statistiche di ascolto",
        @"minuti di ascolto",
        @"brani top",
        @"artisti top",
        @"brani preferiti",
        @"listening stats",
        @"listening statistics",
        @"minutes listened",
        @"top songs",
        @"top tracks",
        @"top artists",
        @"favorite songs",
        @"favourite songs",
        @"liked songs",
    ];
}

static BOOL phraseMatch(NSString *text) {
    if (![text isKindOfClass:NSString.class] || text.length < 4 || text.length > 140) return NO;
    NSString *lower = text.lowercaseString;
    for (NSString *phrase in statsPhrases()) {
        if ([lower containsString:phrase]) return YES;
    }
    BOOL friends = [lower containsString:@"con amici"] || [lower containsString:@"with friends"];
    if (!friends) return NO;
    for (NSString *word in @[@"brani", @"artisti", @"top", @"song", @"artist", @"minuti", @"minute", @"track"]) {
        if ([lower containsString:word]) return YES;
    }
    return NO;
}

// The class dump is wide on purpose. The pill is not: a "stats" class has to be the page itself,
// not a counter buried in the player.
static BOOL classMatch(NSString *name) {
    if (!name.length) return NO;
    NSString *lower = name.lowercaseString;
    if ([lower containsString:@"listeningstat"]) return YES;
    if ([lower containsString:@"listeninghistory"]) return YES;
    if ([lower containsString:@"topitems"]) return YES;
    if ([lower containsString:@"leaderboard"]) return YES;
    if ([lower containsString:@"statistic"]) return YES;
    // "stats" is the page. "status" and Statsig (the experiment SDK) are not listening stats.
    if ([lower containsString:@"stats"] && ![lower containsString:@"status"] && ![lower containsString:@"statsig"]) return YES;
    if ([lower containsString:@"insights"] && ([lower containsString:@"listen"] || [lower containsString:@"stat"] || [lower containsString:@"music"])) return YES;
    if ([lower containsString:@"wrapped"] && ([lower containsString:@"listen"] || [lower containsString:@"stat"] || [lower containsString:@"recap"] || [lower containsString:@"story"])) return YES;
    if ([lower containsString:@"recap"] && ([lower containsString:@"listen"] || [lower containsString:@"stat"] || [lower containsString:@"week"])) return YES;
    return NO;
}

static UIWindow *keyWindow(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.hidden) continue;
            if ([NSStringFromClass(object_getClass(candidate)) containsString:@"FLEX"]) continue;
            if (!window || candidate.isKeyWindow) window = candidate;
        }
    }
    return window;
}

static UIViewController *visibleLeaf(void) {
    UIWindow *window = keyWindow();
    UIViewController *top = window.rootViewController;
    NSUInteger guard = 0;
    while (top.presentedViewController && guard++ < 8) top = top.presentedViewController;
    for (NSUInteger i = 0; top && i < 8; i++) {
        if ([top isKindOfClass:UINavigationController.class]) {
            UINavigationController *nav = (UINavigationController *)top;
            UIViewController *next = nav.visibleViewController ?: nav.topViewController;
            if (!next || next == top) break;
            top = next;
        } else if ([top isKindOfClass:UITabBarController.class]) {
            UIViewController *next = ((UITabBarController *)top).selectedViewController;
            if (!next || next == top) break;
            top = next;
        } else break;
    }
    return top;
}

static NSString *controllerTitle(UIViewController *vc) {
    if (!vc) return nil;
    @try {
        if (vc.title.length) return vc.title;
        if (vc.navigationItem.title.length) return vc.navigationItem.title;
        UINavigationController *nav = vc.navigationController;
        if (nav.visibleViewController == vc && nav.navigationBar.topItem.title.length) return nav.navigationBar.topItem.title;
    } @catch (NSException *ex) {
        return nil;
    }
    return nil;
}

static BOOL viewIsProbe(UIView *view) {
    if (!view) return NO;
    if ([view.accessibilityIdentifier isEqualToString:kProbeID]) return YES;
    return view == sg_probeButton;
}

static BOOL headerLabel(UIView *view, UILabel *label, UIView *page) {
    if (label.font.pointSize >= 20) return YES;
    if (label.accessibilityTraits & UIAccessibilityTraitHeader) return YES;
    UIView *walk = label;
    while (walk && walk != page) {
        if ([walk isKindOfClass:UINavigationBar.class]) return YES;
        walk = walk.superview;
    }
    if (!page) return NO;
    CGRect frame = [label convertRect:label.bounds toView:page];
    return CGRectGetMinY(frame) < 200 && CGRectGetHeight(frame) >= 18;
}

static BOOL labelTreeMatches(UIView *view, UIView *page, NSUInteger depth, NSUInteger *visited, BOOL *insideList) {
    if (!view || view.hidden || depth > 10 || *visited >= 220) return NO;
    if (viewIsProbe(view)) return NO;
    (*visited)++;
    BOOL list = *insideList || [view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UITableView.class];
    BOOL cell = [view isKindOfClass:UICollectionViewCell.class] || [view isKindOfClass:UITableViewCell.class];
    if (cell) {
        // A shelf row can repeat a stats title. Only a large title at the top of the list counts,
        // and its children are not walked.
        for (UIView *sub in view.subviews) {
            if (![sub isKindOfClass:UILabel.class] || ((UILabel *)sub).text.length > 64) continue;
            if (headerLabel(view, (UILabel *)sub, page) && phraseMatch(((UILabel *)sub).text)) return YES;
        }
        return NO;
    }
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        BOOL usable = !list || headerLabel(view, label, page);
        if (usable && label.text.length <= 64 && phraseMatch(label.text)) return YES;
        if (usable && (phraseMatch(label.accessibilityLabel) || phraseMatch(label.accessibilityIdentifier))) return YES;
    }
    NSString *access = view.accessibilityLabel.length ? view.accessibilityLabel : (view.accessibilityIdentifier.length ? view.accessibilityIdentifier : view.accessibilityValue);
    if (access.length <= 64 && phraseMatch(access) && (!list || [view isKindOfClass:UINavigationBar.class])) {
        BOOL nearTop = view == page;
        if (!nearTop && page) {
            CGRect frame = [view convertRect:view.bounds toView:page];
            nearTop = CGRectGetMinY(frame) < 220;
        }
        if ([view isKindOfClass:UINavigationBar.class] || nearTop) return YES;
    }
    BOOL wasList = *insideList;
    *insideList = list;
    for (UIView *sub in view.subviews) {
        if (labelTreeMatches(sub, page, depth + 1, visited, insideList)) return YES;
    }
    *insideList = wasList;
    return NO;
}

static BOOL controllerSignals(UIViewController *vc) {
    if (!vc) return NO;
    NSString *name = NSStringFromClass(object_getClass(vc));
    if (classMatch(name)) return YES;
    if (phraseMatch(controllerTitle(vc))) return YES;
    @try {
        if (vc.isViewLoaded) {
            if (phraseMatch(vc.view.accessibilityLabel) || phraseMatch(vc.view.accessibilityIdentifier) || phraseMatch(vc.view.accessibilityValue)) return YES;
        }
        if (phraseMatch(vc.navigationItem.titleView.accessibilityLabel)) return YES;
    } @catch (NSException *ex) {
        return NO;
    }
    return NO;
}

static BOOL childCovers(UIViewController *child, UIView *page) {
    if (!child.isViewLoaded || !page) return NO;
    UIView *view = child.view;
    if (!view.window || view.hidden) return NO;
    CGRect frame = [view convertRect:view.bounds toView:page];
    CGRect hit = CGRectIntersection(frame, page.bounds);
    if (CGRectIsNull(hit)) return NO;
    return hit.size.height > page.bounds.size.height * 0.4 && hit.size.width > page.bounds.size.width * 0.4;
}

static BOOL subtreeMatches(UIViewController *vc, UIView *page, NSUInteger depth) {
    if (!vc || depth > 4) return NO;
    if (controllerSignals(vc)) {
        if (depth == 0 || childCovers(vc, page)) return YES;
    }
    for (UIViewController *child in vc.childViewControllers) {
        if (subtreeMatches(child, page, depth + 1)) return YES;
    }
    return NO;
}

// Light match for the pill timer: class and title only. Walking the view tree on every
// viewDidAppear (and every 1.2 s) was crashing Spotify during teardown; @try cannot catch that.
static NSString *lightMatchReason(UIViewController *vc, NSUInteger depth) {
    if (!vc || depth > 4) return nil;
    if (classMatch(NSStringFromClass(object_getClass(vc)))) return @"class";
    if (phraseMatch(controllerTitle(vc))) return @"title";
    @try {
        if (vc.isViewLoaded && (phraseMatch(vc.view.accessibilityLabel) || phraseMatch(vc.view.accessibilityIdentifier))) return @"accessibility";
        if (phraseMatch(vc.navigationItem.titleView.accessibilityLabel)) return @"title";
    } @catch (NSException *ex) {
    }
    for (UIViewController *child in vc.childViewControllers) {
        NSString *reason = lightMatchReason(child, depth + 1);
        if (reason) return [@"child-" stringByAppendingString:reason];
    }
    return nil;
}

// Full match for a tap: also walks header labels once, under @try, after the file is open.
static NSString *deepMatchReason(UIViewController *leaf) {
    NSString *reason = lightMatchReason(leaf, 0);
    if (reason) return reason;
    UIView *page = nil;
    @try { page = leaf.isViewLoaded ? leaf.view : nil; }
    @catch (NSException *ex) { page = nil; }
    if (subtreeMatches(leaf, page, 0)) return @"child";
    if (page) {
        NSUInteger visited = 0;
        BOOL inList = NO;
        @try {
            if (labelTreeMatches(page, page, 0, &visited, &inList)) return @"header";
        } @catch (NSException *ex) {
            return nil;
        }
    }
    return nil;
}

static UIViewController *statsPage(NSString **reasonOut, BOOL deep) {
    UIViewController *leaf = visibleLeaf();
    NSString *reason = deep ? deepMatchReason(leaf) : lightMatchReason(leaf, 0);
    if (reasonOut) *reasonOut = reason;
    return reason ? leaf : nil;
}

static NSString *hintFrom(NSString *text) {
    if (!text.length) return nil;
    NSString *lower = text.lowercaseString;
    NSString *hint = nil;
    if ([lower containsString:@"minuti"] || [lower containsString:@"minute"]) hint = @"minuti";
    else if ([lower containsString:@"preferit"] || [lower containsString:@"favorite"] || [lower containsString:@"favourite"] || [lower containsString:@"liked"]) hint = @"preferiti";
    else if ([lower containsString:@"artist"]) hint = @"artisti";
    else if ([lower containsString:@"brani"] || [lower containsString:@"song"] || [lower containsString:@"track"]) hint = @"brani";
    else if ([lower containsString:@"statistiche"] || [lower containsString:@"statistic"] || [lower containsString:@"listening"]) hint = @"home";
    if (!hint) return nil;
    if (![hint isEqualToString:@"home"] && ([lower containsString:@"con amici"] || [lower containsString:@"with friends"]))
        hint = [hint stringByAppendingString:@"-amici"];
    return hint;
}

static NSString *firstPhraseText(UIView *view, UIView *page, NSUInteger depth, NSUInteger *visited, BOOL inList) {
    if (!view || view.hidden || depth > 10 || *visited >= 220 || viewIsProbe(view)) return nil;
    (*visited)++;
    BOOL list = inList || [view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UITableView.class];
    BOOL cell = [view isKindOfClass:UICollectionViewCell.class] || [view isKindOfClass:UITableViewCell.class];
    if (cell) {
        for (UIView *sub in view.subviews) {
            if (![sub isKindOfClass:UILabel.class] || ((UILabel *)sub).text.length > 64) continue;
            if (headerLabel(view, (UILabel *)sub, page) && phraseMatch(((UILabel *)sub).text)) return ((UILabel *)sub).text;
        }
        return nil;
    }
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        if ((!list || headerLabel(view, label, page)) && label.text.length <= 64 && phraseMatch(label.text)) return label.text;
    }
    for (UIView *sub in view.subviews) {
        NSString *found = firstPhraseText(sub, page, depth + 1, visited, list);
        if (found) return found;
    }
    return nil;
}

static NSString *pageHint(UIViewController *page) {
    NSString *title = controllerTitle(page);
    NSString *hint = hintFrom(title);
    if (!hint && page.isViewLoaded) {
        NSUInteger visited = 0;
        hint = hintFrom(firstPhraseText(page.view, page.view, 0, &visited, NO));
        if (!hint) hint = hintFrom(page.view.accessibilityLabel);
    }
    if (!hint) hint = hintFrom(NSStringFromClass(object_getClass(page))) ?: @"page";
    NSMutableString *safe = [NSMutableString string];
    for (NSUInteger i = 0; i < hint.length && safe.length < 24; i++) {
        unichar c = [hint characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') [safe appendFormat:@"%C", c];
    }
    return safe.length ? safe : @"page";
}

#pragma mark - save, share, pill

static void toast(NSString *text) {
    UIWindow *window = keyWindow();
    if (!window) return;
    UILabel *label = sg_toast;
    if (!label || label.superview != window) {
        label = [UILabel new];
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.94];
        label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        label.layer.cornerRadius = 14;
        label.clipsToBounds = YES;
        label.accessibilityIdentifier = kProbeID;
        [window addSubview:label];
        sg_toast = label;
    }
    label.text = text;
    CGFloat width = MIN(window.bounds.size.width - 48, 340);
    CGSize size = [label sizeThatFits:CGSizeMake(width - 28, 220)];
    CGFloat height = size.height + 22;
    CGFloat bottom = window.safeAreaInsets.bottom + 120;
    label.frame = CGRectMake((window.bounds.size.width - width) / 2, window.bounds.size.height - bottom - height, width, height);
    label.alpha = 1;
    [window bringSubviewToFront:label];
    NSUInteger gen = ++sg_toastGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen != sg_toastGen) return;
        [sg_toast removeFromSuperview];
    });
}

static NSString *documentsDir(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

static NSString *newestProbePath(void) {
    NSString *dir = documentsDir();
    if (!dir) return nil;
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
    NSString *best = nil;
    for (NSString *name in names) {
        if (![name hasPrefix:@"spotifyplus-stats-probe-"] || ![name hasSuffix:@".txt"]) continue;
        if (!best || [name compare:best] == NSOrderedDescending) best = name;
    }
    return best ? [dir stringByAppendingPathComponent:best] : nil;
}

static UIViewController *presenter(void) {
    UIViewController *leaf = nil;
    @try { leaf = visibleLeaf(); }
    @catch (NSException *ex) { leaf = nil; }
    return leaf ?: SGTopController();
}

static void presentFile(NSString *path) {
    UIViewController *top = presenter();
    if (!top || !path.length || !top.view) return;
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    sheet.popoverPresentationController.sourceView = top.view;
    [top presentViewController:sheet animated:YES completion:nil];
}

static void alert(NSString *title, NSString *message) {
    UIViewController *top = presenter();
    if (!top) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [sheet addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:sheet animated:YES completion:nil];
}


#pragma mark - crash-safe dump

static NSString *probeText(id value) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *text = [[(NSString *)value stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
        stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    if (text.length > kMaxString) text = [[text substringToIndex:kMaxString] stringByAppendingString:@"…"];
    NSString *lower = text.lowercaseString;
    if ([lower containsString:@"bearer "] || [lower containsString:@"access_token"] ||
        [lower containsString:@"refresh_token"] || [lower containsString:@"authorization:"]) return @"[redacted]";
    return text;
}

static void probeStep(NSString *step) {
    SGLog(@"stats probe: step %@", step);
}

static void probeWrite(NSFileHandle *file, NSString *text, NSUInteger *written) {
    if (!file || !text.length || *written >= kMaxFile) return;
    if (*written + text.length > kMaxFile) {
        text = [[text substringToIndex:kMaxFile - *written] stringByAppendingString:@"\nstopped: size cap\n"];
    }
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;
    @try {
        [file writeData:data];
        [file synchronizeFile];
        *written += data.length;
    } @catch (NSException *ex) {
        SGLog(@"stats probe: write stopped (%@)", ex.name);
    }
}

static BOOL controllerOwnMatch(UIViewController *vc) {
    if (!vc) return NO;
    @try {
        if (classMatch(NSStringFromClass(object_getClass(vc)))) return YES;
        if (phraseMatch(controllerTitle(vc))) return YES;
        if (!vc.isViewLoaded || !vc.view.window || vc.view.hidden) return NO;
    } @catch (NSException *ex) {
        return NO;
    }
    NSUInteger visited = 0;
    BOOL inList = NO;
    @try {
        return labelTreeMatches(vc.view, vc.view, 0, &visited, &inList);
    } @catch (NSException *ex) {
        return NO;
    }
}

// The visible leaf is often the app root. The stats screen is the deepest child whose own
// view actually contains the stats title.
static UIViewController *deepestContent(UIViewController *vc, NSUInteger depth) {
    if (!vc || depth > 7) return nil;
    NSArray<UIViewController *> *children = nil;
    @try { children = [vc.childViewControllers copy]; }
    @catch (NSException *ex) { children = nil; }
    UIViewController *best = nil;
    NSUInteger seen = 0;
    for (UIViewController *child in children) {
        if (seen++ > 24) break;
        UIViewController *found = nil;
        @try { found = deepestContent(child, depth + 1); }
        @catch (NSException *ex) { found = nil; }
        if (found) best = found;
    }
    if (best) return best;
    return controllerOwnMatch(vc) ? vc : nil;
}

static UIViewController *statsContentController(UIViewController *leaf) {
    if (!leaf) return nil;
    UIViewController *found = nil;
    @try { found = deepestContent(leaf, 0); }
    @catch (NSException *ex) { found = nil; }
    return found ?: leaf;
}

static void collectPhraseLabels(UIView *view, NSMutableArray<UILabel *> *labels, NSUInteger depth, NSUInteger *visited) {
    if (!view || depth > 14 || *visited >= 600 || labels.count >= 20) return;
    (*visited)++;
    @try {
        if (view.hidden || view.alpha < 0.01 || viewIsProbe(view)) return;
        if ([view isKindOfClass:UILabel.class]) {
            UILabel *label = (UILabel *)view;
            if (phraseMatch(label.text) || phraseMatch(label.accessibilityLabel)) [labels addObject:label];
        }
    } @catch (NSException *ex) {
        return;
    }
    NSArray<UIView *> *subs = nil;
    @try { subs = [view.subviews copy]; }
    @catch (NSException *ex) { return; }
    for (UIView *sub in subs) collectPhraseLabels(sub, labels, depth + 1, visited);
}

// Smallest view that still holds every stats phrase label, so the root shell is not the dump.
static UIView *tightStatsView(UIView *root) {
    if (!root) return nil;
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    NSUInteger visited = 0;
    collectPhraseLabels(root, labels, 0, &visited);
    UIView *node = labels.firstObject;
    NSUInteger guard = 0;
    while (node && guard++ < 18) {
        NSUInteger hits = 0;
        for (UILabel *label in labels) {
            @try {
                if (label == node || [label isDescendantOfView:node]) hits++;
            } @catch (NSException *ex) {
                continue;
            }
        }
        BOOL bigEnough = NO;
        @try { bigEnough = node.bounds.size.height > 80 && node.bounds.size.width > 80; }
        @catch (NSException *ex) { bigEnough = NO; }
        if (hits == labels.count && bigEnough) return node;
        @try { node = node.superview; }
        @catch (NSException *ex) { break; }
    }
    return root;
}

static UIViewController *ownerOf(UIView *view) {
    NSUInteger guard = 0;
    UIResponder *responder = view;
    while (responder && guard++ < 16) {
        @try {
            if ([responder isKindOfClass:UIViewController.class]) return (UIViewController *)responder;
            responder = responder.nextResponder;
        } @catch (NSException *ex) {
            return nil;
        }
    }
    return nil;
}

static void dumpChain(UIViewController *vc, NSFileHandle *file, NSUInteger *written) {
    probeWrite(file, @"== view controllers\n", written);
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    NSUInteger guard = 0;
    while (vc && guard++ < 12 && *written < kMaxFile) {
        NSValue *key = [NSValue valueWithNonretainedObject:vc];
        if ([seen containsObject:key]) {
            probeWrite(file, @"cycle\n", written);
            break;
        }
        [seen addObject:key];
        NSString *title = nil;
        NSString *name = @"?";
        @try {
            name = NSStringFromClass(object_getClass(vc));
            title = controllerTitle(vc);
        } @catch (NSException *ex) {
            probeWrite(file, [NSString stringWithFormat:@"unreadable (%@)\n", ex.name], written);
            break;
        }
        probeWrite(file, [NSString stringWithFormat:@"%@ title=\"%@\"\n", name, probeText(title)], written);
        @try { vc = vc.parentViewController; }
        @catch (NSException *ex) { break; }
    }
    probeWrite(file, @"\n", written);
}

static void dumpOneView(UIView *view, NSFileHandle *file, NSUInteger *written, NSUInteger depth, NSUInteger *count, NSMutableSet<NSValue *> *seen) {
    if (!view || depth > kMaxDepth || *count >= kMaxViews || *written >= kMaxFile) return;
    NSValue *key = [NSValue valueWithNonretainedObject:view];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    (*count)++;
    NSMutableString *line = [NSMutableString string];
    @try {
        if (view.hidden || view.alpha < 0.01 || viewIsProbe(view)) return;
        NSString *pad = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
        [line appendFormat:@"%@%@ %@", pad, NSStringFromClass(object_getClass(view)), NSStringFromCGRect(view.frame)];
        if ([view isKindOfClass:UILabel.class]) {
            NSString *text = probeText(((UILabel *)view).text);
            if (text.length) [line appendFormat:@" \"%@\"", text];
        }
        if ([view isKindOfClass:UIButton.class]) {
            NSString *text = probeText([(UIButton *)view currentTitle]);
            if (!text.length) text = probeText(((UIButton *)view).titleLabel.text);
            if (text.length) [line appendFormat:@" button=\"%@\"", text];
        }
        if ([view isKindOfClass:UIImageView.class]) {
            UIImage *image = ((UIImageView *)view).image;
            if (image) [line appendFormat:@" image=%.0fx%.0f%@", image.size.width, image.size.height, image.isSymbolImage ? @" symbol" : @""];
            else [line appendString:@" image=none"];
        }
        NSString *ident = probeText(view.accessibilityIdentifier);
        NSString *label = probeText(view.accessibilityLabel);
        NSString *value = probeText(view.accessibilityValue);
        if (ident.length || label.length || value.length)
            [line appendFormat:@" a11y id=%@ label=\"%@\" value=\"%@\"", ident, label, value];
        [line appendString:@"\n"];
    } @catch (NSException *ex) {
        line = [NSMutableString stringWithFormat:@"%*s<unreadable %@>\n", (int)depth * 2, "", ex.name];
    }
    probeWrite(file, line, written);
    NSArray<UIView *> *subs = nil;
    @try { subs = [view.subviews copy]; }
    @catch (NSException *ex) { return; }
    for (UIView *sub in subs) dumpOneView(sub, file, written, depth + 1, count, seen);
}

static void dumpNow(void) {
    probeStep(@"open");
    NSString *reason = nil;
    UIViewController *leaf = nil;
    @try {
        leaf = statsPage(&reason, YES);
        if (!leaf) {
            leaf = visibleLeaf();
            reason = @"visible";
        }
    } @catch (NSException *ex) {
        sg_busy = NO;
        SGLog(@"stats probe: stopped (%@)", ex.name);
        toast(@"Stats probe stopped");
        return;
    }
    if (!leaf) {
        sg_busy = NO;
        toast(@"No page is on screen");
        return;
    }
    probeStep(@"resolve");
    UIViewController *contentVC = statsContentController(leaf);
    UIView *root = nil;
    @try { root = leaf.isViewLoaded ? leaf.view : nil; }
    @catch (NSException *ex) { root = nil; }
    // Prefer a tight stats subview when phrases are on screen; otherwise dump the whole leaf.
    UIView *content = tightStatsView(root) ?: root;
    UIViewController *owner = ownerOf(content) ?: contentVC;
    NSString *title = nil;
    @try { title = controllerTitle(owner) ?: controllerTitle(contentVC) ?: controllerTitle(leaf); }
    @catch (NSException *ex) { title = nil; }
    NSString *hint = pageHint(owner ?: leaf);
    SGLog(@"stats probe: page %@ title %@ leaf %@ view %@",
          NSStringFromClass(object_getClass(owner ?: contentVC ?: leaf)),
          title.length ? title : @"(none)",
          NSStringFromClass(object_getClass(leaf)),
          content ? NSStringFromClass(object_getClass(content)) : @"none");

    NSDateFormatter *fileStamp = [NSDateFormatter new];
    fileStamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fileStamp.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *dir = documentsDir();
    NSString *name = [NSString stringWithFormat:@"spotifyplus-stats-probe-%@-%@.txt", [fileStamp stringFromDate:NSDate.date], hint];
    NSString *path = dir ? [dir stringByAppendingPathComponent:name] : nil;
    if (!path || ![NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil]) {
        sg_busy = NO;
        SGLog(@"stats probe: could not write (create)");
        toast(@"Stats probe could not save");
        return;
    }
    sg_lastPath = path;
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!file) {
        sg_busy = NO;
        SGLog(@"stats probe: could not write (open)");
        toast(@"Stats probe could not save");
        return;
    }
    NSUInteger written = 0;
    NSDateFormatter *stamp = [NSDateFormatter new];
    stamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    stamp.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
    NSString *spotify = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
    probeWrite(file, [NSString stringWithFormat:
        @"spotifyplus stats probe\ntime: %@\nspotify: %@\nios: %@\nbuild: %s %s\nread-only view dump. No ivar walk, no valueForKey.\nleaf: %@\ncontent: %@\nview: %@\ntitle: \"%@\"\nmatched: %@\nhint: %@\n\n",
        [stamp stringFromDate:NSDate.date], spotify, UIDevice.currentDevice.systemVersion, SG_BUILD_BRANCH, SG_BUILD,
        NSStringFromClass(object_getClass(leaf)),
        NSStringFromClass(object_getClass(owner ?: contentVC ?: leaf)),
        content ? NSStringFromClass(object_getClass(content)) : @"none",
        probeText(title), reason ?: @"?", hint], &written);

    probeStep(@"controllers");
    @try { dumpChain(owner ?: contentVC ?: leaf, file, &written); }
    @catch (NSException *ex) {
        probeWrite(file, [NSString stringWithFormat:@"controllers stopped (%@)\n", ex.name], &written);
        SGLog(@"stats probe: stopped (%@)", ex.name);
    }

    probeStep(@"views");
    NSUInteger views = 0;
    @try {
        probeWrite(file, [NSString stringWithFormat:@"== views\nroot %@ %@\n",
                          content ? NSStringFromClass(object_getClass(content)) : @"none",
                          content ? NSStringFromCGRect(content.frame) : @"none"], &written);
        NSMutableSet<NSValue *> *seen = [NSMutableSet set];
        dumpOneView(content, file, &written, 0, &views, seen);
    } @catch (NSException *ex) {
        probeWrite(file, [NSString stringWithFormat:@"views stopped (%@)\n", ex.name], &written);
        SGLog(@"stats probe: stopped (%@)", ex.name);
    }
    probeWrite(file, [NSString stringWithFormat:@"\nviews written: %lu\n", (unsigned long)views], &written);
    @try { [file closeFile]; }
    @catch (NSException *ex) {}

    probeStep(@"done");
    SGLog(@"stats probe: saved %@ page %@ title %@, %lu views",
          name, NSStringFromClass(object_getClass(owner ?: leaf)), title.length ? title : @"(none)", (unsigned long)views);
    sg_busy = NO;
    toast(@"Stats probe saved");
    presentFile(path);
}



static void probeTapped(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ probeTapped(); });
        return;
    }
    if (sg_busy) {
        toast(@"Stats probe is already running");
        return;
    }
    sg_busy = YES;
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    dumpNow();
}

static void placeProbe(UIButton *button, UIWindow *window) {
    CGFloat width = 78;
    CGFloat height = 34;
    CGFloat bottom = window.safeAreaInsets.bottom + 78;
    button.frame = CGRectMake(window.bounds.size.width - width - 14, window.bounds.size.height - bottom - height, width, height);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
}

static UIButton *makeProbe(void) {
    UIButtonConfiguration *config;
    if (@available(iOS 26.0, *)) config = [UIButtonConfiguration glassButtonConfiguration];
    else config = [UIButtonConfiguration filledButtonConfiguration];
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    config.baseForegroundColor = UIColor.whiteColor;
    config.baseBackgroundColor = [UIColor colorWithWhite:0.12 alpha:0.92];
    config.contentInsets = NSDirectionalEdgeInsetsMake(6, 14, 6, 14);
    config.attributedTitle = [[NSAttributedString alloc] initWithString:@"Probe" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: UIColor.whiteColor,
    }];
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        probeTapped();
    }]];
    button.accessibilityIdentifier = kProbeID;
    button.accessibilityLabel = @"Probe";
    button.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    return button;
}

static void refreshProbe(void) {
    if (sg_busy) return;
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;
    // The stats screen is a MusicAppPageHostingViewController whose title lives only in
    // labels — class/title matching never sees it. While the Debug switch is on the pill
    // stays visible on every screen; the dump reads whatever page is up.
    UIWindow *window = keyWindow();
    if (!window) return;
    UIViewController *leaf = nil;
    @try { leaf = visibleLeaf(); }
    @catch (NSException *ex) { leaf = nil; }
    NSString *title = controllerTitle(leaf);
    NSString *key = [NSString stringWithFormat:@"%@|%@", leaf ? NSStringFromClass(object_getClass(leaf)) : @"none", title ?: @""];
    if (![sg_loggedPage isEqualToString:key]) {
        sg_loggedPage = key;
        SGLog(@"stats probe: pill on leaf %@ title %@",
              leaf ? NSStringFromClass(object_getClass(leaf)) : @"none",
              title.length ? title : @"(none)");
    }
    UIButton *button = sg_probeButton;
    if (!button) {
        button = makeProbe();
        sg_probeButton = button;
    }
    if (button.superview != window) [window addSubview:button];
    placeProbe(button, window);
    button.hidden = NO;
    [window bringSubviewToFront:button];
}

static void scheduleRefresh(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ refreshProbe(); });
}

static void sg_viewDidAppear(id self, SEL _cmd, BOOL animated);
static void sg_viewDidDisappear(id self, SEL _cmd, BOOL animated);
static void (*sg_origAppear)(id, SEL, BOOL);
static void (*sg_origDisappear)(id, SEL, BOOL);

static void sg_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (sg_origAppear) sg_origAppear(self, _cmd, animated);
    scheduleRefresh();
}

static void sg_viewDidDisappear(id self, SEL _cmd, BOOL animated) {
    if (sg_origDisappear) sg_origDisappear(self, _cmd, animated);
    scheduleRefresh();
}

static void installProbe(void) {
    if (sg_installed) return;
    sg_installed = YES;
    SGLog(@"stats probe: pill armed (Show Probe pill is on)");
    Method appear = class_getInstanceMethod(UIViewController.class, @selector(viewDidAppear:));
    Method disappear = class_getInstanceMethod(UIViewController.class, @selector(viewDidDisappear:));
    if (appear) {
        sg_origAppear = (void (*)(id, SEL, BOOL))method_getImplementation(appear);
        method_setImplementation(appear, (IMP)sg_viewDidAppear);
    }
    if (disappear) {
        sg_origDisappear = (void (*)(id, SEL, BOOL))method_getImplementation(disappear);
        method_setImplementation(disappear, (IMP)sg_viewDidDisappear);
    }
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), (uint64_t)(1.2 * NSEC_PER_SEC), (uint64_t)(0.2 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{ refreshProbe(); });
    dispatch_resume(timer);
    scheduleRefresh();
}

void SGStatsProbeShareLast(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGStatsProbeShareLast(); });
        return;
    }
    NSString *path = sg_lastPath ?: newestProbePath();
    if (!path || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        alert(@"No stats probe yet", @"Turn on Show Probe pill under Mod → Debug → Stats probe, restart, open Statistiche di ascolto, tap Probe, then share.");
        return;
    }
    presentFile(path);
}

__attribute__((constructor)) static void SGStatsProbeInit(void) {
    // Off until the Debug page asks for it. The old always-on swizzle walked every screen
    // and crashed Spotify (SIGSEGV during view teardown, not an NSException).
    if (!SGHidden(SGKeyStatsProbe)) return;
    installProbe();
}
