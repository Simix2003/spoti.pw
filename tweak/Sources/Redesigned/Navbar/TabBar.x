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
// Full bar width divided by the most tabs seen at that width. Later hides fit the glass bar to
// slot * visible count; the sample is always the unfitted width, so fitting cannot shrink the slot.
static NSUInteger sg_slotCount;
static CGFloat sg_slotWidth;

// UIKit's OnScrollDown minimizes as the list leaves the top and expands again at the top, or when
// the minimized bar is tapped. NO means nothing switches tabBarMinimizeBehavior or removes the accessory.
static const BOOL kScrollUpRestore = NO;
// YES runs the platter slide, itemWidth and title-shortening passes. NO leaves the bar to UIKit:
// regular tabs in the leading platter, Search in the trailing circle because it is a UISearchTab
// placed last. The last leading tab was the one our width pass clipped (icon gone, title "L").
static const BOOL kNavbarCustomLayout = NO;

static void noteTabSlot(CGFloat fullWidth, NSUInteger count) {
    if (count < 2 || fullWidth < 80 || count < sg_slotCount) return;
    sg_slotCount = count;
    sg_slotWidth = fullWidth / (CGFloat)count;
}

static CGFloat fittedTabWidth(NSUInteger count, CGFloat fullWidth) {
    if (sg_slotWidth < 1 || !count) return fullWidth;
    return MIN(fullWidth, sg_slotWidth * (CGFloat)count);
}

static void logTabFit(NSUInteger count, CGFloat fullWidth, CGFloat fitted, NSString *where) {
    static NSUInteger loggedCount;
    static CGFloat loggedFit;
    static NSString *loggedWhere;
    if (count == loggedCount && fabs(fitted - loggedFit) < 0.5 && [where isEqualToString:loggedWhere]) return;
    loggedCount = count;
    loggedFit = fitted;
    loggedWhere = where;
    SGLog(@"tab bar: %lu tabs, full %.0f fitted %.0f slot %.1f (%@)", (unsigned long)count, fullWidth, fitted, sg_slotWidth, where);
}

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

static BOOL isSearchItem(UIView *item) {
    if (!item) return NO;
    // Spotify's id can sit on a descendant (trees/home: TabBar.Item.Search), not on the arranged item.
    __block BOOL byId = NO;
    SGForEachView(item, ^(UIView *v) {
        if (byId) return;
        NSString *ident = v.accessibilityIdentifier;
        if (!ident.length) return;
        if ([ident isEqualToString:@"TabBar.Item.Search"] || [ident hasSuffix:@".Search"]
            || [ident rangeOfString:@"Item.Search"].location != NSNotFound) byId = YES;
    });
    if (byId) return YES;

    id icon = encoreIconOf(iconIn(item));
    NSString *name = [icon respondsToSelector:@selector(name)] ? [icon name] : nil;
    if (name.length && [name rangeOfString:@"search" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;

    NSString *title = labelIn(item).text;
    // Spotify's own order is Home, Search, Library, Create; stock[1] is Search in every locale.
    NSArray<NSString *> *stock = SGRNavbarStock();
    if (title.length && stock.count >= 2 && [title isEqualToString:stock[1]]) return YES;
    if (title.length) {
        static NSArray<NSString *> *names;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            names = @[@"Search", @"Cerca", @"Buscar", @"Suche", @"Recherche", @"Zoeken",
                      @"Pesquisar", @"Haku", @"Søk", @"Sök", @"Szukaj", @"Arama", @"搜索", @"検索", @"검색"];
        });
        for (NSString *n in names) {
            if ([title caseInsensitiveCompare:n] == NSOrderedSame) return YES;
        }
    }
    return NO;
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
            SGLog(@"tab bar: tap -> %@ %@", NSStringFromClass([target class]), NSStringFromSelector(action));
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
        SGLog(@"tab bar: tap -> control %@", NSStringFromClass(v.class));
        [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
        sent = YES;
    });
    item.userInteractionEnabled = was;
    item.alpha = alpha;
    if (!sent) {
        NSMutableString *out = [NSMutableString stringWithFormat:@"tab bar: nothing to tap in %@", NSStringFromClass(item.class)];
        SGForEachView(item, ^(UIView *v) {
            for (UIGestureRecognizer *r in v.gestureRecognizers) [out appendFormat:@"\n  %@ on %@", r, NSStringFromClass(v.class)];
        });
        SGLogLong(@"navbar", out);
    }
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

static void logBarOnce(UITabBar *bar) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SGLogLong(@"navbar", [NSString stringWithFormat:@"system tab bar %@\n%@", NSStringFromCGRect(bar.superview.frame), [bar recursiveDescription]]);
        });
    });
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
        NSMutableString *out = [NSMutableString stringWithString:@"tab bar icons"];
        for (UIView *source in sources) {
            UIView *live = iconIn(source);
            id icon = live ? encoreIconOf(live) : nil;
            id variant = [icon respondsToSelector:NSSelectorFromString(@"active")] ? ((id (*)(id, SEL))objc_msgSend)(icon, NSSelectorFromString(@"active")) : nil;
            [out appendFormat:@"\n  %@: %@ icon %@ active-variant %@ live-isActive %d label-white %d", labelIn(source).text, NSStringFromClass(live.class),
                 [icon respondsToSelector:@selector(name)] ? [icon name] : icon, [variant respondsToSelector:@selector(name)] ? [variant name] : variant,
                 [live respondsToSelector:@selector(isActive)] ? [(SPTEncoreIconView *)live isActive] : -1, isActive(source)];
        }
        SGLogLong(@"navbar", out);
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
    if (kNavbarCustomLayout) {
        noteTabSlot(width, sources.count);
        CGFloat fit = fittedTabWidth(sources.count, width);
        if (sg_slotWidth > 1 && fabs(bar.itemWidth - sg_slotWidth) > 0.5) bar.itemWidth = sg_slotWidth;
        CGRect barFrame = CGRectMake(round((width - fit) / 2), 0, fit, host.bounds.size.height);
        if (!CGRectEqualToRect(bar.frame, barFrame)) bar.frame = barFrame;
        logTabFit(sources.count, width, fit, @"bar");
    } else {
        CGRect barFrame = CGRectMake(0, 0, width, host.bounds.size.height);
        if (!CGRectEqualToRect(bar.frame, barFrame)) bar.frame = barFrame;
    }
    if (host.superview != stockBar) [stockBar addSubview:host];
    else if (stockBar.subviews.lastObject != host) [stockBar bringSubviewToFront:host];
    logBarOnce(bar);
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
// Slides the leading platter when kNavbarCustomLayout is on. With it off this does not run.
- (void)placeLeadingCluster;
// With the mini player accessory up, keep Home/Library content-sized (not stretched to a 3-tab gap).
- (BOOL)shouldHugLeadingTabs;
- (void)applyHugLeadingTabs;
- (void)hugLeadingPlatter;
// The last touch on the bar went down on the minimized leading tab, and its tap went to the first tab
// while UIKit selects the one under it.
@property (nonatomic) BOOL touchedLead, leadRedirected;
@end

static __weak SGRInlineTabs *sg_inlineTabs;
static __weak SGRInlineHost *sg_inlineHost;
static __weak UIScrollView *sg_pageScroll;

// Names Spotify's page in front to the page UIKit reads it from. UIKit looks the scroll view up when a
// page is selected, not when a page names another one later (simulator: toggling the behaviour or an
// appearance pass on the page do not do it), so the selection goes to another tab and back, unseen.
static BOOL sg_flipping;
// While a forced expand is in effect, the page's scroll view stays unlinked. Linking it again
// before a downward drag is what put the capsule straight back inline (the offset is not 0).
static BOOL sg_holdScrollLink;
// A finger is down on the followed list. Reselecting a tab in the middle of that cancels the drag,
// which is the swipe that was supposed to move the capsule.
static BOOL sg_dragActive;
static void searchPageScroll(void);

static void nameScrollView(void) {
    if (sg_holdScrollLink) return;
    if (!sg_inline) return;
    SGRInlineTabs *tabs = sg_inlineTabs;
    UIViewController *page = tabs.selectedViewController;
    UIScrollView *scroll = sg_pageScroll;
    if (!page || !scroll.window) return;
    UIScrollView *named = [page contentScrollViewForEdge:NSDirectionalRectEdgeBottom];
    if (named != scroll) {
        [page setContentScrollView:scroll forEdge:NSDirectionalRectEdgeAll];
        named = [page contentScrollViewForEdge:NSDirectionalRectEdgeBottom];
        static NSUInteger linked;
        if (linked++ < 12) SGLog(@"tab bar: list link %@ %@ %p", named == scroll ? @"set" : @"did not stick", NSStringFromClass(scroll.class), scroll);
    }
    // Name every loaded stand-in page so a later tab select still hands UIKit the same list.
    for (UIViewController *vc in tabs.viewControllers) {
        if (!vc || vc == page) continue;
        if ([vc contentScrollViewForEdge:NSDirectionalRectEdgeBottom] != scroll)
            [vc setContentScrollView:scroll forEdge:NSDirectionalRectEdgeAll];
    }
    if (named == scroll) {
        static BOOL once;
        if (!once) {
            once = YES;
            SGLog(@"tab bar: minimize follows %@ %p", NSStringFromClass(scroll.class), scroll);
        }
        return;
    }
    // UIKit reads the scroll view when the page is selected, not when it is named. Flipping on every
    // layout pass, including under a finger, cancelled the drag and the capsule never followed it.
    if (sg_dragActive) {
        static NSUInteger during;
        if (during++ < 6) SGLog(@"tab bar: list linked during a drag, not reselecting");
        return;
    }
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
    if (sg_inline) {
        searchPageScroll();
        nameScrollView();
    }
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (sg_inline) {
        searchPageScroll();
        nameScrollView();
    }
}
// UIKit minimizes from this. The stand-in page has no list of its own; Spotify's page list is named
// here so Home and Library both hand UIKit the same bottom-edge scroll view.
- (UIScrollView *)contentScrollViewForEdge:(NSDirectionalRectEdge)edge {
    UIScrollView *superScroll = [super contentScrollViewForEdge:edge];
    if (edge & NSDirectionalRectEdgeBottom) {
        UIScrollView *page = sg_pageScroll;
        static NSUInteger logged;
        if (logged++ < 6) SGLog(@"tab bar: contentScrollView bottom %@ super %@",
                                page ? NSStringFromClass(page.class) : @"none",
                                superScroll ? NSStringFromClass(superScroll.class) : @"none");
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
            UITabBar *bar = self.tabs.tabBar;
            CGPoint inBar = [bar convertPoint:point fromView:self];
            if (inBar.x >= CGRectGetWidth(bar.bounds) - 96) {
                static NSUInteger yielded;
                if (yielded++ < 12) SGLog(@"search tab: tap received, glass rim yielded to %@", NSStringFromClass(hit.class));
            }
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

- (NSString *)accessoryTrait {
    if (@available(iOS 26.0, *)) {
        if (!self.bottomAccessory) return @"no-accessory";
        return self.minimized ? @"inline" : @"expanded";
    }
    return @"none";
}

- (void)logAccessoryFrame:(NSString *)when {
    if (@available(iOS 26.0, *)) {
        UIView *content = self.bottomAccessory.contentView;
        UIView *host = content.superview;
        CGRect hostInWindow = host ? [host convertRect:host.bounds toView:nil] : CGRectZero;
        SGLog(@"tab bar: accessory %@ trait %@ behavior %ld content %@ host %@",
              when, [self accessoryTrait], (long)self.tabBarMinimizeBehavior,
              content ? NSStringFromCGRect(content.frame) : @"none",
              host ? NSStringFromCGRect(hostInWindow) : @"none");
    }
}


- (instancetype)init {
    if (!(self = [super init])) return nil;
    self.delegate = self;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    if (@available(iOS 26.0, *)) {
        // Split Search is always on; the accessory and OnScrollDown are the Apple Music style player.
        if (sg_inline) {
            self.tabBarMinimizeBehavior = UITabBarMinimizeBehaviorOnScrollDown;
            self.accessory = [[UITabAccessory alloc] initWithContentView:SGRMakeMiniPlayer()];
            [self.accessory.contentView registerForTraitChanges:@[UITraitTabAccessoryEnvironment.class] withTarget:self action:@selector(minimizedChanged)];
        } else {
            self.tabBarMinimizeBehavior = UITabBarMinimizeBehaviorNever;
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
    SGLog(@"tab bar: split Search on, mini player %@, custom layout %@, scroll-up restore %@",
          sg_inline ? @"on" : @"off", kNavbarCustomLayout ? @"on" : @"off", kScrollUpRestore ? @"on" : @"off");
}

// iOS 26 draws the regular tabs in one liquid-glass platter and the search tab in another.
// Moving the buttons' frames (round 3) left that platter where UIKit put it.
static BOOL tabNameHas(UIView *view, NSString *needle) {
    return [NSStringFromClass(view.class) containsString:needle];
}

static UIFont *sg_tabTitleFont(void) {
    return [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
}

static CGFloat sg_titlePixels(NSString *title) {
    if (!title.length) return 64;
    return ceil([title sizeWithAttributes:@{NSFontAttributeName: sg_tabTitleFont()}].width);
}

// One regular tab, after the side margins and Search's circle. Hidden tabs are not given a slot:
// sharing the row with the hidden Create tab is what squeezed "La tua libreria" down to "L".
static CGFloat sg_tabRoom(CGFloat barW, NSUInteger regular) {
    if (!regular) return 120;
    if (barW < 80) barW = 402;
    CGFloat room = barW - 21 * 2 - 64 - 8;
    return MAX(96, floor(room / (CGFloat)regular));
}

static NSString *sg_titleThatFits(NSString *title, CGFloat room) {
    if (!title.length) return title ?: @"";
    CGFloat need = sg_titlePixels(title) + 18;
    if (need <= room) return title;
    if ([title.lowercaseString containsString:@"librer"] && title.length > 8) {
        static NSString *logged;
        if (![logged isEqualToString:title]) {
            logged = [title copy];
            SGLog(@"tab bar: title \"%@\" needs %.0fpt in a %.0fpt slot, using Libreria", title, need, room);
        }
        return @"Libreria";
    }
    return title;
}

static void collectPlatters(UIView *view, NSMutableArray<UIView *> *out, NSInteger depth) {
    if (depth > 5 || view.hidden || view.alpha < 0.01) return;
    if (depth > 0 && tabNameHas(view, @"Platter") && !tabNameHas(view, @"Background")
        && view.bounds.size.width >= 36 && view.bounds.size.height >= 36) {
        [out addObject:view];
    }
    if (tabNameHas(view, @"Accessory")) return;
    for (UIView *sub in view.subviews) collectPlatters(sub, out, depth + 1);
}

static BOOL isTabButton(UIView *view) {
    return tabNameHas(view, @"TabButton") || tabNameHas(view, @"TabBarButton");
}

static void collectButtonRows(UIView *view, NSMutableArray<NSArray<UIView *> *> *rows) {
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    for (UIView *sub in view.subviews) {
        if (!isTabButton(sub) || sub.hidden || sub.alpha < 0.01) continue;
        if (sub.bounds.size.width < 24 || sub.bounds.size.height < 24) continue;
        [buttons addObject:sub];
    }
    if (buttons.count) [rows addObject:buttons];
    for (UIView *sub in view.subviews) if (!isTabButton(sub)) collectButtonRows(sub, rows);
}

static void logTabTreeOnce(UIView *bar) {
    static BOOL logged;
    if (logged) return;
    logged = YES;
    NSMutableString *out = [NSMutableString stringWithString:@"tab bar views"];
    NSInteger count = 0;
    NSMutableArray<NSArray *> *stack = [NSMutableArray arrayWithObject:@[bar, @0]];
    while (stack.count && count < 40) {
        NSArray *item = stack.lastObject;
        [stack removeLastObject];
        UIView *view = item[0];
        NSInteger depth = [item[1] integerValue];
        count++;
        NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)depth * 2 withString:@" " startingAtIndex:0];
        [out appendFormat:@"\n%@%@ %.0f,%.0f %.0fx%.0f", pad, NSStringFromClass(view.class),
            view.frame.origin.x, view.frame.origin.y, view.bounds.size.width, view.bounds.size.height];
        if (depth >= 4) continue;
        for (UIView *sub in view.subviews.reverseObjectEnumerator) [stack addObject:@[sub, @(depth + 1)]];
    }
    SGLogLong(@"navbar", out);
}

static void noteButtonContents(UIView *view, NSInteger depth, NSMutableString *text, CGRect *label, CGRect *image, BOOL *sawImage) {
    if (!view || depth > 6) return;
    if ([view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length && !text.length) {
        [text appendString:((UILabel *)view).text];
        *label = view.frame;
    }
    if ([view isKindOfClass:UIImageView.class] && !*sawImage) {
        *image = view.frame;
        *sawImage = YES;
    }
    for (UIView *sub in view.subviews) noteButtonContents(sub, depth + 1, text, label, image, sawImage);
}

static void logPlatterButtons(UIView *platter) {
    NSMutableArray<NSArray<UIView *> *> *rows = [NSMutableArray array];
    collectButtonRows(platter, rows);
    if (!rows.firstObject.count) return;
    NSArray<UIView *> *ordered = [rows.firstObject sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        if (a.frame.origin.x < b.frame.origin.x) return NSOrderedAscending;
        if (a.frame.origin.x > b.frame.origin.x) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSMutableString *out = [NSMutableString stringWithString:@"tab bar buttons"];
    for (UIView *button in ordered) {
        NSMutableString *text = [NSMutableString string];
        CGRect label = CGRectZero, image = CGRectZero;
        BOOL sawImage = NO;
        noteButtonContents(button, 0, text, &label, &image, &sawImage);
        [out appendFormat:@" \"%@\" button %.0fx%.0f label %@ image %@",
            text.length ? text : @"?", button.bounds.size.width, button.bounds.size.height,
            NSStringFromCGRect(label), sawImage ? NSStringFromCGRect(image) : @"none"];
    }
    static NSString *last;
    if ([out isEqualToString:last]) return;
    last = [out copy];
    SGLog(@"%@", out);
}

static void sg_describeButton(UIView *button, NSMutableString *out, NSString *shell, NSUInteger index) {
    UIImageView *imageView = nil;
    UILabel *label = nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:button];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (!imageView && [view isKindOfClass:UIImageView.class]) imageView = (UIImageView *)view;
        if (!label && [view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) label = (UILabel *)view;
        if (view != button && isTabButton(view)) continue;
        for (UIView *sub in view.subviews) [stack addObject:sub];
    }
    UIImage *image = imageView.image;
    [out appendFormat:@"\n  %@ %lu \"%@\" button %@ alpha %.2f hidden %d image %@ alpha %.2f hidden %d img %.0fx%.0f label %@ \"%@\" alpha %.2f hidden %d",
        shell, (unsigned long)index, label.text ?: @"",
        NSStringFromCGRect(button.frame), button.alpha, button.hidden,
        imageView ? NSStringFromCGRect(imageView.frame) : @"none",
        imageView ? imageView.alpha : 0, imageView ? imageView.hidden : 1,
        image.size.width, image.size.height,
        label ? NSStringFromCGRect(label.frame) : @"none", label.text ?: @"",
        label ? label.alpha : 0, label ? label.hidden : 1];
}

// Once per distinct layout, capped. ContentView and SelectedContentView each keep their own
// _UITabButton copies; the last leading tab was the one whose image collapsed to 1x1.
static void sg_logLeadingTabs(SGRInlineTabs *tabs) {
    UITabBar *bar = tabs.tabBar;
    if (!bar || bar.bounds.size.width < 80) return;
    NSMutableString *out = [NSMutableString stringWithFormat:@"tab bar leading custom %d", kNavbarCustomLayout];
    if (@available(iOS 26.0, *)) {
        [out appendString:@"\n  model"];
        NSUInteger i = 0;
        for (UITab *tab in tabs.tabs) {
            BOOL hidden = NO;
            if ([tab respondsToSelector:@selector(isHidden)])
                hidden = ((BOOL (*)(id, SEL))objc_msgSend)(tab, @selector(isHidden));
            [out appendFormat:@" [%lu \"%@\" hidden %d%@]", (unsigned long)i, tab.title ?: @"", hidden,
                [tab isKindOfClass:UISearchTab.class] ? @" search" : @""];
            i++;
        }
    }
    NSMutableArray<UIView *> *platters = [NSMutableArray array];
    collectPlatters(bar, platters, 0);
    UIView *tabsPlatter = nil;
    CGFloat best = 0;
    for (UIView *platter in platters) {
        CGRect rect = [platter convertRect:platter.bounds toView:bar];
        BOOL square = rect.size.width < 110 && rect.size.width <= rect.size.height * 1.5;
        if (square || rect.size.width <= best) continue;
        best = rect.size.width;
        tabsPlatter = platter;
    }
    if (!tabsPlatter) {
        [out appendString:@"\n  no leading platter"];
    } else {
        NSMutableArray<UIView *> *shells = [NSMutableArray array];
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:tabsPlatter];
        while (stack.count) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            NSString *name = NSStringFromClass(view.class);
            if (view != tabsPlatter && ([name containsString:@"SelectedContentView"] || [name containsString:@"ContentView"])) {
                [shells addObject:view];
                continue;
            }
            for (UIView *sub in view.subviews) [stack addObject:sub];
        }
        for (UIView *shell in shells) {
            NSString *kind = [NSStringFromClass(shell.class) containsString:@"SelectedContent"] ? @"selected" : @"content";
            NSMutableArray<UIView *> *buttons = [NSMutableArray array];
            NSMutableArray<UIView *> *walk = [NSMutableArray arrayWithObject:shell];
            while (walk.count) {
                UIView *view = walk.lastObject;
                [walk removeLastObject];
                if (view != shell && isTabButton(view)) {
                    [buttons addObject:view];
                    continue;
                }
                for (UIView *sub in view.subviews) [walk addObject:sub];
            }
            [buttons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
                if (a.frame.origin.x < b.frame.origin.x) return NSOrderedAscending;
                if (a.frame.origin.x > b.frame.origin.x) return NSOrderedDescending;
                return NSOrderedSame;
            }];
            if (!buttons.count) [out appendFormat:@"\n  %@ (no buttons)", kind];
            for (NSUInteger i = 0; i < buttons.count; i++) sg_describeButton(buttons[i], out, kind, i);
        }
    }
    static NSString *last;
    static NSUInteger logged;
    if ([out isEqualToString:last] || logged >= 20) return;
    logged++;
    last = [out copy];
    SGLogLong(@"navbar", out);
}

// Search stays in its own circle. The leading platter is only slid to the leading margin; its
// buttons are UIKit's, at the item width set before this layout. Their frames are not written.
// With kNavbarCustomLayout off this never runs: writing the platter's frame is what clipped the
// last leading tab down to its first letter.
- (void)placeLeadingCluster {
    if (!kNavbarCustomLayout || self.minimized) return;
    UITabBar *bar = self.tabBar;
    CGFloat barW = bar.bounds.size.width;
    if (barW < 80 || self.sources.count < 2) return;
    logTabTreeOnce(bar);

    NSMutableArray<UIView *> *platters = [NSMutableArray array];
    collectPlatters(bar, platters, 0);
    UIView *tabsPlatter = nil, *searchPlatter = nil;
    CGRect tabsRect = CGRectZero, searchRect = CGRectZero;
    for (UIView *platter in platters) {
        CGRect rect = [platter convertRect:platter.bounds toView:bar];
        if (rect.size.width > barW - 8) continue;
        BOOL square = rect.size.width < 110 && rect.size.width <= rect.size.height * 1.5;
        if (square) {
            if (!searchPlatter || CGRectGetMidX(rect) > CGRectGetMidX(searchRect)) {
                searchPlatter = platter;
                searchRect = rect;
            }
        } else if (!tabsPlatter || rect.size.width > tabsRect.size.width) {
            tabsPlatter = platter;
            tabsRect = rect;
        }
    }
    if (!tabsPlatter && platters.count == 1) {
        tabsPlatter = platters.firstObject;
        tabsRect = [tabsPlatter convertRect:tabsPlatter.bounds toView:bar];
        searchPlatter = nil;
    }
    NSUInteger regular = 0;
    for (UIView *source in self.sources) if (!isSearchItem(source)) regular++;
    if (!regular) regular = self.sources.count > 1 ? self.sources.count - 1 : self.sources.count;
    if (!tabsPlatter || !regular) {
        static NSUInteger misses;
        if (misses++ < 4) SGLog(@"tab bar: no leading platter (%lu platters, %lu tabs)",
                                (unsigned long)platters.count, (unsigned long)self.sources.count);
        return;
    }
    logPlatterButtons(tabsPlatter);

    CGFloat margin = 16;
    if (searchPlatter) {
        CGFloat trail = barW - CGRectGetMaxX(searchRect);
        if (trail >= 0 && trail <= 28) margin = trail;
    } else if (CGRectGetMinX(tabsRect) >= 0 && CGRectGetMinX(tabsRect) <= 28) {
        margin = CGRectGetMinX(tabsRect);
    }
    BOOL leadOff = fabs(CGRectGetMinX(tabsRect) - margin) > 2;
    BOOL searchOff = searchPlatter && fabs((barW - margin) - CGRectGetMaxX(searchRect)) > 2;
    static NSString *last;
    NSString *mark = [NSString stringWithFormat:@"%.0f %.0f %.0f %d %d", tabsRect.size.width, CGRectGetMinX(tabsRect), margin, leadOff, searchOff];
    if (![mark isEqualToString:last]) {
        last = [mark copy];
        SGLog(@"tab bar: platter %.0f at x %.0f (margin %.0f), search %@, item width %.0f, platters %lu",
              tabsRect.size.width, CGRectGetMinX(tabsRect), margin,
              searchPlatter ? @"own circle" : @"inside the platter", bar.itemWidth, (unsigned long)platters.count);
    }
    if (!leadOff && !searchOff) return;

    if (leadOff) {
        CGPoint leading = [bar convertPoint:CGPointMake(margin, CGRectGetMinY(tabsRect)) toView:tabsPlatter.superview];
        CGRect platterFrame = tabsPlatter.frame;
        platterFrame.origin.x = leading.x;
        tabsPlatter.frame = platterFrame;
    }
    if (searchOff) {
        CGPoint origin = [bar convertPoint:CGPointMake(barW - margin - searchRect.size.width, CGRectGetMinY(searchRect)) toView:searchPlatter.superview];
        CGRect frame = searchPlatter.frame;
        frame.origin.x = origin.x;
        searchPlatter.frame = frame;
    }
}

// The controller's bar stays the full screen wide. A narrower centered frame pulled the Search
// circle off the trailing edge and centered the remaining tabs with it. Minimized, UIKit places
// the leading tab and that circle itself, which also needs the full width.
//
// With a bottom accessory, UIKit stretches Fixed leading tabs across the gap to Search — the same
// widths as a three-tab platter. itemWidth alone does not stick on the glass bar, so hugLeadingPlatter
// also shrinks that platter and packs the buttons to content size after every layout pass.
- (CGFloat)fittingItemWidth {
    if (@available(iOS 26.0, *)) {
        NSUInteger regular = 0;
        CGFloat need = 0;
        for (NSUInteger i = 0; i < self.sources.count && i < self.tabs.count; i++) {
            if (isSearchItem(self.sources[i])) continue;
            regular++;
            NSString *title = self.tabs[i].title.length ? self.tabs[i].title : labelIn(self.sources[i]).text;
            // Icon above title: width is the label (or icon) plus side padding — not icon+label in a row.
            CGFloat width = MAX(28, sg_titlePixels(title)) + 20;
            if (width < 64) width = 64;
            if (width > need) need = width;
        }
        if (!regular || need < 1) return 0;
        CGFloat room = sg_tabRoom(self.view.bounds.size.width, regular);
        if (need > room) need = room;
        return need;
    }
    return 0;
}

- (BOOL)shouldHugLeadingTabs {
    if (!sg_inline || self.minimized) return NO;
    if (@available(iOS 26.0, *)) return self.bottomAccessory != nil;
    return NO;
}

- (void)applyHugLeadingTabs {
    UITabBar *bar = self.tabBar;
    if (![self shouldHugLeadingTabs]) {
        if (!kNavbarCustomLayout && bar.itemWidth != 0) bar.itemWidth = 0;
        return;
    }
    CGFloat width = [self fittingItemWidth];
    if (width < 1) return;
    // Always re-assert: UIKit's layout pass clears or stretches without this.
    if (fabs(bar.itemWidth - width) > 0.25) {
        bar.itemWidth = width;
        static CGFloat logged;
        if (fabs(logged - width) > 0.5) {
            logged = width;
            SGLog(@"tab bar: item width %.0f (hug accessory)", width);
        }
    } else {
        bar.itemWidth = width;
    }
    if (bar.itemPositioning != UITabBarItemPositioningCentered)
        bar.itemPositioning = UITabBarItemPositioningCentered;
}

// UIKit's accessory layout keeps the leading glass as wide as a full three-tab cluster. Shrink that
// platter and pack its buttons to the content item width — without the title-shortening pass that
// kNavbarCustomLayout used to run.
- (void)hugLeadingPlatter {
    if (![self shouldHugLeadingTabs]) return;
    UITabBar *bar = self.tabBar;
    CGFloat barW = bar.bounds.size.width;
    CGFloat itemW = [self fittingItemWidth];
    if (barW < 80 || itemW < 1) return;

    NSMutableArray<UIView *> *platters = [NSMutableArray array];
    collectPlatters(bar, platters, 0);
    UIView *tabsPlatter = nil;
    CGRect tabsRect = CGRectZero;
    for (UIView *platter in platters) {
        CGRect rect = [platter convertRect:platter.bounds toView:bar];
        if (rect.size.width > barW - 8) continue;
        BOOL square = rect.size.width < 110 && rect.size.width <= rect.size.height * 1.5;
        if (square) continue;
        if (!tabsPlatter || rect.size.width > tabsRect.size.width) {
            tabsPlatter = platter;
            tabsRect = rect;
        }
    }
    if (!tabsPlatter) return;

    NSUInteger regular = 0;
    for (UIView *source in self.sources) if (!isSearchItem(source)) regular++;
    if (regular < 1) return;

    CGFloat pad = 10;
    CGFloat want = pad * 2 + itemW * (CGFloat)regular;
    if (want > barW - 80) want = barW - 80;
    // Already hugging (same look as mini player off).
    if (tabsRect.size.width <= want + 6) return;

    CGFloat margin = 16;
    CGPoint leading = [bar convertPoint:CGPointMake(margin, CGRectGetMinY(tabsRect)) toView:tabsPlatter.superview];
    CGRect platterFrame = tabsPlatter.frame;
    platterFrame.origin.x = leading.x;
    platterFrame.size.width = want;
    tabsPlatter.frame = platterFrame;

    NSMutableArray<NSArray<UIView *> *> *rows = [NSMutableArray array];
    collectButtonRows(tabsPlatter, rows);
    for (NSArray<UIView *> *buttons in rows) {
        if (buttons.count < regular) continue;
        NSArray<UIView *> *ordered = [buttons sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
            if (a.frame.origin.x < b.frame.origin.x) return NSOrderedAscending;
            if (a.frame.origin.x > b.frame.origin.x) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        CGFloat x = pad;
        NSUInteger n = MIN(ordered.count, regular);
        for (NSUInteger i = 0; i < n; i++) {
            UIView *button = ordered[i];
            CGRect frame = button.frame;
            // Only rewrite when stretched; leave height/y alone.
            if (fabs(frame.origin.x - x) > 0.5 || fabs(frame.size.width - itemW) > 0.5) {
                frame.origin.x = x;
                frame.size.width = itemW;
                button.frame = frame;
            }
            x += itemW;
        }
    }
    static CGFloat loggedWant;
    if (fabs(loggedWant - want) > 0.5) {
        loggedWant = want;
        SGLog(@"tab bar: leading platter %.0f → %.0f (item %.0f × %lu)", tabsRect.size.width, want, itemW, (unsigned long)regular);
    }
}

- (void)viewDidLayoutSubviews {
    UITabBar *bar = self.tabBar;
    [super viewDidLayoutSubviews];
    // After UIKit lays the accessory bar out — before, itemWidth does not stick.
    if ([self shouldHugLeadingTabs] || kNavbarCustomLayout) [self applyHugLeadingTabs];
    else if (bar.itemWidth != 0) bar.itemWidth = 0;
    if (sg_inline && !sg_pageScroll.window) searchPageScroll();
    if (!kNavbarCustomLayout) return;
    // Width of one tab, not of the bar. fullWidth/count stretched two tabs across the gap Create
    // left. Zero let UIKit share that gap with the hidden tab and clip "La tua libreria" to "L".
    static BOOL fitting;
    if (fitting) return;
    NSUInteger count = self.sources.count;
    CGFloat full = self.view.bounds.size.width;
    if (count < 2 || full < 80) return;
    noteTabSlot(full, count);
    if (self.minimized && bar.itemWidth != 0) bar.itemWidth = 0;
    CGRect frame = bar.frame;
    BOOL widthWrong = fabs(frame.size.width - full) > 0.5 || fabs(frame.origin.x) > 0.5;
    if (widthWrong) {
        fitting = YES;
        frame.origin.x = 0;
        frame.size.width = full;
        bar.frame = frame;
        [bar layoutIfNeeded];
        fitting = NO;
        logTabFit(count, full, full, self.minimized ? @"inline minimized" : @"inline");
    }
}

// The accessory is inline beside the minimized bar; with no track there is no accessory and no telling.
- (BOOL)minimized {
    if (@available(iOS 26.0, *)) return self.bottomAccessory.contentView.traitCollection.tabAccessoryEnvironment == UITabAccessoryEnvironmentInline;
    return NO;
}

- (void)minimizedChanged {
    [self logAccessoryFrame:self.minimized ? @"trait inline" : @"trait expanded"];
    if (self.minimized) {
        static BOOL once;
        if (!once) {
            once = YES;
            SGLog(@"tab bar: accessory minimized inline (UIKit OnScrollDown)");
        }
    }
    if (self.stockBar) syncBar(self.stockBar);
}

// Between the first tab and the trailing circle.
- (BOOL)isMiddle:(NSUInteger)index {
    return index > 0 && index + 1 < self.sources.count;
}

// A tap on the minimized selected tab only expands the bar, with no shouldSelectTab.
- (void)leadingTapped:(UITapGestureRecognizer *)tap {
    SGLog(@"tab bar: the minimized leading tab takes the tap for %@", labelIn(self.sources.firstObject).text);
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
        BOOL track = SGURIString(state.track.URI).length > 0;
        UITabAccessory *want = track ? self.accessory : nil;
        BOOL changed = self.bottomAccessory != want;
        if (changed) [self setBottomAccessory:want animated:self.viewIfLoaded.window != nil];
        // Keep OnScrollDown armed whenever the accessory is up; nothing else may leave it on Never.
        if (want && self.tabBarMinimizeBehavior != UITabBarMinimizeBehaviorOnScrollDown)
            self.tabBarMinimizeBehavior = UITabBarMinimizeBehaviorOnScrollDown;
        if (want && (changed || !sg_pageScroll.window)) {
            searchPageScroll();
            nameScrollView();
            if (changed) SGLog(@"tab bar: accessory %@, behavior %ld", track ? @"on" : @"off", (long)self.tabBarMinimizeBehavior);
        }
        if (want) {
            // Accessory attachment reflows the bar; hug before the next user-visible frame.
            dispatch_async(dispatch_get_main_queue(), ^{ [self applyHugLeadingTabs]; });
        }
    }
}

- (BOOL)tabBarController:(UITabBarController *)controller shouldSelectTab:(UITab *)tab API_AVAILABLE(ios(26.0)) {
    if (sg_flipping) return YES;
    NSUInteger index = [self.tabs indexOfObject:tab];
    self.leadRedirected = self.touchedLead && [self isMiddle:index];
    if (self.leadRedirected) index = 0;
    UIView *source = index < self.sources.count ? self.sources[index] : nil;
    BOOL search = isSearchItem(source);
    BOOL already = isActive(source);
    if (search) {
        id icon = encoreIconOf(iconIn(source));
        NSString *iconName = [icon respondsToSelector:@selector(name)] ? [icon name] : @"";
        SGLog(@"search tab: tap received title %@ icon %@ already %d", labelIn(source).text ?: @"", iconName, already);
    }
    if (source) SGRTabPicked(source);
    // Home tapped while on Home pops Spotify's stack, which would take Mod Settings straight off it.
    BOOL sent = source && !self.holding && forwardTap(source);
    if (search) SGLog(@"search tab: tab selected, Spotify tap %@", sent ? @"fired" : @"not fired");
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
    if (!CGRectEqualToRect(host.frame, view.bounds)) {
        SGLog(@"tab bar: host frame %@ -> %@", NSStringFromCGRect(host.frame), NSStringFromCGRect(view.bounds));
        host.frame = view.bounds;
    }
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

    NSUInteger regularCount = 0;
    for (UIView *source in sources) if (!isSearchItem(source)) regularCount++;
    CGFloat room = sg_tabRoom(stockBar.bounds.size.width, MAX(regularCount, 1));
    // Search in the middle of the model (Home, Search, Library) is still drawn in the trailing
    // circle, and the regular tab that ends up last in the leading platter is the one UIKit lays
    // out with the search button's metrics: image view 1x1, title the first letter. Regular tabs
    // stay in Spotify's order; Search is appended so it is the last tab.
    // Rebuild when Search is newly detected too: the first pass can miss the icon / stock list, and
    // leaving every tab as a plain UITab keeps one unified platter.
    BOOL hasSearchTab = NO;
    for (UITab *tab in tabs.tabs) {
        if ([tab isKindOfClass:UISearchTab.class]) { hasSearchTab = YES; break; }
    }
    BOOL wantsSearch = NO;
    for (UIView *source in sources) {
        if (isSearchItem(source)) { wantsSearch = YES; break; }
    }
    if (![sources isEqualToArray:tabs.stockOrder] || wantsSearch != hasSearchTab) {
        NSMutableArray<UIView *> *ordered = [NSMutableArray array];
        NSMutableArray<UITab *> *list = [NSMutableArray array];
        UIView *searchSource = nil;
        UITab *searchTabBuilt = nil;
        NSMutableArray<NSString *> *platterNames = [NSMutableArray array];
        NSString *circle = @"none";
        NSMutableString *detect = [NSMutableString stringWithString:@"tab bar: detect"];
        for (UIView *source in sources) {
            NSString *full = labelIn(source).text ?: @"";
            BOOL search = isSearchItem(source);
            id icon = encoreIconOf(iconIn(source));
            NSString *iconName = [icon respondsToSelector:@selector(name)] ? [icon name] : @"-";
            [detect appendFormat:@"\n  \"%@\" icon %@ search %d id %@", full, iconName, search,
                 source.accessibilityIdentifier ?: @"-"];
            NSString *title = hideLabels ? @"" : (kNavbarCustomLayout && !search ? sg_titleThatFits(full, room) : full);
            UITab *tab;
            // Only Search is a UISearchTab. The last visible item used to become the circle, so
            // while Create was hiding, La tua libreria was that circle and drew as its first letter.
            if (search) {
                UISearchTab *searchTab = [[UISearchTab alloc] initWithViewControllerProvider:^UIViewController *(UITab *t) { return inlinePage(t); }];
                searchTab.title = title;
                searchTab.image = glyphOf(source, NO);
                // automaticallyActivatesSearch opens UIKit's search on this tab's view controller,
                // which is an empty stand-in, not Spotify's Search page: the tap then never focuses
                // Spotify's field. The circle only selects; shouldSelectTab forwards to Spotify and
                // asks for the field.
                searchTab.automaticallyActivatesSearch = NO;
                // Pinned puts Search on the trailing edge as its own circle; Fixed keeps the rest
                // in the leading platter so Automatic does not stretch them into one block.
                searchTab.preferredPlacement = UITabPlacementPinned;
                tab = searchTab;
                searchSource = source;
                searchTabBuilt = tab;
                circle = full.length ? full : @"search";
            } else {
                NSString *identifier = [NSString stringWithFormat:@"spotifyglass.tab.%lu", (unsigned long)list.count];
                UIImage *glyph = glyphOf(source, NO);
                tab = [[UITab alloc] initWithTitle:title image:glyph identifier:identifier
                            viewControllerProvider:^UIViewController *(UITab *t) { return inlinePage(t); }];
                tab.preferredPlacement = UITabPlacementFixed;
                [ordered addObject:source];
                [list addObject:tab];
                [platterNames addObject:[NSString stringWithFormat:@"%@%@", title, glyph ? @"" : @" (no glyph)"]];
            }
        }
        if (searchSource && searchTabBuilt) {
            [ordered addObject:searchSource];
            [list addObject:searchTabBuilt];
        }
        tabs.stockOrder = sources;
        tabs.sources = ordered;
        tabs.tabs = list;
        SGLogLong(@"navbar", detect);
        SGLog(@"tab bar: %lu tabs, platter %@, circle %@ last, slot %.0f, custom layout %@",
              (unsigned long)list.count,
              platterNames.count ? [platterNames componentsJoinedByString:@", "] : @"none", circle, room,
              kNavbarCustomLayout ? @"on" : @"off");
        if ([circle isEqualToString:@"none"]) {
            SGLog(@"tab bar: no Search tab detected — bar stays one platter until Search is found");
        }
    }
    if (kNavbarCustomLayout && tabs.tabBar.itemPositioning != UITabBarItemPositioningCentered)
        tabs.tabBar.itemPositioning = UITabBarItemPositioningCentered;

    // Spotify's selected tab shows its filled icon, as UITabBarItem's selectedImage did on the other bar.
    // Minimized, and only with custom layout on, the middle tabs wear the first tab's glyph.
    NSArray<UIView *> *shown = tabs.sources ?: @[];
    UITab *selected = nil;
    UIView *current = SGRCurrentModTab();
    NSUInteger modTab = current ? [shown indexOfObject:current] : NSNotFound;
    BOOL missing = NO;
    static UIImage *leadFrom, *lead;
    UIImage *leadGlyph = kNavbarCustomLayout && tabs.minimized && shown.count ? glyphOf(shown.firstObject, NO) : nil;
    if (leadGlyph != leadFrom) {
        leadFrom = leadGlyph;
        lead = [leadGlyph imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    }
    for (NSUInteger i = 0; i < shown.count && i < tabs.tabs.count; i++) {
        UITab *tab = tabs.tabs[i];
        BOOL active = modTab != NSNotFound ? i == modTab : isActive(shown[i]);
        if (active && !selected) selected = tab;
        if ([tab isKindOfClass:UISearchTab.class]) {
            UISearchTab *search = (UISearchTab *)tab;
            if (search.automaticallyActivatesSearch) search.automaticallyActivatesSearch = NO;
            if (search.preferredPlacement != UITabPlacementPinned) search.preferredPlacement = UITabPlacementPinned;
        } else if (tab.preferredPlacement != UITabPlacementFixed) {
            tab.preferredPlacement = UITabPlacementFixed;
        }
        UIImage *image = [tab isKindOfClass:UISearchTab.class] ? searchTabImage(shown[i], active) : glyphOf(shown[i], active);
        missing |= !image;
        if (kNavbarCustomLayout && lead && [tabs isMiddle:i]) image = lead;
        if (image && tab.image != image) tab.image = image;
        if (![tab isKindOfClass:UISearchTab.class] && !hideLabels) {
            NSString *full = labelIn(shown[i]).text ?: @"";
            NSString *title = kNavbarCustomLayout ? sg_titleThatFits(full, room) : full;
            if (title.length && ![tab.title isEqualToString:title]) tab.title = title;
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
    static NSUInteger retries;
    if (missing && retries++ < 40) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            syncBar(stockBar);
        });
    }
    nameScrollView();
}

// Minimize follows whatever vertical list is moving. No page allow list: Home, Search, Library,
// playlists, albums, and anything else that scrolls. Horizontal shelves and the glass host are
// ignored; everything else that moves on Y retargets UIKit's contentScrollView immediately.
static BOOL isPrimarilyHorizontal(UIScrollView *scroll) {
    CGFloat bw = scroll.bounds.size.width, bh = scroll.bounds.size.height;
    CGFloat cw = scroll.contentSize.width, ch = scroll.contentSize.height;
    if (bw < 1 || bh < 1) return NO;
    return cw > bw + 8 && ch <= bh + 8;
}

static BOOL canDriveMinimize(UIScrollView *scroll) {
    if (!sg_inline || !scroll) return NO;
    if (!scroll.window || scroll.hidden || scroll.alpha < 0.01) return NO;
    if (scroll.pagingEnabled) return NO;
    if ([scroll isDescendantOfView:sg_inlineHost]) return NO;
    if (isPrimarilyHorizontal(scroll)) return NO;
    if (scroll.bounds.size.height < 64) return NO;
    UIView *container = sg_inlineHost.superview;
    if (container && [scroll isDescendantOfView:container]) return YES;
    // Content that is not under TabBarContainer still counts if it sits above the glass bar.
    UITabBar *bar = sg_inlineTabs.tabBar;
    if (!bar.window || scroll.window != bar.window) return NO;
    CGRect scrollInWindow = [scroll convertRect:scroll.bounds toView:nil];
    CGRect barInWindow = [bar convertRect:bar.bounds toView:nil];
    return CGRectGetMidY(scrollInWindow) < CGRectGetMinY(barInWindow) - 8;
}

static BOOL isNearerFront(UIView *a, UIView *b, UIView *container) {
    if (!b) return YES;
    if (!a) return NO;
    if (!container) return YES;
    NSMutableArray<UIView *> *pathA = [NSMutableArray array];
    NSMutableArray<UIView *> *pathB = [NSMutableArray array];
    for (UIView *v = a; v && v != container; v = v.superview) [pathA insertObject:v atIndex:0];
    for (UIView *v = b; v && v != container; v = v.superview) [pathB insertObject:v atIndex:0];
    NSUInteger n = MIN(pathA.count, pathB.count);
    for (NSUInteger i = 0; i < n; i++) {
        if (pathA[i] == pathB[i]) continue;
        UIView *parent = i > 0 ? pathA[i - 1] : container;
        NSUInteger ia = [parent.subviews indexOfObjectIdenticalTo:pathA[i]];
        NSUInteger ib = [parent.subviews indexOfObjectIdenticalTo:pathB[i]];
        return ia >= ib;
    }
    return pathA.count >= pathB.count;
}

static UIScrollView *scrollFromHit(UIView *root, CGPoint point) {
    UIView *hit = [root hitTest:point withEvent:nil];
    if (!hit || hit == sg_inlineHost || [hit isDescendantOfView:sg_inlineHost]) return nil;
    for (UIView *v = hit; v && v != root; v = v.superview) {
        if ([v isKindOfClass:UIScrollView.class] && canDriveMinimize((UIScrollView *)v)) return (UIScrollView *)v;
    }
    return nil;
}

static void takePageScroll(UIScrollView *scroll, NSString *why) {
    if (!scroll || !canDriveMinimize(scroll)) return;
    if (sg_pageScroll == scroll) return;
    sg_pageScroll = scroll;
    static NSUInteger logged;
    if (logged++ < 40) SGLog(@"tab bar: follows %@ %p %@ (%@)", NSStringFromClass(scroll.class), scroll, NSStringFromCGRect(scroll.frame), why);
    nameScrollView();
}

static void considerScrollView(UIScrollView *scroll) {
    if (!canDriveMinimize(scroll)) return;
    UIScrollView *current = sg_pageScroll;
    if (current == scroll) return;
    UIView *container = sg_inlineHost.superview;
    if (current.window && canDriveMinimize(current) && [scroll isDescendantOfView:current]) return;
    if (current.window && [current isDescendantOfView:scroll]) {
        takePageScroll(scroll, @"outer page list");
        return;
    }
    if (current.window && canDriveMinimize(current) && container && !isNearerFront(scroll, current, container)) return;
    takePageScroll(scroll, @"came on screen");
}

static BOOL sg_forceScrollSearch;

static void searchPageScroll(void) {
    if (!sg_inline) return;
    UIView *container = sg_inlineHost.superview;
    UIView *root = container ?: sg_inlineTabs.view.window;
    if (!root) return;
    if (sg_pageScroll && !canDriveMinimize(sg_pageScroll)) {
        static NSUInteger dropped;
        if (dropped++ < 12) SGLog(@"tab bar: drops %@ %p (cannot drive minimize)",
                                  NSStringFromClass(sg_pageScroll.class), sg_pageScroll);
        sg_pageScroll = nil;
    }
    static CFTimeInterval last;
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval gap = sg_pageScroll.window ? 0.75 : 0.2;
    if (!sg_forceScrollSearch && now - last < gap) return;
    sg_forceScrollSearch = NO;
    last = now;

    CGFloat w = root.bounds.size.width, h = root.bounds.size.height;
    CGPoint probes[] = {
        CGPointMake(w * 0.5, h * 0.28),
        CGPointMake(w * 0.5, h * 0.42),
        CGPointMake(w * 0.5, h * 0.55),
        CGPointMake(w * 0.5, h * 0.68),
    };
    for (NSUInteger i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
        UIScrollView *front = scrollFromHit(root, probes[i]);
        if (!front) continue;
        takePageScroll(front, @"front hit");
        return;
    }

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    UIScrollView *best = nil;
    NSUInteger found = 0, seen = 0;
    while (queue.count) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (view == sg_inlineHost || view.hidden || view.alpha < 0.01) continue;
        if ([view isKindOfClass:UIScrollView.class]) {
            seen++;
            UIScrollView *scroll = (UIScrollView *)view;
            if (canDriveMinimize(scroll)) {
                found++;
                if (!best) best = scroll;
                else if ([best isDescendantOfView:scroll]) best = scroll;
                else if ([scroll isDescendantOfView:best]) { /* keep outer */ }
                else if (isNearerFront(scroll, best, root)) best = scroll;
            }
        }
        for (UIView *sub in view.subviews.reverseObjectEnumerator) [queue addObject:sub];
    }
    if (best) takePageScroll(best, @"searched");
    static NSUInteger logged;
    if (!sg_pageScroll.window && logged++ < 8) {
        SGLog(@"tab bar: no page list found to minimize by (%lu of %lu scroll views)",
              (unsigned long)found, (unsigned long)seen);
    }
}

@interface SGRScrollDrag : NSObject
@end

@implementation SGRScrollDrag
+ (void)dragged:(UIPanGestureRecognizer *)pan {
    UIScrollView *scroll = (UIScrollView *)pan.view;
    if (![scroll isKindOfClass:UIScrollView.class]) return;
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        CGPoint velocity = [pan velocityInView:scroll];
        CGPoint translation = [pan translationInView:scroll];
        BOOL vertical = fabs(velocity.y) >= fabs(velocity.x) || fabs(translation.y) >= fabs(translation.x);
        if (vertical && canDriveMinimize(scroll)) takePageScroll(scroll, @"dragged");
    }
    if (pan.state == UIGestureRecognizerStateEnded && scroll == sg_pageScroll) {
        static NSUInteger logged;
        UIEdgeInsets inset = scroll.adjustedContentInset;
        if (logged++ < 40) SGLog(@"tab bar: drag ended on the followed list, offset %.0f, inset top %.0f bottom %.0f, content %.0f of %.0f, page names it %d",
                                 scroll.contentOffset.y, inset.top, inset.bottom, scroll.contentSize.height, scroll.bounds.size.height,
                                 [sg_inlineTabs.selectedViewController contentScrollViewForEdge:NSDirectionalRectEdgeBottom] == scroll);
    }
    if (scroll == sg_pageScroll) {
        if (pan.state == UIGestureRecognizerStateBegan) sg_dragActive = YES;
        else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) sg_dragActive = NO;
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) sg_dragActive = NO;
}
@end

// Native UIKit expands at the top of the page and when the minimized bar is tapped.
// These stay so MiniPlayer.m still links; they do not move the accessory.
void SGRExpandInlineBar(void) {
    static BOOL logged;
    if (!logged) {
        logged = YES;
        SGLog(@"tab bar: expand left to UIKit (top of the page, or a tap on the minimized bar)");
    }
}

void SGRMinimizeInlineBar(void) {
    static BOOL logged;
    if (!logged) {
        logged = YES;
        SGLog(@"tab bar: minimize left to UIKit (scroll down from the top)");
    }
}

static char kDragKey;

%group SGRInlinePlayerScroll
%hook UIScrollView
- (void)setContentOffset:(CGPoint)offset {
    CGPoint old = self.contentOffset;
    %orig;
    if (!sg_inline || !sg_inlineTabs) return;
    CGFloat dy = fabs(offset.y - old.y);
    if (dy < 0.5) return;
    UIScrollView *scroll = (UIScrollView *)self;
    // Any vertical movement on a list that can drive minimize — no height floor, no page allow list.
    if (!canDriveMinimize(scroll)) return;
    if (fabs(offset.x - old.x) > dy) return; // horizontal pan
    takePageScroll(scroll, @"offset");
}
- (void)didMoveToWindow {
    %orig;
    if (!self.window || !sg_inline) return;
    if (!objc_getAssociatedObject(self, &kDragKey)) {
        objc_setAssociatedObject(self, &kDragKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self.panGestureRecognizer addTarget:SGRScrollDrag.class action:@selector(dragged:)];
    }
    considerScrollView(self);
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

%hook UITabBar
- (void)layoutSubviews {
    %orig;
    SGRInlineTabs *tabs = sg_inlineTabs;
    if (!tabs || (UITabBar *)self != tabs.tabBar) return;
    // After UIKit's pass: itemWidth, then shrink the leading glass so two tabs do not fill a 3-tab gap.
    static BOOL hugging;
    if (!hugging && [tabs shouldHugLeadingTabs]) {
        hugging = YES;
        [tabs applyHugLeadingTabs];
        [tabs hugLeadingPlatter];
        hugging = NO;
    }
    if (tabs.minimized) return;
    sg_logLeadingTabs(tabs);
    if (!kNavbarCustomLayout) return;
    // setFrame on the platter can dirty layout. Don't re-enter this pass.
    static BOOL placing;
    if (placing) return;
    placing = YES;
    [tabs placeLeadingCluster];
    placing = NO;
}
%end

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
    SGRLogTabBarRow((UIView *)self);
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
    SGRLogTabBarRow(bar);
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
    // Library root stays full-frame under a playlist / album; retarget minimize to the page in front.
    if (sg_inline) {
        sg_pageScroll = nil;
        sg_forceScrollSearch = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            searchPageScroll();
            nameScrollView();
        });
    }
}
%end

// A tab changed from elsewhere (a link, the side drawer) repaints the labels without a layout pass.
%hook _TtC23NavigationUI_TabBarImpl19TabBarContainerImpl
- (void)setSelectedViewController:(UIViewController *)controller {
    %orig;
    if (sg_inline) {
        sg_pageScroll = nil;
        sg_forceScrollSearch = YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *bar = sg_stockBar;
        if (bar) syncBar(bar);
        if (sg_inline) {
            searchPageScroll();
            nameScrollView();
        }
    });
}
// The message bar coming or going changes the view's safe area before Spotify lays the bar out for it,
// so the room follows in that same pass, and inside the message bar's animation.
- (void)viewSafeAreaInsetsDidChange {
    %orig;
    makeRoom((UIViewController *)self);
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
    ]);
}
