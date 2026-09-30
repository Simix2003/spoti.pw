// Tab bar: Spotify's own bar stays where it is but goes invisible, and a system bar sits on top of
// it. On iOS 26 the redesign uses a UITabBarController so Search can be a UISearchTab: UIKit then
// draws the regular tabs in a leading Liquid Glass platter and Search as its own trailing circle,
// the way Music does. With the Apple Music style player on, that same controller also takes a
// UITabAccessory mini player and minimizes on scroll. Spotify's bar keeps its frame, so the page
// insets and the now playing bar stay where Spotify puts them; where the system bar is taller than
// Spotify's, Spotify is made to leave it the room (see "room for the glass bar").
//
// A tab picked on the system bar is passed on as a tap on the hidden Spotify item it mirrors, and the
// system bar's selection follows whichever Spotify label is painted white, or a tab of the mod's own
// while the page it opened is on the stack. Navbar.x composes the hidden row, so its order, hidden tabs
// and tabs of the mod's own carry over. Always on in the redesign.
//
// Tree (trees/home.txt): NavigationUI_TabBarImpl.TabBarView > TabBarCompactView > UIStackView of
//   ElementContentView<TabBarItemElement>, each with an SPTEncoreIconView and an SPTEncoreLabel.
#import "Core/SGCore.h"
#import "Navbar.h"
#import "Redesigned/Kit/SGRTokens.h"
#import "Settings/SGPage.h"
#import "Headers/SPTEncoreIconView.h"
#import "Shared/Player/PlayerState.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"
#import <objc/message.h>
#import <objc/runtime.h>

static char kBarKey, kHostKey;
static __weak UIView *sg_stockBar;
static CGFloat sg_room, sg_glassHeight;   // see "room for the glass bar"
// UITabBarController + UISearchTab: leading platter (Home, Library, …) and Search as its own
// trailing circle, the way Music lays the bar out. Always on for the redesign on iOS 26.
static BOOL sg_systemTabs;
// Mini player as UITabAccessory with OnScrollDown minimize. Opt-in (SGRInlinePlayer).
static BOOL sg_inline;

@interface SGRSystemTabBar : UITabBar <UITabBarDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *stockBar;
@property (nonatomic, copy) NSArray<UIView *> *sources;
@property (nonatomic, weak) UILongPressGestureRecognizer *hold;
@property (nonatomic) BOOL holding;
@end

static void syncBar(UIView *stockBar);

#pragma mark - reading Spotify's items

// The items the bar shows, left to right as Navbar/Navbar.x placed them.
static NSArray<UIView *> *tabItems(UIView *tabBar) {
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    for (UIView *item in SGRowIn(tabBar).arrangedSubviews) {
        // The navbar list's mark, not hidden alone: Spotify's layout pass turns hidden back off
        // and the glass bar would keep the tab it was told to drop.
        if (!SGRNavbarShowsItem(item) || item.hidden || item.bounds.size.width < 20) continue;
        [items addObject:item];
    }
    return [items sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return [@(SGFrameIn(a, tabBar).origin.x) compare:@(SGFrameIn(b, tabBar).origin.x)];
    }];
}

// Navbar.x never reorders Spotify's row and appends the mod's own tabs after it, so Home stays first.
static BOOL isHome(UIView *item, UIView *tabBar) {
    return item && item == SGRowIn(tabBar).arrangedSubviews.firstObject;
}

static UILabel *labelIn(UIView *item) {
    __block UILabel *label = nil;
    SGForEachView(item, ^(UIView *v) {
        if (!label && [v isKindOfClass:UILabel.class] && ((UILabel *)v).text.length) label = (UILabel *)v;
    });
    return label;
}

static UIView *iconIn(UIView *item) {
    __block UIView *icon = nil;
    SGForEachView(item, ^(UIView *v) {
        if (icon || v.bounds.size.width < 2) return;
        if ([v isKindOfClass:UIImageView.class] || [NSStringFromClass(v.class) containsString:@"IconView"]) icon = v;
    });
    return icon;
}

// Spotify paints the selected tab's label white and the rest #B3B3B3.
static BOOL isActive(UIView *item) {
    UIColor *color = labelIn(item).textColor;
    CGFloat white = 0, alpha = 0, r, g, b;
    if (![color getWhite:&white alpha:&alpha] && [color getRed:&r green:&g blue:&b alpha:&alpha]) white = MIN(r, MIN(g, b));
    return white > 0.95;
}

static BOOL hasInk(UIImage *image) {
    CGImageRef cg = image.CGImage;
    size_t width = CGImageGetWidth(cg), height = CGImageGetHeight(cg);
    if (!width || !height) return NO;
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height];
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, width, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cg);
    CGContextRelease(context);
    const uint8_t *alpha = pixels.bytes;
    for (size_t i = 0; i < pixels.length; i++) if (alpha[i] > 16) return YES;
    return NO;
}

static UIImage *renderLayer(CALayer *layer, CGSize size) {
    if (size.width < 8 || size.height < 8) return nil;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [layer renderInContext:context.CGContext];
    }];
    return hasInk(image) ? [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] : nil;
}

// The SPTEncoreIcon an icon view was built with. Encore keeps it in a Swift ivar with no getter.
static id encoreIconOf(UIView *view) {
    Ivar ivar = class_getInstanceVariable(view.class, "icon");
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    return type && type[0] == '@' ? object_getIvar(view, ivar) : nil;
}

// Encore draws a tab's icon from one SPTEncoreIcon in two states: isActive picks its filled variant.
// Both are drawn on an icon view of our own, off screen, so the images do not wait for Spotify's
// views to lay out and paint, and UITabBar swaps image and selectedImage itself.
static UIImage *glyphOf(UIView *item, BOOL active) {
    UIView *live = iconIn(item);
    if (!live) return nil;
    CGSize size = live.bounds.size;
    if (size.width < 8 || size.height < 8) size = CGSizeMake(24, 24);
    id icon = encoreIconOf(live);
    Class viewClass = NSClassFromString(@"SPTEncoreIconView");
    if (icon && viewClass) {
        static NSCache<NSString *, UIImage *> *cache;
        if (!cache) cache = [NSCache new];
        NSString *key = [NSString stringWithFormat:@"%@ %d %@", [icon respondsToSelector:@selector(name)] ? [icon name] : icon, active, NSStringFromCGSize(size)];
        UIImage *cached = [cache objectForKey:key];
        if (cached) return cached;
        SPTEncoreIconView *view = [[viewClass alloc] initWithIcon:icon];
        view.alpha = 1;
        view.hidden = NO;
        view.frame = (CGRect){CGPointZero, size};
        [view setForegroundColor:UIColor.whiteColor];
        if ([view respondsToSelector:@selector(setActiveForegroundColor:)]) [view setActiveForegroundColor:UIColor.whiteColor];
        if ([view respondsToSelector:@selector(setIsActive:)]) [view setIsActive:active];
        [view layoutIfNeeded];
        view.layer.opacity = 1;
        UIImage *image = renderLayer(view.layer, size);
        // An outline that draws nothing while inactive still has a filled state. A nil image is
        // what makes UIKit draw the title's first letter and collapse the image view to 1x1.
        if (!image && active == NO) {
            if ([view respondsToSelector:@selector(setIsActive:)]) [view setIsActive:YES];
            [view layoutIfNeeded];
            image = renderLayer(view.layer, size);
        }
        if (image) {
            [cache setObject:image forKey:key];
            return image;
        }
    }
    // Tabs of the mod's own draw a UIImageView, or an icon Encore would not draw off screen.
    // The live view can sit in a row whose alpha is 0; its own layer still has the pixels.
    float opacity = live.layer.opacity;
    live.layer.opacity = 1;
    UIImage *image = renderLayer(live.layer, size);
    live.layer.opacity = opacity;
    if (!image) {
        static NSUInteger misses;
        if (misses++ < 8) SGLog(@"tab bar: no glyph for %@", labelIn(item).text ?: @"?");
    }
    return image;
}

// The search circle keeps the accent on its icon after another tab is selected when the image is a
// template: UIKit tints that button with the bar's tint and does not put it back. The idle icon is
// drawn in Spotify's own idle grey, the selected one in the accent, both as original images.
static UIImage *searchTabImage(UIView *item, BOOL active) {
    UIImage *base = glyphOf(item, active);
    if (!base) return nil;
    UIColor *ink = active ? SGRAccent() : [UIColor colorWithWhite:0xB3 / 255.0 alpha:1];
    static UIImage *onImage, *offImage, *onBase, *offBase;
    static UIColor *onInk;
    if (active) {
        if (onImage && onBase == base && [onInk isEqual:ink]) return onImage;
        onBase = base;
        onInk = ink;
        onImage = [base imageWithTintColor:ink renderingMode:UIImageRenderingModeAlwaysOriginal];
        return onImage;
    }
    if (offImage && offBase == base) return offImage;
    offBase = base;
    offImage = [base imageWithTintColor:ink renderingMode:UIImageRenderingModeAlwaysOriginal];
    return offImage;
}

// Title -> viewURI from Spotify's tab model (NavigationUI_TabBarItemsImpl's list: "Ricerca · spotify:find").
// The item view's accessibility id and icon name do not say Search on this build, and the Italian title
// does not contain "search", so isSearchItem used to miss it and no UISearchTab was built.
static NSMutableDictionary<NSString *, NSString *> *sg_uriByTitle;
// How the Search item in the current row was recognised: uri, id, icon, title, or nil.
static NSString *sg_searchHow;

static NSString *spotifyText(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSURL.class]) return ((NSURL *)value).absoluteString;
    if ([value respondsToSelector:@selector(absoluteString)]) {
        id text = [value absoluteString];
        if ([text isKindOfClass:NSString.class]) return text;
    }
    return nil;
}

static BOOL isSearchURI(NSString *uri) {
    if (![uri isKindOfClass:NSString.class]) return NO;
    NSString *rest = uri.lowercaseString;
    if (![rest hasPrefix:@"spotify:"]) return NO;
    rest = [rest substringFromIndex:@"spotify:".length];
    NSRange cut = [rest rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/?#"]];
    if (cut.location != NSNotFound) rest = [rest substringToIndex:cut.location];
    return [rest isEqualToString:@"find"] || [rest isEqualToString:@"search"];
}

static NSString *uriHolding(id object) {
    if (!object || [object isKindOfClass:NSString.class] || [object isKindOfClass:NSNumber.class]) return nil;
    NSString *text = spotifyText(object);
    if ([text hasPrefix:@"spotify:"]) return text;
    if (![object respondsToSelector:NSSelectorFromString(@"viewURI")]) return nil;
    id value = nil;
    @try {
        value = [object valueForKey:@"viewURI"];
    } @catch (NSException *exception) {
        return nil;
    }
    text = spotifyText(value);
    return [text hasPrefix:@"spotify:"] ? text : nil;
}

// The row's views do not publish the URI. The model object on the view does, under viewURI, and so
// does the list Spotify reads, keyed by the same title the label shows.
static NSString *uriForTab(UIView *item) {
    if ([item respondsToSelector:@selector(uri)]) {
        id value = nil;
        @try {
            value = [item valueForKey:@"uri"];
        } @catch (NSException *exception) {
            value = nil;
        }
        NSString *uri = spotifyText(value);
        if ([uri hasPrefix:@"spotify:"]) return uri;
    }
    NSString * (^scan)(id) = ^NSString *(id object) {
        NSString *held = uriHolding(object);
        if (held) return held;
        NSString *found = nil;
        for (Class cls = object_getClass(object); cls && cls != NSObject.class && !found; cls = class_getSuperclass(cls)) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(cls, &count);
            for (unsigned int i = 0; i < count && !found; i++) {
                const char *type = ivar_getTypeEncoding(ivars[i]);
                if (!type || type[0] != '@') continue;
                found = uriHolding(object_getIvar(object, ivars[i]));
            }
            free(ivars);
        }
        return found;
    };
    NSString *found = scan(item);
    if (!found) {
        for (UIView *sub in item.subviews) {
            found = scan(sub);
            if (found) break;
        }
    }
    if (found) return found;
    NSString *title = labelIn(item).text;
    return title.length ? sg_uriByTitle[title] : nil;
}

static BOOL isSearchTitle(NSString *title) {
    if (!title.length) return NO;
    static NSSet<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[
            @"search", @"ricerca", @"cerca", @"buscar", @"suche", @"recherche", @"pesquisar",
            @"zoeken", @"sök", @"sok", @"haku", @"søg", @"ara",
        ]];
    });
    return [names containsObject:title.lowercaseString];
}

// nil when this is not Search. Otherwise what identified it, for the tab-bar log line.
static NSString *searchKind(UIView *item) {
    if (!item) return nil;
    if (isSearchURI(uriForTab(item))) return @"uri";
    NSString *ident = item.accessibilityIdentifier;
    if ([ident isEqualToString:@"TabBar.Item.Search"] || [ident hasSuffix:@".Search"]) return @"id";
    id icon = encoreIconOf(iconIn(item));
    NSString *name = [icon respondsToSelector:@selector(name)] ? [icon name] : nil;
    if (name.length && ([name rangeOfString:@"search" options:NSCaseInsensitiveSearch].location != NSNotFound
                        || [name caseInsensitiveCompare:@"find"] == NSOrderedSame)) return @"icon";
    if (isSearchTitle(labelIn(item).text)) return @"title";
    return nil;
}

static BOOL isSearchItem(UIView *item) {
    return searchKind(item) != nil;
}

#pragma mark - passing a tap on

// NavigationUI_TabBarImpl's TabBarItemElementUI answers a tap recognizer (-handleTap), so the tap is
// replayed through the recognizer's own target-action pairs, the same call a real touch ends in.
BOOL SGRFireTapRecognizers(UIView *view) {
    Ivar targetsIvar = class_getInstanceVariable(UIGestureRecognizer.class, "_targets");
    if (!targetsIvar) return NO;
    BOOL fired = NO;
    for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
        if (![recognizer isKindOfClass:UITapGestureRecognizer.class] || !recognizer.enabled) continue;
        for (id pair in object_getIvar(recognizer, targetsIvar)) {
            Ivar targetIvar = class_getInstanceVariable([pair class], "_target");
            Ivar actionIvar = class_getInstanceVariable([pair class], "_action");
            if (!targetIvar || !actionIvar) continue;
            id target = object_getIvar(pair, targetIvar);
            SEL action = *(SEL *)((char *)(__bridge void *)pair + ivar_getOffset(actionIvar));
            if (!target || !action || ![target respondsToSelector:action]) continue;
            ((void (*)(id, SEL, id))objc_msgSend)(target, action, recognizer);
            fired = YES;
        }
    }
    return fired;
}

static BOOL forwardTap(UIView *item) {
    if (!item) return NO;
    // Spotify's bar is left invisible and untouchable under the glass one. Its handler is invoked
    // directly; interaction is put back for that call in case the handler checks it and drops the tap.
    BOOL was = item.userInteractionEnabled;
    CGFloat alpha = item.alpha;
    item.userInteractionEnabled = YES;
    if (item.alpha < 0.01) item.alpha = 0.02;
    __block BOOL sent = NO;
    SGForEachView(item, ^(UIView *v) {
        if (!sent) sent = SGRFireTapRecognizers(v);
    });
    SGForEachView(item, ^(UIView *v) {
        if (sent || ![v isKindOfClass:UIControl.class]) return;
        [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
        sent = YES;
    });
    item.userInteractionEnabled = was;
    item.alpha = alpha;
    if (!sent) SGLog(@"tab bar: nothing to tap in %@", NSStringFromClass(item.class));
    return sent;
}

static UITabBarItem *itemAtPoint(UITabBar *bar, CGPoint point) {
    __block UITabBarItem *nearest = nil;
    __block CGFloat best = CGFLOAT_MAX;
    SGForEachView(bar, ^(UIView *v) {
        BOOL label = [v isKindOfClass:UILabel.class], glyph = [v isKindOfClass:UIImageView.class];
        if ((!label && !glyph) || v.bounds.size.width < 1) return;
        CGFloat distance = fabs([v convertPoint:CGPointMake(CGRectGetMidX(v.bounds), 0) toView:bar].x - point.x);
        if (distance >= best) return;
        for (UITabBarItem *item in bar.items) {
            UIImage *image = glyph ? ((UIImageView *)v).image : nil;
            if (label ? ![((UILabel *)v).text isEqualToString:item.title] : !image || (image != item.image && image != item.selectedImage)) continue;
            best = distance;
            nearest = item;
            break;
        }
    });
    return nearest;
}

#pragma mark - the system bar

@implementation SGRSystemTabBar

- (void)tabBar:(UITabBar *)tabBar didSelectItem:(UITabBarItem *)item {
    NSUInteger index = [self.items indexOfObject:item];
    if (index == NSNotFound || index >= self.sources.count) return;
    UIView *source = self.sources[index];
    BOOL search = isSearchItem(source);
    BOOL already = isActive(source);
    if (search) {
        id icon = encoreIconOf(iconIn(source));
        NSString *iconName = [icon respondsToSelector:@selector(name)] ? [icon name] : @"";
        SGLog(@"search tab: tap received title %@ icon %@ already %d", labelIn(source).text ?: @"", iconName, already);
    }
    SGRTabPicked(source);
    // Home tapped while on Home pops Spotify's stack, which would take Mod Settings straight off it.
    BOOL sent = NO;
    if (!self.holding) sent = forwardTap(source);
    if (search) SGLog(@"search tab: tab selected, Spotify tap %@", sent ? @"fired" : @"not fired");
    // Coming from another tab, Spotify's tap only opens the page. Already on Search, the same tap
    // can miss the field, so both ask for it.
    if (search && !self.holding) SGRFocusSearchPage();
    else if (!search) SGRCancelSearchFocus();
    // Spotify repaints its labels a moment later; a tap it did not take snaps the selection back.
    UIView *stockBar = self.stockBar;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (stockBar) syncBar(stockBar);
    });
}

// UIKit's item views are private, so the item under a touch is the one whose title label or glyph is
// nearest. With the labels hidden only the glyph is left; UIKit shows the item's own image instance.
- (UITabBarItem *)itemAt:(CGPoint)point {
    return itemAtPoint(self, point);
}

// UIView asks itself this for its own recognizers too, so only the hold is answered here.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (recognizer != self.hold) return [super gestureRecognizerShouldBegin:recognizer];
    NSUInteger index = [self.items indexOfObject:[self itemAt:[recognizer locationInView:self]]];
    return index < self.sources.count && isHome(self.sources[index], self.stockBar);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)held:(UILongPressGestureRecognizer *)hold {
    if (hold.state == UIGestureRecognizerStateBegan) {
        self.holding = YES;
        SGOpenModSettings(self);
    } else if (hold.state != UIGestureRecognizerStateChanged) {
        // The bar may still pick Home as the finger lifts, after this.
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            weakSelf.holding = NO;
        });
    }
}

@end

// The system bar's own view in Spotify's bar. UIKit measures the system bar and lays it out by the safe
// area of the view it stands in, and the room made under Spotify's bar is not the phone's: on a phone
// with a home button it went under the platter as well, squeezing it to 49 pt. So this view hands the
// bar the safe area without the room.
//
// It also draws the fade over the pages behind the bars. Spotify darkens whatever scrolls under its bar
// with a TabBarGradientView reaching 112 pt above the bar's top (trees/continuous/5.txt:2200), but that
// sits in the compact view hidden above, so it went with it: only the field behind a page (Kit/SGRField.h)
// faded to black, and the rows, covers and text over it ran on bright under the now playing bar and the
// glass. The fade stands under the glass bar, so it moves and goes away with the bar.
static const CGFloat kFadeRise = 112;
static const NSUInteger kFadeStops = 7;
static const CGFloat kFadeDepth = 0.5;

@interface SGRTabBarHost : UIView
@end

@implementation SGRTabBarHost {
    CAGradientLayer *_fade;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _fade = [CAGradientLayer layer];
    NSNull *off = NSNull.null;
    _fade.actions = @{@"bounds": off, @"position": off, @"frame": off};
    // Clear to half black on a smoothstep, so there is no edge where it starts.
    NSMutableArray *colors = [NSMutableArray array], *locations = [NSMutableArray array];
    for (NSUInteger i = 0; i < kFadeStops; i++) {
        CGFloat t = (CGFloat)i / (kFadeStops - 1);
        [colors addObject:(id)[UIColor colorWithWhite:0 alpha:kFadeDepth * t * t * (3 - 2 * t)].CGColor];
        [locations addObject:@(t)];
    }
    _fade.colors = colors;
    _fade.locations = locations;
    [self.layer insertSublayer:_fade atIndex:0];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGRect fade = CGRectMake(0, -kFadeRise, bounds.size.width, bounds.size.height + kFadeRise);
    if (!CGRectEqualToRect(_fade.frame, fade)) _fade.frame = fade;
}

- (UIEdgeInsets)safeAreaInsets {
    UIEdgeInsets insets = [super safeAreaInsets];
    insets.bottom = MAX(0, insets.bottom - sg_room);
    return insets;
}
@end

@interface SGRHomeHold : UILongPressGestureRecognizer
@end

@implementation SGRHomeHold
+ (void)held:(SGRHomeHold *)hold {
    if (hold.state == UIGestureRecognizerStateBegan) SGOpenModSettings(hold.view);
}
@end

// On Spotify's own bar a hold that begins fails the item's tap recognizer, so Home is not tapped too.
static void holdHome(UIView *stockBar) {
    UIView *home = SGRowIn(stockBar).arrangedSubviews.firstObject;
    if (!home) return;
    for (UIGestureRecognizer *recognizer in home.gestureRecognizers) {
        if ([recognizer isKindOfClass:SGRHomeHold.class]) return;
    }
    [home addGestureRecognizer:[[SGRHomeHold alloc] initWithTarget:SGRHomeHold.class action:@selector(held:)]];
}

#pragma mark - room for the glass bar

// UIKit's glass bar asks for 83 pt, the platter the top 62 of it, over no more safe area than a Face ID
// phone's 34 (simulator, iOS 26.5 and 27). Spotify's bar is its 49 pt row over the bottom safe area of
// TabBarContainerImpl's view: a guide from 49 pt above the safe area's bottom to the view's bottom sets
// its height (its viewDidLoad, 0x100840a2c), the now playing bar stands on that guide's top
// (MainUIContainer's chrome bottom anchor, 0x100ae0178), the bar slides away by the inset plus 49 when
// Spotify hides it (0x1037169a4) and the pages get 49 on top of the inset (0x10707bde4). A Face ID
// phone gives the view 34 and the two bars match. A phone with a home button gives it none, and so does
// Spotify's message bar (LimitedExperienceIndicatorBar: Offline, Private Session) coming in under the
// tab bar, which takes the home indicator's inset for itself: the glass bar stood 34 pt above
// Spotify's, over the now playing bar. So the view gets the rest of the glass bar's height as safe
// area, and Spotify lays its bar, the now playing bar, the pages and the hide out for the glass bar
// itself, and moves them all with the message bar.
static const CGFloat kStockRow = 49;

// UIKit asks for 62 + max(21, inset) on a phone with a home button, max(83, 49 + inset) on a Face ID
// phone, by the safe area of the view the bar stands in. SGRTabBarHost keeps the room out of that; if
// it ever reached the bar again, the bar would ask for more room every pass, so what it asks for with
// no room made is what is kept.
static CGFloat glassHeight(UITabBar *bar, UIView *stockBar) {
    if (sg_room < 0.5 || sg_glassHeight <= 0) sg_glassHeight = [bar sizeThatFits:CGSizeMake(stockBar.bounds.size.width, kStockRow)].height;
    return sg_glassHeight;
}

static UIViewController *containerOf(UIView *stockBar) {
    Class containerClass = NSClassFromString(@"_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl");
    for (UIResponder *r = stockBar.nextResponder; r; r = r.nextResponder) {
        if ([r isKindOfClass:containerClass]) return (UIViewController *)r;
    }
    return nil;
}

static void makeRoom(UIViewController *container) {
    UIView *stockBar = sg_stockBar;
    UITabBar *bar = stockBar ? objc_getAssociatedObject(stockBar, &kBarKey) : nil;
    if (!bar.window || !container.isViewLoaded || ![stockBar isDescendantOfView:container.view]) return;
    UIEdgeInsets extra = container.additionalSafeAreaInsets;
    CGFloat inset = container.view.safeAreaInsets.bottom - extra.bottom;
    CGFloat height = glassHeight(bar, stockBar);
    // Spotify's regular width bar is a fixed 76 pt that ignores the inset.
    BOOL compact = container.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact;
    CGFloat room = compact && !sg_systemTabs ? MAX(0, ceil(height - kStockRow - inset)) : 0;
    if (fabs(extra.bottom - room) < 0.5) return;
    sg_room = extra.bottom = room;
    container.additionalSafeAreaInsets = extra;
    SGLog(@"tab bar: %.0f pt of room made under Spotify's bar for the glass bar's %.0f, over an inset of %.0f", room, height, inset);
}

static void syncInline(UIView *stockBar) API_AVAILABLE(ios(26.0));

static void syncBar(UIView *stockBar) {
    sg_stockBar = stockBar;
    // Split bar (leading tabs + trailing Search circle) needs UITabBarController + UISearchTab.
    // A plain UITabBar draws every tab in one platter.
    if (sg_systemTabs) {
        if (@available(iOS 26.0, *)) syncInline(stockBar);
        return;
    }

    SGRSystemTabBar *bar = objc_getAssociatedObject(stockBar, &kBarKey);
    if (!bar) {
        bar = [[SGRSystemTabBar alloc] initWithFrame:stockBar.bounds];
        // UIKit draws the glass in the appearance the bar inherits, and the bar is outside the navigation
        // stacks Spotify makes dark itself (-[SPNavigationController viewDidLoad] while +[SPTLiquidGlass
        // isEnabled]), so a phone in light mode had it light over Spotify's black. Spotify is dark whatever
        // the system is, and so is the bar.
        bar.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        bar.delegate = bar;
        bar.stockBar = stockBar;
        UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:bar action:@selector(held:)];
        hold.delegate = bar;
        [bar addGestureRecognizer:hold];
        bar.hold = hold;
        objc_setAssociatedObject(stockBar, &kBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGRTabBarHost *host = [SGRTabBarHost new];
        [host addSubview:bar];
        objc_setAssociatedObject(stockBar, &kHostKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIColor *accent = SGRAccent();
    if (![bar.tintColor isEqual:accent]) bar.tintColor = accent;
    UIView *host = objc_getAssociatedObject(stockBar, &kHostKey);

    for (UIView *sub in stockBar.subviews) {
        if (sub == host) continue;
        if (sub.alpha != 0) sub.alpha = 0;
        if (sub.userInteractionEnabled) sub.userInteractionEnabled = NO;
    }
    stockBar.superview.layer.backgroundColor = NULL;

    NSArray<UIView *> *sources = tabItems(stockBar);
    if (!sources.count) return;
    // An item with no title is drawn by UIKit as its glyph alone, centred, on a bar of the same height.
    BOOL hideLabels = SGHidden(SGRKeyNavbarHideLabels);

    if (![sources isEqualToArray:bar.sources]) {
        NSMutableArray<UITabBarItem *> *items = [NSMutableArray array];
        for (UIView *source in sources) [items addObject:[[UITabBarItem alloc] initWithTitle:hideLabels ? nil : labelIn(source).text image:nil tag:items.count]];
        bar.sources = sources;
        [bar setItems:items animated:NO];
    }

    UITabBarItem *selected = nil;
    UIView *current = SGRCurrentModTab();
    NSUInteger modTab = current ? [sources indexOfObject:current] : NSNotFound;
    BOOL missing = NO;
    for (NSUInteger i = 0; i < sources.count; i++) {
        UITabBarItem *item = bar.items[i];
        if (!item.image) item.image = glyphOf(sources[i], NO);
        if (!item.selectedImage || item.selectedImage == item.image) item.selectedImage = glyphOf(sources[i], YES);
        missing |= !item.image || !item.selectedImage;
        NSString *title = hideLabels ? nil : labelIn(sources[i]).text;
        if (hideLabels ? item.title != nil : title.length && ![title isEqualToString:item.title]) item.title = title;
        if (!selected && (modTab != NSNotFound ? i == modTab : isActive(sources[i]))) selected = item;
    }
    if (selected && bar.selectedItem != selected) bar.selectedItem = selected;
    if (selected) {
        NSUInteger index = [bar.items indexOfObject:selected];
        if (index < sources.count && isSearchItem(sources[index])) {
            UIView *page = containerOf(stockBar).view;
            if (page) SGRRaiseSearchChrome(page);
        }
    }
    // An icon view Spotify has not built yet is looked for again shortly, not on the next touch.
    static NSUInteger retries;
    if (missing && retries++ < 40) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            syncBar(stockBar);
        });
    }

    CGRect bounds = stockBar.bounds;
    CGFloat width = bounds.size.width;
    CGFloat height = MAX(bounds.size.height, glassHeight(bar, stockBar));
    CGRect frame = CGRectMake(0, CGRectGetMaxY(bounds) - height, width, height);
    if (!CGRectEqualToRect(host.frame, frame)) host.frame = frame;
    CGRect barFrame = CGRectMake(0, 0, width, host.bounds.size.height);
    if (!CGRectEqualToRect(bar.frame, barFrame)) bar.frame = barFrame;
    if (host.superview != stockBar) [stockBar addSubview:host];
    else if (stockBar.subviews.lastObject != host) [stockBar bringSubviewToFront:host];
    makeRoom(containerOf(stockBar));
}

#pragma mark - the split tab bar (and the mini player)

// On iOS 26 the glass bar is a UITabBarController's: UISearchTab as the last tab puts Search in the
// trailing circle and the rest in the leading platter. With the mini player on (SGRKeyInlinePlayer),
// the same controller also takes a bottom accessory and minimizes on scroll: UIKit then draws the
// mini player above the bar and, scrolled, moves it in between the first tab and Search, all of it
// its own morph. The controller's pages are empty and clear; Spotify's pages stay where they are,
// under it.
//
// Minimizing needs no private API: UIKit watches the scroll view the selected page names for its
// bottom edge (-setContentScrollView:forEdge:), and the one named is the page of Spotify's in front,
// which need not be inside the controller (checked in the simulator, iOS 26.5, with a real drag).
//
// The controller's view covers TabBarContainerImpl's (SGRInlineHost), since the mini player stands
// above Spotify's bar and a touch outside a view's bounds never reaches it; everything but the bar and
// the accessory is passed through. The controller is not made a child of Spotify's container, whose
// Swift code may count on the children it put there itself, so its appearance calls are made by hand.
// Spotify's bar stays under it, invisible, and so does the room made for the other glass bar: none.


@interface SGRInlinePage : UIViewController
@end

@interface SGRInlineHost : UIView
@property (nonatomic, weak) UITabBarController *tabs;
@end

@interface SGRInlineTabs : UITabBarController <UITabBarControllerDelegate, UIGestureRecognizerDelegate, SGPlayerStateObserver>
@property (nonatomic, weak) UIView *stockBar;
// Spotify's row, in its own order. `sources` is the same tabs with Search moved last so it lines
// up with `tabs` (UISearchTab is the trailing circle only when it is the last tab).
@property (nonatomic, copy) NSArray<UIView *> *stockOrder;
@property (nonatomic, copy) NSArray<UIView *> *sources;
@property (nonatomic, strong) UITabAccessory *accessory API_AVAILABLE(ios(26.0));
@property (nonatomic) BOOL holding;
@property (nonatomic, readonly) BOOL minimized;
// The last touch on the bar went down on the minimized leading tab, and its tap went to the first tab
// while UIKit selects the one under it.
@property (nonatomic) BOOL touchedLead, leadRedirected;
- (void)attachMiniPlayer;
- (void)logChrome;
@end

static __weak SGRInlineTabs *sg_inlineTabs;
static __weak SGRInlineHost *sg_inlineHost;
static __weak UIScrollView *sg_pageScroll;

// Names Spotify's page in front to the page UIKit reads it from. UIKit looks the scroll view up when a
// page is selected, not when a page names another one later (simulator: toggling the behaviour or an
// appearance pass on the page do not do it), so the selection goes to another tab and back, unseen.
static BOOL sg_flipping;
// A finger is down on the followed list. Reselecting a tab in the middle of that cancels the drag,
// which is the swipe that was supposed to move the capsule.
static BOOL sg_dragActive;
static void searchPageScroll(void);

// iOS 27 separates one tab, the prominent one. A UISearchTab gets that on its own only when
// automaticallyActivatesSearch is YES, which would open UIKit's search on the empty stand-in page.
// The search tab is marked prominent instead, so the trailing circle stays and Spotify's field
// is still asked for from shouldSelectTab.
static NSString *const kSearchTabIdentifier = @"spotifyglass.tab.search";

static void assignSearchIdentifier(UISearchTab *tab) API_AVAILABLE(ios(26.0)) {
    if ([tab respondsToSelector:@selector(setIdentifier:)])
        ((void (*)(id, SEL, NSString *))objc_msgSend)(tab, @selector(setIdentifier:), kSearchTabIdentifier);
}

static NSString *prominentIdentifier(UITabBarController *tabs) API_AVAILABLE(ios(26.0)) {
    if (![tabs respondsToSelector:@selector(prominentTabIdentifier)]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(tabs, @selector(prominentTabIdentifier));
}

static void setProminentSearch(UITabBarController *tabs, NSString *identifier) API_AVAILABLE(ios(26.0)) {
    SEL set = @selector(setProminentTabIdentifier:);
    if (![tabs respondsToSelector:set]) return;
    id current = prominentIdentifier(tabs);
    if (identifier ? [current isEqual:identifier] : current == nil) return;
    ((void (*)(id, SEL, id))objc_msgSend)(tabs, set, identifier);
}

// One line when the model changes: which tabs are in the bar, and whether Search has the role
// UIKit uses for the trailing circle.
static void noteSearchRole(UITabBarController *tabs) API_AVAILABLE(ios(26.0)) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSString *role = nil;
    NSString *ident = nil;
    for (UITab *tab in tabs.tabs) {
        BOOL search = [tab isKindOfClass:UISearchTab.class];
        [names addObject:[NSString stringWithFormat:@"%@%@", tab.title.length ? tab.title : @"?", search ? @"*" : @""]];
        if (!search || role) continue;
        role = tab.title.length ? tab.title : @"search";
        ident = tab.identifier.length ? tab.identifier : nil;
    }
    setProminentSearch(tabs, ident);
    BOOL prominent = ident.length && [prominentIdentifier(tabs) isEqualToString:ident];
    static NSString *last;
    NSString *line = [NSString stringWithFormat:@"tab bar: %@, search role %@%@, search %@",
                      names.count ? [names componentsJoinedByString:@", "] : @"none",
                      role ?: @"none", prominent ? @" prominent" : @"",
                      sg_searchHow ? [@"detected by " stringByAppendingString:sg_searchHow] : @"not detected"];
    if ([line isEqualToString:last]) return;
    last = [line copy];
    SGLog(@"%@", line);
}

static void nameScrollView(void) {
    if (!sg_inline) return;
    SGRInlineTabs *tabs = sg_inlineTabs;
    UIViewController *page = tabs.selectedViewController;
    UIScrollView *scroll = sg_pageScroll;
    if (!page || !scroll.window) return;
    // The search stand-in stays a search tab. Naming Spotify's list onto it pulls Search into the
    // leading platter, and the mini player then has no trailing circle to sit against.
    if (@available(iOS 26.0, *)) {
        if ([tabs.selectedTab isKindOfClass:UISearchTab.class]) return;
    }
    UIScrollView *named = [page contentScrollViewForEdge:NSDirectionalRectEdgeBottom];
    if (named != scroll) {
        [page setContentScrollView:scroll forEdge:NSDirectionalRectEdgeAll];
        named = [page contentScrollViewForEdge:NSDirectionalRectEdgeBottom];
    }
    if (named == scroll) return;
    // UIKit reads the scroll view when the page is selected, not when it is named. Flipping on every
    // layout pass, including under a finger, cancelled the drag and the capsule never followed it.
    if (sg_dragActive) return;
    if (sg_flipping || !tabs.viewIfLoaded.window) return;
    static CFTimeInterval lastFlip;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastFlip < 1.5) return;
    lastFlip = now;
    if (@available(iOS 26.0, *)) {
        UITab *selected = tabs.selectedTab;
        UITab *other = nil;
        for (UITab *tab in tabs.tabs) if (tab != selected && ![tab isKindOfClass:UISearchTab.class]) { other = tab; break; }
        if (!selected || !other) return;
        SGLog(@"tab bar: reselects %@ so UIKit reads the list", selected.title);
        sg_flipping = YES;
        [UIView performWithoutAnimation:^{
            tabs.selectedTab = other;
            tabs.selectedTab = selected;
        }];
        sg_flipping = NO;
    }
}

@implementation SGRInlinePage
- (void)loadView {
    UIView *view = [UIView new];
    view.backgroundColor = UIColor.clearColor;
    view.userInteractionEnabled = NO;
    self.view = view;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    nameScrollView();
}
// UIKit minimizes from this. The stand-in page has no list of its own; Spotify's page list is named
// here so Home and Library both hand UIKit the same bottom-edge scroll view. The search stand-in
// does not: a list on that page is what keeps Search in the leading platter.
- (UIScrollView *)contentScrollViewForEdge:(NSDirectionalRectEdge)edge {
    UIScrollView *superScroll = [super contentScrollViewForEdge:edge];
    if (@available(iOS 18.0, *)) {
        if ([self.tab isKindOfClass:UISearchTab.class]) return superScroll;
    }
    if (edge & NSDirectionalRectEdgeBottom) {
        UIScrollView *page = sg_pageScroll;
        if (page.window) return page;
    }
    return superScroll;
}
@end

@implementation SGRInlineHost
// The bar's own view, anything in it and the accessory take a touch; the rest is Spotify's.
// The glass UIKit draws around the accessory can be a sibling of the content view, and a platter
// there used to take the tap. A point on the capsule, or on the snug glass around it, goes to the
// mini player.
- (UIView *)miniPlayerHit:(CGPoint)point event:(UIEvent *)event {
    if (@available(iOS 26.0, *)) {
        UIView *mini = self.tabs.bottomAccessory.contentView;
        if (!mini || mini.hidden || mini.alpha < 0.01 || !mini.userInteractionEnabled) return nil;
        UIView *capsule = mini;
        for (UIView *v = mini.superview; v && v != self; v = v.superview) {
            // The glass rim around the capsule, not the row it sits in: a full-width ancestor would
            // take the tabs beside the minimized capsule.
            CGFloat dw = v.bounds.size.width - mini.bounds.size.width;
            CGFloat dh = fabs(v.bounds.size.height - mini.bounds.size.height);
            if (dh >= 28 || dw < -12 || dw > 40) break;
            capsule = v;
        }
        CGPoint inCapsule = [capsule convertPoint:point fromView:self];
        if (![capsule pointInside:inCapsule withEvent:event]) return nil;
        CGPoint inMini = [mini convertPoint:point fromView:self];
        return [mini hitTest:inMini withEvent:event] ?: mini;
    }
    return nil;
}

// A tab button inside the bar, rather than the glass around the mini player. The rim used to be wide
// enough to cover the trailing Search circle, so that tap never reached the tab.
- (BOOL)hitIsTabControl:(UIView *)hit {
    UITabBar *bar = self.tabs.tabBar;
    UIView *mini = nil;
    if (@available(iOS 26.0, *)) mini = self.tabs.bottomAccessory.contentView;
    if (!hit || !bar || ![hit isDescendantOfView:bar]) return NO;
    if (mini && (hit == mini || [hit isDescendantOfView:mini])) return NO;
    for (UIView *v = hit; v && v != bar; v = v.superview) {
        if (mini && v == mini) return NO;
        if ([v isKindOfClass:UIControl.class]) return YES;
        NSString *name = NSStringFromClass(v.class);
        if ([name containsString:@"Button"] || [name containsString:@"TabBarItem"]) return YES;
    }
    return NO;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    UIView *miniHit = [self miniPlayerHit:point event:event];
    if (miniHit && [self hitIsTabControl:hit]) {
        UIView *mini = nil;
        if (@available(iOS 26.0, *)) mini = self.tabs.bottomAccessory.contentView;
        CGPoint inMini = mini ? [mini convertPoint:point fromView:self] : CGPointZero;
        // The capsule itself still opens the player. Only the glass past its bounds yields to a tab.
        if (!mini || ![mini pointInside:inMini withEvent:event]) {
            return hit;
        }
    }
    if (miniHit) return miniHit;
    UITabBar *bar = self.tabs.tabBar;
    // Expanded, the accessory is not inside the bar and UIKit's views around it are not named for it.
    for (UIView *v = hit; v && v != self; v = v.superview) {
        if (v == bar) return hit == bar ? nil : hit;
        if ([NSStringFromClass(v.class) containsString:@"Accessory"]) return hit;
    }
    return nil;
}
@end


@implementation SGRInlineTabs

- (instancetype)init {
    if (!(self = [super init])) return nil;
    self.delegate = self;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    if (@available(iOS 26.0, *)) {
        // Split Search is always on; the accessory and OnScrollDown are the Apple Music style player.
        // OnScrollDown waits until the accessory's content view is in a window. Setting it here, before
        // that view has a superview, leaves the environment unspecified and the leading tabs fill the row
        // the accessory and the Search circle should share.
        self.tabBarMinimizeBehavior = UITabBarMinimizeBehaviorNever;
        if (sg_inline) {
            self.accessory = [[UITabAccessory alloc] initWithContentView:SGRMakeMiniPlayer()];
            [self.accessory.contentView registerForTraitChanges:@[UITraitTabAccessoryEnvironment.class] withTarget:self action:@selector(minimizedChanged)];
        }
    }
    SGAddPlayerStateObserver(self);
    // Setting the controller up above can load its view, so viewDidLoad may have run with no accessory yet.
    [self playerStateDidChange:SGPlayerState()];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(held:)];
    hold.delegate = self;
    [self.tabBar addGestureRecognizer:hold];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(leadingTapped:)];
    tap.delegate = self;
    tap.cancelsTouchesInView = NO;
    [self.tabBar addGestureRecognizer:tap];
    [self playerStateDidChange:SGPlayerState()];
    SGLog(@"tab bar: split Search on, mini player %@", sg_inline ? @"on" : @"off");
}

// The accessory is inline beside the minimized bar; with no track there is no accessory and no telling.
- (BOOL)minimized {
    if (@available(iOS 26.0, *)) return self.bottomAccessory.contentView.traitCollection.tabAccessoryEnvironment == UITabAccessoryEnvironmentInline;
    return NO;
}

- (void)minimizedChanged {
    [self logChrome];
    if (self.stockBar) syncBar(self.stockBar);
}

// With a bottom accessory and OnScrollDown, Automatic placement fills the leading group out to the
// trailing edge, which is the gap the inline player and the Search circle occupy. Fixed keeps each
// regular tab in that group; Centered keeps the group's own width, so the circle stays put and the
// accessory has a row to sit in. Neither is set while the accessory is off: that bar already lays out.
- (void)placeLeadingTabs:(BOOL)hug {
    if (@available(iOS 26.0, *)) {
        UITabBarItemPositioning positioning = hug ? UITabBarItemPositioningCentered : UITabBarItemPositioningAutomatic;
        if (self.tabBar.itemPositioning != positioning) self.tabBar.itemPositioning = positioning;
        UITabPlacement placement = hug ? UITabPlacementFixed : UITabPlacementAutomatic;
        for (UITab *tab in self.tabs) {
            if ([tab isKindOfClass:UISearchTab.class]) continue;
            if (tab.preferredPlacement != placement) tab.preferredPlacement = placement;
        }
    }
}

- (NSString *)accessoryEnvironment {
    if (@available(iOS 26.0, *)) {
        UIView *content = self.bottomAccessory.contentView;
        if (!self.bottomAccessory || !content) return @"none";
        if (!content.superview) return @"unspecified";
        switch (content.traitCollection.tabAccessoryEnvironment) {
            case UITabAccessoryEnvironmentInline: return @"inline";
            case UITabAccessoryEnvironmentRegular: return @"regular";
            case UITabAccessoryEnvironmentNone: return @"none";
            default: return @"unspecified";
        }
    }
    return @"none";
}

- (void)logChrome {
    if (@available(iOS 26.0, *)) {
        BOOL track = SGURIString(SGPlayerState().track.URI).length > 0;
        UIView *content = self.bottomAccessory.contentView;
        NSString *selected = self.selectedTab.title.length ? self.selectedTab.title : @"none";
        NSString *line = [NSString stringWithFormat:@"tab bar: accessory %@ content %@ bar %@ env %@ selected %@ minimized %d tabs %lu track %@ stockbar %@",
                          self.bottomAccessory ? @"yes" : @"no",
                          content ? NSStringFromCGRect(content.frame) : @"none",
                          NSStringFromCGRect(self.tabBar.frame),
                          [self accessoryEnvironment],
                          selected,
                          self.minimized,
                          (unsigned long)self.tabs.count,
                          track ? @"yes" : @"no",
                          SGRStockNowPlayingHidden() ? @"hidden" : @"visible"];
        static NSString *last;
        if ([line isEqualToString:last]) return;
        last = [line copy];
        SGLog(@"%@", line);
    }
}

// The accessory is applied once this view is in a window, then again if its content view was never
// moved into a superview (the environment stays unspecified until then). OnScrollDown follows that,
// so the bar does not minimize into a row that has no player and no Search circle.
- (void)attachMiniPlayer {
    if (!sg_inline || !self.viewIfLoaded.window) return;
    if (@available(iOS 26.0, *)) {
        BOOL track = SGURIString(SGPlayerState().track.URI).length > 0;
        UITabAccessory *want = track ? self.accessory : nil;
        [self placeLeadingTabs:want != nil];
        BOOL changed = self.bottomAccessory != want;
        if (changed) [self setBottomAccessory:want animated:NO];
        UIView *content = self.bottomAccessory.contentView;
        // Just assigned: UIKit parents the content view on the layout that follows, not in this call.
        if (want && content && !content.superview && !changed) {
            static NSUInteger retries;
            static BOOL pending;
            if (!pending && retries < 4) {
                pending = YES;
                retries++;
                __weak typeof(self) weakSelf = self;
                dispatch_async(dispatch_get_main_queue(), ^{
                    pending = NO;
                    if (@available(iOS 26.0, *)) {
                        SGRInlineTabs *tabs = weakSelf;
                        if (!tabs) return;
                        [tabs setBottomAccessory:nil animated:NO];
                        [tabs attachMiniPlayer];
                    }
                });
            }
        }
        UITabBarMinimizeBehavior behavior = (want && self.bottomAccessory.contentView.superview)
            ? UITabBarMinimizeBehaviorOnScrollDown : UITabBarMinimizeBehaviorNever;
        if (self.tabBarMinimizeBehavior != behavior) {
            self.tabBarMinimizeBehavior = behavior;
            changed = YES;
        }
        if (changed) [self logChrome];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self attachMiniPlayer];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf logChrome];
    });
}

// Between the first tab and the trailing circle.
- (BOOL)isMiddle:(NSUInteger)index {
    return index > 0 && index + 1 < self.sources.count;
}

// A tap on the minimized selected tab only expands the bar, with no shouldSelectTab.
- (void)leadingTapped:(UITapGestureRecognizer *)tap {
    SGRTabPicked(self.sources.firstObject);
    forwardTap(self.sources.firstObject);
}

// The mini player is there while Spotify has a track to show on its bar, paused or not.
- (void)playerStateDidChange:(SPTPlayerState *)state {
    if (@available(iOS 26.0, *)) {
        if (!sg_inline) {
            if (self.bottomAccessory) [self setBottomAccessory:nil animated:NO];
            return;
        }
        (void)state;
        [self attachMiniPlayer];
    }
}

- (BOOL)tabBarController:(UITabBarController *)controller shouldSelectTab:(UITab *)tab API_AVAILABLE(ios(26.0)) {
    if (sg_flipping) return YES;
    NSUInteger index = [self.tabs indexOfObject:tab];
    self.leadRedirected = self.touchedLead && [self isMiddle:index];
    if (self.leadRedirected) index = 0;
    UIView *source = index < self.sources.count ? self.sources[index] : nil;
    BOOL search = isSearchItem(source);
    if (source) SGRTabPicked(source);
    // Home tapped while on Home pops Spotify's stack, which would take Mod Settings straight off it.
    if (source && !self.holding) forwardTap(source);
    // UISearchTab's own search mode would open on the empty stand-in page. Spotify's field is asked
    // for here, including when the tab already looks selected and the field never took focus.
    if (search && !self.holding) SGRFocusSearchPage();
    else if (!search) SGRCancelSearchFocus();
    UIView *stockBar = self.stockBar;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (stockBar) syncBar(stockBar);
    });
    return YES;
}

- (void)tabBarController:(UITabBarController *)controller didSelectTab:(UITab *)tab previousTab:(UITab *)previous API_AVAILABLE(ios(26.0)) {
    // Selecting another tab in here leaves UIKit lighting this one.
    if (self.leadRedirected) {
        self.leadRedirected = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ self.selectedTab = self.tabs.firstObject; });
    }
    nameScrollView();
}

// Held on Home, Mod Settings, as on the other glass bar.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if ([recognizer isKindOfClass:UITapGestureRecognizer.class]) return YES;
    UIView *home = self.sources.firstObject;
    if (!home || !isHome(home, self.stockBar)) return NO;
    UITabBarItem *item = itemAtPoint(self.tabBar, [recognizer locationInView:self.tabBar]);
    NSString *title = labelIn(home).text;
    if (item && title.length && [item.title isEqualToString:title]) return YES;
    if (@available(iOS 26.0, *)) return item && self.tabs.count && item.image == self.tabs.firstObject.image;
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    if (![recognizer isKindOfClass:UITapGestureRecognizer.class]) return YES;
    self.touchedLead = NO;
    if (@available(iOS 26.0, *)) {
        UIView *mini = self.minimized ? self.bottomAccessory.contentView : nil;
        self.touchedLead = mini.window && [touch locationInView:nil].x < CGRectGetMinX([mini convertRect:mini.bounds toView:nil]);
        return self.touchedLead && [self isMiddle:[self.tabs indexOfObject:self.selectedTab]];
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)held:(UILongPressGestureRecognizer *)hold {
    if (hold.state == UIGestureRecognizerStateBegan) {
        self.holding = YES;
        SGOpenModSettings(self.tabBar);
    } else if (hold.state != UIGestureRecognizerStateChanged) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            weakSelf.holding = NO;
        });
    }
}

@end

static UIViewController *inlinePage(UITab *tab) API_AVAILABLE(ios(26.0)) {
    return [SGRInlinePage new];
}

static void syncInline(UIView *stockBar) API_AVAILABLE(ios(26.0)) {
    UIViewController *container = containerOf(stockBar);
    if (!container.isViewLoaded) return;

    SGRInlineTabs *tabs = sg_inlineTabs;
    SGRInlineHost *host = sg_inlineHost;
    if (!tabs) {
        tabs = [SGRInlineTabs new];
        tabs.stockBar = stockBar;
        host = [SGRInlineHost new];
        host.tabs = tabs;
        // The host holds the controller: nothing else of Spotify's or UIKit's does.
        objc_setAssociatedObject(host, &kBarKey, tabs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sg_inlineTabs = tabs;
        sg_inlineHost = host;
    }
    tabs.stockBar = stockBar;
    tabs.tabBar.tintColor = SGRAccent();

    for (UIView *sub in stockBar.subviews) {
        sub.alpha = 0;
        sub.userInteractionEnabled = NO;
    }
    stockBar.superview.layer.backgroundColor = NULL;

    UIView *view = container.view;
    if (!CGRectEqualToRect(host.frame, view.bounds)) host.frame = view.bounds;
    if (host.superview != view) {
        [tabs beginAppearanceTransition:YES animated:NO];
        [view addSubview:host];
        tabs.view.frame = host.bounds;
        tabs.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host addSubview:tabs.view];
        [tabs endAppearanceTransition];
        SGLog(@"tab bar: the split tab bar controller is up over %@", NSStringFromCGRect(view.bounds));
        dispatch_async(dispatch_get_main_queue(), ^{ searchPageScroll(); });
    } else if (view.subviews.lastObject != host) {
        [view bringSubviewToFront:host];
    }
    // A page that hides Spotify's bar hides this one too.
    BOOL hidden = stockBar.hidden || stockBar.superview.hidden || stockBar.alpha < 0.01 || !stockBar.window;
    if (host.hidden != hidden) {
        SGLog(@"tab bar: %@ with Spotify's bar", hidden ? @"hidden" : @"shown");
        host.hidden = hidden;
    }

    NSArray<UIView *> *sources = tabItems(stockBar);
    if (!sources.count) return;
    BOOL hideLabels = SGHidden(SGRKeyNavbarHideLabels);

    // Search in the middle of the model (Home, Search, Library) is still drawn in the trailing
    // circle, and the regular tab that ends up last in the leading platter is the one UIKit lays
    // out with the search button's metrics: image view 1x1, title the first letter. Regular tabs
    // stay in Spotify's order; Search is appended so it is the last tab. A first pass that built
    // regular tabs, before Search could be told apart, is rebuilt once it can.
    sg_searchHow = nil;
    for (UIView *source in sources) {
        NSString *kind = searchKind(source);
        if (!kind) continue;
        sg_searchHow = kind;
        break;
    }
    BOOL wantSearch = sg_searchHow != nil;
    BOOL haveSearch = NO;
    for (UITab *tab in tabs.tabs) if ([tab isKindOfClass:UISearchTab.class]) haveSearch = YES;
    if (wantSearch != haveSearch || ![sources isEqualToArray:tabs.stockOrder]) {
        NSMutableArray<UIView *> *ordered = [NSMutableArray array];
        NSMutableArray<UITab *> *list = [NSMutableArray array];
        UIView *searchSource = nil;
        UITab *searchTabBuilt = nil;
        for (UIView *source in sources) {
            NSString *full = labelIn(source).text ?: @"";
            BOOL search = isSearchItem(source);
            NSString *title = hideLabels ? @"" : full;
            UITab *tab;
            // Only Search is a UISearchTab. The last visible item used to become the circle, so
            // while Create was hiding, La tua libreria was that circle and drew as its first letter.
            if (search) {
                UISearchTab *searchTab = [[UISearchTab alloc] initWithViewControllerProvider:^UIViewController *(UITab *t) { return inlinePage(t); }];
                searchTab.title = title;
                searchTab.image = glyphOf(source, NO);
                assignSearchIdentifier(searchTab);
                // automaticallyActivatesSearch opens UIKit's search on this tab's view controller,
                // which is an empty stand-in, not Spotify's Search page: the tap then never focuses
                // Spotify's field. The circle only selects; shouldSelectTab forwards to Spotify and
                // asks for the field. The trailing circle itself is the prominent tab, set below.
                searchTab.automaticallyActivatesSearch = NO;
                tab = searchTab;
                searchSource = source;
                searchTabBuilt = tab;
            } else {
                NSString *identifier = [NSString stringWithFormat:@"spotifyglass.tab.%lu", (unsigned long)list.count];
                UIImage *glyph = glyphOf(source, NO);
                tab = [[UITab alloc] initWithTitle:title image:glyph identifier:identifier
                            viewControllerProvider:^UIViewController *(UITab *t) { return inlinePage(t); }];
                [ordered addObject:source];
                [list addObject:tab];
            }
        }
        if (searchSource && searchTabBuilt) {
            [ordered addObject:searchSource];
            [list addObject:searchTabBuilt];
        }
        tabs.stockOrder = sources;
        tabs.sources = ordered;
        tabs.tabs = list;
    }
    noteSearchRole(tabs);

    // Spotify's selected tab shows its filled icon. UIKit lays the platter out.
    NSArray<UIView *> *shown = tabs.sources ?: @[];
    UITab *selected = nil;
    UIView *current = SGRCurrentModTab();
    NSUInteger modTab = current ? [shown indexOfObject:current] : NSNotFound;
    BOOL missing = NO;
    for (NSUInteger i = 0; i < shown.count && i < tabs.tabs.count; i++) {
        UITab *tab = tabs.tabs[i];
        BOOL active = modTab != NSNotFound ? i == modTab : isActive(shown[i]);
        if (active && !selected) selected = tab;
        if ([tab isKindOfClass:UISearchTab.class]) {
            UISearchTab *search = (UISearchTab *)tab;
            if (search.automaticallyActivatesSearch) search.automaticallyActivatesSearch = NO;
        }
        UIImage *image = [tab isKindOfClass:UISearchTab.class] ? searchTabImage(shown[i], active) : glyphOf(shown[i], active);
        missing |= !image;
        if (image && tab.image != image) tab.image = image;
        if (![tab isKindOfClass:UISearchTab.class] && !hideLabels) {
            NSString *full = labelIn(shown[i]).text ?: @"";
            if (full.length && ![tab.title isEqualToString:full]) tab.title = full;
        }
    }
    if (selected && tabs.selectedTab != selected) {
        SGLog(@"tab bar: selection follows Spotify to %@", selected.title);
        tabs.selectedTab = selected;
    }
    if (selected) {
        NSUInteger index = [tabs.tabs indexOfObject:selected];
        if (index < shown.count && isSearchItem(shown[index])) {
            UIView *page = containerOf(stockBar).view;
            if (page) SGRRaiseSearchChrome(page);
        }
    }
    if (!sg_pageScroll.window) searchPageScroll();
    [tabs attachMiniPlayer];
    static NSUInteger retries;
    if (missing && retries++ < 40) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            syncBar(stockBar);
        });
    }
    nameScrollView();
}

// The leading platter's left edge and the Search circle's right edge, in `space`. The platter is the
// wide glass; the circle is the square glass past it. NO when the bar has not drawn them yet.
BOOL SGRTabBarContentSpan(UIView *space, CGFloat *minX, CGFloat *maxX) {
    SGRInlineTabs *tabs = sg_inlineTabs;
    UITabBar *bar = tabs.viewIfLoaded.window ? tabs.tabBar : nil;
    if (!bar || !space || bar.bounds.size.width < 80) return NO;
    CGFloat barW = bar.bounds.size.width;
    __block CGRect platter = CGRectNull, circle = CGRectNull;
    __block CGFloat platterW = 0, circleX = -1;
    SGForEachView(bar, ^(UIView *v) {
        if (v == bar || v.hidden || v.alpha < 0.01) return;
        CGSize size = v.bounds.size;
        if (size.height < 48 || size.height > 74 || size.width < 48 || size.width > barW - 24) return;
        CGRect rect = [space convertRect:v.bounds fromView:v];
        BOOL round = fabs(size.width - size.height) <= 10;
        if (!round && size.width >= size.height * 1.6 && size.width > platterW) {
            platterW = size.width;
            platter = rect;
        }
        if (round && CGRectGetMaxX(rect) > circleX) {
            circleX = CGRectGetMaxX(rect);
            circle = rect;
        }
    });
    if (CGRectIsNull(platter) || CGRectIsNull(circle) || !minX || !maxX) return NO;
    if (CGRectGetMaxX(circle) < CGRectGetMaxX(platter) + 4) return NO;
    *minX = CGRectGetMinX(platter);
    *maxX = CGRectGetMaxX(circle);
    return *maxX > *minX + 40;
}

// The scroll view UIKit should minimize the bar by is Spotify's page in front: a vertical list over most
// of the screen inside the tab bar container, the innermost when one holds another. Horizontal pagers
// are left out. Spotify's first page is on screen before the bar is, so the container is searched once
// the bar is up; later pages are taken as they come on screen, and whichever list a finger starts
// dragging up or down is taken on the spot, in case the guess was another.
static BOOL isPageScroll(UIScrollView *scroll) {
    SGRInlineHost *host = sg_inlineHost;
    UIView *container = host.superview;
    if (!container || !scroll.window || scroll.hidden || scroll.pagingEnabled) return NO;
    if (![scroll isDescendantOfView:container] || [scroll isDescendantOfView:host]) return NO;
    // A playlist list under a tall header is still the page list when it covers about a third of the screen.
    return scroll.bounds.size.height >= container.bounds.size.height * 0.35;
}

static void takePageScroll(UIScrollView *scroll) {
    if (sg_pageScroll == scroll) return;
    sg_pageScroll = scroll;
    nameScrollView();
}

static void considerScrollView(UIScrollView *scroll) {
    if (!isPageScroll(scroll)) return;
    UIScrollView *current = sg_pageScroll;
    if (current == scroll) return;
    if (current.window && [current isDescendantOfView:scroll]) return;
    takePageScroll(scroll);
}

static void searchPageScroll(void) {
    UIView *container = sg_inlineHost.superview;
    if (!container) return;
    // The bar lays out often; a page with no list is searched at most once a second.
    static CFTimeInterval last;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - last < 1) return;
    last = now;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:container];
    while (queue.count) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (view == sg_inlineHost || view.hidden || view.alpha < 0.01) continue;
        if ([view isKindOfClass:UIScrollView.class] && isPageScroll((UIScrollView *)view))
            considerScrollView((UIScrollView *)view);
        [queue addObjectsFromArray:view.subviews];
    }
}

@interface SGRScrollDrag : NSObject
@end

@implementation SGRScrollDrag
+ (void)dragged:(UIPanGestureRecognizer *)pan {
    UIScrollView *scroll = (UIScrollView *)pan.view;
    if (pan.state == UIGestureRecognizerStateBegan && [scroll isKindOfClass:UIScrollView.class] && scroll != sg_pageScroll && isPageScroll(scroll)) {
        CGPoint velocity = [pan velocityInView:scroll];
        if (fabs(velocity.y) > fabs(velocity.x)) takePageScroll(scroll);
    }
    if (scroll == sg_pageScroll) {
        if (pan.state == UIGestureRecognizerStateBegan) sg_dragActive = YES;
        else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) sg_dragActive = NO;
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) sg_dragActive = NO;
}
@end

static char kDragKey;

%group SGRInlinePlayerScroll
%hook UIScrollView
- (void)setContentOffset:(CGPoint)offset {
    CGPoint old = self.contentOffset;
    %orig;
    if (!sg_inlineTabs || fabs(offset.y - old.y) < 0.5 || self.bounds.size.height < 200) return;
    UIScrollView *scroll = (UIScrollView *)self;
    if (!isPageScroll(scroll)) return;
    if (sg_pageScroll != scroll) {
        sg_pageScroll = scroll;
        nameScrollView();
    }
}
- (void)didMoveToWindow {
    %orig;
    if (!self.window) return;
    if (!objc_getAssociatedObject(self, &kDragKey)) {
        objc_setAssociatedObject(self, &kDragKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self.panGestureRecognizer addTarget:SGRScrollDrag.class action:@selector(dragged:)];
    }
    considerScrollView(self);
    // A page arriving in a transition may not have its size yet.
    __weak UIScrollView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIScrollView *scroll = weakSelf;
        if (scroll) considerScrollView(scroll);
    });
}
%end
%end

#pragma mark - hooks

static UIView *tabBarOf(UIView *item) {
    Class barClass = NSClassFromString(@"_TtC23NavigationUI_TabBarImpl10TabBarView");
    for (UIView *v = item.superview; v; v = v.superview) if ([v isKindOfClass:barClass]) return v;
    return nil;
}

// Set while the bar lays its items out itself, so each item's pass leaves the work to the bar's one.
static BOOL sg_barPass, sg_itemsLaidOut;

%hook _TtC23NavigationUI_TabBarImpl10TabBarView
- (void)layoutSubviews {
    %orig;
    SGRComposeTabBar((UIView *)self);
    sg_barPass = YES;
    sg_itemsLaidOut = NO;
    for (UIView *sub in ((UIView *)self).subviews) {
        if (![sub isKindOfClass:SGRTabBarHost.class]) [sub layoutIfNeeded];
    }
    sg_barPass = NO;
    if (sg_itemsLaidOut) SGRComposeTabBar((UIView *)self);
    holdHome((UIView *)self);
    syncBar((UIView *)self);
}
%end

// The bar's own pass runs before Spotify has filled the row; the items lay out as they arrive.
static void itemDidLayOut(UIView *item) {
    if (sg_barPass) {
        sg_itemsLaidOut = YES;
        return;
    }
    UIView *bar = tabBarOf(item);
    if (!bar) return;
    SGRComposeTabBar(bar);
    holdHome(bar);
    syncBar(bar);
}

%hook _TtC23NavigationUI_TabBarImpl21TabBarItemElementView
- (void)layoutSubviews {
    %orig;
    itemDidLayOut((UIView *)self);
}
%end

%hook _TtC25CreateMenu_TabBarItemImpl24CreateMenuTabBarItemView
- (void)layoutSubviews {
    %orig;
    itemDidLayOut((UIView *)self);
}
%end

// A page pushed or popped decides whether a tab of the mod's own is the one lit.
%hook SPNavigationController
- (void)navigationController:(UINavigationController *)controller didShowViewController:(UIViewController *)page animated:(BOOL)animated {
    %orig;
    UIView *bar = sg_stockBar;
    if (bar) syncBar(bar);
}
%end

// A tab changed from elsewhere (a link, the side drawer) repaints the labels without a layout pass.
%hook _TtC23NavigationUI_TabBarImpl19TabBarContainerImpl
- (void)setSelectedViewController:(UIViewController *)controller {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *bar = sg_stockBar;
        if (bar) syncBar(bar);
    });
}
// The message bar coming or going changes the view's safe area before Spotify lays the bar out for it,
// so the room follows in that same pass, and inside the message bar's animation.
- (void)viewSafeAreaInsetsDidChange {
    %orig;
    makeRoom((UIViewController *)self);
}
%end

// Spotify's own tab model. The views in the row are not what carries the URI; this list is.
// "Ricerca · spotify:find" is Search whatever the Navbar page's order is, including after Reset.
%hook _TtC28NavigationUI_TabBarItemsImpl29TabBarItemsNavigationListImpl
- (NSArray *)items {
    NSArray *items = %orig;
    if (!sg_uriByTitle) sg_uriByTitle = [NSMutableDictionary dictionary];
    for (id item in items) {
        id title = nil, viewURI = nil;
        @try {
            title = [item valueForKey:@"title"];
            viewURI = [item valueForKey:@"viewURI"];
        } @catch (NSException *exception) {
            continue;
        }
        NSString *uri = spotifyText(viewURI);
        if ([title isKindOfClass:NSString.class] && uri.length) sg_uriByTitle[title] = uri;
    }
    return items;
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (@available(iOS 26.0, *)) {
        // Split bar always; mini player accessory only when the setting is on.
        sg_systemTabs = YES;
        sg_inline = SGRInlinePlayer();
    }
    %init;
    if (sg_inline) %init(SGRInlinePlayerScroll);
    SGRequireClasses(@[
        @"_TtC23NavigationUI_TabBarImpl10TabBarView",
        @"_TtC23NavigationUI_TabBarImpl21TabBarItemElementView",
        @"_TtC25CreateMenu_TabBarItemImpl24CreateMenuTabBarItemView",
        @"_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl",
        @"SPNavigationController",
        @"_TtC28NavigationUI_TabBarItemsImpl29TabBarItemsNavigationListImpl",
    ]);
}
