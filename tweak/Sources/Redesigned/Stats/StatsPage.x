// Statistiche di ascolto, redesigned: the week's tiles and the summary line of each detail page drawn
// again over Spotify's own cells.
//
// What the recorded page proves (Spotify 9.1.78, the stats deep probes of 2026-09-30): every cell is a
// UICollectionViewCell holding Element_UIKit's ElementView over an ElementContentView generic in the
// element, `StatsTileGridElement` for a week's five tiles (370x563) and `SummaryStatsElement` for the
// line that opens a detail page. The five tiles themselves are MinutesListenedTile / IndividualStatsTile /
// SocialStatsTile ElementUIs, and their copy is on accessibility labels ("Minuti di ascolto, 367. Sei il
// numero 2 tra gli amici"). A generic Swift class has no runtime name until its first instance exists, so
// the hook is on the cell, which always does.
//
// Spotify's cell stays where it is and keeps every touch: the cards go over it as views that take none,
// at the frames of the tile UIs (or of their accessibility elements), so a tap on a card is a tap on the
// tile under it. When a tile or label is not found, the cell is left as Spotify drew it.
//
// Main thread only; every hook is installed only while Redesigned UI is on.
#import "Core/SGCore.h"
#import "Core/SGViewTree.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Stats.h"
#import "StatsParse.h"
#import "StatsViews.h"

typedef NS_ENUM(NSInteger, StatsHost) { StatsHostNone, StatsHostGrid, StatsHostSummary };

static char kGridKey, kSummaryKey, kSignatureKey, kRetryKey, kMissKey;

static void logOnce(NSString *key, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
static void logOnce(NSString *key, NSString *format, ...) {
     static NSMutableSet<NSString *> *seen;
     if (!seen) seen = [NSMutableSet set];
     if ([seen containsObject:key]) return;
     [seen addObject:key];
     va_list args;
     va_start(args, format);
     NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
     va_end(args);
     SGLog(@"%@", text);
}

static StatsHost hostKind(UIView *view) {
     NSString *name = NSStringFromClass(object_getClass(view));
     if ([name containsString:@"StatsTileGridElement"]) return StatsHostGrid;
     if ([name containsString:@"SummaryStatsElement"]) return StatsHostSummary;
     return StatsHostNone;
}

static BOOL isTileUI(NSString *name) {
     return [name containsString:@"MinutesListenedTile"] ||
            [name containsString:@"IndividualStatsTile"] ||
            [name containsString:@"SocialStatsTile"];
}

// The cell holds its element a few views down (cell > content view > ElementView > ElementContentView).
static UIView *findHost(UIView *view, StatsHost *kind, NSUInteger depth) {
     if (depth > 5) return nil;
     for (UIView *sub in view.subviews) {
         StatsHost found = hostKind(sub);
         if (found != StatsHostNone) {
             *kind = found;
             return sub;
         }
         if ([sub isKindOfClass:UICollectionView.class]) continue;
         UIView *deeper = findHost(sub, kind, depth + 1);
         if (deeper) return deeper;
     }
     return nil;
}

#pragma mark - collecting tiles

static void addTile(SGRStatsTile *tile, CGRect frame, UIView *host, NSMutableArray<SGRStatsTile *> *tiles, NSMutableArray<NSValue *> *frames) {
     if (!tile) return;
     BOOL sane = frame.size.width > 40 && frame.size.height > 40 &&
                 frame.size.width < host.bounds.size.width * 0.99 + 2 &&
                 frame.size.height < host.bounds.size.height * 0.99 + 2 &&
                 CGRectIntersectsRect(CGRectInset(frame, 1, 1), host.bounds);
     if (!sane) return;
     for (SGRStatsTile *have in tiles) if (have.kind == tile.kind) return;
     [tiles addObject:tile];
     [frames addObject:[NSValue valueWithCGRect:frame]];
}

static NSString *labelOf(UIView *view) {
     if (view.accessibilityLabel.length) return view.accessibilityLabel;
     if (view.accessibilityValue.length) return view.accessibilityValue;
     for (UIView *sub in view.subviews) {
         if (![sub isKindOfClass:UILabel.class]) continue;
         NSString *text = ((UILabel *)sub).text;
         if (text.length > 2) return text;
     }
     return nil;
}

// Preferred: the five ElementUI views Spotify already laid out, by class name.
static void collectTileUIs(UIView *view, UIView *host, UIView *skip, NSMutableArray<SGRStatsTile *> *tiles, NSMutableArray<NSValue *> *frames, NSUInteger depth) {
     if (depth > 10 || view == skip) return;
     for (UIView *sub in view.subviews) {
         if (sub == skip || sub.alpha < 0.01) continue;
         NSString *name = NSStringFromClass(object_getClass(sub));
         if (isTileUI(name)) {
             SGRStatsTile *tile = SGRStatsParseTile(labelOf(sub));
             // Minutes has no entity name in its a11y when VoiceOver has not yet built the elements; fall
             // back to the class so the card still covers the minutes tile.
             if (!tile && [name containsString:@"MinutesListenedTile"]) {
                 tile = [SGRStatsTile new];
                 tile.kind = SGRStatsTileMinutes;
                 tile.title = @"Minuti di ascolto";
                 for (UIView *child in sub.subviews) {
                     if (![child isKindOfClass:UILabel.class]) continue;
                     NSString *text = ((UILabel *)child).text;
                     if (!text.length) continue;
                     if (!tile.value && [text rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location != NSNotFound)
                         tile.value = text;
                 }
             }
             addTile(tile, SGFrameIn(sub, host), host, tiles, frames);
             continue;
         }
         collectTileUIs(sub, host, skip, tiles, frames, depth + 1);
     }
}

static void collectLabeledViews(UIView *view, UIView *host, UIView *skip, NSMutableArray<SGRStatsTile *> *tiles, NSMutableArray<NSValue *> *frames, NSUInteger depth) {
     if (depth > 10 || view == skip) return;
     for (UIView *sub in view.subviews) {
         if (sub == skip || sub.alpha < 0.01) continue;
         addTile(SGRStatsParseTile(sub.accessibilityLabel), SGFrameIn(sub, host), host, tiles, frames);
         collectLabeledViews(sub, host, skip, tiles, frames, depth + 1);
     }
}

static void collectElements(UIView *root, UIView *host, NSMutableArray<SGRStatsTile *> *tiles, NSMutableArray<NSValue *> *frames, NSUInteger depth) {
     if (!root || depth > 6) return;
     UIWindow *window = host.window;
     NSArray *elements = root.accessibilityElements;
     for (id element in elements) {
         NSString *label = [element respondsToSelector:@selector(accessibilityLabel)] ? [element accessibilityLabel] : nil;
         SGRStatsTile *tile = SGRStatsParseTile(label);
         if (!tile || ![element respondsToSelector:@selector(accessibilityFrame)] || !window) continue;
         CGRect screen = [element accessibilityFrame];
         if (CGRectIsEmpty(screen) || screen.size.width < 2) continue;
         CGRect inWindow = [window convertRect:screen fromWindow:nil];
         CGRect frame = [host convertRect:inWindow fromView:window];
         addTile(tile, frame, host, tiles, frames);
     }
     if (tiles.count >= 2) return;
     for (UIView *sub in root.subviews) {
         if (sub.alpha < 0.01) continue;
         collectElements(sub, host, tiles, frames, depth + 1);
         if (tiles.count >= 2) return;
     }
}

// When Spotify gave us the five labels but no usable frames (a11y frames often empty until VoiceOver
// runs), place the cards in the layout the page already uses: minutes tall on the leading half, the
// four entity tiles in a 2×2 on the trailing half.
static void layoutFallback(UIView *host, NSArray<SGRStatsTile *> *tiles, NSMutableArray<NSValue *> *frames) {
     [frames removeAllObjects];
     CGFloat w = host.bounds.size.width, h = host.bounds.size.height;
     CGFloat gap = 8;
     CGFloat halfW = (w - gap) / 2;
     CGFloat topH = (h - gap) * 0.55;
     CGFloat botH = h - gap - topH;
     CGFloat rowH = (botH - gap) / 2;
     CGRect minutes = CGRectMake(0, 0, halfW, topH + gap + rowH);
     CGRect artist = CGRectMake(halfW + gap, 0, halfW, topH);
     CGRect track = CGRectMake(halfW + gap, topH + gap, halfW, rowH);
     CGRect friendsArtists = CGRectMake(0, CGRectGetMaxY(minutes) + gap, halfW, rowH);
     CGRect friendsTracks = CGRectMake(halfW + gap, CGRectGetMaxY(minutes) + gap, halfW, rowH);
     // Keep minutes tall only when the trailing column has room; otherwise a simple column.
     if (h < 280) {
         minutes = CGRectMake(0, 0, w, h * 0.4);
         artist = CGRectMake(0, h * 0.4 + gap, (w - gap) / 2, h * 0.28);
         track = CGRectMake(halfW + gap, h * 0.4 + gap, (w - gap) / 2, h * 0.28);
         friendsArtists = CGRectMake(0, h * 0.7 + gap, (w - gap) / 2, h * 0.28);
         friendsTracks = CGRectMake(halfW + gap, h * 0.7 + gap, (w - gap) / 2, h * 0.28);
     }
     for (SGRStatsTile *tile in tiles) {
         CGRect frame = CGRectZero;
         switch (tile.kind) {
             case SGRStatsTileMinutes: frame = minutes; break;
             case SGRStatsTileFavoriteArtist: frame = artist; break;
             case SGRStatsTileFavoriteTrack: frame = track; break;
             case SGRStatsTileFriendsArtists: frame = friendsArtists; break;
             case SGRStatsTileFriendsTracks: frame = friendsTracks; break;
             default: frame = CGRectMake(0, 0, halfW, rowH); break;
         }
         [frames addObject:[NSValue valueWithCGRect:frame]];
     }
}

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

static void applyGrid(UIView *host, UIView *cell) {
     SGRStatsGridOverlay *overlay = objc_getAssociatedObject(host, &kGridKey);
     NSMutableArray<SGRStatsTile *> *tiles = [NSMutableArray array];
     NSMutableArray<NSValue *> *frames = [NSMutableArray array];
     NSString *path = @"none";

     collectTileUIs(host, host, overlay, tiles, frames, 0);
     if (tiles.count >= 2) path = @"tile-ui";
     if (tiles.count < 2) {
         [tiles removeAllObjects];
         [frames removeAllObjects];
         collectLabeledViews(host, host, overlay, tiles, frames, 0);
         if (tiles.count >= 2) path = @"labels";
     }
     if (tiles.count < 2) {
         [tiles removeAllObjects];
         [frames removeAllObjects];
         collectElements(cell ?: host, host, tiles, frames, 0);
         if (tiles.count >= 2) path = @"a11y";
     }
     if (tiles.count >= 2 && frames.count != tiles.count) {
         layoutFallback(host, tiles, frames);
         path = [path stringByAppendingString:@"+fallback"];
     }
     if (tiles.count < 2) {
         overlay.hidden = YES;
         NSMutableArray<NSString *> *names = [NSMutableArray array];
         void (^walk)(UIView *, NSUInteger);
         __block __weak void (^weakWalk)(UIView *, NSUInteger);
         weakWalk = walk = ^(UIView *view, NSUInteger depth) {
             if (depth > 4) return;
             for (UIView *sub in view.subviews) {
                 NSString *name = NSStringFromClass(object_getClass(sub));
                 if ([name containsString:@"Stats"] || [name containsString:@"Tile"] || [name containsString:@"Highlight"]) {
                     if (names.count < 12) [names addObject:name];
                 }
                 weakWalk(sub, depth + 1);
             }
         };
         walk(host, 0);
         logOnce(@"miss-grid", @"redesign stats: grid found but no tiles on %@ %@ (children %@)",
                 NSStringFromClass(object_getClass(host)), NSStringFromCGSize(host.bounds.size),
                 names.count ? [names componentsJoinedByString:@", "] : @"none");
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
         SGLog(@"redesign stats: week card over %@ %@, %lu tiles via %@", NSStringFromClass(object_getClass(host)),
               NSStringFromCGSize(host.bounds.size), (unsigned long)tiles.count, path);
     }
     overlay.hidden = NO;
     overlay.frame = host.bounds;
     if (host.subviews.lastObject != overlay) [host bringSubviewToFront:overlay];

     NSString *old = objc_getAssociatedObject(host, &kSignatureKey);
     if (![old isEqualToString:signature]) {
         objc_setAssociatedObject(host, &kSignatureKey, signature, OBJC_ASSOCIATION_COPY_NONATOMIC);
         [overlay setTiles:tiles frames:frames images:images];
     }

     NSNumber *tries = objc_getAssociatedObject(host, &kRetryKey);
     if (missing && tries.integerValue < 8) {
         objc_setAssociatedObject(host, &kRetryKey, @(tries.integerValue + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
         __weak UIView *weakHost = host;
         __weak UIView *weakCell = cell;
         dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
             if (weakHost.window) applyGrid(weakHost, weakCell);
         });
     } else if (!missing) {
         objc_setAssociatedObject(host, &kRetryKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
     }
}

#pragma mark - summary

static void collectLabels(UIView *view, UIView *skip, NSMutableArray<NSString *> *texts, NSUInteger depth) {
     if (depth > 8 || view == skip) return;
     for (UIView *sub in view.subviews) {
         if (sub == skip || sub.alpha < 0.01) continue;
         if ([sub isKindOfClass:UILabel.class]) {
             NSString *text = ((UILabel *)sub).text;
             if (text.length) [texts addObject:text];
         }
         if (sub.accessibilityLabel.length) [texts addObject:sub.accessibilityLabel];
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
         else if (!comparison && text.length < 80 && ![text isEqualToString:range]) comparison = text;
     }
     if (!summary) {
         overlay.hidden = YES;
         logOnce(@"miss-summary", @"redesign stats: summary host %@ %@ with no count (labels %@)",
                 NSStringFromClass(object_getClass(host)), NSStringFromCGSize(host.bounds.size),
                 texts.count ? [texts componentsJoinedByString:@" | "] : @"none");
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
     if (!cell.window || cell.bounds.size.height < 40) return;
     StatsHost kind = StatsHostNone;
     UIView *host = findHost(cell.contentView, &kind, 0);
     if (!host) {
         // Tall week cells still worth a one-shot look when the ElementContentView name differs.
         if (cell.bounds.size.height > 400 && cell.bounds.size.width > 280) {
             NSString *mark = objc_getAssociatedObject(cell, &kMissKey);
             if (!mark) {
                 objc_setAssociatedObject(cell, &kMissKey, @"1", OBJC_ASSOCIATION_COPY_NONATOMIC);
                 NSMutableArray<NSString *> *names = [NSMutableArray array];
                 void (^walk)(UIView *, NSUInteger);
                 __block __weak void (^weakWalk)(UIView *, NSUInteger);
                 weakWalk = walk = ^(UIView *view, NSUInteger depth) {
                     if (depth > 4) return;
                     for (UIView *sub in view.subviews) {
                         if (names.count < 16) [names addObject:NSStringFromClass(object_getClass(sub))];
                         weakWalk(sub, depth + 1);
                     }
                 };
                 walk(cell.contentView, 0);
                 logOnce(@"miss-host", @"redesign stats: tall cell %@ with no host (tree %@)",
                         NSStringFromCGSize(cell.bounds.size),
                         names.count ? [names componentsJoinedByString:@" > "] : @"empty");
             }
         }
         return;
     }
     if (kind == StatsHostGrid) applyGrid(host, cell);
     else applySummary(host);
}

%hook UICollectionViewCell
- (void)layoutSubviews {
     %orig;
     style((UICollectionViewCell *)self);
}
%end

%ctor {
     if (!SGRedesignedUI()) {
         SGLog(@"redesign stats: skipped (native UI)");
         return;
     }
     %init;
     SGLog(@"redesign stats: installed");
}
