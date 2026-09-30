// What a running Spotify already exposes about a Jam, written down without poking it.
//
// No class is hooked and no selector is invented. Names come from objc_copyClassList and from
// the views on screen. Methods are listed, not called, except property getters whose names are
// plain reads (no argument, and not an action such as join, add, skip, or play) plus the player
// fields SPTPlayer.h already declares. UIKit is touched on the main thread only. A short time
// budget and hard caps stop the walk if the process is full of matches.
#import "JamProbe.h"
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Player/PlayerState.h"
#import <objc/message.h>
#import <objc/runtime.h>

#ifndef SG_BUILD
#define SG_BUILD "unknown"
#endif
#ifndef SG_BUILD_BRANCH
#define SG_BUILD_BRANCH "unknown"
#endif

static const NSTimeInterval kDelay = 3;
static const NSTimeInterval kBudget = 1.6;
static const NSUInteger kPerPattern = 40;
static const NSUInteger kDumpCap = 200;
static const NSUInteger kMaxMethods = 48;
static const NSUInteger kMaxIvars = 36;
static const NSUInteger kMaxProperties = 24;
static const NSUInteger kMaxProtocols = 12;
static const NSUInteger kMaxVCs = 80;
static const NSUInteger kMaxDepth = 8;
static const NSUInteger kMaxViewDepth = 14;
static const NSUInteger kMaxVisitedViews = 3500;
static const NSUInteger kMaxMatchViews = 120;
static const NSUInteger kMaxCells = 36;
static const NSUInteger kMaxLabels = 10;
static const NSUInteger kMaxElements = 6;
static const NSUInteger kMaxString = 160;
static const NSUInteger kMaxFile = 700000;

static const char *kPatterns[] = {
    "jam", "participant", "collaborat", "listening", "party", "member", "queue", "social", "session", "shared",
};
static const NSUInteger kPatternCount = sizeof kPatterns / sizeof kPatterns[0];

static BOOL sg_busy = NO;
static NSString *sg_lastPath;
static CFAbsoluteTime sg_deadline;
static BOOL sg_expired;
static NSUInteger sg_toastGen;
static __weak UILabel *sg_toast;

static BOOL budgetHit(void) {
    if (sg_expired) return YES;
    if (CFAbsoluteTimeGetCurrent() > sg_deadline) sg_expired = YES;
    return sg_expired;
}

static NSString *clip(NSString *text) {
    if (!text) return @"";
    NSString *one = [[text stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
        stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    if (one.length > kMaxString) one = [[one substringToIndex:kMaxString] stringByAppendingString:@"…"];
    return one;
}

// Field names that carry credentials are omitted. A value that already looks like a token is
// replaced, so a participant name still comes through.
static BOOL sensitiveName(NSString *name) {
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

static int patternIndex(NSString *name) {
    if (!name.length) return -1;
    NSString *lower = name.lowercaseString;
    for (NSUInteger i = 0; i < kPatternCount; i++) {
        if ([lower containsString:@(kPatterns[i])]) return (int)i;
    }
    return -1;
}

static BOOL nameMatches(NSString *name) {
    return patternIndex(name) >= 0;
}

static NSString *firstWord(NSString *name) {
    if (!name.length) return @"";
    NSMutableString *word = [NSMutableString string];
    [word appendFormat:@"%C", [name characterAtIndex:0]];
    for (NSUInteger i = 1; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if ([[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:c]) break;
        [word appendFormat:@"%C", c];
    }
    return word.lowercaseString;
}

// The first camel-case word is the verb. "addedBy" stays, because its word is "added", not "add".
// "play" and "skipTo" do not. A leading underscore is private and is not called.
static BOOL selectorAllowed(SEL sel) {
    NSString *name = NSStringFromSelector(sel);
    if (!name.length || [name containsString:@":"] || [name hasPrefix:@"_"]) return NO;
    if (sensitiveName(name)) return NO;
    static NSSet<NSString *> *denied;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        denied = [NSSet setWithArray:@[
            @"action", @"join", @"leave", @"add", @"remove", @"invite", @"share", @"start", @"end", @"play", @"skip",
            @"set", @"init", @"dealloc", @"copy", @"mutablecopy", @"perform", @"send", @"post", @"fetch", @"request",
            @"load", @"reload", @"refresh", @"update", @"delete", @"create", @"open", @"close", @"dismiss", @"present",
            @"push", @"pop", @"login", @"logout", @"connect", @"disconnect", @"subscribe", @"unsubscribe", @"follow",
            @"unfollow", @"message", @"notify", @"alloc", @"new", @"begin", @"commit", @"cancel", @"stop", @"resume",
            @"pause", @"seek", @"insert", @"append", @"write", @"save", @"apply", @"enable", @"disable", @"register",
            @"unregister", @"observe", @"schedule", @"invoke", @"call", @"fire", @"trigger", @"handle", @"view",
            @"window", @"layer", @"superview", @"subviews", @"description", @"debug", @"hash", @"class", @"self",
            @"zone", @"retain", @"release", @"autorelease", @"mutable", @"presented", @"presenting", @"navigation",
            @"child", @"parent", @"toolbar", @"storyboard", @"nib", @"popover", @"modal",
        ]];
    });
    return ![denied containsObject:firstWord(name)];
}

static const char *skipQualifiers(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL plainFoundation(id obj, Class kind) {
    if (!obj || ![obj isKindOfClass:kind]) return NO;
    NSString *name = NSStringFromClass(object_getClass(obj));
    if ([name containsString:@"Swift"] || [name containsString:@"Deferred"] || [name hasPrefix:@"_Tt"]) return NO;
    return [name hasPrefix:@"NS"] || [name hasPrefix:@"__NS"];
}

static BOOL appendCapped(NSMutableString *out, NSString *line) {
    if (out.length >= kMaxFile) return NO;
    [out appendString:line];
    return out.length < kMaxFile;
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

static NSString *describePlain(id value) {
    if (!value || value == NSNull.null) return @"nil";
    if (plainFoundation(value, NSString.class)) return [NSString stringWithFormat:@"\"%@\"", clean(value)];
    if (plainFoundation(value, NSNumber.class)) return [(NSNumber *)value stringValue];
    if (plainFoundation(value, NSURL.class)) return [NSString stringWithFormat:@"\"%@\"", clean([(NSURL *)value absoluteString])];
    if (plainFoundation(value, NSDate.class)) return [(NSDate *)value description];
    return nil;
}

static void appendStringFields(id object, NSMutableString *out, NSString *indent) {
    if (!object || budgetHit()) return;
    NSString *plain = describePlain(object);
    if (plain) {
        appendCapped(out, [NSString stringWithFormat:@"%@%@\n", indent, plain]);
        return;
    }
    if ([object isKindOfClass:UIView.class] || [object isKindOfClass:UIViewController.class] || [object isKindOfClass:CALayer.class]) {
        appendCapped(out, [NSString stringWithFormat:@"%@%@\n", indent, NSStringFromClass(object_getClass(object))]);
        return;
    }
    Class cls = object_getClass(object);
    unsigned count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    NSUInteger shown = 0;
    for (unsigned i = 0; ivars && i < count && shown < 8 && !budgetHit(); i++) {
        const char *raw = ivar_getName(ivars[i]);
        NSString *name = raw ? @(raw) : @"?";
        if (sensitiveName(name)) continue;
        const char *type = skipQualifiers(ivar_getTypeEncoding(ivars[i]));
        if (type && type[0] == '@') {
            id value = nil;
            @try { value = object_getIvar(object, ivars[i]); }
            @catch (NSException *ex) { value = nil; }
            NSString *text = describePlain(value);
            if (!text) continue;
            appendCapped(out, [NSString stringWithFormat:@"%@%@=%@\n", indent, name, text]);
            shown++;
        } else {
            NSString *text = nil;
            @try { text = primitiveIvar(object, ivars[i]); }
            @catch (NSException *ex) { text = nil; }
            if (!text) continue;
            appendCapped(out, [NSString stringWithFormat:@"%@%@=%@\n", indent, name, text]);
            shown++;
        }
    }
    free(ivars);
    if (!shown) appendCapped(out, [NSString stringWithFormat:@"%@%@\n", indent, NSStringFromClass(cls)]);
}

static SEL propertyGetter(objc_property_t prop) {
    const char *attrs = property_getAttributes(prop);
    if (attrs) {
        const char *marker = strstr(attrs, ",G");
        if (marker) {
            marker += 2;
            const char *end = strchr(marker, ',');
            size_t length = end ? (size_t)(end - marker) : strlen(marker);
            if (length > 0 && length < 128) {
                char buf[128];
                memcpy(buf, marker, length);
                buf[length] = 0;
                return sel_registerName(buf);
            }
        }
    }
    const char *name = property_getName(prop);
    return name ? sel_registerName(name) : NULL;
}

static NSString *callPrimitive(id object, SEL sel, const char *type) {
    @try {
        switch (type[0]) {
            case 'B': case 'C': case 'c': {
                char (*fn)(id, SEL) = (char (*)(id, SEL))objc_msgSend;
                return [NSString stringWithFormat:@"%d", (int)fn(object, sel)];
            }
            case 's': case 'S': {
                short (*fn)(id, SEL) = (short (*)(id, SEL))objc_msgSend;
                return [NSString stringWithFormat:@"%d", (int)fn(object, sel)];
            }
            case 'i': case 'I': {
                int (*fn)(id, SEL) = (int (*)(id, SEL))objc_msgSend;
                return [NSString stringWithFormat:@"%d", fn(object, sel)];
            }
            case 'q': case 'Q': {
                long long (*fn)(id, SEL) = (long long (*)(id, SEL))objc_msgSend;
                return [NSString stringWithFormat:@"%lld", fn(object, sel)];
            }
            case 'f': {
                float (*fn)(id, SEL) = (float (*)(id, SEL))objc_msgSend;
                float raw = fn(object, sel);
                return isfinite(raw) ? [NSString stringWithFormat:@"%g", raw] : @"nan";
            }
            case 'd': {
                double (*fn)(id, SEL) = (double (*)(id, SEL))objc_msgSend;
                double raw = fn(object, sel);
                return isfinite(raw) ? [NSString stringWithFormat:@"%g", raw] : @"nan";
            }
            default: return nil;
        }
    } @catch (NSException *ex) {
        return nil;
    }
}

// One call. Arrays and dictionaries are counted here; their elements are not messaged except for
// string and number fields already stored on them.
static NSString *callGetterOnce(id object, SEL sel, Method method) {
    const char *type = skipQualifiers(method_getTypeEncoding(method));
    if (!type || method_getNumberOfArguments(method) != 2) return nil;
    if (type[0] != '@') return callPrimitive(object, sel, type);
    @try {
        id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id value = fn(object, sel);
        if (!value) return @"nil";
        NSString *plain = describePlain(value);
        if (plain) return plain;
        if (plainFoundation(value, NSArray.class)) {
            NSArray *list = value;
            NSMutableString *extra = [NSMutableString stringWithFormat:@"array %lu", (unsigned long)list.count];
            NSUInteger n = MIN(list.count, kMaxElements);
            for (NSUInteger e = 0; e < n && !budgetHit(); e++) {
                id item = list[e];
                [extra appendFormat:@"\n    [%lu] %@", (unsigned long)e, NSStringFromClass(object_getClass(item))];
                appendStringFields(item, extra, @"      ");
            }
            return extra;
        }
        if (plainFoundation(value, NSDictionary.class)) {
            NSDictionary *map = value;
            NSMutableString *extra = [NSMutableString stringWithFormat:@"dictionary %lu", (unsigned long)map.count];
            NSUInteger n = 0;
            for (id key in map) {
                if (n >= kMaxElements || budgetHit()) break;
                NSString *keyText = plainFoundation(key, NSString.class) ? key : NSStringFromClass(object_getClass(key));
                if (sensitiveName(keyText)) {
                    [extra appendFormat:@"\n    %@ [skipped]", keyText];
                    continue;
                }
                [extra appendFormat:@"\n    %@=%@", keyText, describePlain(map[key]) ?: NSStringFromClass(object_getClass(map[key]))];
                n++;
            }
            return extra;
        }
        return [NSString stringWithFormat:@"<%@>", NSStringFromClass(object_getClass(value))];
    } @catch (NSException *ex) {
        return nil;
    }
}

static void appendReadable(id object, NSMutableString *out, NSString *indent) {
    if (!object || budgetHit() || out.length >= kMaxFile) return;
    Class cls = object_getClass(object);
    unsigned count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    NSUInteger shown = 0;
    for (unsigned i = 0; ivars && i < count && shown < kMaxIvars && !budgetHit(); i++) {
        const char *raw = ivar_getName(ivars[i]);
        NSString *name = raw ? @(raw) : @"?";
        if (sensitiveName(name)) {
            appendCapped(out, [NSString stringWithFormat:@"%@ivar %@ [skipped]\n", indent, name]);
            continue;
        }
        const char *type = skipQualifiers(ivar_getTypeEncoding(ivars[i]));
        if (!type) continue;
        if (type[0] == '@') {
            id value = nil;
            @try { value = object_getIvar(object, ivars[i]); }
            @catch (NSException *ex) { continue; }
            NSString *plain = describePlain(value);
            if (plain) {
                appendCapped(out, [NSString stringWithFormat:@"%@ivar %@=%@\n", indent, name, plain]);
                shown++;
                continue;
            }
            if (plainFoundation(value, NSArray.class)) {
                NSArray *list = value;
                appendCapped(out, [NSString stringWithFormat:@"%@ivar %@ array %lu\n", indent, name, (unsigned long)list.count]);
                NSUInteger n = MIN(list.count, kMaxElements);
                for (NSUInteger e = 0; e < n && !budgetHit(); e++) {
                    id item = nil;
                    @try { item = list[e]; }
                    @catch (NSException *ex) { break; }
                    appendCapped(out, [NSString stringWithFormat:@"%@  [%lu] %@\n", indent, (unsigned long)e, NSStringFromClass(object_getClass(item))]);
                    appendStringFields(item, out, [indent stringByAppendingString:@"    "]);
                }
                shown++;
                continue;
            }
            if (plainFoundation(value, NSDictionary.class)) {
                NSDictionary *map = value;
                appendCapped(out, [NSString stringWithFormat:@"%@ivar %@ dictionary %lu\n", indent, name, (unsigned long)map.count]);
                NSUInteger n = 0;
                for (id key in map) {
                    if (n >= kMaxElements || budgetHit()) break;
                    NSString *keyText = plainFoundation(key, NSString.class) ? key : NSStringFromClass(object_getClass(key));
                    if (sensitiveName(keyText)) {
                        appendCapped(out, [NSString stringWithFormat:@"%@  %@ [skipped]\n", indent, keyText]);
                        continue;
                    }
                    id item = nil;
                    @try { item = map[key]; }
                    @catch (NSException *ex) { continue; }
                    NSString *text = describePlain(item);
                    appendCapped(out, [NSString stringWithFormat:@"%@  %@=%@\n", indent, keyText, text ?: NSStringFromClass(object_getClass(item))]);
                    n++;
                }
                shown++;
                continue;
            }
            if (value) {
                appendCapped(out, [NSString stringWithFormat:@"%@ivar %@ <%@>\n", indent, name, NSStringFromClass(object_getClass(value))]);
                if (![value isKindOfClass:UIView.class] && ![value isKindOfClass:UIViewController.class])
                    appendStringFields(value, out, [indent stringByAppendingString:@"  "]);
                shown++;
            }
        } else {
            NSString *text = nil;
            @try { text = primitiveIvar(object, ivars[i]); }
            @catch (NSException *ex) { text = nil; }
            if (!text) continue;
            appendCapped(out, [NSString stringWithFormat:@"%@ivar %@=%@\n", indent, name, text]);
            shown++;
        }
    }
    free(ivars);

    unsigned props = 0;
    objc_property_t *properties = class_copyPropertyList(cls, &props);
    NSUInteger called = 0;
    for (unsigned i = 0; properties && i < props && called < kMaxProperties && !budgetHit(); i++) {
        const char *raw = property_getName(properties[i]);
        NSString *name = raw ? @(raw) : @"?";
        SEL sel = propertyGetter(properties[i]);
        if (!sel || sensitiveName(name) || !selectorAllowed(sel)) {
            if (sensitiveName(name)) appendCapped(out, [NSString stringWithFormat:@"%@prop %@ [skipped]\n", indent, name]);
            continue;
        }
        Method method = class_getInstanceMethod(cls, sel);
        if (!method) continue;
        NSString *text = callGetterOnce(object, sel, method);
        if (!text) continue;
        appendCapped(out, [NSString stringWithFormat:@"%@prop %@=%@\n", indent, name, text]);
        called++;
    }
    free(properties);
}

static NSString *imageKey(Class cls) {
    const char *image = class_getImageName(cls);
    if (!image || !image[0]) return @"(no image)";
    return @(image);
}

static BOOL swiftName(NSString *name) {
    return [name hasPrefix:@"_Tt"] || [name containsString:@"."];
}

static void appendClass(Class cls, NSMutableString *out) {
    NSString *name = NSStringFromClass(cls);
    Class supercls = class_getSuperclass(cls);
    appendCapped(out, [NSString stringWithFormat:@"-- %@ [%@]\nsuperclass: %@\n", name, swiftName(name) ? @"swift" : @"objc",
                        supercls ? NSStringFromClass(supercls) : @"(none)"]);
    unsigned count = 0;
    Protocol *__unsafe_unretained *protocols = class_copyProtocolList(cls, &count);
    NSMutableArray<NSString *> *protocolNames = [NSMutableArray array];
    for (unsigned i = 0; protocols && i < count && protocolNames.count < kMaxProtocols; i++) {
        const char *raw = protocol_getName(protocols[i]);
        if (raw) [protocolNames addObject:@(raw)];
    }
    free(protocols);
    appendCapped(out, [NSString stringWithFormat:@"protocols: %@\n", protocolNames.count ? [protocolNames componentsJoinedByString:@", "] : @"(none)"]);

    unsigned ivars = 0;
    Ivar *ivarList = class_copyIvarList(cls, &ivars);
    NSMutableArray<NSString *> *ivarNames = [NSMutableArray array];
    for (unsigned i = 0; ivarList && i < ivars && ivarNames.count < kMaxIvars; i++) {
        const char *raw = ivar_getName(ivarList[i]);
        const char *type = ivar_getTypeEncoding(ivarList[i]);
        NSString *encoding = type ? @(type) : @"?";
        if (encoding.length > 80) encoding = [[encoding substringToIndex:80] stringByAppendingString:@"…"];
        [ivarNames addObject:[NSString stringWithFormat:@"%@ `%@`", raw ? @(raw) : @"?", encoding]];
    }
    unsigned ivarTotal = ivars;
    free(ivarList);
    appendCapped(out, [NSString stringWithFormat:@"ivars (%lu of %u): %@\n", (unsigned long)ivarNames.count, ivarTotal,
                        ivarNames.count ? [ivarNames componentsJoinedByString:@", "] : @"(none)"]);

    unsigned props = 0;
    objc_property_t *propList = class_copyPropertyList(cls, &props);
    NSMutableArray<NSString *> *propNames = [NSMutableArray array];
    for (unsigned i = 0; propList && i < props && propNames.count < kMaxProperties; i++) {
        const char *raw = property_getName(propList[i]);
        if (raw) [propNames addObject:@(raw)];
    }
    unsigned propTotal = props;
    free(propList);
    appendCapped(out, [NSString stringWithFormat:@"properties (%lu of %u): %@\n", (unsigned long)propNames.count, propTotal,
                        propNames.count ? [propNames componentsJoinedByString:@", "] : @"(none)"]);

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

static void appendClassCensus(NSMutableString *out, NSUInteger *dumped, NSUInteger *jamLoaded) {
    int total = 0;
    Class *classes = objc_copyClassList(&total);
    NSMutableArray<NSMutableArray *> *buckets = [NSMutableArray array];
    NSMutableArray<NSNumber *> *counts = [NSMutableArray array];
    for (NSUInteger i = 0; i < kPatternCount; i++) {
        [buckets addObject:[NSMutableArray array]];
        [counts addObject:@0];
    }
    for (int i = 0; classes && i < total && !budgetHit(); i++) {
        NSString *name = NSStringFromClass(classes[i]);
        int index = patternIndex(name);
        if (index < 0) continue;
        counts[index] = @(counts[index].unsignedIntegerValue + 1);
        if (buckets[index].count < kPerPattern) [buckets[index] addObject:(id)classes[i]];
    }
    free(classes);
    [out appendString:@"== class census\n"];
    for (NSUInteger i = 0; i < kPatternCount; i++) {
        [out appendFormat:@"pattern %s: %lu loaded, %lu kept\n", kPatterns[i], counts[i].unsignedLongValue, (unsigned long)buckets[i].count];
        if (i == 0) *jamLoaded = counts[0].unsignedIntegerValue;
    }
    NSMutableDictionary<NSString *, NSMutableString *> *byImage = [NSMutableDictionary dictionary];
    NSUInteger kept = 0;
    for (NSUInteger p = 0; p < kPatternCount && kept < kDumpCap && !budgetHit(); p++) {
        [buckets[p] sortUsingComparator:^NSComparisonResult(id a, id b) {
            return [NSStringFromClass((Class)a) compare:NSStringFromClass((Class)b)];
        }];
        for (id item in buckets[p]) {
            if (kept >= kDumpCap || budgetHit()) break;
            Class cls = (Class)item;
            NSString *key = imageKey(cls);
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
        NSString *base = key.lastPathComponent ?: key;
        [out appendFormat:@"\n== image %@\npath %@\n%@", base, key, byImage[key]];
    }
    if (sg_expired) [out appendString:@"class census stopped: time budget\n"];
}

static void walkControllers(UIViewController *vc, NSUInteger depth, NSMutableSet<NSValue *> *seen, NSMutableString *out, NSUInteger *count, NSUInteger *jamOnScreen) {
    if (!vc || depth > kMaxDepth || *count >= kMaxVCs || budgetHit()) return;
    NSValue *key = [NSValue valueWithNonretainedObject:vc];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    (*count)++;
    NSString *name = NSStringFromClass(object_getClass(vc));
    NSString *title = nil;
    @try { title = vc.title; }
    @catch (NSException *ex) { title = nil; }
    BOOL match = nameMatches(name) || nameMatches(title);
    if (match && nameMatches(name) && [[name lowercaseString] containsString:@"jam"]) (*jamOnScreen)++;
    NSString *pad = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    appendCapped(out, [NSString stringWithFormat:@"%@%@ %@%@\n", pad, match ? @"*" : @"-", name, title.length ? [NSString stringWithFormat:@" title=\"%@\"", clean(title)] : @""]);
    if (match) appendReadable(vc, out, [pad stringByAppendingString:@"  "]);
    if ([vc isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in ((UINavigationController *)vc).viewControllers) walkControllers(child, depth + 1, seen, out, count, jamOnScreen);
    }
    if ([vc isKindOfClass:UITabBarController.class]) {
        for (UIViewController *child in ((UITabBarController *)vc).viewControllers) walkControllers(child, depth + 1, seen, out, count, jamOnScreen);
    }
    for (UIViewController *child in vc.childViewControllers) walkControllers(child, depth + 1, seen, out, count, jamOnScreen);
    if (vc.presentedViewController) walkControllers(vc.presentedViewController, depth + 1, seen, out, count, jamOnScreen);
}

static void appendLabels(UIView *view, NSUInteger depth, NSMutableString *out, NSString *indent, NSUInteger *count) {
    if (!view || depth > 8 || *count >= kMaxLabels || budgetHit()) return;
    if ([view isKindOfClass:UILabel.class]) {
        NSString *text = ((UILabel *)view).text;
        if (text.length) {
            appendCapped(out, [NSString stringWithFormat:@"%@label \"%@\"\n", indent, clean(text)]);
            (*count)++;
        }
    }
    NSString *ident = view.accessibilityIdentifier;
    NSString *label = view.accessibilityLabel;
    NSString *value = view.accessibilityValue;
    if ((ident.length || label.length || value.length) && (nameMatches(ident) || nameMatches(label) || nameMatches(value) ||
                                                            [label.lowercaseString containsString:@"added"])) {
        appendCapped(out, [NSString stringWithFormat:@"%@a11y id=%@ label=\"%@\" value=\"%@\"\n", indent, clean(ident), clean(label), clean(value)]);
    }
    for (UIView *sub in view.subviews) appendLabels(sub, depth + 1, out, indent, count);
}

static void appendButtonOwners(UIView *view, NSUInteger depth, NSMutableString *out, NSString *indent, NSUInteger *count) {
    if (!view || depth > 6 || *count >= 6 || budgetHit()) return;
    if ([view isKindOfClass:UIControl.class]) {
        UIControl *control = (UIControl *)view;
        BOOL interesting = nameMatches(NSStringFromClass(object_getClass(control))) || nameMatches(control.accessibilityIdentifier) ||
                           nameMatches(control.accessibilityLabel);
        if (interesting || [NSStringFromClass(object_getClass(control)) containsString:@"Encore"] ||
            [NSStringFromClass(object_getClass(control)) containsString:@"Button"]) {
            (*count)++;
            appendCapped(out, [NSString stringWithFormat:@"%@control %@ id=%@ label=\"%@\"\n", indent, NSStringFromClass(object_getClass(control)),
                                clean(control.accessibilityIdentifier), clean(control.accessibilityLabel)]);
            NSUInteger targets = 0;
            for (id target in control.allTargets) {
                if (targets >= 4 || budgetHit()) break;
                if (target == control || ![target isKindOfClass:NSObject.class] || [target isKindOfClass:NSNull.class]) continue;
                NSString *targetName = NSStringFromClass(object_getClass(target));
                appendCapped(out, [NSString stringWithFormat:@"%@  target %@\n", indent, targetName]);
                if (nameMatches(targetName) || [targetName containsString:@"Encore"]) appendReadable(target, out, [indent stringByAppendingString:@"    "]);
                targets++;
            }
        }
    }
    for (UIView *sub in view.subviews) appendButtonOwners(sub, depth + 1, out, indent, count);
}

static void collectCells(UIView *view, NSUInteger depth, NSMutableArray<UIView *> *cells, NSUInteger *visited) {
    if (!view || depth > kMaxViewDepth || *visited >= kMaxVisitedViews || cells.count >= kMaxCells) return;
    (*visited)++;
    if ([view isKindOfClass:UITableView.class]) {
        for (UIView *cell in ((UITableView *)view).visibleCells) {
            if (cells.count >= kMaxCells) break;
            [cells addObject:cell];
        }
    } else if ([view isKindOfClass:UICollectionView.class]) {
        for (UIView *cell in ((UICollectionView *)view).visibleCells) {
            if (cells.count >= kMaxCells) break;
            [cells addObject:cell];
        }
    }
    for (UIView *sub in view.subviews) collectCells(sub, depth + 1, cells, visited);
}

static void collectMatching(UIView *view, NSUInteger depth, NSMutableArray<UIView *> *found, NSUInteger *visited) {
    if (!view || depth > kMaxViewDepth || *visited >= kMaxVisitedViews || found.count >= kMaxMatchViews || budgetHit()) return;
    (*visited)++;
    NSString *name = NSStringFromClass(object_getClass(view));
    if (nameMatches(name) || nameMatches(view.accessibilityIdentifier) || nameMatches(view.accessibilityLabel) || nameMatches(view.accessibilityValue))
        [found addObject:view];
    for (UIView *sub in view.subviews) collectMatching(sub, depth + 1, found, visited);
}

static void appendScreen(NSMutableString *out, NSUInteger *jamOnScreen, NSUInteger *cellCount) {
    [out appendString:@"\n== view controllers\n"];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    NSUInteger controllers = 0;
    NSMutableArray<UIView *> *cells = [NSMutableArray array];
    NSMutableArray<UIView *> *matching = [NSMutableArray array];
    NSUInteger visited = 0;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (budgetHit() || ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || budgetHit()) continue;
            appendCapped(out, [NSString stringWithFormat:@"window %@ key=%d\n", NSStringFromClass(object_getClass(window)), window.isKeyWindow]);
            if (window.rootViewController) walkControllers(window.rootViewController, 1, seen, out, &controllers, jamOnScreen);
            collectCells(window, 0, cells, &visited);
            collectMatching(window, 0, matching, &visited);
        }
    }
    [out appendFormat:@"controllers walked: %lu\n", (unsigned long)controllers];
    [out appendString:@"\n== matching views\n"];
    for (UIView *view in matching) {
        if (budgetHit()) break;
        appendCapped(out, [NSString stringWithFormat:@"%@ id=%@ label=\"%@\" value=\"%@\"\n", NSStringFromClass(object_getClass(view)),
                            clean(view.accessibilityIdentifier), clean(view.accessibilityLabel), clean(view.accessibilityValue)]);
        if ([view isKindOfClass:UIViewController.class]) continue;
        NSString *viewName = NSStringFromClass(object_getClass(view));
        NSString *image = imageKey(object_getClass(view));
        if (nameMatches(viewName) && ![view isKindOfClass:UILabel.class] && ![image containsString:@"UIKitCore"] && ![image containsString:@"/UIKit"])
            appendReadable(view, out, @"  ");
    }
    [out appendString:@"\n== visible cells\n"];
    *cellCount = cells.count;
    NSUInteger index = 0;
    for (UIView *cell in cells) {
        if (budgetHit()) break;
        appendCapped(out, [NSString stringWithFormat:@"cell %lu %@ id=%@ label=\"%@\" value=\"%@\"\n", (unsigned long)index,
                            NSStringFromClass(object_getClass(cell)), clean(cell.accessibilityIdentifier), clean(cell.accessibilityLabel),
                            clean(cell.accessibilityValue)]);
        NSUInteger labels = 0;
        appendLabels(cell, 0, out, @"  ", &labels);
        NSUInteger buttons = 0;
        appendButtonOwners(cell, 0, out, @"  ", &buttons);
        index++;
    }
    if (sg_expired) [out appendString:@"screen walk stopped: time budget\n"];
}

static void appendTrack(id track, NSMutableString *out, NSString *indent) {
    if (![track isKindOfClass:NSObject.class]) return;
    NSString *title = nil, *artist = nil, *uri = nil;
    @try {
        if ([track respondsToSelector:@selector(trackTitle)]) title = [track trackTitle];
        if ([track respondsToSelector:@selector(artistName)]) artist = [track artistName];
        if ([track respondsToSelector:@selector(URI)]) uri = SGURIString([track URI]);
    } @catch (NSException *ex) {
        title = nil;
    }
    appendCapped(out, [NSString stringWithFormat:@"%@\"%@\" — %@ — %@\n", indent, clean(title), clean(artist), clean(uri)]);
}

static void appendPlayback(NSMutableString *out) {
    [out appendString:@"\n== playback\n"];
    SPTPlayerState *state = nil;
    @try { state = SGPlayerState(); }
    @catch (NSException *ex) { state = nil; }
    if (![state isKindOfClass:objc_getClass("SPTPlayerState")] && state) {
        [out appendFormat:@"player state class %@ (not SPTPlayerState)\n", NSStringFromClass(object_getClass(state))];
        return;
    }
    if (!state) {
        [out appendString:@"player has not reported a state this launch\n"];
        return;
    }
    @try {
        SPTPlayerTrack *track = state.track;
        [out appendFormat:@"title: %@\nartist: %@\nuri: %@\ncontext: %@\npaused: %d\nplaying: %d\nloading: %d\nposition: %g\npositionAsOfTimestamp: %g\nduration: %g\n",
                          clean(track.trackTitle), clean(track.artistName), clean(SGURIString(track.URI)), clean(SGURIString(state.contextURI)),
                          state.isPaused, state.isPlaying, state.isLoading, state.position, state.positionAsOfTimestamp, state.duration];
        SPTPlayerOptions *options = state.options;
        if ([NSStringFromClass(object_getClass(options)) containsString:@"SPTPlayerOptions"]) {
            [out appendFormat:@"shuffle: %d\nrepeatContext: %d\nrepeatTrack: %d\n", options.shufflingContext, options.repeatingContext, options.repeatingTrack];
        }
        NSArray *future = plainFoundation(state.future, NSArray.class) ? state.future : nil;
        NSArray *reverse = plainFoundation(state.reverse, NSArray.class) ? state.reverse : nil;
        [out appendFormat:@"future: %lu\n", (unsigned long)(future.count)];
        NSUInteger n = MIN(future.count, 12);
        for (NSUInteger i = 0; i < n; i++) appendTrack(future[i], out, @"  ");
        [out appendFormat:@"reverse: %lu\n", (unsigned long)(reverse.count)];
        n = MIN(reverse.count, 6);
        for (NSUInteger i = 0; i < n; i++) appendTrack(reverse[i], out, @"  ");
        if (!future && state.future) [out appendFormat:@"future class: %@\n", NSStringFromClass(object_getClass(state.future))];
    } @catch (NSException *ex) {
        [out appendFormat:@"playback read stopped: %@\n", ex.name];
    }
}

static NSString *buildProbe(NSUInteger *dumped, NSUInteger *jamLoaded, NSUInteger *jamOnScreen, NSUInteger *cells) {
    sg_deadline = CFAbsoluteTimeGetCurrent() + kBudget;
    sg_expired = NO;
    NSMutableString *out = [NSMutableString string];
    NSDateFormatter *stamp = [NSDateFormatter new];
    stamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    stamp.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
    NSString *spotify = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
    [out appendFormat:@"spotifyplus jam probe\ntime: %@\nspotify: %@\nios: %@\nbuild: %s %s\n",
                       [stamp stringFromDate:NSDate.date], spotify, UIDevice.currentDevice.systemVersion, SG_BUILD_BRANCH, SG_BUILD];
    [out appendString:@"read-only. Selectors were listed. Only plain property getters and the player fields already declared in SPTPlayer.h were called.\n"];
    appendClassCensus(out, dumped, jamLoaded);
    appendScreen(out, jamOnScreen, cells);
    appendPlayback(out);
    [out appendFormat:@"\n== notes\njam-named classes loaded: %lu\njam-named controllers on screen: %lu\n",
                       (unsigned long)*jamLoaded, (unsigned long)*jamOnScreen];
    [out appendString:@"One file is one moment. Compare a solo Jam with a Jam a friend has joined, and a queue that has several added tracks.\n"];
    if (out.length >= kMaxFile) [out appendString:@"output stopped: size cap\n"];
    return out;
}

static void toast(NSString *text, BOOL hide) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.hidden) continue;
            if (!window || candidate.isKeyWindow) window = candidate;
        }
    }
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
        [window addSubview:label];
        sg_toast = label;
    }
    label.text = text;
    CGFloat width = MIN(window.bounds.size.width - 48, 340);
    CGSize size = [label sizeThatFits:CGSizeMake(width - 28, 220)];
    CGFloat height = size.height + 22;
    CGFloat bottom = window.safeAreaInsets.bottom + 72;
    label.frame = CGRectMake((window.bounds.size.width - width) / 2, window.bounds.size.height - bottom - height, width, height);
    label.alpha = 1;
    [window bringSubviewToFront:label];
    if (!hide) return;
    NSUInteger gen = ++sg_toastGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
        if (![name hasPrefix:@"spotifyplus-jam-probe-"] || ![name hasSuffix:@".txt"]) continue;
        if (!best || [name compare:best] == NSOrderedDescending) best = name;
    }
    return best ? [dir stringByAppendingPathComponent:best] : nil;
}

static void presentFile(NSString *path) {
    UIViewController *top = SGTopController();
    if (!top || !path.length) return;
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    sheet.popoverPresentationController.sourceView = top.view;
    [top presentViewController:sheet animated:YES completion:nil];
}

static void alert(NSString *title, NSString *message) {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [sheet addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:sheet animated:YES completion:nil];
}

static void runNow(void) {
    NSUInteger dumped = 0, jamLoaded = 0, jamOnScreen = 0, cells = 0;
    NSString *text = nil;
    @try {
        text = buildProbe(&dumped, &jamLoaded, &jamOnScreen, &cells);
    } @catch (NSException *ex) {
        sg_busy = NO;
        SGLog(@"jam probe: stopped (%@)", ex.name);
        toast(@"Jam probe stopped", YES);
        return;
    }
    NSDateFormatter *fileStamp = [NSDateFormatter new];
    fileStamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fileStamp.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *dir = documentsDir();
    NSString *name = [NSString stringWithFormat:@"spotifyplus-jam-probe-%@.txt", [fileStamp stringFromDate:NSDate.date]];
    NSString *path = dir ? [dir stringByAppendingPathComponent:name] : nil;
    NSString *summary = [NSString stringWithFormat:@"jam probe: %@, %lu classes, %lu jam loaded, %lu jam on screen, %lu cells%@",
                                                   name, (unsigned long)dumped, (unsigned long)jamLoaded, (unsigned long)jamOnScreen,
                                                   (unsigned long)cells, sg_expired ? @", truncated" : @""];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        BOOL ok = path && [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_busy = NO;
            if (!ok) {
                SGLog(@"jam probe: could not write (%@)", error.domain ?: @"file");
                toast(@"Jam probe could not save", YES);
                return;
            }
            sg_lastPath = path;
            SGLog(@"%@", summary);
            toast(@"Jam probe saved", YES);
        });
    });
}

void SGJamProbeRun(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGJamProbeRun(); });
        return;
    }
    if (sg_busy) {
        toast(@"Jam probe is already running", YES);
        return;
    }
    sg_busy = YES;
    toast(@"Open the Jam screen. Probe runs in 3 seconds.", NO);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        runNow();
    });
}

void SGJamProbeShareLast(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGJamProbeShareLast(); });
        return;
    }
    NSString *path = sg_lastPath ?: newestProbePath();
    if (!path || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        alert(@"No Jam probe yet", @"Run Jam probe now, wait for the toast, then share the file.");
        return;
    }
    presentFile(path);
}
