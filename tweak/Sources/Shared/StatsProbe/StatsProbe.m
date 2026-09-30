// What a running Spotify already has loaded for Statistiche di ascolto, written down without
// asking it for more. No request is sent and no setter, reload, or cell-for-index is called.
// Cells that are not on screen are included only when the collection already holds them.
//
// The pill is shown from the visible page's class, title, and header labels (Italian and the
// English equivalents). Swift values that are not objects still contribute the class name in
// the ivar encoding, which is the same read the Jam probe uses.
#import "StatsProbe.h"
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Player/PlayerState.h"
#import <math.h>
#import <objc/runtime.h>
#import <string.h>

#ifndef SG_BUILD
#define SG_BUILD "unknown"
#endif
#ifndef SG_BUILD_BRANCH
#define SG_BUILD_BRANCH "unknown"
#endif

static const NSUInteger kObjDepth = 4;
static const NSUInteger kMaxFile = 400 * 1024;
static const NSUInteger kMaxNodes = 1600;
static const NSUInteger kMaxViews = 3500;
static const NSUInteger kMaxViewDepth = 28;
static const NSUInteger kMaxCells = 80;
static const NSUInteger kMaxIvars = 36;
static const NSUInteger kMaxChildren = 32;
static const NSUInteger kMaxDeepChildren = 8;
static const NSUInteger kMaxString = 180;
static const NSUInteger kMaxInterest = 100;
static const NSUInteger kMaxObservables = 80;
static const NSUInteger kMaxMethods = 64;
static const NSUInteger kMaxClassIvars = 48;
static const NSUInteger kPerPattern = 36;
static const NSUInteger kDumpCap = 140;
static const NSTimeInterval kBudget = 2.2;
static NSString *const kProbeID = @"spotifyplus.stats-probe";

static const char *kPatterns[] = {
    "ListeningHistory", "TopItems", "Leaderboard", "Statistic", "Insights", "Wrapped", "Recap", "Minutes", "Charts", "Stats",
};
static const NSUInteger kPatternCount = sizeof kPatterns / sizeof kPatterns[0];

static BOOL sg_busy = NO;
static BOOL sg_installed = NO;
static NSString *sg_lastPath;
static NSString *sg_loggedPage;
static CFAbsoluteTime sg_deadline;
static BOOL sg_expired;
static NSUInteger sg_nodes;
static NSUInteger sg_toastGen;
static __weak UILabel *sg_toast;
static __weak UIButton *sg_probeButton;
static __weak UIViewController *sg_cacheLeaf;
static NSString *sg_cacheTitle;
static NSString *sg_cacheReason;
static BOOL sg_cacheMatch;
static BOOL sg_cacheValid;

static NSMutableArray<NSString *> *sg_interest;
static NSMutableArray<NSString *> *sg_observables;

static BOOL budgetHit(void) {
    if (sg_expired) return YES;
    if (CFAbsoluteTimeGetCurrent() > sg_deadline) sg_expired = YES;
    return sg_expired;
}

static BOOL fileRoom(NSMutableString *out) {
    return out.length < kMaxFile && !budgetHit();
}

static BOOL room(NSMutableString *out) {
    return fileRoom(out) && sg_nodes < kMaxNodes;
}

static BOOL appendCapped(NSMutableString *out, NSString *line) {
    if (!line || out.length >= kMaxFile) return NO;
    [out appendString:line];
    return out.length < kMaxFile;
}

static NSString *clip(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return @"";
    NSString *one = [[text stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
        stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    if (one.length > kMaxString) one = [[one substringToIndex:kMaxString] stringByAppendingString:@"…"];
    return one;
}

static BOOL sensitiveName(NSString *name) {
    if (![name isKindOfClass:NSString.class] || !name.length) return NO;
    NSString *lower = name.lowercaseString;
    for (NSString *word in @[@"token", @"secret", @"auth", @"password", @"cookie"]) {
        if ([lower containsString:word]) return YES;
    }
    return NO;
}

static NSString *clean(NSString *text) {
    NSString *clipped = clip(text);
    NSString *lower = clipped.lowercaseString;
    if ([lower containsString:@"bearer "] || [lower containsString:@"access_token"] ||
        [lower containsString:@"refresh_token"] || [lower containsString:@"authorization:"]) return @"[redacted]";
    return clipped;
}

static const char *skipQualifiers(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}

static NSString *encodingText(const char *type) {
    if (!type || !type[0]) return @"?";
    NSString *text = @(type);
    if (text.length > 96) text = [[text substringToIndex:96] stringByAppendingString:@"…"];
    return text;
}

// @"ClassName" inside an object type encoding. Nil when the runtime left the class out.
static NSString *declaredClass(const char *type) {
    type = skipQualifiers(type);
    if (!type || type[0] != '@' || type[1] != '"') return nil;
    const char *start = type + 2;
    const char *end = strchr(start, '"');
    if (!end || end == start) return nil;
    return [[NSString alloc] initWithBytes:start length:(NSUInteger)(end - start) encoding:NSUTF8StringEncoding];
}

static BOOL plainFoundation(id obj, Class kind) {
    if (!obj || ![obj isKindOfClass:kind]) return NO;
    NSString *name = NSStringFromClass(object_getClass(obj));
    if ([name containsString:@"Swift"] || [name containsString:@"Deferred"] || [name hasPrefix:@"_Tt"]) return NO;
    return [name hasPrefix:@"NS"] || [name hasPrefix:@"__NS"];
}

static NSString *primitiveIvar(id object, Ivar ivar) {
    const char *type = skipQualifiers(ivar_getTypeEncoding(ivar));
    if (!type || !type[0] || !object) return nil;
    size_t len = 0;
    switch (type[0]) {
        case 'c': case 'B': case 'C': len = sizeof(char); break;
        case 's': case 'S': len = sizeof(short); break;
        case 'i': case 'I': len = sizeof(int); break;
        case 'q': case 'Q': len = sizeof(long long); break;
        case 'f': len = sizeof(float); break;
        case 'd': len = sizeof(double); break;
        default: return nil;
    }
    ptrdiff_t offset = ivar_getOffset(ivar);
    Class cls = object_getClass(object);
    if (!cls || offset < 0 || (size_t)offset + len > class_getInstanceSize(cls)) return nil;
    const uint8_t *bytes = (const uint8_t *)(__bridge void *)object + offset;
    switch (type[0]) {
        case 'B': case 'C': return [NSString stringWithFormat:@"%u", (unsigned)bytes[0]];
        case 'c': return [NSString stringWithFormat:@"%d", (int)(signed char)bytes[0]];
        case 's': case 'S': {
            unsigned short raw = 0;
            memcpy(&raw, bytes, sizeof raw);
            return type[0] == 's' ? [NSString stringWithFormat:@"%d", (int)(short)raw] : [NSString stringWithFormat:@"%u", raw];
        }
        case 'i': case 'I': {
            unsigned raw = 0;
            memcpy(&raw, bytes, sizeof raw);
            return type[0] == 'i' ? [NSString stringWithFormat:@"%d", (int)raw] : [NSString stringWithFormat:@"%u", raw];
        }
        case 'q': case 'Q': {
            unsigned long long raw = 0;
            memcpy(&raw, bytes, sizeof raw);
            return type[0] == 'q' ? [NSString stringWithFormat:@"%lld", (long long)raw] : [NSString stringWithFormat:@"%llu", raw];
        }
        case 'f': {
            float raw = 0;
            memcpy(&raw, bytes, sizeof raw);
            return isfinite(raw) ? [NSString stringWithFormat:@"%g", raw] : @"nan";
        }
        case 'd': {
            double raw = 0;
            memcpy(&raw, bytes, sizeof raw);
            return isfinite(raw) ? [NSString stringWithFormat:@"%g", raw] : @"nan";
        }
        default: return nil;
    }
}

static void noteInterest(NSString *path, NSString *text) {
    if (!sg_interest || sg_interest.count >= kMaxInterest || !path.length) return;
    [sg_interest addObject:[NSString stringWithFormat:@"%@ = %@", path, text ?: @"nil"]];
}

static void noteObservable(NSString *path, NSString *className, NSString *ivar) {
    if (!sg_observables || sg_observables.count >= kMaxObservables) return;
    [sg_observables addObject:[NSString stringWithFormat:@"%@ %@ ivar %@", path ?: @"?", className ?: @"?", ivar ?: @"?"]];
}

static BOOL interestName(NSString *name) {
    if (!name.length) return NO;
    NSString *lower = name.lowercaseString;
    for (NSString *word in @[
        @"minute", @"ascolto", @"leaderboard", @"friend", @"amici", @"avatar", @"playcount", @"play_count",
        @"streamcount", @"timesplayed", @"trend", @"streak", @"week", @"nowplaying", @"now_playing",
        @"recap", @"rank", @"listened", @"listening", @"topsong", @"topartist", @"toptrack", @"imageurl",
        @"image_url", @"portrait", @"datarange", @"daterange", @"timeframe",
    ]) {
        if ([lower containsString:word]) return YES;
    }
    return NO;
}

static BOOL observableName(NSString *name) {
    if (!name.length) return NO;
    NSString *lower = name.lowercaseString;
    for (NSString *word in @[@"publisher", @"subject", @"observable", @"currentvalue", @"passthrough", @"subscriber", @"anypublisher", @"published", @"combine"]) {
        if ([lower containsString:word]) return YES;
    }
    return NO;
}

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

static NSString *matchReason(UIViewController *leaf) {
    if (!leaf) return nil;
    if (classMatch(NSStringFromClass(object_getClass(leaf)))) return @"class";
    if (phraseMatch(controllerTitle(leaf))) return @"title";
    @try {
        if (leaf.isViewLoaded && (phraseMatch(leaf.view.accessibilityLabel) || phraseMatch(leaf.view.accessibilityIdentifier))) return @"accessibility";
    } @catch (NSException *ex) {
    }
    UIView *page = leaf.isViewLoaded ? leaf.view : nil;
    if (subtreeMatches(leaf, page, 0)) return @"child";
    if (page) {
        NSUInteger visited = 0;
        BOOL inList = NO;
        if (labelTreeMatches(page, page, 0, &visited, &inList)) return @"header";
    }
    return nil;
}

static UIViewController *statsPage(NSString **reasonOut) {
    UIViewController *leaf = visibleLeaf();
    NSString *reason = matchReason(leaf);
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

#pragma mark - object graph

static NSString *describePlain(id value) {
    if (!value || value == (id)kCFNull || value == NSNull.null) return @"nil";
    if (plainFoundation(value, NSString.class)) return [NSString stringWithFormat:@"\"%@\"", clean(value)];
    if (plainFoundation(value, NSNumber.class)) return [(NSNumber *)value stringValue];
    if (plainFoundation(value, NSURL.class)) return [NSString stringWithFormat:@"\"%@\"", clean([(NSURL *)value absoluteString])];
    if (plainFoundation(value, NSDate.class)) return [(NSDate *)value description];
    if (plainFoundation(value, NSData.class)) return [NSString stringWithFormat:@"<NSData %lu bytes>", (unsigned long)[(NSData *)value length]];
    return nil;
}

static BOOL isViewish(id value) {
    return [value isKindOfClass:UIView.class] || [value isKindOfClass:CALayer.class] || [value isKindOfClass:UIViewController.class] ||
           [value isKindOfClass:UIGestureRecognizer.class];
}

static void appendObject(id object, NSMutableString *out, NSString *indent, NSUInteger depth, NSMutableSet<NSValue *> *seen, NSString *path);

static NSUInteger childCap(NSUInteger depth) {
    return depth <= 1 ? kMaxChildren : kMaxDeepChildren;
}

static void appendCollection(id collection, NSMutableString *out, NSString *indent, NSUInteger depth, NSMutableSet<NSValue *> *seen, NSString *path) {
    if (plainFoundation(collection, NSArray.class) || plainFoundation(collection, NSOrderedSet.class)) {
        NSArray *list = [collection isKindOfClass:NSArray.class] ? collection : [(NSOrderedSet *)collection array];
        appendCapped(out, [NSString stringWithFormat:@"%@array %lu\n", indent, (unsigned long)list.count]);
        NSUInteger n = MIN(list.count, childCap(depth));
        for (NSUInteger i = 0; i < n && room(out); i++) {
            id item = nil;
            @try { item = list[i]; }
            @catch (NSException *ex) { break; }
            NSString *childPath = [NSString stringWithFormat:@"%@[%lu]", path, (unsigned long)i];
            appendCapped(out, [NSString stringWithFormat:@"%@  [%lu] ", indent, (unsigned long)i]);
            NSString *plain = describePlain(item);
            if (plain) {
                appendCapped(out, [plain stringByAppendingString:@"\n"]);
                if (interestName(path)) noteInterest(childPath, plain);
            } else {
                appendCapped(out, @"\n");
                appendObject(item, out, [indent stringByAppendingString:@"    "], depth + 1, seen, childPath);
            }
        }
        if (list.count > n) appendCapped(out, [NSString stringWithFormat:@"%@  … %lu more\n", indent, (unsigned long)(list.count - n)]);
        return;
    }
    if (plainFoundation(collection, NSDictionary.class)) {
        NSDictionary *map = collection;
        appendCapped(out, [NSString stringWithFormat:@"%@dictionary %lu\n", indent, (unsigned long)map.count]);
        NSArray *keys = nil;
        @try { keys = map.allKeys; }
        @catch (NSException *ex) { keys = @[]; }
        NSArray *sorted = keys;
        @try {
            sorted = [keys sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
                NSString *as = plainFoundation(a, NSString.class) ? a : NSStringFromClass(object_getClass(a));
                NSString *bs = plainFoundation(b, NSString.class) ? b : NSStringFromClass(object_getClass(b));
                return [as compare:bs];
            }];
        } @catch (NSException *ex) {
            sorted = keys;
        }
        NSUInteger n = 0;
        for (id key in sorted) {
            if (n >= childCap(depth) || !room(out)) break;
            NSString *keyText = plainFoundation(key, NSString.class) ? key : NSStringFromClass(object_getClass(key));
            if (sensitiveName(keyText)) {
                appendCapped(out, [NSString stringWithFormat:@"%@  %@ [skipped]\n", indent, keyText]);
                n++;
                continue;
            }
            id item = nil;
            @try { item = map[key]; }
            @catch (NSException *ex) { continue; }
            NSString *childPath = [NSString stringWithFormat:@"%@.%@", path, clip(keyText)];
            NSString *plain = describePlain(item);
            if (plain) {
                appendCapped(out, [NSString stringWithFormat:@"%@  %@=%@\n", indent, clip(keyText), plain]);
                if (interestName(keyText) || interestName(path)) noteInterest(childPath, plain);
            } else {
                appendCapped(out, [NSString stringWithFormat:@"%@  %@\n", indent, clip(keyText)]);
                appendObject(item, out, [indent stringByAppendingString:@"    "], depth + 1, seen, childPath);
            }
            n++;
        }
        return;
    }
    if (plainFoundation(collection, NSSet.class)) {
        appendCapped(out, [NSString stringWithFormat:@"%@set %lu\n", indent, (unsigned long)[(NSSet *)collection count]]);
        NSUInteger n = 0;
        @try {
            for (id item in collection) {
                if (n >= childCap(depth) || !room(out)) break;
                appendObject(item, out, [indent stringByAppendingString:@"  "], depth + 1, seen, [NSString stringWithFormat:@"%@[%lu]", path, (unsigned long)n]);
                n++;
            }
        } @catch (NSException *ex) {
            appendCapped(out, [NSString stringWithFormat:@"%@  unreadable\n", indent]);
        }
        return;
    }
}

static void appendObject(id object, NSMutableString *out, NSString *indent, NSUInteger depth, NSMutableSet<NSValue *> *seen, NSString *path) {
    if (!room(out)) return;
    if (!object || object == NSNull.null) {
        appendCapped(out, [NSString stringWithFormat:@"%@nil\n", indent]);
        return;
    }
    NSString *plain = describePlain(object);
    if (plain) {
        appendCapped(out, [NSString stringWithFormat:@"%@%@\n", indent, plain]);
        return;
    }
    if (plainFoundation(object, NSArray.class) || plainFoundation(object, NSDictionary.class) ||
        plainFoundation(object, NSSet.class) || plainFoundation(object, NSOrderedSet.class)) {
        NSValue *key = [NSValue valueWithNonretainedObject:object];
        if ([seen containsObject:key]) {
            appendCapped(out, [NSString stringWithFormat:@"%@cycle\n", indent]);
            return;
        }
        [seen addObject:key];
        appendCollection(object, out, indent, depth, seen, path);
        return;
    }
    NSString *className = NSStringFromClass(object_getClass(object));
    if (observableName(className)) noteObservable(path, className, @"(object)");
    if (depth >= kObjDepth || sg_nodes >= kMaxNodes) {
        appendCapped(out, [NSString stringWithFormat:@"%@<%@>\n", indent, className]);
        return;
    }
    NSValue *key = [NSValue valueWithNonretainedObject:object];
    if ([seen containsObject:key]) {
        appendCapped(out, [NSString stringWithFormat:@"%@<%@> cycle\n", indent, className]);
        return;
    }
    [seen addObject:key];
    sg_nodes++;
    if (isViewish(object) && depth > 0) {
        appendCapped(out, [NSString stringWithFormat:@"%@<%@>\n", indent, className]);
        return;
    }
    appendCapped(out, [NSString stringWithFormat:@"%@<%@>\n", indent, className]);
    Class cls = object_getClass(object);
    Class stop = NSObject.class;
    if ([object isKindOfClass:UIViewController.class]) stop = UIViewController.class;
    else if ([object isKindOfClass:UIView.class]) stop = UIView.class;
    NSUInteger levels = 0;
    while (cls && cls != stop && cls != NSObject.class && levels < 8 && room(out)) {
        unsigned count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        NSUInteger shown = 0;
        for (unsigned i = 0; ivars && i < count && shown < kMaxIvars && room(out); i++) {
            const char *raw = ivar_getName(ivars[i]);
            NSString *name = raw ? @(raw) : @"?";
            const char *type = ivar_getTypeEncoding(ivars[i]);
            const char *bare = skipQualifiers(type);
            NSString *declared = declaredClass(type);
            if (sensitiveName(name)) {
                appendCapped(out, [NSString stringWithFormat:@"%@  ivar %@ [skipped]\n", indent, name]);
                continue;
            }
            if (observableName(name) || (declared && observableName(declared))) noteObservable(path, declared ?: className, name);
            NSString *childPath = [NSString stringWithFormat:@"%@.%@", path, name];
            if (!bare || !bare[0]) continue;
            if (bare[0] == '@' && bare[1] == '?') {
                appendCapped(out, [NSString stringWithFormat:@"%@  ivar %@ block\n", indent, name]);
                continue;
            }
            if (bare[0] == '@') {
                id value = nil;
                @try { value = object_getIvar(object, ivars[i]); }
                @catch (NSException *ex) {
                    appendCapped(out, [NSString stringWithFormat:@"%@  ivar %@ unreadable declared %@\n", indent, name, declared ?: encodingText(type)]);
                    shown++;
                    continue;
                }
                if (plainFoundation(value, NSArray.class) || plainFoundation(value, NSDictionary.class) ||
                    plainFoundation(value, NSSet.class) || plainFoundation(value, NSOrderedSet.class)) {
                    appendCapped(out, [NSString stringWithFormat:@"%@  ivar %@\n", indent, name]);
                    appendCollection(value, out, [indent stringByAppendingString:@"    "], depth, seen, childPath);
                    if (interestName(name)) {
                        NSString *kind = @"collection";
                        if (plainFoundation(value, NSArray.class)) kind = [NSString stringWithFormat:@"array %lu", (unsigned long)[(NSArray *)value count]];
                        else if (plainFoundation(value, NSDictionary.class)) kind = [NSString stringWithFormat:@"dictionary %lu", (unsigned long)[(NSDictionary *)value count]];
                        noteInterest(childPath, kind);
                    }
                    shown++;
                    continue;
                }
                NSString *asPlain = describePlain(value);
                if (asPlain) {
                    appendCapped(out, [NSString stringWithFormat:@"%@  ivar %@=%@\n", indent, name, asPlain]);
                    if (interestName(name)) noteInterest(childPath, asPlain);
                    shown++;
                    continue;
                }
                if (!value) {
                    appendCapped(out, [NSString stringWithFormat:@"%@  ivar %@ nil%@\n", indent, name, declared ? [NSString stringWithFormat:@" declared %@", declared] : @""]);
                    shown++;
                    continue;
                }
                NSString *valueClass = NSStringFromClass(object_getClass(value));
                appendCapped(out, [NSString stringWithFormat:@"%@  ivar %@ <%@>%@\n", indent, name, valueClass,
                                    (declared && ![declared isEqualToString:valueClass]) ? [NSString stringWithFormat:@" declared %@", declared] : (declared ? @"" : @"")]);
                if (interestName(name)) noteInterest(childPath, [NSString stringWithFormat:@"<%@>", valueClass]);
                if (!isViewish(value)) appendObject(value, out, [indent stringByAppendingString:@"    "], depth + 1, seen, childPath);
                shown++;
            } else {
                NSString *text = nil;
                @try { text = primitiveIvar(object, ivars[i]); }
                @catch (NSException *ex) { text = nil; }
                if (text) {
                    appendCapped(out, [NSString stringWithFormat:@"%@  ivar %@=%@\n", indent, name, text]);
                    if (interestName(name)) noteInterest(childPath, text);
                } else {
                    appendCapped(out, [NSString stringWithFormat:@"%@  ivar %@ unreadable type %@\n", indent, name, encodingText(type)]);
                    if (interestName(name)) noteInterest(childPath, [NSString stringWithFormat:@"unreadable %@", encodingText(type)]);
                }
                shown++;
            }
        }
        free(ivars);
        cls = class_getSuperclass(cls);
        levels++;
    }
}

#pragma mark - views and cells

static BOOL isCell(UIView *view) {
    return [view isKindOfClass:UITableViewCell.class] || [view isKindOfClass:UICollectionViewCell.class];
}

static void appendImageStrings(UIImageView *imageView, NSMutableString *out, NSString *indent) {
    Class cls = object_getClass(imageView);
    unsigned count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    NSUInteger shown = 0;
    for (unsigned i = 0; ivars && i < count && shown < 8 && room(out); i++) {
        const char *raw = ivar_getName(ivars[i]);
        NSString *name = raw ? @(raw) : @"?";
        if (sensitiveName(name)) continue;
        const char *type = skipQualifiers(ivar_getTypeEncoding(ivars[i]));
        if (!type || type[0] != '@') continue;
        id value = nil;
        @try { value = object_getIvar(imageView, ivars[i]); }
        @catch (NSException *ex) { continue; }
        NSString *plain = describePlain(value);
        if (!plain) continue;
        appendCapped(out, [NSString stringWithFormat:@"%@image-ivar %@=%@\n", indent, name, plain]);
        if (interestName(name)) noteInterest([NSString stringWithFormat:@"image.%@", name], plain);
        shown++;
    }
    free(ivars);
}

static void collectExistingCells(UIView *view, NSMutableArray<UIView *> *cells, NSMutableSet<NSValue *> *seen, NSUInteger depth, NSUInteger *visited);

static void harvestCellObject(id object, NSMutableArray<UIView *> *cells, NSMutableSet<NSValue *> *seen, NSUInteger depth) {
    if (!object || depth > 3 || cells.count >= kMaxCells) return;
    if (isCell(object)) {
        NSValue *key = [NSValue valueWithNonretainedObject:object];
        if (![seen containsObject:key]) {
            [seen addObject:key];
            [cells addObject:object];
        }
        return;
    }
    if (plainFoundation(object, NSArray.class) || plainFoundation(object, NSSet.class)) {
        for (id item in object) {
            if (cells.count >= kMaxCells) break;
            @try { harvestCellObject(item, cells, seen, depth + 1); }
            @catch (NSException *ex) { break; }
        }
        return;
    }
    if (plainFoundation(object, NSDictionary.class)) {
        @try {
            for (id item in [(NSDictionary *)object allValues]) {
                if (cells.count >= kMaxCells) break;
                harvestCellObject(item, cells, seen, depth + 1);
            }
        } @catch (NSException *ex) {
            return;
        }
        return;
    }
    if (![object isKindOfClass:UICollectionView.class] && ![object isKindOfClass:UITableView.class]) return;
    @try {
        for (UIView *cell in [object visibleCells]) harvestCellObject(cell, cells, seen, depth + 1);
    } @catch (NSException *ex) {
    }
    unsigned count = 0;
    Ivar *ivars = class_copyIvarList(object_getClass(object), &count);
    for (unsigned i = 0; ivars && i < count && cells.count < kMaxCells; i++) {
        const char *type = skipQualifiers(ivar_getTypeEncoding(ivars[i]));
        if (!type || type[0] != '@') continue;
        id value = nil;
        @try { value = object_getIvar(object, ivars[i]); }
        @catch (NSException *ex) { continue; }
        harvestCellObject(value, cells, seen, depth + 1);
    }
    free(ivars);
}

static void collectExistingCells(UIView *view, NSMutableArray<UIView *> *cells, NSMutableSet<NSValue *> *seen, NSUInteger depth, NSUInteger *visited) {
    if (!view || depth > kMaxViewDepth || *visited >= kMaxViews || cells.count >= kMaxCells || viewIsProbe(view)) return;
    (*visited)++;
    if ([view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UITableView.class]) harvestCellObject(view, cells, seen, 0);
    if (isCell(view)) {
        NSValue *key = [NSValue valueWithNonretainedObject:view];
        if (![seen containsObject:key]) {
            [seen addObject:key];
            [cells addObject:view];
        }
    }
    for (UIView *sub in view.subviews) collectExistingCells(sub, cells, seen, depth + 1, visited);
}

static NSString *indexPathText(UIView *cell) {
    UIView *view = cell.superview;
    NSUInteger guard = 0;
    while (view && guard++ < 12) {
        @try {
            if ([view isKindOfClass:UITableView.class] && [cell isKindOfClass:UITableViewCell.class]) {
                NSIndexPath *path = [(UITableView *)view indexPathForCell:(UITableViewCell *)cell];
                if (path) return [NSString stringWithFormat:@"%ld.%ld", (long)path.section, (long)path.item];
            }
            if ([view isKindOfClass:UICollectionView.class] && [cell isKindOfClass:UICollectionViewCell.class]) {
                NSIndexPath *path = [(UICollectionView *)view indexPathForCell:(UICollectionViewCell *)cell];
                if (path) return [NSString stringWithFormat:@"%ld.%ld", (long)path.section, (long)path.item];
            }
        } @catch (NSException *ex) {
            return nil;
        }
        view = view.superview;
    }
    return nil;
}

static void appendLabelLines(UIView *view, NSMutableString *out, NSString *indent, NSUInteger depth, NSUInteger *count) {
    if (!view || depth > 8 || *count >= 16 || !room(out) || viewIsProbe(view)) return;
    if ([view isKindOfClass:UILabel.class]) {
        NSString *text = ((UILabel *)view).text;
        if (text.length) {
            appendCapped(out, [NSString stringWithFormat:@"%@label \"%@\"\n", indent, clean(text)]);
            (*count)++;
        }
    }
    for (UIView *sub in view.subviews) appendLabelLines(sub, out, indent, depth + 1, count);
}

static void appendSources(UIView *root, NSMutableString *out, NSMutableSet<NSValue *> *seen, UIViewController *page) {
    NSMutableArray<UIView *> *lists = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger guard = 0;
    while (stack.count && lists.count < 8 && guard++ < kMaxViews) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (!view || viewIsProbe(view)) continue;
        if ([view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UITableView.class]) [lists addObject:view];
        for (UIView *sub in view.subviews.reverseObjectEnumerator) [stack addObject:sub];
    }
    [out appendString:@"\n== data sources\n"];
    for (UIView *list in lists) {
        if (!room(out)) break;
        id source = nil;
        id delegate = nil;
        @try {
            if ([list isKindOfClass:UITableView.class]) {
                source = ((UITableView *)list).dataSource;
                delegate = ((UITableView *)list).delegate;
            } else if ([list isKindOfClass:UICollectionView.class]) {
                source = ((UICollectionView *)list).dataSource;
                delegate = ((UICollectionView *)list).delegate;
            }
        } @catch (NSException *ex) {
            source = nil;
        }
        appendCapped(out, [NSString stringWithFormat:@"%@ dataSource %@ delegate %@\n", NSStringFromClass(object_getClass(list)),
                            source ? NSStringFromClass(object_getClass(source)) : @"nil",
                            delegate ? NSStringFromClass(object_getClass(delegate)) : @"nil"]);
        if (source && source != page && source != list) appendObject(source, out, @"  ", 0, seen, @"dataSource");
        else if (source == page) appendCapped(out, @"  data source is the page controller\n");
        if (delegate && delegate != source && delegate != page && delegate != list) appendObject(delegate, out, @"  ", 0, seen, @"delegate");
    }
}

static void appendHierarchy(UIView *view, NSMutableString *out, NSString *indent, NSUInteger depth, NSMutableSet<NSValue *> *seen, NSUInteger *views) {
    if (!view || depth > kMaxViewDepth || *views >= kMaxViews || !room(out) || viewIsProbe(view)) return;
    NSValue *key = [NSValue valueWithNonretainedObject:view];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    (*views)++;
    NSMutableString *line = [NSMutableString stringWithFormat:@"%@%@ %@", indent, NSStringFromClass(object_getClass(view)), NSStringFromCGRect(view.frame)];
    if (view.hidden) [line appendString:@" hidden"];
    if (view.alpha < 0.99) [line appendFormat:@" alpha=%.2f", view.alpha];
    if ([view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) [line appendFormat:@" \"%@\"", clean(((UILabel *)view).text)];
    if ([view isKindOfClass:UIImageView.class]) [line appendFormat:@" image=%@", ((UIImageView *)view).image ? @"yes" : @"no"];
    if ([view isKindOfClass:UIScrollView.class]) {
        CGSize size = ((UIScrollView *)view).contentSize;
        CGPoint offset = ((UIScrollView *)view).contentOffset;
        [line appendFormat:@" content=%.0fx%.0f offset=%.0f,%.0f", size.width, size.height, offset.x, offset.y];
    }
    NSString *ident = view.accessibilityIdentifier;
    NSString *label = view.accessibilityLabel;
    NSString *value = view.accessibilityValue;
    if (ident.length || label.length || value.length)
        [line appendFormat:@" a11y id=%@ label=\"%@\" value=\"%@\"", clean(ident), clean(label), clean(value)];
    [line appendString:@"\n"];
    appendCapped(out, line);
    if ([view isKindOfClass:UIImageView.class]) appendImageStrings((UIImageView *)view, out, [indent stringByAppendingString:@"  "]);
    NSString *next = [indent stringByAppendingString:@"  "];
    for (UIView *sub in view.subviews) appendHierarchy(sub, out, next, depth + 1, seen, views);
}

static void appendControllers(UIViewController *vc, NSMutableString *out, NSString *indent, NSUInteger depth, NSMutableSet<NSValue *> *seen) {
    if (!vc || depth > 8 || !room(out)) return;
    NSValue *key = [NSValue valueWithNonretainedObject:vc];
    if ([seen containsObject:key]) {
        appendCapped(out, [NSString stringWithFormat:@"%@%@ cycle\n", indent, NSStringFromClass(object_getClass(vc))]);
        return;
    }
    NSString *title = controllerTitle(vc);
    appendCapped(out, [NSString stringWithFormat:@"%@%@%@\n", indent, NSStringFromClass(object_getClass(vc)),
                        title.length ? [NSString stringWithFormat:@" title=\"%@\"", clean(title)] : @""]);
    @try {
        if (vc.isViewLoaded) {
            appendCapped(out, [NSString stringWithFormat:@"%@  view-a11y id=%@ label=\"%@\" value=\"%@\"\n", indent,
                                clean(vc.view.accessibilityIdentifier), clean(vc.view.accessibilityLabel), clean(vc.view.accessibilityValue)]);
        } else appendCapped(out, [NSString stringWithFormat:@"%@  view not loaded\n", indent]);
    } @catch (NSException *ex) {
        appendCapped(out, [NSString stringWithFormat:@"%@  view unreadable\n", indent]);
    }
    appendObject(vc, out, [indent stringByAppendingString:@"  "], 0, seen, @"vc");
    NSString *next = [indent stringByAppendingString:@"  "];
    for (UIViewController *child in vc.childViewControllers) appendControllers(child, out, next, depth + 1, seen);
    if (vc.presentedViewController && depth < 2) appendControllers(vc.presentedViewController, out, next, depth + 1, seen);
}

#pragma mark - class census

static int patternIndex(NSString *name) {
    if (!name.length || [name hasPrefix:@"SG"]) return -1;
    for (NSUInteger i = 0; i < kPatternCount; i++) {
        if ([name rangeOfString:@(kPatterns[i]) options:NSCaseInsensitiveSearch].location != NSNotFound) return (int)i;
    }
    return -1;
}

static void appendClass(Class cls, NSMutableString *out) {
    NSString *name = NSStringFromClass(cls);
    Class supercls = class_getSuperclass(cls);
    BOOL swift = [name hasPrefix:@"_Tt"] || [name containsString:@"."];
    appendCapped(out, [NSString stringWithFormat:@"-- %@ [%@]\nsuperclass: %@\n", name, swift ? @"swift" : @"objc",
                        supercls ? NSStringFromClass(supercls) : @"(none)"]);
    unsigned count = 0;
    Protocol *__unsafe_unretained *protocols = class_copyProtocolList(cls, &count);
    NSMutableArray<NSString *> *protocolNames = [NSMutableArray array];
    for (unsigned i = 0; protocols && i < count && protocolNames.count < 12; i++) {
        const char *raw = protocol_getName(protocols[i]);
        if (raw) [protocolNames addObject:@(raw)];
    }
    free(protocols);
    appendCapped(out, [NSString stringWithFormat:@"protocols: %@\n", protocolNames.count ? [protocolNames componentsJoinedByString:@", "] : @"(none)"]);
    unsigned ivars = 0;
    Ivar *ivarList = class_copyIvarList(cls, &ivars);
    NSMutableArray<NSString *> *ivarNames = [NSMutableArray array];
    for (unsigned i = 0; ivarList && i < ivars && ivarNames.count < kMaxClassIvars; i++) {
        const char *raw = ivar_getName(ivarList[i]);
        NSString *encoding = encodingText(ivar_getTypeEncoding(ivarList[i]));
        [ivarNames addObject:[NSString stringWithFormat:@"%@ `%@`", raw ? @(raw) : @"?", encoding]];
    }
    unsigned ivarTotal = ivars;
    free(ivarList);
    appendCapped(out, [NSString stringWithFormat:@"ivars (%lu of %u): %@\n", (unsigned long)ivarNames.count, ivarTotal,
                        ivarNames.count ? [ivarNames componentsJoinedByString:@", "] : @"(none)"]);
    unsigned methods = 0;
    Method *methodList = class_copyMethodList(cls, &methods);
    NSMutableArray<NSString *> *selectors = [NSMutableArray array];
    for (unsigned i = 0; methodList && i < methods && selectors.count < kMaxMethods; i++) {
        SEL sel = method_getName(methodList[i]);
        if (sel) [selectors addObject:NSStringFromSelector(sel)];
    }
    unsigned methodTotal = methods;
    free(methodList);
    appendCapped(out, [NSString stringWithFormat:@"methods (%lu of %u): %@\n", (unsigned long)selectors.count, methodTotal,
                        selectors.count ? [selectors componentsJoinedByString:@" "] : @"(none)"]);
}

static void appendClassCensus(NSMutableString *out, NSUInteger *dumped) {
    unsigned int total = 0;
    Class *classes = objc_copyClassList(&total);
    NSMutableArray<NSMutableArray *> *buckets = [NSMutableArray array];
    NSMutableArray<NSNumber *> *counts = [NSMutableArray array];
    for (NSUInteger i = 0; i < kPatternCount; i++) {
        [buckets addObject:[NSMutableArray array]];
        [counts addObject:@0];
    }
    for (unsigned int i = 0; classes && i < total && fileRoom(out); i++) {
        NSString *name = NSStringFromClass(classes[i]);
        int index = patternIndex(name);
        if (index < 0) continue;
        // Statsig is the experiment SDK. Its classes contain "Stats" and would crowd out the page.
        if ([name rangeOfString:@"statsig" options:NSCaseInsensitiveSearch].location != NSNotFound) continue;
        counts[index] = @(counts[index].unsignedIntegerValue + 1);
        if (buckets[index].count < kPerPattern) [buckets[index] addObject:(id)classes[i]];
    }
    free(classes);
    [out appendString:@"\n== class census\n"];
    for (NSUInteger i = 0; i < kPatternCount; i++) {
        [out appendFormat:@"pattern %s: %lu loaded, %lu kept\n", kPatterns[i], counts[i].unsignedLongValue, (unsigned long)buckets[i].count];
    }
    NSMutableDictionary<NSString *, NSMutableString *> *byImage = [NSMutableDictionary dictionary];
    NSUInteger kept = 0;
    for (NSUInteger p = 0; p < kPatternCount && kept < kDumpCap && fileRoom(out); p++) {
        [buckets[p] sortUsingComparator:^NSComparisonResult(id a, id b) {
            return [NSStringFromClass((Class)a) compare:NSStringFromClass((Class)b)];
        }];
        for (id item in buckets[p]) {
            if (kept >= kDumpCap || !fileRoom(out)) break;
            Class cls = (Class)item;
            const char *image = class_getImageName(cls);
            NSString *key = image ? @(image) : @"(no image)";
            NSMutableString *block = byImage[key];
            if (!block) {
                block = [NSMutableString string];
                byImage[key] = block;
            }
            appendClass(cls, block);
            kept++;
        }
    }
    *dumped = kept;
    [out appendFormat:@"dumped %lu classes\n", (unsigned long)kept];
    for (NSString *key in [byImage.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (!fileRoom(out)) break;
        [out appendFormat:@"\n== image %@\npath %@\n%@", key.lastPathComponent ?: key, key, byImage[key]];
    }
}

static void appendPlayback(NSMutableString *out) {
    [out appendString:@"\n== playback\n"];
    SPTPlayerState *state = nil;
    @try { state = SGPlayerState(); }
    @catch (NSException *ex) { state = nil; }
    if (!state) {
        [out appendString:@"player has not reported a state this launch\n"];
        return;
    }
    @try {
        SPTPlayerTrack *track = state.track;
        [out appendFormat:@"title: %@\nartist: %@\nuri: %@\npaused: %d\nplaying: %d\n",
                          clean(track.trackTitle), clean(track.artistName), clean(SGURIString(track.URI)), state.isPaused, state.isPlaying];
    } @catch (NSException *ex) {
        [out appendFormat:@"playback read stopped: %@\n", ex.name];
    }
}

static NSString *buildProbe(UIViewController *page, NSString *reason, NSUInteger *viewsOut, NSUInteger *cellsOut, NSUInteger *classesOut) {
    sg_deadline = CFAbsoluteTimeGetCurrent() + kBudget;
    sg_expired = NO;
    sg_nodes = 0;
    sg_interest = [NSMutableArray array];
    sg_observables = [NSMutableArray array];
    NSMutableString *out = [NSMutableString string];
    NSDateFormatter *stamp = [NSDateFormatter new];
    stamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    stamp.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
    NSString *spotify = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
    NSString *title = controllerTitle(page);
    NSString *className = page ? NSStringFromClass(object_getClass(page)) : @"(none)";
    [out appendFormat:@"spotifyplus stats probe\ntime: %@\nspotify: %@\nios: %@\nbuild: %s %s\n",
                       [stamp stringFromDate:NSDate.date], spotify, UIDevice.currentDevice.systemVersion, SG_BUILD_BRANCH, SG_BUILD];
    [out appendString:@"read-only. Ivars were read. Spotify getters that load or change state were not called. UIKit text, accessibility, contentSize, visible cells, and dataSource were read.\n"];
    [out appendFormat:@"page: %@\ntitle: \"%@\"\nmatched: %@\nhint: %@\n", className, clean(title), reason ?: @"?", pageHint(page)];
    Class chain = page ? object_getClass(page) : Nil;
    NSMutableArray<NSString *> *supers = [NSMutableArray array];
    while (chain && chain != NSObject.class && supers.count < 8) {
        [supers addObject:NSStringFromClass(chain)];
        chain = class_getSuperclass(chain);
    }
    [out appendFormat:@"class chain: %@\n", supers.count ? [supers componentsJoinedByString:@" → "] : @"(none)"];

    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    [out appendString:@"\n== view controllers\n"];
    if (page.navigationController) {
        appendCapped(out, @"navigation stack:\n");
        for (UIViewController *item in page.navigationController.viewControllers) {
            appendCapped(out, [NSString stringWithFormat:@"  %@%@%@\n", item == page ? @"* " : @"- ",
                                NSStringFromClass(object_getClass(item)),
                                controllerTitle(item).length ? [NSString stringWithFormat:@" title=\"%@\"", clean(controllerTitle(item))] : @""]);
        }
    }
    appendControllers(page, out, @"", 0, seen);

    NSUInteger views = 0;
    [out appendString:@"\n== view hierarchy\n"];
    if (page.isViewLoaded) {
        NSMutableSet<NSValue *> *viewSeen = [NSMutableSet set];
        appendHierarchy(page.view, out, @"", 0, viewSeen, &views);
    } else [out appendString:@"view not loaded\n"];
    *viewsOut = views;

    [out appendString:@"\n== cells\n"];
    NSMutableArray<UIView *> *cells = [NSMutableArray array];
    NSMutableSet<NSValue *> *cellSeen = [NSMutableSet set];
    NSUInteger visited = 0;
    if (page.isViewLoaded) collectExistingCells(page.view, cells, cellSeen, 0, &visited);
    *cellsOut = cells.count;
    NSUInteger index = 0;
    for (UIView *cell in cells) {
        if (!room(out)) break;
        NSString *path = indexPathText(cell);
        appendCapped(out, [NSString stringWithFormat:@"cell %lu %@%@ id=%@ label=\"%@\" value=\"%@\"\n", (unsigned long)index,
                            NSStringFromClass(object_getClass(cell)),
                            path ? [NSString stringWithFormat:@" path=%@", path] : @"",
                            clean(cell.accessibilityIdentifier), clean(cell.accessibilityLabel), clean(cell.accessibilityValue)]);
        NSUInteger labels = 0;
        appendLabelLines(cell, out, @"  ", 0, &labels);
        appendObject(cell, out, @"  ", 0, seen, [NSString stringWithFormat:@"cell%lu", (unsigned long)index]);
        index++;
    }
    if (page.isViewLoaded) appendSources(page.view, out, seen, page);

    [out appendString:@"\n== observables\n"];
    if (!sg_observables.count) [out appendString:@"(none named on the objects walked)\n"];
    for (NSString *line in sg_observables) appendCapped(out, [line stringByAppendingString:@"\n"]);

    [out appendString:@"\n== interest\n"];
    [out appendString:@"ivar names that look like minutes, friends, avatars, play counts, trend, streak, week, or now playing\n"];
    if (!sg_interest.count) [out appendString:@"(none on the objects walked)\n"];
    for (NSString *line in sg_interest) appendCapped(out, [line stringByAppendingString:@"\n"]);

    if ([page respondsToSelector:@selector(_printHierarchy)]) {
        [out appendString:@"\n== controller hierarchy (system)\n"];
        @try {
            NSString *tree = [page _printHierarchy];
            if (tree.length > 12000) tree = [[tree substringToIndex:12000] stringByAppendingString:@"\n…truncated\n"];
            appendCapped(out, tree ?: @"(empty)\n");
            if (tree && ![tree hasSuffix:@"\n"]) [out appendString:@"\n"];
        } @catch (NSException *ex) {
            [out appendFormat:@"unreadable (%@)\n", ex.name];
        }
    }

    appendPlayback(out);
    NSUInteger dumped = 0;
    appendClassCensus(out, &dumped);
    *classesOut = dumped;
    if (sg_expired) [out appendString:@"\nstopped: time budget\n"];
    if (out.length > kMaxFile) {
        [out deleteCharactersInRange:NSMakeRange(kMaxFile, out.length - kMaxFile)];
        [out appendString:@"\nstopped: size cap\n"];
    }
    sg_interest = nil;
    sg_observables = nil;
    return out;
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

static void dumpNow(void) {
    NSString *reason = nil;
    UIViewController *page = statsPage(&reason);
    if (!page) {
        sg_busy = NO;
        toast(@"Stats page is not on screen");
        return;
    }
    NSUInteger views = 0, cells = 0, classes = 0;
    NSString *text = nil;
    NSString *className = NSStringFromClass(object_getClass(page));
    NSString *title = controllerTitle(page);
    NSString *hint = pageHint(page);
    @try {
        text = buildProbe(page, reason, &views, &cells, &classes);
    } @catch (NSException *ex) {
        sg_busy = NO;
        SGLog(@"stats probe: stopped (%@)", ex.name);
        toast(@"Stats probe stopped");
        return;
    }
    NSDateFormatter *fileStamp = [NSDateFormatter new];
    fileStamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fileStamp.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *dir = documentsDir();
    NSString *name = [NSString stringWithFormat:@"spotifyplus-stats-probe-%@-%@.txt", [fileStamp stringFromDate:NSDate.date], hint];
    NSString *path = dir ? [dir stringByAppendingPathComponent:name] : nil;
    NSString *summary = [NSString stringWithFormat:@"stats probe: saved %@ page %@ title %@, %lu views, %lu cells, %lu classes%@",
                                                   name, className, title.length ? title : @"(none)", (unsigned long)views, (unsigned long)cells,
                                                   (unsigned long)classes, (sg_expired || text.length >= kMaxFile) ? @", truncated" : @""];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        BOOL ok = path && [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_busy = NO;
            if (!ok) {
                SGLog(@"stats probe: could not write (%@)", error.domain ?: @"file");
                toast(@"Stats probe could not save");
                return;
            }
            sg_lastPath = path;
            SGLog(@"%@", summary);
            toast(@"Stats probe saved");
            presentFile(path);
        });
    });
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
    NSString *reason = nil;
    UIViewController *page = nil;
    UIViewController *leaf = nil;
    @try { leaf = visibleLeaf(); }
    @catch (NSException *ex) { leaf = nil; }
    NSString *leafTitle = controllerTitle(leaf);
    BOOL laidOut = leaf.isViewLoaded && leaf.view.bounds.size.height > 2;
    BOOL sameLeaf = laidOut && sg_cacheValid && leaf == sg_cacheLeaf && (leafTitle == sg_cacheTitle || [leafTitle isEqualToString:sg_cacheTitle]);
    if (sameLeaf) {
        page = sg_cacheMatch ? leaf : nil;
        reason = sg_cacheReason;
    } else {
        @try { page = statsPage(&reason); }
        @catch (NSException *ex) { page = nil; }
        sg_cacheLeaf = leaf;
        sg_cacheTitle = leafTitle;
        sg_cacheReason = reason;
        sg_cacheMatch = page != nil;
        // A page with no height yet has not laid out its title, so the next pass looks again.
        sg_cacheValid = laidOut;
    }
    if (!page) {
        sg_loggedPage = nil;
        sg_probeButton.hidden = YES;
        return;
    }
    NSString *title = controllerTitle(page);
    NSString *key = [NSString stringWithFormat:@"%@|%@", NSStringFromClass(object_getClass(page)), title ?: @""];
    if (![sg_loggedPage isEqualToString:key]) {
        sg_loggedPage = key;
        SGLog(@"stats probe: page %@ title %@", NSStringFromClass(object_getClass(page)), title.length ? title : @"(none)");
    }
    UIWindow *window = keyWindow();
    if (!window) return;
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
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), (uint64_t)(1.2 * NSEC_PER_SEC), (uint64_t)(0.2 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{ refreshProbe(); });
    dispatch_resume(timer);
}

void SGStatsProbeShareLast(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGStatsProbeShareLast(); });
        return;
    }
    NSString *path = sg_lastPath ?: newestProbePath();
    if (!path || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        alert(@"No stats probe yet", @"Open Statistiche di ascolto and tap Probe, then share the file.");
        return;
    }
    presentFile(path);
}

__attribute__((constructor)) static void SGStatsProbeInit(void) {
    installProbe();
}
