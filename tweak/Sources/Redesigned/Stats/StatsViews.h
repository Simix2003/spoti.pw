// The views the redesigned Statistiche di ascolto draws over Spotify's own cells. Both are plain UIKit,
// take no touches (so Spotify's tiles underneath keep answering them, at the frames they have) and
// paint an opaque black cover under what they draw, so what they replace does not show through.
//
// Threading: main thread only.
#import <UIKit/UIKit.h>
#import "StatsParse.h"

// A week's grid of tiles: one card per tile, each placed at the frame Spotify gave the tile it covers.
@interface SGRStatsGridOverlay : UIView
// `frames` are in this view's coordinates; `images` holds a UIImage or NSNull per tile, the artwork
// Spotify loaded into the tile.
- (void)setTiles:(NSArray<SGRStatsTile *> *)tiles frames:(NSArray<NSValue *> *)frames images:(NSArray *)images;
@end

// The line that opens a detail page ("Questa settimana hai ascoltato per 367 minuti."), as a number
// with its unit and the week under it.
@interface SGRStatsSummaryOverlay : UIView
- (void)setSummary:(SGRStatsSummary *)summary range:(NSString *)range comparison:(NSString *)comparison;
@end
