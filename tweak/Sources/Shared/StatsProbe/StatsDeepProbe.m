// Deep stats probe: ElementKit Props / ivars on HighlightsStats views already on screen,
// plus a class index of loaded HighlightsStats_* types. Read-only. No network, no setters.
// Called from the Deep pill in StatsProbe.m while SGKeyStatsProbe is on.
#import "StatsDeepProbe.h"
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import <math.h>
#import <objc/runtime.h>
#import <string.h>

#ifndef SG_BUILD
#define SG_BUILD "unknown"
#endif
#ifndef SG_BUILD_BRANCH
#define SG_BUILD_BRANCH "unknown"
#endif

static const NSTimeInterval kBudget = 2.0;
static const NSUInteger kMaxFile = 700 * 1024;
static const NSUInteger kMaxString = 200;
static const NSUInteger kMaxIvars = 40;
static const NSUInteger kMaxInteresting = 48;
static const NSUInteger kMaxVisited = 800;
static const NSUInteger kMaxElements = 8;
static const NSUInteger kMaxClasses = 80;

static CFAbsoluteTime sg_deadline;
static BOOL sg_expired;
static NSUInteger sg_nodes;
static NSUInteger sg_toastGen;
static __weak UILabel *sg_toast;
static NSString *sg_lastDeepPath;

static BOOL budgetHit(void) {
    if (sg_expired) return YES;
    if (CFAbsoluteTimeGetCurrent() > sg_deadline) sg_expired = YES;
    return sg_expired;
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
    if (!type) return type;
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' || *type == 'O' ||
           *type == 'R' || *type == 'V') type++;
    return type;
}

static BOOL plainFoundation(id obj, Class kind) {
    if (!obj || ![obj isKindOfClass:kind]) return NO;
    NSString *name = NSStringFromClass(object_getClass(obj));
    if ([name containsString:@"Swift"] || [name containsString:@"Deferred"] || [name hasPrefix:@"_Tt"]) return NO;
    return [name hasPrefix:@"NS"] || [name hasPrefix:@"__NS"];
}

static NSString *describePlain(id value) {
    if (!value || value == NSNull.null) return @"nil";
    if (plainFoundation(value, NSString.class)) return [NSString stringWithFormat:@"\"%@\"", clean(value)];
    if (plainFoundation(value, NSNumber.class)) return [(NSNumber *)value stringValue];
    if (plainFoundation(value, NSURL.class)) return [NSString stringWithFormat:@"\"%@\"", clean([(NSURL *)value absoluteString])];
    if (plainFoundation(value, NSDate.class)) return [(NSDate *)value description];
    if (plainFoundation(value, NSData.class)) return [NSString stringWithFormat:@"<NSData %lu>", (unsigned long)[(NSData *)value length]];
    return nil;
}

static NSString *primitiveIvar(id object, Ivar ivar) {
    const char *type = skipQualifiers(ivar_getTypeEncoding(ivar));
    if (!type || !type[0]) return nil;
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
    if (offset < 0 || (size_t)offset + len > class_getInstanceSize(cls)) return nil;
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

static BOOL interestingClass(NSString *name) {
    if (!name.length) return NO;
    NSString *lower = name.lowercaseString;
    static NSArray<NSString *> *needles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        needles = @[
            @"highlightsstats", @"statstile", @"statsdetails", @"usertimeline",
            @"timelinedate", @"summarystats", @"leaderboard", @"addfriends", @"playindicator",
            @"elementcontentview", @"elementview", @"elementkit", @"ecmkit",
        ];
    });
    for (NSString *n in needles) {
        if ([lower containsString:n]) return YES;
    }
    return NO;
}

#pragma mark - UI helpers

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

static NSString *navTitle(UIViewController *vc) {
    if (!vc) return nil;
    @try {
        if (vc.title.length) return vc.title;
        if (vc.navigationItem.title.length) return vc.navigationItem.title;
        UINavigationController *nav = vc.navigationController;
        if (nav.visibleViewController == vc && nav.navigationBar.topItem.title.length) return nav.navigationBar.topItem.title;
        if (nav.navigationBar.accessibilityIdentifier.length) return nav.navigationBar.accessibilityIdentifier;
    } @catch (NSException *ex) {
        return nil;
    }
    return nil;
}

static NSString *pageHint(NSString *text) {
    if (!text.length) return @"page";
    NSString *lower = text.lowercaseString;
    NSString *hint = @"page";
    if ([lower containsString:@"minuti"] || [lower containsString:@"minute"]) hint = @"minuti";
    else if ([lower containsString:@"preferit"] || [lower containsString:@"favorite"] || [lower containsString:@"favourite"] || [lower containsString:@"liked"]) hint = @"preferiti";
    else if ([lower containsString:@"artist"]) hint = @"artisti";
    else if ([lower containsString:@"brani"] || [lower containsString:@"song"] || [lower containsString:@"track"]) hint = @"brani";
    else if ([lower containsString:@"statistiche"] || [lower containsString:@"statistic"] || [lower containsString:@"listening"]) hint = @"home";
    if (![hint isEqualToString:@"home"] && ([lower containsString:@"con amici"] || [lower containsString:@"with friends"] || [lower containsString:@"gli amici"]))
        hint = [hint stringByAppendingString:@"-amici"];
    NSMutableString *safe = [NSMutableString string];
    for (NSUInteger i = 0; i < hint.length && safe.length < 28; i++) {
        unichar c = [hint characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') [safe appendFormat:@"%C", c];
    }
    return safe.length ? safe : @"page";
}

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
        label.accessibilityIdentifier = @"spotifyplus.stats-deep";
        [window addSubview:label];
        sg_toast = label;
    }
    label.text = text;
    CGFloat width = MIN(window.bounds.size.width - 48, 340);
    CGSize size = [label sizeThatFits:CGSizeMake(width - 28, 220)];
    CGFloat height = size.height + 22;
    CGFloat bottom = window.safeAreaInsets.bottom + 160;
    label.frame = CGRectMake((window.bounds.size.width - width) / 2, window.bounds.size.height - bottom - height, width, height);
    label.alpha = 1;
    [window bringSubviewToFront:label];
    NSUInteger gen = ++sg_toastGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen != sg_toastGen) return;
        [sg_toast removeFromSuperview];
    });
}

static void presentFile(NSString *path) {
    UIViewController *top = visibleLeaf() ?: SGTopController();
    if (!top || !path.length || !top.view) return;
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    sheet.popoverPresentationController.sourceView = top.view;
    [top presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - object walk (crash-safe)

// Only Foundation object encodings are read. Swift Props / ElementKit ivars are often
// opaque `@` with no class name — object_getIvar + NSStringFromClass on those SIGSEGVs.
// objc_msgSend of props/model did the same. We list name + encoding for those instead.

static NSString *declaredClass(const char *type) {
    type = skipQualifiers(type);
    if (!type || type[0] != '@' || type[1] != '"') return nil;
    const char *start = type + 2;
    const char *end = strchr(start, '"');
    if (!end || end <= start) return nil;
    return [[NSString alloc] initWithBytes:start length:(NSUInteger)(end - start) encoding:NSUTF8StringEncoding];
}

static BOOL safeFoundationDeclared(NSString *name) {
    if (!name.length) return NO;
    static NSSet<NSString *> *ok;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ok = [NSSet setWithArray:@[
            @"NSString", @"NSMutableString", @"NSNumber", @"NSURL", @"NSDate", @"NSData", @"NSMutableData",
            @"NSArray", @"NSMutableArray", @"NSDictionary", @"NSMutableDictionary",
            @"NSSet", @"NSMutableSet", @"NSOrderedSet", @"NSMutableOrderedSet",
            @"__NSCFString", @"__NSCFNumber", @"__NSCFBoolean", @"__NSCFArray", @"__NSCFDictionary",
            @"NSTaggedPointerString", @"NSUUID", @"NSValue",
        ]];
    });
    return [ok containsObject:name];
}

static void dumpSafeIvars(id object, NSMutableString *out, NSString *indent) {
    if (!object || budgetHit()) return;
    Class cls = object_getClass(object);
    Class stop = NSObject.class;
    @try {
        if ([object isKindOfClass:UIView.class]) stop = UIView.class;
        else if ([object isKindOfClass:UIViewController.class]) stop = UIViewController.class;
    } @catch (NSException *ex) {
        return;
    }
    NSUInteger levels = 0;
    while (cls && cls != stop && cls != NSObject.class && levels < 5 && !budgetHit()) {
        unsigned count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        NSUInteger shown = 0;
        for (unsigned i = 0; ivars && i < count && shown < kMaxIvars && !budgetHit(); i++) {
            const char *raw = ivar_getName(ivars[i]);
            NSString *name = raw ? @(raw) : @"?";
            const char *type = skipQualifiers(ivar_getTypeEncoding(ivars[i]));
            if (sensitiveName(name)) {
                appendCapped(out, [NSString stringWithFormat:@"%@ivar %@ [skipped]\n", indent, name]);
                shown++;
                continue;
            }
            if (!type || !type[0]) continue;
            if (type[0] == '@' && type[1] == '?') {
                appendCapped(out, [NSString stringWithFormat:@"%@ivar %@ block\n", indent, name]);
                shown++;
                continue;
            }
            if (type[0] == '@') {
                NSString *declared = declaredClass(type);
                if (!safeFoundationDeclared(declared)) {
                    appendCapped(out, [NSString stringWithFormat:@"%@ivar %@ unread `%s`%@\n", indent, name, type,
                                        declared ? [NSString stringWithFormat:@" declared %@", declared] : @""]);
                    shown++;
                    continue;
                }
                id value = nil;
                @try { value = object_getIvar(object, ivars[i]); }
                @catch (NSException *ex) {
                    appendCapped(out, [NSString stringWithFormat:@"%@ivar %@ unreadable\n", indent, name]);
                    shown++;
                    continue;
                }
                NSString *asPlain = describePlain(value);
                if (asPlain) {
                    appendCapped(out, [NSString stringWithFormat:@"%@ivar %@=%@\n", indent, name, asPlain]);
                } else if (plainFoundation(value, NSArray.class)) {
                    NSArray *list = value;
                    appendCapped(out, [NSString stringWithFormat:@"%@ivar %@ array %lu\n", indent, name, (unsigned long)list.count]);
                    NSUInteger n = MIN(list.count, kMaxElements);
                    for (NSUInteger e = 0; e < n; e++) {
                        NSString *itemPlain = describePlain(list[e]);
                        appendCapped(out, [NSString stringWithFormat:@"%@  [%lu] %@\n", indent, (unsigned long)e,
                                            itemPlain ?: [NSString stringWithFormat:@"<%@>", NSStringFromClass(object_getClass(list[e]))]]);
                    }
                } else if (plainFoundation(value, NSDictionary.class)) {
                    NSDictionary *map = value;
                    appendCapped(out, [NSString stringWithFormat:@"%@ivar %@ dictionary %lu\n", indent, name, (unsigned long)map.count]);
                    NSUInteger n = 0;
                    @try {
                        for (id key in map) {
                            if (n >= kMaxElements) break;
                            NSString *keyText = plainFoundation(key, NSString.class) ? key : @"?";
                            if (sensitiveName(keyText)) continue;
                            appendCapped(out, [NSString stringWithFormat:@"%@  %@=%@\n", indent, clip(keyText),
                                                describePlain(map[key]) ?: @"<?>"]);
                            n++;
                        }
                    } @catch (NSException *ex) {}
                } else if (!value) {
                    appendCapped(out, [NSString stringWithFormat:@"%@ivar %@ nil declared %@\n", indent, name, declared]);
                } else {
                    appendCapped(out, [NSString stringWithFormat:@"%@ivar %@ <%@>\n", indent, name, NSStringFromClass(object_getClass(value))]);
                }
                shown++;
                continue;
            }
            // Structs / primitives: print encoding; try primitive read when size is known.
            NSString *text = nil;
            @try { text = primitiveIvar(object, ivars[i]); }
            @catch (NSException *ex) { text = nil; }
            if (text) appendCapped(out, [NSString stringWithFormat:@"%@ivar %@=%@\n", indent, name, text]);
            else appendCapped(out, [NSString stringWithFormat:@"%@ivar %@ type `%s`\n", indent, name, type]);
            shown++;
        }
        free(ivars);
        cls = class_getSuperclass(cls);
        levels++;
        sg_nodes++;
    }
}

static void dumpLabelsOn(UIView *view, NSMutableString *out, NSString *indent, NSUInteger depth, NSUInteger *visited) {
    if (!view || depth > 6 || *visited >= 120 || budgetHit()) return;
    (*visited)++;
    @try {
        if (view.hidden) return;
        if ([view isKindOfClass:UILabel.class]) {
            NSString *text = ((UILabel *)view).text;
            if (text.length) appendCapped(out, [NSString stringWithFormat:@"%@label \"%@\"\n", indent, clean(text)]);
        }
        NSString *al = view.accessibilityLabel;
        if (al.length && al.length < 120) appendCapped(out, [NSString stringWithFormat:@"%@a11y \"%@\"\n", indent, clean(al)]);
    } @catch (NSException *ex) {
        return;
    }
    NSArray *subs = nil;
    @try { subs = [view.subviews copy]; }
    @catch (NSException *ex) { return; }
    for (UIView *sub in subs) dumpLabelsOn(sub, out, indent, depth + 1, visited);
}

static void collectInteresting(UIView *view, NSMutableArray<UIView *> *hits, NSUInteger depth, NSUInteger *visited) {
    if (!view || depth > 14 || *visited >= kMaxVisited || hits.count >= kMaxInteresting || budgetHit()) return;
    (*visited)++;
    @try {
        if (view.hidden || view.alpha < 0.01) return;
        NSString *name = NSStringFromClass(object_getClass(view));
        if (interestingClass(name)) [hits addObject:view];
        else if ([view isKindOfClass:UICollectionViewCell.class] || [view isKindOfClass:UITableViewCell.class]) {
            for (UIView *sub in view.subviews) {
                if (interestingClass(NSStringFromClass(object_getClass(sub)))) {
                    [hits addObject:view];
                    break;
                }
            }
        }
    } @catch (NSException *ex) {
        return;
    }
    NSArray *subs = nil;
    @try { subs = [view.subviews copy]; }
    @catch (NSException *ex) { return; }
    for (UIView *sub in subs) collectInteresting(sub, hits, depth + 1, visited);
}

static void dumpClassIndex(NSMutableString *out) {
    appendCapped(out, @"== HighlightsStats classes (loaded)\n");
    unsigned total = 0;
    Class *classes = objc_copyClassList(&total);
    NSUInteger kept = 0;
    for (unsigned i = 0; classes && i < total && kept < kMaxClasses && !budgetHit(); i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if (![name containsString:@"HighlightsStats"]) continue;
        appendCapped(out, [NSString stringWithFormat:@"%@\n", name]);
        unsigned count = 0;
        Ivar *ivars = class_copyIvarList(classes[i], &count);
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (unsigned j = 0; ivars && j < count && names.count < 24; j++) {
            const char *raw = ivar_getName(ivars[j]);
            const char *type = ivar_getTypeEncoding(ivars[j]);
            if (!raw) continue;
            NSString *n = @(raw);
            if (sensitiveName(n)) continue;
            [names addObject:[NSString stringWithFormat:@"%@ `%@`", n, type ? @(type) : @"?"]];
        }
        free(ivars);
        if (names.count) appendCapped(out, [NSString stringWithFormat:@"  ivars: %@\n", [names componentsJoinedByString:@", "]]);
        kept++;
    }
    free(classes);
    appendCapped(out, [NSString stringWithFormat:@"classes listed: %lu\n\n", (unsigned long)kept]);
}

static void flushOut(NSFileHandle *file, NSMutableString *out) {
    if (!file || !out.length) return;
    NSData *data = [out dataUsingEncoding:NSUTF8StringEncoding];
    @try {
        [file writeData:data];
        [file synchronizeFile];
    } @catch (NSException *ex) {
        SGLog(@"stats deep: write stopped (%@)", ex.name);
    }
    [out setString:@""];
}

#pragma mark - run

static NSString *documentsDir(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

NSString *SGStatsDeepNewestPath(void) {
    NSString *dir = documentsDir();
    if (!dir) return nil;
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
    NSString *best = nil;
    for (NSString *name in names) {
        if (![name hasPrefix:@"spotifyplus-stats-deep-"] || ![name hasSuffix:@".txt"]) continue;
        if (!best || [name compare:best] == NSOrderedDescending) best = name;
    }
    return best ? [dir stringByAppendingPathComponent:best] : nil;
}

NSString *SGStatsDeepLastPath(void) {
    return sg_lastDeepPath ?: SGStatsDeepNewestPath();
}

void SGStatsDeepDump(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGStatsDeepDump(); });
        return;
    }
    sg_deadline = CFAbsoluteTimeGetCurrent() + kBudget;
    sg_expired = NO;
    sg_nodes = 0;
    SGLog(@"stats deep: open");

    UIViewController *leaf = nil;
    @try { leaf = visibleLeaf(); }
    @catch (NSException *ex) { leaf = nil; }
    if (!leaf) {
        toast(@"Deep probe: no page");
        SGLog(@"stats deep: no leaf");
        return;
    }
    UIView *root = nil;
    @try { root = leaf.isViewLoaded ? leaf.view : nil; }
    @catch (NSException *ex) { root = nil; }
    NSString *title = navTitle(leaf);
    if (!title.length) {
        @try {
            UINavigationController *nav = leaf.navigationController ?: ([leaf isKindOfClass:UINavigationController.class] ? (UINavigationController *)leaf : nil);
            title = nav.navigationBar.accessibilityIdentifier;
        } @catch (NSException *ex) {
            title = nil;
        }
    }
    NSString *hint = pageHint(title);

    NSDateFormatter *fileStamp = [NSDateFormatter new];
    fileStamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fileStamp.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *dir = documentsDir();
    NSString *fileName = [NSString stringWithFormat:@"spotifyplus-stats-deep-%@-%@.txt", [fileStamp stringFromDate:NSDate.date], hint];
    NSString *path = dir ? [dir stringByAppendingPathComponent:fileName] : nil;
    if (!path || ![NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil]) {
        SGLog(@"stats deep: could not write (create)");
        toast(@"Deep probe could not save");
        return;
    }
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!file) {
        SGLog(@"stats deep: could not write (open)");
        toast(@"Deep probe could not save");
        return;
    }
    sg_lastDeepPath = path;

    NSMutableString *out = [NSMutableString string];
    NSDateFormatter *stamp = [NSDateFormatter new];
    stamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    stamp.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
    NSString *spotify = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
    appendCapped(out, [NSString stringWithFormat:
        @"spotifyplus stats deep probe\ntime: %@\nspotify: %@\nios: %@\nbuild: %s %s\ncrash-safe: Foundation ivars only; Swift/ElementKit Props listed as unread encodings. No objc_msgSend getters, no valueForKey.\nleaf: %@\ntitle: \"%@\"\nhint: %@\n\n",
        [stamp stringFromDate:NSDate.date], spotify, UIDevice.currentDevice.systemVersion, SG_BUILD_BRANCH, SG_BUILD,
        NSStringFromClass(object_getClass(leaf)), clean(title ?: @""), hint]);
    flushOut(file, out);

    @try { dumpClassIndex(out); }
    @catch (NSException *ex) {
        appendCapped(out, [NSString stringWithFormat:@"class index stopped (%@)\n\n", ex.name]);
    }
    flushOut(file, out);
    SGLog(@"stats deep: step classes");

    NSMutableArray<UIView *> *hits = [NSMutableArray array];
    NSUInteger visited = 0;
    @try {
        if (root) collectInteresting(root, hits, 0, &visited);
    } @catch (NSException *ex) {
        appendCapped(out, [NSString stringWithFormat:@"collect stopped (%@)\n", ex.name]);
    }
    appendCapped(out, [NSString stringWithFormat:@"== interesting views (%lu of %lu visited)\n", (unsigned long)hits.count, (unsigned long)visited]);
    flushOut(file, out);
    SGLog(@"stats deep: step views %lu", (unsigned long)hits.count);

    NSUInteger index = 0;
    for (UIView *view in hits) {
        if (budgetHit()) break;
        NSString *name = @"?";
        NSString *label = nil;
        NSString *ident = nil;
        CGRect frame = CGRectZero;
        @try {
            name = NSStringFromClass(object_getClass(view));
            label = view.accessibilityLabel;
            ident = view.accessibilityIdentifier;
            frame = view.frame;
        } @catch (NSException *ex) {
            appendCapped(out, [NSString stringWithFormat:@"\n-- [%lu] unreadable (%@)\n", (unsigned long)index, ex.name]);
            flushOut(file, out);
            index++;
            continue;
        }
        appendCapped(out, [NSString stringWithFormat:@"\n-- [%lu] %@ %@ a11y id=%@ label=\"%@\"\n",
                            (unsigned long)index, name, NSStringFromCGRect(frame),
                            clean(ident ?: @""), clean(label ?: @"")]);
        @try { dumpSafeIvars(view, out, @"  "); }
        @catch (NSException *ex) {
            appendCapped(out, [NSString stringWithFormat:@"  ivars stopped (%@)\n", ex.name]);
        }
        NSUInteger labelVisits = 0;
        @try { dumpLabelsOn(view, out, @"  ", 0, &labelVisits); }
        @catch (NSException *ex) {}
        if ([view isKindOfClass:UICollectionViewCell.class] || [view isKindOfClass:UITableViewCell.class]) {
            @try {
                UIView *content = [(id)view contentView];
                NSArray<UIView *> *kids = content.subviews.count ? content.subviews : view.subviews;
                for (UIView *sub in kids) {
                    NSString *subName = NSStringFromClass(object_getClass(sub));
                    if (!interestingClass(subName)) continue;
                    appendCapped(out, [NSString stringWithFormat:@"  content %@\n", subName]);
                    dumpSafeIvars(sub, out, @"    ");
                    break;
                }
            } @catch (NSException *ex) {}
        }
        flushOut(file, out);
        index++;
    }
    appendCapped(out, [NSString stringWithFormat:@"\nnodes: %lu\nbudget hit: %@\nviews written: %lu\n",
                        (unsigned long)sg_nodes, budgetHit() ? @"yes" : @"no", (unsigned long)index]);
    flushOut(file, out);
    @try { [file closeFile]; }
    @catch (NSException *ex) {}

    SGLog(@"stats deep: saved %@ title %@, %lu views, %lu nodes",
          fileName, title.length ? title : @"(none)", (unsigned long)index, (unsigned long)sg_nodes);
    toast(@"Deep probe saved");
    presentFile(path);
}
