// Player redesign: the ⋯ opens the system's own menu, laid out the way the Music app lays out its own, in
// place of Spotify's sheet of rows -- while what is in it, and what each row does, stay Spotify's.
//
// The rows come from Swift item factories with no way in, and which there are depends on the track, where it
// plays from, the account, the market and the flags; each does what only Spotify's code knows how to. So the
// ⋯ still opens Spotify's sheet, kept out of sight from its presentation's first frame, and the menu is read
// off its table: each row placed by the number its Encore ListRow carries as its accessibility identifier
// (kKnown; a number not known goes under More) and fired through that ListRow. The menu opens on the rows the
// last menu had, kept across launches, and is updated in place once Spotify's are in.
//
// The menu opens from a button of the mod's own over the ⋯ (SGRPlayerMenuAnchor) on the tap, on the
// rows the last menu had. Spotify's sheet still arrives underneath and dismisses a menu it finds
// open, so that one close is put back once the present returns. A page Spotify pushes onto its
// sheet (Share) shows the sheet as Spotify draws it; so does a sheet whose rows cannot be read, or a menu the
// system does not open. Speed and pitch's sliders open in a popover of their own.
#import <objc/message.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/Player/SpeedPitch.h"
#import "Player.h"

// A sheet this soon after the ⋯'s tap is the player's.
static const NSTimeInterval kMenuAfterTap = 3;
// A row picked before Spotify's rows are in and still not fired by then, and Spotify's own sheet is shown
// instead, with whatever it is showing; rows in the table that still cannot be read by then, likewise.
static const NSTimeInterval kRowsWait = 4;
// A sheet hidden as its presentation begins and still without a menu taken over by then is shown again.
static const NSTimeInterval kClaimWait = 1;
// How often the table is looked at while the menu waits for Spotify's rows. A fiftieth of a second
// was a visible wait between the table gaining rows and the menu showing them; the player's
// transitions run at 120Hz, and this wait stays under a frame without a display link.
static const NSTimeInterval kRowsPoll = 1.0 / 120.0;
// A menu the system has not shown by then is given up for Spotify's sheet.
static const NSTimeInterval kShowWait = 0.8;
// How long after the menu has closed a pick may still come in before the sheet is taken away.
static const NSTimeInterval kPickGrace = 0.3;
// How long Spotify has, after a row is fired, to take its sheet away or put something over it.
static const NSTimeInterval kSettle = 0.8;
// The rows of the last menu, for the next one to open on.
static NSString *const kLastRowsKey = @"spotifyglass.redesign.player.menuRows";
static const CGFloat kPanelWidth = 300, kPanelTop = 12;

// Whether the hooks are in, so the ⋯ is watched only when a menu can be taken over.
static BOOL sgr_menuOn;
static __weak UIView *sgr_moreButton;
static NSTimeInterval sgr_moreTappedAt;
static char kTakeoverKey, kWatchedKey, kDimmingKey, kMaskKey, kSavedMaskKey, kClaimKey, kTakenKey, kHiddenDimmingsKey, kAnchorKey, kContainerTouchesKey;
// YES from a present that can dismiss the menu opened on the tap until the next turn. An outside
// tap after that is the person closing it, and must not run the reopen meant for that present.
static BOOL sgr_sheetPresenting;

#pragma mark - where each of Spotify's rows goes

typedef NS_ENUM(NSInteger, SGRPlayerMenuPlace) {
    SGRPlaceMore,          // under More, the default for a number not known here
    SGRPlaceTile,          // the row of three across the top
    SGRPlaceMain,          // the first group of rows
    SGRPlaceFeedback,      // with More
    SGRPlaceDestructive,   // last, in red
};

typedef struct {
    const char *identifier;
    SGRPlayerMenuPlace place;
    const char *symbol;
} SGRPlayerMenuKnownRow;

// Numbers read off the ListRows of 9.1.78 (trees/continuous/1.txt:650-716). The glyphs are the Music app's
// for the same thing where it has one.
static const SGRPlayerMenuKnownRow kKnown[] = {
    {"19", SGRPlaceTile, "text.badge.plus"},                              // Add to playlist
    {"11", SGRPlaceTile, "text.line.last.and.arrowtriangle.forward"},     // Add to Queue
    {"9", SGRPlaceTile, "square.and.arrow.up"},                           // Share
    {"59", SGRPlaceFeedback, "hand.thumbsdown"},                          // Exclude track from your taste profile
    {"27", SGRPlaceDestructive, "minus.circle"},                          // Remove from this playlist
    {"28", SGRPlaceMore, "quote.bubble"},                                 // Lyrics • On/Off: the redesign shows its own
    {"34", SGRPlaceMore, "list.bullet"},                                  // Go to Queue: the footer has the queue glyph
};

static const SGRPlayerMenuKnownRow *knownRow(NSString *identifier) {
    for (size_t i = 0; i < sizeof(kKnown) / sizeof(kKnown[0]); i++) {
        if ([identifier isEqualToString:@(kKnown[i].identifier)]) return &kKnown[i];
    }
    return NULL;
}

static UIImage *symbol(NSString *name) {
    return name ? [UIImage systemImageNamed:name] : nil;
}

#pragma mark - the player's ⋯

static void openEarly(UIView *button);

@interface SGRPlayerMoreTapWatcher : NSObject <UIGestureRecognizerDelegate>
@end

@implementation SGRPlayerMoreTapWatcher
- (void)tapped:(id)sender {
    UIView *button = [sender isKindOfClass:UIGestureRecognizer.class] ? ((UIGestureRecognizer *)sender).view : sender;
    sgr_moreButton = button;
    sgr_moreTappedAt = CACurrentMediaTime();
    // The glass menu used to wait until Spotify's sheet had begun presenting. That wait is the lag.
    openEarly(button);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    // Touch down, so the sheet Spotify presents on touch up is already inside the window that counts
    // as the ⋯'s, even when Spotify's own action runs before this recognizer's.
    sgr_moreButton = recognizer.view;
    sgr_moreTappedAt = CACurrentMediaTime();
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
@end

void SGRPlayerMenuWatchMoreButton(UIView *button) {
    if (!sgr_menuOn || !button || objc_getAssociatedObject(button, &kWatchedKey)) return;
    static SGRPlayerMoreTapWatcher *watcher;
    if (!watcher) watcher = [SGRPlayerMoreTapWatcher new];
    objc_setAssociatedObject(button, &kWatchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // An Encore button may read its touches through a gesture recognizer rather than as a control, so both
    // are watched, as Speed and pitch watches it.
    if ([button isKindOfClass:UIControl.class]) {
        [(UIControl *)button addTarget:watcher action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside | UIControlEventPrimaryActionTriggered];
    }
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:watcher action:@selector(tapped:)];
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesEnded = NO;
    tap.delegate = watcher;
    [button addGestureRecognizer:tap];
}

#pragma mark - Spotify's rows, read

@interface SGRPlayerMenuSpotifyRow : NSObject
@property (nonatomic, strong) NSIndexPath *indexPath;
@property (nonatomic, copy) NSString *identifier, *title, *subtitle;
@property (nonatomic, strong) UIImage *image;
@property (nonatomic) BOOL disabled;
@end

@implementation SGRPlayerMenuSpotifyRow
@end

static UITableView *tableIn(UIView *root, int depth) {
    if ([root isKindOfClass:UITableView.class]) return (UITableView *)root;
    if (!root || depth > 6) return nil;
    for (UIView *child in root.subviews) {
        UITableView *table = tableIn(child, depth + 1);
        if (table) return table;
    }
    return nil;
}

static NSInteger rowCount(UITableView *table) {
    NSInteger rows = 0;
    for (NSInteger section = 0; section < table.numberOfSections; section++) rows += [table numberOfRowsInSection:section];
    return rows;
}

// The ListRow of a cell: the control that carries the item's number.
static UIControl *listRowIn(UITableViewCell *cell) {
    __block UIControl *found = nil;
    SGForEachView(cell.contentView, ^(UIView *v) {
        if (!found && [v isKindOfClass:UIControl.class] && v.accessibilityIdentifier.length) found = (UIControl *)v;
    });
    return found;
}

static BOOL shown(UIView *view, UIView *within) {
    for (UIView *v = view; v && v != within; v = v.superview) {
        if (v.hidden || v.alpha < 0.01) return NO;
    }
    return YES;
}

static SGRPlayerMenuSpotifyRow *readRow(UITableViewCell *cell, NSIndexPath *indexPath) {
    UIControl *control = listRowIn(cell);
    if (!control) return nil;
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    __block UIImageView *glyph = nil;
    SGForEachView(control, ^(UIView *v) {
        if ([v isKindOfClass:UILabel.class] && ((UILabel *)v).text.length && shown(v, control)) [labels addObject:(UILabel *)v];
        if (!glyph && [v isKindOfClass:UIImageView.class] && ((UIImageView *)v).image && v.bounds.size.width <= 40 && shown(v, control)) glyph = (UIImageView *)v;
    });
    if (!labels.count) return nil;
    [labels sortUsingComparator:^NSComparisonResult(UILabel *a, UILabel *b) {
        CGPoint pa = [a convertPoint:CGPointZero toView:control], pb = [b convertPoint:CGPointZero toView:control];
        if (fabs(pa.y - pb.y) > 1) return pa.y < pb.y ? NSOrderedAscending : NSOrderedDescending;
        return pa.x < pb.x ? NSOrderedAscending : NSOrderedDescending;
    }];
    SGRPlayerMenuSpotifyRow *row = [SGRPlayerMenuSpotifyRow new];
    row.indexPath = indexPath;
    row.identifier = control.accessibilityIdentifier;
    row.title = labels[0].text;
    if (labels.count > 1) row.subtitle = labels[1].text;
    // "Lyrics • Off" is one label of Spotify's: its state goes under the words, the way the Music app puts it.
    NSRange dot = [row.title rangeOfString:@" • "];
    if (!row.subtitle && dot.location != NSNotFound && dot.location > 0) {
        row.subtitle = [row.title substringFromIndex:NSMaxRange(dot)];
        row.title = [row.title substringToIndex:dot.location];
    }
    row.image = glyph.image;
    row.disabled = !control.enabled || !shown(control, cell);
    return row;
}

// Runs `block` with every row of the table laid out: the hidden table is as short as the sheet would be,
// and only its cells on screen exist, so for the moment of the block it is as tall as its content. A table
// that has just taken its rows has not measured them yet -- its content size is the old one until it lays
// out, and reading it then got 9 of 15 rows (harness, 2026-09-24) -- so it is laid out first, and grown
// again for as long as the rows it then measures run past it.
static void withEveryCell(UITableView *table, void (^block)(void)) {
    CGRect saved = table.bounds;
    [table layoutIfNeeded];
    UIEdgeInsets insets = table.adjustedContentInset;
    BOOL grown = NO;
    for (int round = 0; round < 3; round++) {
        NSInteger sections = table.numberOfSections;
        CGFloat content = table.contentSize.height;
        if (sections) content = MAX(content, CGRectGetMaxY([table rectForSection:sections - 1]));
        CGRect wanted = CGRectMake(saved.origin.x, -insets.top, saved.size.width, MAX(content + insets.top + insets.bottom, saved.size.height));
        if (CGRectEqualToRect(table.bounds, wanted)) break;
        table.bounds = wanted;
        grown = YES;
        [table layoutIfNeeded];
    }
    block();
    if (grown) {
        table.bounds = saved;
        [table layoutIfNeeded];
    }
}

// `complete` says whether every row of the table had a cell to read (a cell that is not one of Spotify's
// item rows is passed over, and does not make the read incomplete).
static NSArray<SGRPlayerMenuSpotifyRow *> *readRows(UITableView *table, BOOL *complete) {
    NSInteger count = rowCount(table);
    *complete = NO;
    if (!count) return @[];
    NSMutableArray<SGRPlayerMenuSpotifyRow *> *rows = [NSMutableArray array];
    __block NSInteger cells = 0;
    withEveryCell(table, ^{
        for (NSInteger section = 0; section < table.numberOfSections; section++) {
            for (NSInteger item = 0; item < [table numberOfRowsInSection:section]; item++) {
                NSIndexPath *indexPath = [NSIndexPath indexPathForRow:item inSection:section];
                UITableViewCell *cell = [table cellForRowAtIndexPath:indexPath];
                if (cell) cells++;
                SGRPlayerMenuSpotifyRow *row = cell ? readRow(cell, indexPath) : nil;
                if (row) [rows addObject:row];
            }
        }
    });
    *complete = cells == count;
    if (!*complete) {
        static int logged;
        if (logged++ < 3) SGLog(@"redesign player menu: %ld of the table's %ld rows had a cell to read", (long)cells, (long)count);
    }
    return rows;
}

static NSString *signatureOf(NSArray<SGRPlayerMenuSpotifyRow *> *rows) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (SGRPlayerMenuSpotifyRow *row in rows) [parts addObject:[NSString stringWithFormat:@"%@=%@|%@|%d", row.identifier, row.title, row.subtitle ?: @"", row.disabled]];
    return [parts componentsJoinedByString:@", "];
}

// Every number once, with its words and where it went, so kKnown can grow from the log.
static void logNumbers(NSArray<SGRPlayerMenuSpotifyRow *> *rows) {
    static NSMutableSet<NSString *> *seen;
    if (!seen) seen = [NSMutableSet set];
    NSMutableArray<NSString *> *fresh = [NSMutableArray array];
    for (SGRPlayerMenuSpotifyRow *row in rows) {
        if ([seen containsObject:row.identifier]) continue;
        [seen addObject:row.identifier];
        [fresh addObject:[NSString stringWithFormat:@"%@ \"%@\"%@", row.identifier, row.title, knownRow(row.identifier) ? @"" : @" (under More)"]];
    }
    if (fresh.count) SGLog(@"redesign player menu: Spotify's rows %@", [fresh componentsJoinedByString:@", "]);
}

#pragma mark - the rows of the last menu

static NSArray<SGRPlayerMenuSpotifyRow *> *sgr_lastRows;
static NSString *sgr_lastSignature;

static NSArray<SGRPlayerMenuSpotifyRow *> *lastRows(void) {
    if (sgr_lastRows) return sgr_lastRows;
    NSData *data = [NSUserDefaults.standardUserDefaults dataForKey:kLastRowsKey];
    if (!data) return nil;
    NSSet *classes = [NSSet setWithObjects:NSArray.class, NSDictionary.class, NSString.class, NSNumber.class, UIImage.class, nil];
    id stored = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:data error:nil];
    NSMutableArray<SGRPlayerMenuSpotifyRow *> *rows = [NSMutableArray array];
    for (NSDictionary *entry in [stored isKindOfClass:NSArray.class] ? stored : @[]) {
        if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"id"] isKindOfClass:NSString.class] || ![entry[@"title"] isKindOfClass:NSString.class]) continue;
        SGRPlayerMenuSpotifyRow *row = [SGRPlayerMenuSpotifyRow new];
        row.identifier = entry[@"id"];
        row.title = entry[@"title"];
        row.subtitle = [entry[@"subtitle"] isKindOfClass:NSString.class] ? entry[@"subtitle"] : nil;
        row.image = [entry[@"image"] isKindOfClass:UIImage.class] ? entry[@"image"] : nil;
        row.disabled = [entry[@"disabled"] boolValue];
        [rows addObject:row];
    }
    sgr_lastRows = rows.count ? rows : nil;
    sgr_lastSignature = sgr_lastRows ? signatureOf(sgr_lastRows) : nil;
    return sgr_lastRows;
}

// Kept only when they differ from what is kept. A row the menu draws with a glyph of its own keeps no picture.
static void keepRows(NSArray<SGRPlayerMenuSpotifyRow *> *rows, NSString *signature) {
    if ([signature isEqualToString:sgr_lastSignature]) return;
    sgr_lastRows = rows;
    sgr_lastSignature = signature;
    NSMutableArray *stored = [NSMutableArray array], *bare = [NSMutableArray array];
    for (SGRPlayerMenuSpotifyRow *row in rows) {
        NSMutableDictionary *entry = [@{@"id": row.identifier, @"title": row.title, @"disabled": @(row.disabled)} mutableCopy];
        if (row.subtitle) entry[@"subtitle"] = row.subtitle;
        [bare addObject:[entry copy]];
        if (row.image && !knownRow(row.identifier)) entry[@"image"] = row.image;
        [stored addObject:entry];
    }
    // A picture that does not archive costs the pictures, not the rows.
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:stored requiringSecureCoding:YES error:nil]
        ?: [NSKeyedArchiver archivedDataWithRootObject:bare requiringSecureCoding:YES error:nil];
    if (data) [NSUserDefaults.standardUserDefaults setObject:data forKey:kLastRowsKey];
}

#pragma mark - where the menu opens from

// A button of the mod's own laid over Spotify's ⋯ for the system menu to open from. It takes no touches, so
// the ⋯ stays Spotify's, and a long press on it opens nothing.
@interface SGRPlayerMenuAnchor : UIButton
@property (nonatomic, copy) void (^shown)(void);
@property (nonatomic, copy) void (^closed)(void);
@end

@implementation SGRPlayerMenuAnchor
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willDisplayMenuForConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator {
    if ([UIButton instancesRespondToSelector:_cmd]) [super contextMenuInteraction:interaction willDisplayMenuForConfiguration:configuration animator:animator];
    if (self.shown) self.shown();
}

- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willEndForConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator {
    if ([UIButton instancesRespondToSelector:_cmd]) [super contextMenuInteraction:interaction willEndForConfiguration:configuration animator:animator];
    void (^closed)(void) = self.closed;
    if (!closed) return;
    if (animator) [animator addCompletion:closed];
    else closed();
}
@end

static SGRPlayerMenuAnchor *anchorIn(UIView *button) {
    SGRPlayerMenuAnchor *anchor = objc_getAssociatedObject(button, &kAnchorKey);
    if (!anchor) {
        anchor = [SGRPlayerMenuAnchor buttonWithType:UIButtonTypeCustom];
        anchor.userInteractionEnabled = NO;
        anchor.isAccessibilityElement = NO;
        anchor.accessibilityElementsHidden = YES;
        anchor.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        // The player is outside Spotify's dark navigation stacks, so the menu would follow the system's look.
        anchor.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        anchor.preferredMenuElementOrder = UIContextMenuConfigurationElementOrderFixed;
        objc_setAssociatedObject(button, &kAnchorKey, anchor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (anchor.superview != button) [button addSubview:anchor];
    anchor.frame = button.bounds;
    return anchor;
}

#pragma mark - Speed and pitch's panel

// The sliders in a popover from the ⋯: a system menu has no room for a view of its own.
@interface SGRSpeedPitchPanel : UIViewController <UIPopoverPresentationControllerDelegate>
@end

@implementation SGRSpeedPitchPanel {
    UIView *_panel;
    id _observer;
}

- (void)dealloc {
    if (_observer) [NSNotificationCenter.defaultCenter removeObserver:_observer];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _panel = SGSpeedPitchPanelMake();
    [self.view addSubview:_panel];
    [self fit];
    __weak SGRSpeedPitchPanel *weak = self;
    // Pitch following speed folds its slider away, and the panel with it.
    _observer = [NSNotificationCenter.defaultCenter addObserverForName:SGSpeedPitchChangedNotification object:nil
                                                                queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        [weak fit];
        [weak.view setNeedsLayout];
    }];
}

- (void)fit {
    CGSize size = CGSizeMake(kPanelWidth, kPanelTop + SGSpeedPitchPanelHeight());
    if (!CGSizeEqualToSize(self.preferredContentSize, size)) self.preferredContentSize = size;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect safe = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    _panel.frame = CGRectMake(CGRectGetMinX(safe), CGRectGetMinY(safe) + kPanelTop, safe.size.width, SGSpeedPitchPanelHeight());
}

- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller traitCollection:(UITraitCollection *)traits {
    return UIModalPresentationNone;
}
@end

#pragma mark - the takeover of one sheet

@interface SGRPlayerMenuTakeover : NSObject
@property (nonatomic, weak) UIViewController *menu;
@property (nonatomic, weak) UIViewController *sheet;   // the presented container the menu is in
@property (nonatomic, weak) UIViewController *player;  // what the sheet came up over
@property (nonatomic, weak) UIView *button;
@property (nonatomic, strong) SGRPlayerMenuAnchor *anchor;
@property (nonatomic, copy) NSArray<SGRPlayerMenuSpotifyRow *> *rows;
@property (nonatomic, copy) NSString *signature;
@property (nonatomic) BOOL hasRows, complete, opened, shown, closed, revealed, finished, pickRan;
// Showing the last menu's rows until Spotify's are in; a row picked meanwhile, fired once they are.
@property (nonatomic) BOOL provisional;
@property (nonatomic, copy) NSString *pendingIdentifier;
@property (nonatomic) NSTimeInterval pendingAt;
// Spotify's rows as last read, by number, for a row of the menu made from the last menu's to fire.
@property (nonatomic, copy) NSDictionary<NSString *, SGRPlayerMenuSpotifyRow *> *rowsByIdentifier;
@property (nonatomic) NSTimeInterval tappedAt;
@property (nonatomic, strong) NSTimer *poll;
// The menu was opened on the tap, before Spotify's sheet exists. A present that then dismisses it
// is the sheet arriving, not the person closing it, so the menu is put back.
@property (nonatomic) BOOL waitingForSheet, sheetStoleMenu, reopenQueued;
@property (nonatomic, copy) void (^pick)(SGRPlayerMenuTakeover *t);
// The loading row's, while the menu has no rows at all to show.
@property (nonatomic, copy) void (^loadingDone)(NSArray<UIMenuElement *> *elements);
@end

@implementation SGRPlayerMenuTakeover
- (void)dealloc {
    [_poll invalidate];
    if (_loadingDone) _loadingDone(@[]);
}
@end

static UIViewController *presentedSheet(UIViewController *menu) {
    UIViewController *top = menu;
    while (top.parentViewController) top = top.parentViewController;
    return top.presentingViewController ? top : nil;
}

static UIView *sheetViewOf(UIViewController *sheet) {
    return sheet.presentationController.presentedView ?: sheet.viewIfLoaded;
}

static UIView *dimmingIn(UIView *container) {
    return SGRFindByIdentifier(container, @"Components.UI.SheetPresentation.Dimming", &kDimmingKey);
}

// The sheet and Spotify's dimming out of sight, by `hidden` and, on the sheet, a mask that lets nothing
// through; never by alpha or colour. The sheet's presentation sets its presented view's alpha back to 1
// whenever the container lays out, the dimming's colour and alpha are what Spotify's transition animates,
// and iOS 26 draws a sheet's glass through a mask of no size at all, so the mask is a point of nothing
// rather than empty. The sheet's own mask, if it had one, is kept to put back.
//
// UIKit's own dimming goes too, wherever the system sheet put it: in the sheet's container, where Spotify
// hides it once the sheet is up (trees/continuous/1.txt: "UIDimmingView ... hidden"), and over the view the
// sheet came up over, which UIKit wraps in a drop shadow view of its own with a UIDimmingView in it, black
// at 0.48 (harness, 2026-09-24). Under Spotify's 0.7 neither showed; with Spotify's hidden, the screen went
// dark for a moment as the ⋯ was tapped (device, 2026-09-24). They sit within three levels of the window.
// Those outside the container are put back with the sheet; the container's stays hidden, as Spotify keeps it.
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

// The claimed sheet's container is full screen. Hiding the presented view leaves that container
// able to take the tap that should dismiss the glass menu.
static void dropContainerTouches(UIView *container) {
    if (!container) return;
    if (!objc_getAssociatedObject(container, &kContainerTouchesKey))
        objc_setAssociatedObject(container, &kContainerTouchesKey, @(container.userInteractionEnabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (container.userInteractionEnabled) container.userInteractionEnabled = NO;
}

static void restoreContainerTouches(UIView *container) {
    NSNumber *was = objc_getAssociatedObject(container, &kContainerTouchesKey);
    if (!was) return;
    container.userInteractionEnabled = was.boolValue;
    objc_setAssociatedObject(container, &kContainerTouchesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void hidePresentation(UIView *sheet, UIView *container) {
    dropContainerTouches(container);
    if (!sheet) {
        if (container) {
            UIView *dimming = dimmingIn(container);
            if (dimming && !dimming.hidden) dimming.hidden = YES;
            hideSystemDimming(container);
        }
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
    UIView *dimming = dimmingIn(container);
    if (dimming && !dimming.hidden) dimming.hidden = YES;
    hideSystemDimming(container);
}

static void showPresentation(UIView *sheet, UIView *container) {
    restoreContainerTouches(container);
    dimmingIn(container).hidden = NO;
    showSystemDimming(container);
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

static void hideSheet(SGRPlayerMenuTakeover *t, UIView *container) {
    hidePresentation(sheetViewOf(t.sheet), container);
}

// Spotify's sheet as Spotify draws it, and the menu gone.
static void reveal(SGRPlayerMenuTakeover *t, NSString *why) {
    if (t.revealed || t.finished) return;
    t.revealed = YES;
    [t.poll invalidate];
    SGLog(@"redesign player menu: Spotify's sheet shown, %@", why);
    objc_setAssociatedObject(t.sheet, &kClaimKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (t.shown && !t.closed) [t.anchor.contextMenuInteraction dismissMenu];
    showPresentation(sheetViewOf(t.sheet), t.sheet.presentationController.containerView);
}

// Spotify's sheet taken away, out of sight as it is, once the menu has nothing more to do with it.
static void finish(SGRPlayerMenuTakeover *t, NSString *why, void (^then)(void)) {
    if (t.finished || t.revealed) return;
    t.finished = YES;
    [t.poll invalidate];
    if (t.loadingDone) {
        t.loadingDone(@[]);
        t.loadingDone = nil;
    }
    UIViewController *sheet = t.sheet;
    if (!sheet.presentingViewController || sheet.isBeingDismissed) {
        if (then) then();
        return;
    }
    SGLog(@"redesign player menu: Spotify's sheet taken away, %@", why);
    [sheet dismissViewControllerAnimated:NO completion:then];
}

// A row that changes in place (Lyrics • On) leaves Spotify's sheet up with nothing to show it.
static void settle(SGRPlayerMenuTakeover *t) {
    __weak SGRPlayerMenuTakeover *weak = t;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSettle * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SGRPlayerMenuTakeover *strong = weak;
        if (!strong || strong.revealed || strong.finished) return;
        UIViewController *sheet = strong.sheet;
        if (!sheet.presentingViewController || sheet.isBeingDismissed) return;
        if (sheet.presentedViewController) {
            settle(strong);
            return;
        }
        finish(strong, @"the row left it up", nil);
    });
}

static void fire(SGRPlayerMenuTakeover *t, SGRPlayerMenuSpotifyRow *row) {
    UITableView *table = tableIn(t.menu.viewIfLoaded, 0);
    __block BOOL fired = NO;
    if (table) {
        withEveryCell(table, ^{
            UITableViewCell *cell = row.indexPath ? [table cellForRowAtIndexPath:row.indexPath] : nil;
            UIControl *control = cell ? listRowIn(cell) : nil;
            // The rows may have moved since they were read: the number is what the row is.
            if (![control.accessibilityIdentifier isEqualToString:row.identifier]) {
                control = nil;
                for (UITableViewCell *visible in table.visibleCells) {
                    UIControl *candidate = listRowIn(visible);
                    if ([candidate.accessibilityIdentifier isEqualToString:row.identifier]) control = candidate;
                }
            }
            if (!control) return;
            SGLog(@"redesign player menu: \"%@\" (%@) fired", row.title, row.identifier);
            SGRActivate(control);
            fired = YES;
        });
    }
    if (!fired) {
        SGLog(@"redesign player menu: \"%@\" (%@) is not in the sheet any more", row.title, row.identifier);
        reveal(t, @"a row could not be fired");
        return;
    }
    settle(t);
}

// A row picked before Spotify's rows are in waits for them, and past kRowsWait it is Spotify's sheet that
// is waited on instead, where the row can be tapped again once it is there.
static void hold(SGRPlayerMenuTakeover *t, SGRPlayerMenuSpotifyRow *row) {
    NSTimeInterval at = CACurrentMediaTime();
    t.pendingIdentifier = row.identifier;
    t.pendingAt = at;
    SGLog(@"redesign player menu: \"%@\" (%@) picked %.2f s after the ⋯, before Spotify's rows are in, held", row.title, row.identifier, at - t.tappedAt);
    __weak SGRPlayerMenuTakeover *weak = t;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRowsWait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SGRPlayerMenuTakeover *strong = weak;
        if (!strong || !strong.pendingIdentifier || strong.pendingAt != at) return;
        reveal(strong, [NSString stringWithFormat:@"a row was picked and Spotify's rows are still not in %.0f s later", kRowsWait]);
    });
}

static void runPick(SGRPlayerMenuTakeover *t) {
    if (!t.pick || t.pickRan || t.finished || t.revealed) return;
    t.pickRan = YES;
    t.pick(t);
}

// What a pick does is done once the menu has closed: the menu is presented over Spotify's sheet, and what
// a pick does to the sheet would take the menu with it mid-animation.
static void pick(SGRPlayerMenuTakeover *t, void (^what)(SGRPlayerMenuTakeover *t)) {
    if (!t || t.pick || t.finished || t.revealed) return;
    t.pick = what;
    if (t.closed) runPick(t);
}

static void openMenu(SGRPlayerMenuTakeover *t);

static void menuClosed(SGRPlayerMenuTakeover *t) {
    if (!t || t.closed) return;
    // Only the dismiss inside the sheet's present reopens. A later outside tap used to hit this
    // with sheetStoleMenu still set and put the menu straight back.
    if (t.sheetStoleMenu && !t.pick && sgr_sheetPresenting) {
        t.opened = NO;
        t.shown = NO;
        if (t.reopenQueued) return;
        t.reopenQueued = YES;
        __weak SGRPlayerMenuTakeover *weak = t;
        // After the present returns: reopening inside it is dismissed again by the same present.
        dispatch_async(dispatch_get_main_queue(), ^{
            SGRPlayerMenuTakeover *strong = weak;
            if (!strong || strong.finished || strong.revealed) return;
            strong.sheetStoleMenu = NO;
            strong.reopenQueued = NO;
            strong.waitingForSheet = NO;
            SGLog(@"redesign player menu: the sheet closed the menu that opened on the tap, reopening");
            openMenu(strong);
        });
        return;
    }
    t.sheetStoleMenu = NO;
    t.reopenQueued = NO;
    t.waitingForSheet = NO;
    t.closed = YES;
    SGLog(@"redesign player menu: closed%@", t.pick ? @", a row was picked" : @"");
    if (t.pick) {
        runPick(t);
        return;
    }
    __weak SGRPlayerMenuTakeover *weak = t;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPickGrace * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SGRPlayerMenuTakeover *strong = weak;
        if (strong && !strong.pick) finish(strong, @"the menu closed with nothing picked", nil);
    });
}

static void openSpeedPitch(SGRPlayerMenuTakeover *t) {
    UIView *button = t.button;
    UIViewController *player = t.player;
    finish(t, @"Speed and pitch opens its panel", ^{
        if (!player || !button.window || player.presentedViewController) return;
        SGRSpeedPitchPanel *panel = [SGRSpeedPitchPanel new];
        panel.modalPresentationStyle = UIModalPresentationPopover;
        UIPopoverPresentationController *popover = panel.popoverPresentationController;
        popover.sourceView = button;
        popover.sourceRect = button.bounds;
        popover.permittedArrowDirections = UIPopoverArrowDirectionUp;
        popover.delegate = panel;
        [player presentViewController:panel animated:YES completion:nil];
    });
}

#pragma mark building the menu

static UIMenu *group(NSArray<UIMenuElement *> *children) {
    return [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:children];
}

static UIAction *actionFor(SGRPlayerMenuTakeover *t, SGRPlayerMenuSpotifyRow *row, const SGRPlayerMenuKnownRow *known) {
    UIImage *image = (known ? symbol(@(known->symbol)) : nil) ?: [row.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    __weak SGRPlayerMenuTakeover *weak = t;
    UIAction *action = [UIAction actionWithTitle:row.title image:image identifier:nil handler:^(UIAction *sender) {
        pick(weak, ^(SGRPlayerMenuTakeover *strong) {
            if (strong.provisional) hold(strong, row);
            else fire(strong, strong.rowsByIdentifier[row.identifier] ?: row);
        });
    }];
    action.subtitle = row.subtitle;
    action.attributes = (row.disabled ? UIMenuElementAttributesDisabled : 0)
                      | (known && known->place == SGRPlaceDestructive ? UIMenuElementAttributesDestructive : 0);
    return action;
}

static UIAction *speedAndPitchAction(SGRPlayerMenuTakeover *t) {
    __weak SGRPlayerMenuTakeover *weak = t;
    UIAction *action = [UIAction actionWithTitle:@"Speed and pitch" image:symbol(@"slider.horizontal.3") identifier:nil handler:^(UIAction *sender) {
        pick(weak, ^(SGRPlayerMenuTakeover *strong) { openSpeedPitch(strong); });
    }];
    action.subtitle = SGSpeedPitchSummary();
    return action;
}

static UIMenu *menuFor(SGRPlayerMenuTakeover *t) {
    NSArray<SGRPlayerMenuSpotifyRow *> *rows = t.rows ?: @[];
    // Tiles in the Music app's order, Share last.
    NSArray<SGRPlayerMenuSpotifyRow *> *ordered = [rows sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(SGRPlayerMenuSpotifyRow *a, SGRPlayerMenuSpotifyRow *b) {
        const SGRPlayerMenuKnownRow *ka = knownRow(a.identifier), *kb = knownRow(b.identifier);
        if (!ka || !kb || ka->place != SGRPlaceTile || kb->place != SGRPlaceTile || ka == kb) return NSOrderedSame;
        return ka < kb ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSMutableArray<UIMenuElement *> *tiles = [NSMutableArray array], *main = [NSMutableArray array],
                                   *feedback = [NSMutableArray array], *more = [NSMutableArray array],
                                   *destructive = [NSMutableArray array];
    for (SGRPlayerMenuSpotifyRow *row in ordered) {
        const SGRPlayerMenuKnownRow *known = knownRow(row.identifier);
        UIAction *action = actionFor(t, row, known);
        switch (known ? known->place : SGRPlaceMore) {
            case SGRPlaceTile: [tiles addObject:action]; break;
            case SGRPlaceMain: [main addObject:action]; break;
            case SGRPlaceFeedback: [feedback addObject:action]; break;
            case SGRPlaceDestructive: [destructive addObject:action]; break;
            case SGRPlaceMore: [more addObject:action]; break;
        }
    }
    while (tiles.count > 3) {
        [main insertObject:tiles.lastObject atIndex:0];
        [tiles removeLastObject];
    }
    [main addObject:speedAndPitchAction(t)];
    if (more.count == 1) {
        [feedback addObject:more.firstObject];
    } else if (more.count) {
        [feedback addObject:[UIMenu menuWithTitle:@"More" image:symbol(@"ellipsis.circle") identifier:nil options:0 children:more]];
    }

    NSMutableArray<UIMenuElement *> *groups = [NSMutableArray array];
    if (tiles.count) {
        UIMenu *tileGroup = group(tiles);
        tileGroup.preferredElementSize = UIMenuElementSizeMedium;
        [groups addObject:tileGroup];
    }
    [groups addObject:group(main)];
    if (!rows.count) {
        __weak SGRPlayerMenuTakeover *weak = t;
        [groups addObject:group(@[[UIDeferredMenuElement elementWithProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
            SGRPlayerMenuTakeover *strong = weak;
            if (!strong || strong.hasRows || strong.finished || strong.revealed) completion(@[]);
            else strong.loadingDone = completion;
        }]])];
    }
    if (feedback.count) [groups addObject:group(feedback)];
    if (destructive.count) [groups addObject:group(destructive)];
    return [UIMenu menuWithTitle:@"" children:groups];
}

static void showRows(SGRPlayerMenuTakeover *t) {
    if (!t.anchor) return;
    UIMenu *menu = menuFor(t);
    t.anchor.menu = menu;
    if (t.shown && !t.closed) [t.anchor.contextMenuInteraction updateVisibleMenuWithBlock:^UIMenu *(UIMenu *visible) { return menu; }];
    if (t.rows.count && t.loadingDone) {
        t.loadingDone(@[]);
        t.loadingDone = nil;
    }
}

static __weak SGRPlayerMenuTakeover *sgr_early;

static void openEarly(UIView *button) {
    if (!button.window) return;
    SGRPlayerMenuTakeover *existing = sgr_early;
    if (existing && !existing.finished && !existing.revealed && !existing.closed) return;
    SGRPlayerMenuTakeover *t = [SGRPlayerMenuTakeover new];
    t.tappedAt = sgr_moreTappedAt;
    t.button = button;
    t.waitingForSheet = YES;
    NSArray<SGRPlayerMenuSpotifyRow *> *last = lastRows();
    if (last.count) {
        t.provisional = YES;
        t.rows = last;
        t.signature = signatureOf(last);
        SGLog(@"redesign player menu: opens on the last menu's rows, before the sheet");
    } else {
        SGLog(@"redesign player menu: opens while Spotify's rows are read");
    }
    sgr_early = t;
    openMenu(t);
}

static void openMenu(SGRPlayerMenuTakeover *t) {
    if (t.opened || t.revealed || t.finished) return;
    t.opened = YES;
    UIView *button = t.button;
    SEL present = NSSelectorFromString(@"_presentMenuAtLocation:");
    if (button.window) {
        t.anchor = anchorIn(button);
        __weak SGRPlayerMenuTakeover *weak = t;
        t.anchor.shown = ^{ weak.shown = YES; };
        t.anchor.closed = ^{ menuClosed(weak); };
        showRows(t);
    }
    UIContextMenuInteraction *interaction = t.anchor.contextMenuInteraction;
    if (![interaction respondsToSelector:present]) {
        reveal(t, button.window ? @"the system menu cannot be opened" : @"the ⋯ is not on screen");
        return;
    }
    CGPoint at = CGPointMake(CGRectGetMidX(t.anchor.bounds), CGRectGetMidY(t.anchor.bounds));
    ((void (*)(id, SEL, CGPoint))objc_msgSend)(interaction, present, at);
    __weak SGRPlayerMenuTakeover *weak = t;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kShowWait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SGRPlayerMenuTakeover *strong = weak;
        if (strong && !strong.shown && !strong.closed) reveal(strong, @"the system menu did not open");
    });
}

#pragma mark the pass

static void pass(SGRPlayerMenuTakeover *t) {
    if (t.revealed || t.finished) return;
    UIViewController *menu = t.menu;
    if (!t.sheet) t.sheet = presentedSheet(menu);
    if (!t.player) t.player = t.sheet.presentingViewController;
    UIView *container = t.sheet.presentationController.containerView;
    if (container) hideSheet(t, container);

    UITableView *table = tableIn(menu.viewIfLoaded, 0);
    BOOL complete = NO;
    NSArray<SGRPlayerMenuSpotifyRow *> *rows = table ? readRows(table, &complete) : @[];
    if (!rows.count) return;
    BOOL first = !t.hasRows;
    t.hasRows = YES;
    t.provisional = NO;
    NSMutableDictionary<NSString *, SGRPlayerMenuSpotifyRow *> *byIdentifier = [NSMutableDictionary dictionary];
    for (SGRPlayerMenuSpotifyRow *row in rows) byIdentifier[row.identifier] = row;
    t.rowsByIdentifier = byIdentifier;
    NSString *signature = signatureOf(rows);
    t.complete = complete;
    if (first) {
        SGLog(@"redesign player menu: Spotify's rows in %.2f s after the tap, %@%@", CACurrentMediaTime() - t.tappedAt,
              [signature isEqualToString:t.signature] ? @"the last menu's" : t.signature ? @"not the last menu's" : @"none shown before",
              complete ? @"" : @" (not all of them read yet)");
    }
    // Only a whole menu is kept for the next one to open on, and a held pick waits for the whole menu
    // before it is given up.
    if (complete) {
        [t.poll invalidate];
        keepRows(rows, signature);
    }
    SGRPlayerMenuSpotifyRow *pending = t.pendingIdentifier ? byIdentifier[t.pendingIdentifier] : nil;
    if (pending || complete) t.pendingIdentifier = nil;
    if (pending) {
        fire(t, pending);
        return;
    }
    if (![signature isEqualToString:t.signature]) {
        t.signature = signature;
        t.rows = rows;
        logNumbers(rows);
        showRows(t);
    }
}

static BOOL moreTappedRecently(void) {
    return sgr_moreTappedAt && CACurrentMediaTime() - sgr_moreTappedAt < kMenuAfterTap;
}

// Spotify's context menu, `controller` or one of its children.
static UIViewController *contextMenuIn(UIViewController *controller, int depth) {
    if ([NSStringFromClass(controller.class) containsString:@"ContextMenu"]) return controller;
    if (depth > 5) return nil;
    for (UIViewController *child in controller.childViewControllers) {
        UIViewController *menu = contextMenuIn(child, depth + 1);
        if (menu) return menu;
    }
    return nil;
}

static SGRPlayerMenuTakeover *takeoverFor(UIViewController *menu) {
    id existing = objc_getAssociatedObject(menu, &kTakeoverKey);
    if (existing) return existing == NSNull.null ? nil : existing;
    BOOL claimed = [objc_getAssociatedObject(presentedSheet(menu), &kClaimKey) boolValue];
    if (!moreTappedRecently() && !claimed) {
        objc_setAssociatedObject(menu, &kTakeoverKey, NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return nil;
    }
    SGRPlayerMenuTakeover *t = sgr_early;
    BOOL adopted = t && !t.finished && !t.revealed && !t.menu;
    if (!adopted) {
        t = [SGRPlayerMenuTakeover new];
        t.tappedAt = sgr_moreTappedAt ?: CACurrentMediaTime();
        t.button = sgr_moreButton;
        NSArray<SGRPlayerMenuSpotifyRow *> *last = lastRows();
        if (last.count) {
            t.provisional = YES;
            t.rows = last;
            t.signature = signatureOf(last);
        }
        sgr_early = t;
    }
    sgr_moreTappedAt = 0;
    t.menu = menu;
    if (!t.button) t.button = sgr_moreButton;
    UIViewController *sheet = presentedSheet(menu);
    if (sheet) objc_setAssociatedObject(sheet, &kTakenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(menu, &kTakeoverKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak SGRPlayerMenuTakeover *weak = t;
    t.poll = [NSTimer timerWithTimeInterval:kRowsPoll repeats:YES block:^(NSTimer *timer) {
        SGRPlayerMenuTakeover *strong = weak;
        if (!strong || strong.complete || strong.finished || strong.revealed) {
            [timer invalidate];
            return;
        }
        UITableView *table = tableIn(strong.menu.viewIfLoaded, 0);
        if (table && rowCount(table) > 0) pass(strong);
    }];
    [NSRunLoop.mainRunLoop addTimer:t.poll forMode:NSRunLoopCommonModes];
    [t.poll fire];
    // Spotify's rows are waited on for as long as the menu is open, the table looked at until they are all
    // in. What is worth saying by kRowsWait is whether they are late, and whether they are there and unreadable.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRowsWait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SGRPlayerMenuTakeover *strong = weak;
        if (!strong || strong.hasRows || strong.finished || strong.revealed) return;
        UITableView *table = tableIn(strong.menu.viewIfLoaded, 0);
        if (table && rowCount(table) > 0) {
            reveal(strong, [NSString stringWithFormat:@"the table has %ld rows and none could be read", (long)rowCount(table)]);
            return;
        }
        SGLog(@"redesign player menu: no rows of Spotify's %.0f s after the tap, still waiting with %@", kRowsWait,
              strong.provisional ? @"the last menu's rows" : @"a loading row");
    });
    SGLog(@"redesign player menu: the ⋯'s sheet taken over");
    return t;
}

#pragma mark - what darkens the screen as the menu opens

// A dark picture across the screen flashed as the menu opened on the phone, with the sheet and its dimming
// out of sight from the presentation's first frame (device, 2026-09-24). So the first menus of a launch say
// what they find at a few moments after the ⋯'s tap: every view drawn dark over most of the window, and the
// windows themselves.
static NSString *darkness(UIColor *color) {
    CGFloat white = 1, alpha = 0;
    if (!color || ![color getWhite:&white alpha:&alpha]) {
        CGFloat r, g, b;
        if (![color getRed:&r green:&g blue:&b alpha:&alpha]) return nil;
        white = (r + g + b) / 3;
    }
    return alpha >= 0.3 && white < 0.15 ? [NSString stringWithFormat:@"%.2f@%.2f", white, alpha] : nil;
}

static void findDark(UIView *view, UIView *window, CGFloat alpha, int depth, NSMutableArray<NSString *> *out) {
    if (view.hidden || view.alpha < 0.01 || depth > 40 || out.count > 20) return;
    alpha *= view.alpha;
    CGRect frame = [view convertRect:view.bounds toView:window];
    CGRect screen = CGRectIntersection(frame, window.bounds);
    BOOL covers = !CGRectIsNull(screen) && screen.size.width * screen.size.height > 0.6 * window.bounds.size.width * window.bounds.size.height;
    if (!covers) return;
    NSString *dark = darkness(view.backgroundColor) ?: (view.layer.backgroundColor ? darkness([UIColor colorWithCGColor:view.layer.backgroundColor]) : nil);
    if (dark && alpha > 0.05) {
        [out addObject:[NSString stringWithFormat:@"%@%@ bg %@ alpha %.2f", NSStringFromClass(view.class),
                        view.accessibilityIdentifier.length ? [@" id=" stringByAppendingString:view.accessibilityIdentifier] : @"", dark, alpha]];
    }
    for (UIView *child in view.subviews) findDark(child, window, alpha, depth + 1, out);
}

static void logDarkness(UIView *anyView) {
    static int menus;
    if (menus++ >= 2) return;
    for (NSNumber *after in @[@0, @0.02, @0.05, @0.1, @0.2, @0.4]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindowScene *scene = anyView.window.windowScene;
            NSMutableArray<NSString *> *lines = [NSMutableArray array];
            for (UIWindow *window in scene.windows) {
                if (window.hidden) continue;
                NSMutableArray<NSString *> *dark = [NSMutableArray array];
                findDark(window, window, 1, 0, dark);
                [lines addObject:[NSString stringWithFormat:@"%@ level %.0f: %@", NSStringFromClass(window.class), window.windowLevel,
                                  dark.count ? [dark componentsJoinedByString:@"; "] : @"nothing dark over it"]];
            }
            SGLog(@"redesign player menu: %.2f s after the sheet began: %@", after.doubleValue, [lines componentsJoinedByString:@" | "]);
        });
    }
}

// A present while the menu opened on the tap is up is Spotify's sheet arriving: it dismisses that
// menu, and the menu goes straight back rather than being treated as closed.
%hook UIViewController
- (void)presentViewController:(UIViewController *)viewController animated:(BOOL)animated completion:(void (^)(void))completion {
    SGRPlayerMenuTakeover *early = sgr_early;
    BOOL steal = early && early.waitingForSheet && early.shown && !early.closed && !early.finished && !early.revealed;
    if (steal) {
        early.sheetStoleMenu = YES;
        sgr_sheetPresenting = YES;
    }
    %orig;
    if (!steal) return;
    // menuClosed can run as the present returns, or on the turn after it. The flag stays up for
    // that turn and is down before a person can tap outside.
    dispatch_async(dispatch_get_main_queue(), ^{ sgr_sheetPresenting = NO; });
}
%end

// The glass menu is already up when Spotify's sheet starts presenting, and the sheet's context menu
// is often not in the hierarchy yet. Waiting for that menu before hiding let the sheet animate in
// on top of the glass menu. Any sheet in the ⋯'s window is claimed and hidden immediately; the menu
// is adopted once it appears. A sheet that never becomes the player's menu is shown again, unless
// the glass menu is still up, in which case it stays hidden so the two are not on screen together.
static void adoptClaimedMenu(UIViewController *sheet) {
    if (!sheet || objc_getAssociatedObject(sheet, &kTakenKey)) return;
    UIViewController *menu = contextMenuIn(sheet, 0);
    if (!menu) return;
    SGRPlayerMenuTakeover *t = takeoverFor(menu);
    if (!t) return;
    if (!t.sheet) t.sheet = sheet;
    if (t.shown && !t.closed) t.sheetStoleMenu = NO;
    t.waitingForSheet = NO;
    pass(t);
    openMenu(t);
}

static BOOL glassMenuIsUp(void) {
    SGRPlayerMenuTakeover *early = sgr_early;
    return early && !early.finished && !early.revealed && !early.closed && (early.shown || early.opened);
}

// The sheet and its dimming go out of sight as the presentation begins, before its first frame: the menu's
// own appearance comes later than that, and hiding them only from there let the dimming's black and the sheet
// show for a frame or two as the ⋯ was tapped (device, 2026-09-24). A presentation taken this way is claimed,
// and the menu inside it is taken over whatever the timing of the tap.
%hook _TtC22NavigationUI_SheetImpl27SheetPresentationController

- (void)presentationTransitionWillBegin {
    UIPresentationController *presentation = (UIPresentationController *)self;
    UIViewController *sheet = presentation.presentedViewController;
    BOOL claim = moreTappedRecently();
    if (claim) {
        objc_setAssociatedObject(sheet, &kClaimKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGRPlayerMenuTakeover *early = sgr_early;
        if (early && !early.finished && !early.revealed && !early.sheet) early.sheet = sheet;
        hidePresentation(presentation.presentedView, presentation.containerView);
    }
    %orig;
    if (!claim) return;
    hidePresentation(presentation.presentedView, presentation.containerView);
    SGLog(@"redesign player menu: sheet hidden at present (menu %@)", contextMenuIn(sheet, 0) ? @"in the sheet" : @"not in the sheet yet");
    logDarkness(presentation.containerView ?: presentation.presentingViewController.view);
    __weak UIViewController *weakSheet = sheet;
    dispatch_async(dispatch_get_main_queue(), ^{
        adoptClaimedMenu(weakSheet);
    });
    for (NSNumber *delay in @[@0.05, @0.16, @0.4]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *strong = weakSheet;
            if (!strong || ![objc_getAssociatedObject(strong, &kClaimKey) boolValue]) return;
            hidePresentation(sheetViewOf(strong), strong.presentationController.containerView);
            adoptClaimedMenu(strong);
        });
    }
    // A claimed sheet whose menu is never taken over would stay out of sight with nothing in its place.
    // While the glass menu is up the sheet stays hidden; showing it then is the two-menus bug.
    __weak UIPresentationController *weak = presentation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kClaimWait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIPresentationController *strong = weak;
        UIViewController *presented = strong.presentedViewController;
        if (!presented || objc_getAssociatedObject(presented, &kTakenKey) || ![objc_getAssociatedObject(presented, &kClaimKey) boolValue]) return;
        hidePresentation(strong.presentedView, strong.containerView);
        if (glassMenuIsUp()) {
            SGLog(@"redesign player menu: sheet stays hidden, the glass menu is up");
            return;
        }
        SGLog(@"redesign player menu: no menu taken over in the ⋯'s sheet within %.0f s, the sheet shown", kClaimWait);
        objc_setAssociatedObject(presented, &kClaimKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        showPresentation(strong.presentedView, strong.containerView);
    });
}

- (void)presentationTransitionDidEnd:(BOOL)completed {
    %orig;
    UIPresentationController *presentation = (UIPresentationController *)self;
    if (![objc_getAssociatedObject(presentation.presentedViewController, &kClaimKey) boolValue]) return;
    hidePresentation(presentation.presentedView, presentation.containerView);
    SGLog(@"redesign player menu: sheet kept hidden after present");
    adoptClaimedMenu(presentation.presentedViewController);
}

- (void)containerViewDidLayoutSubviews {
    %orig;
    UIPresentationController *presentation = (UIPresentationController *)self;
    if ([objc_getAssociatedObject(presentation.presentedViewController, &kClaimKey) boolValue]) {
        hidePresentation(presentation.presentedView, presentation.containerView);
    }
}

%end

%hook _TtC24ContextMenu_InternalImpl25ContextMenuViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    SGRPlayerMenuTakeover *t = takeoverFor((UIViewController *)self);
    if (t) pass(t);
}

- (void)viewDidLayoutSubviews {
    %orig;
    SGRPlayerMenuTakeover *t = takeoverFor((UIViewController *)self);
    if (t) pass(t);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SGRPlayerMenuTakeover *t = objc_getAssociatedObject(self, &kTakeoverKey);
    if ([t isKindOfClass:SGRPlayerMenuTakeover.class]) pass(t);
}

// The sheet going away takes the menu with it; a page of Spotify's pushed onto it shows the sheet.
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    SGRPlayerMenuTakeover *t = objc_getAssociatedObject(self, &kTakeoverKey);
    if (![t isKindOfClass:SGRPlayerMenuTakeover.class]) return;
    UINavigationController *navigation = ((UIViewController *)self).navigationController;
    UIViewController *sheet = t.sheet;
    BOOL leaving = !sheet.presentingViewController || sheet.isBeingDismissed || sheet.presentingViewController.isBeingDismissed;
    if (leaving) {
        if (t.shown && !t.closed) [t.anchor.contextMenuInteraction dismissMenu];
    } else if (navigation.viewControllers.count > 1) {
        reveal(t, @"Spotify opened a page of its own on it");
    }
}

%end

%ctor {
    if (!SGRedesignedUI()) return;
    sgr_menuOn = YES;
    %init;
    SGRequireClasses(@[@"_TtC24ContextMenu_InternalImpl25ContextMenuViewController", @"_TtC22NavigationUI_SheetImpl27SheetPresentationController"]);
}
