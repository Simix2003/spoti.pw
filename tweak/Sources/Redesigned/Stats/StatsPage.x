// Statistiche di ascolto, redesigned: the week's tiles and the summary line of each detail page drawn
// again over Spotify's own cells.
//
// What the recorded page proves (Spotify 9.1.78, the stats deep probes of 2026-09-30): every cell is a
// UICollectionViewCell holding Element_UIKit's ElementView over an ElementContentView generic in the
// element, `StatsTileGridElement` for a week's five tiles (370x563) and `SummaryStatsElement` for the
// line that opens a detail page (370x72 to 111). The tiles carry their copy as accessibility labels
// ("Minuti di ascolto, 367. Sei il numero 2 tra gli amici"), the summary line as a UILabel. A generic
// Swift class has no runtime name until its first instance exists, so the hook is on the cell, which
// always does, and the element is told from the class name of the view inside it.
//
// Spotify's cell stays where it is and keeps every touch: the cards go over it as views that take none,
// at the frames Spotify gave its tiles, so a tap on a card is a tap on the tile under it. When a tile or a
// label is not found, the cell is left as Spotify drew it. The detail pages' rows (StatsDetailsTrack,
// LeaderboardRow) have nothing readable but a title and are not touched.
//
// Main thread only; every hook is installed only while Redesigned UI is on.
#import "Core/SGCore.h"
#import "Core/SGViewTree.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Stats.h"
#import "StatsParse.h"
#import "StatsViews.h"

typedef NS_ENUM(NSInteger, StatsHost) { StatsHostNone, StatsHostGrid, StatsHostSummary };

static char kGridKey, kSummaryKey, kSignatureKey, kRetryKey;

static StatsHost hostKind(UIView *view) {
    NSString *name = NSStringFromClass(object_getClass(view));
    if (![name hasPrefix:@"_TtGC13Element_UIKit18ElementContentView"]) return StatsHostNone;
    if ([name containsString:@"StatsTileGridElement_"]) return StatsHostGrid;
    if ([name containsString:@"SummaryStatsElement_"]) return StatsHostSummary;
    return StatsHostNone;
}

// The cell holds its element a few views down (cell > content view > ElementView > ElementContentView).
static UIView *findHost(UIView *view, StatsHost *kind, NSUInteger depth) {
    if (depth > 3) return nil;
    for (UIView *sub in view.subviews) {
        StatsHost found = hostKind(sub);
        if (found != StatsHostNone) {
            *kind = found;
            return sub;
        }
        if ([sub isKindOfClass:UICollectionView.class] || sub.subviews.count > 12) continue;
        UIView *deeper = findHost(sub, kind, depth + 1);
        if (deeper) return deeper;
    }
    return nil;
}

#pragma mark - the week's tiles

static void collectTiles(UIView *view, UIView *host, UIView *skip, NSMutableArray<SGRStatsTile *> *tiles, NSMutableArray<NSValue *> *frames, NSUInteger depth) {
    if (depth > 8 || view == skip) return;
    for (UIView *sub in view.subviews) {
        if (sub == skip || sub.alpha < 0.01) continue;
        SGRStatsTile *tile = SGRStatsParseTile(sub.accessibilityLabel);
        CGRect frame = tile ? SGFrameIn(sub, host) : CGRectZero;
        BOOL sane = tile && frame.size.width > 40 && frame.size.height > 40 &&
                    frame.size.width < host.bounds.size.width * 0.98 + 1 &&
                    CGRectIntersectsRect(frame, host.bounds);
        if (sane) {
            BOOL seen = NO;
            for (SGRStatsTile *have in tiles) if (have.kind == tile.kind) seen = YES;
            if (!seen) {
                [tiles addObject:tile];
                [frames addObject:[NSValue valueWithCGRect:frame]];
            }
            continue;
        }
        collectTiles(sub, host, skip, tiles, frames, depth + 1);
    }
}

// When the tiles are accessibility elements of the host rather than views with a label.
static void collectElements(UIView *host, NSMutableArray<SGRStatsTile *> *tiles, NSMutableArray<NSValue *> *frames) {
    UIWindow *window = host.window;
    if (!window) return;
    for (id element in host.accessibilityElements) {
        SGRStatsTile *tile = SGRStatsParseTile([element respondsToSelector:@selector(accessibilityLabel)] ? [element accessibilityLabel] : nil);
        if (!tile || ![element respondsToSelector:@selector(accessibilityFrame)]) continue;
        CGRect screen = [element accessibilityFrame];
        CGRect frame = [host convertRect:[window convertRect:screen fromWindow:nil] fromView:window];
        if (frame.size.width < 40 || frame.size.height < 40 || frame.size.width > host.bounds.size.width * 0.98 + 1) continue;
        BOOL seen = NO;
        for (SGRStatsTile *have in tiles) if (have.kind == tile.kind) seen = YES;
        if (seen) continue;
        [tiles addObject:tile];
        [frames addObject:[NSValue valueWithCGRect:frame]];
    }
}

// The artwork Spotify loaded into a tile: the largest picture whose centre lies in the tile's frame.
static UIImage *artworkIn(UIView *view, UIView *host, CGRect tile, UIView *skip, CGFloat *best, UIImage *found, NSUInteger depth) {
    if (depth > 10) return found;
    for (UIView *sub in view.subviews) {
        if (sub == skip) continue;
        if ([sub isKindOfClass:UIImageView.class] && ((UIImageView *)sub).image && !((UIImageView *)sub).image.isSymbolImage) {
            CGRect frame = SGFrameIn(sub, host);
            CGPoint centre = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
            CGFloat area = frame.size.width * frame.size.height;
            if (CGRectContainsPoint(tile, centre) && frame.size.width >= 24 && area > *best) {
                *best = area;
                found = ((UIImageView *)sub).image;
            }
        }
        found = artworkIn(sub, host, tile, skip, best, found, depth + 1);
    }
    return found;
}

static void applyGrid(UIView *host) {
    SGRStatsGridOverlay *overlay = objc_getAssociatedObject(host, &kGridKey);
    NSMutableArray<SGRStatsTile *> *tiles = [NSMutableArray array];
    NSMutableArray<NSValue *> *frames = [NSMutableArray array];
    collectTiles(host, host, overlay, tiles, frames, 0);
    if (tiles.count < 2) {
        [tiles removeAllObjects];
        [frames removeAllObjects];
        collectElements(host, tiles, frames);
    }
    if (tiles.count < 2) {
        overlay.hidden = YES;
        return;
    }

    NSMutableArray *images = [NSMutableArray array];
    NSMutableString *signature = [NSMutableString string];
    NSUInteger missing = 0;
    for (NSUInteger i = 0; i < tiles.count; i++) {
        CGFloat best = 0;
        UIImage *image = artworkIn(host, host, frames[i].CGRectValue, overlay, &best, nil, 0);
        if (!image) missing++;
        [images addObject:image ?: (id)NSNull.null];
        [signature appendFormat:@"%ld|%@|%@|%p;", (long)tiles[i].kind, tiles[i].value, NSStringFromCGRect(frames[i].CGRectValue), image];
    }

    if (!overlay) {
        overlay = [[SGRStatsGridOverlay alloc] initWithFrame:host.bounds];
        objc_setAssociatedObject(host, &kGridKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host addSubview:overlay];
        SGLog(@"redesign stats: week card over %@ %@, %lu tiles", NSStringFromClass(object_getClass(host)),
              NSStringFromCGSize(host.bounds.size), (unsigned long)tiles.count);
    }
    overlay.hidden = NO;
    overlay.frame = host.bounds;
    if (host.subviews.lastObject != overlay) [host bringSubviewToFront:overlay];

    NSString *old = objc_getAssociatedObject(host, &kSignatureKey);
    if (![old isEqualToString:signature]) {
        objc_setAssociatedObject(host, &kSignatureKey, signature, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [overlay setTiles:tiles frames:frames images:images];
    }

    // Artwork lands after the cell is laid out and sets no layout of its own: look again a few times.
    NSNumber *tries = objc_getAssociatedObject(host, &kRetryKey);
    if (missing && tries.integerValue < 6) {
        objc_setAssociatedObject(host, &kRetryKey, @(tries.integerValue + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIView *weakHost = host;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (weakHost.window) applyGrid(weakHost);
        });
    } else if (!missing) {
        objc_setAssociatedObject(host, &kRetryKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

#pragma mark - a detail page's summary

static void collectLabels(UIView *view, UIView *skip, NSMutableArray<NSString *> *texts, NSUInteger depth) {
    if (depth > 8 || view == skip) return;
    for (UIView *sub in view.subviews) {
        if (sub == skip || sub.alpha < 0.01) continue;
        if ([sub isKindOfClass:UILabel.class]) {
            NSString *text = ((UILabel *)sub).text;
            if (text.length) [texts addObject:text];
        }
        collectLabels(sub, skip, texts, depth + 1);
    }
}

static BOOL looksLikeRange(NSString *text) {
    return [text containsString:@"–"] || [text containsString:@"-"];
}

static void applySummary(UIView *host) {
    SGRStatsSummaryOverlay *overlay = objc_getAssociatedObject(host, &kSummaryKey);
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    collectLabels(host, overlay, texts, 0);
    SGRStatsSummary *summary = nil;
    NSString *line = nil, *range = nil, *comparison = nil;
    for (NSString *text in texts) {
        SGRStatsSummary *parsed = summary ? nil : SGRStatsParseSummary(text);
        if (parsed) {
            summary = parsed;
            line = text;
        }
    }
    for (NSString *text in texts) {
        if ([text isEqualToString:line]) continue;
        if (!range && looksLikeRange(text) && text.length <= 24) range = text;
        else if (!comparison) comparison = text;
    }
    if (!summary) {
        overlay.hidden = YES;
        return;
    }

    if (!overlay) {
        overlay = [[SGRStatsSummaryOverlay alloc] initWithFrame:host.bounds];
        objc_setAssociatedObject(host, &kSummaryKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host addSubview:overlay];
        SGLog(@"redesign stats: summary over %@ %@, %@ %@", NSStringFromClass(object_getClass(host)),
              NSStringFromCGSize(host.bounds.size), summary.number, summary.unit);
    }
    overlay.hidden = NO;
    overlay.frame = host.bounds;
    if (host.subviews.lastObject != overlay) [host bringSubviewToFront:overlay];

    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@|%@", summary.number, summary.unit, range, comparison];
    if (![signature isEqualToString:objc_getAssociatedObject(host, &kSignatureKey)]) {
        objc_setAssociatedObject(host, &kSignatureKey, signature, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [overlay setSummary:summary range:range comparison:comparison];
    }
}

#pragma mark - hook

static void style(UICollectionViewCell *cell) {
    if (!cell.window) return;
    StatsHost kind = StatsHostNone;
    UIView *host = findHost(cell.contentView, &kind, 0);
    if (!host) return;
    if (kind == StatsHostGrid) applyGrid(host);
    else applySummary(host);
}

%hook UICollectionViewCell
- (void)layoutSubviews {
    %orig;
    style((UICollectionViewCell *)self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
}
