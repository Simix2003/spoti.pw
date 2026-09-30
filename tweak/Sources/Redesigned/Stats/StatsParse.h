// What the redesigned Statistiche di ascolto reads off Spotify's own cells: the accessibility labels of
// the week's tiles and the summary line of a detail page. Nothing else of the page is readable (its
// props are Combine publishers), so this is the whole model. Italian only, which is what the recorded
// page speaks (trees of 2026-09-30, Spotify 9.1.78); a label that matches nothing here leaves its tile
// as Spotify drew it.
//
// Threading: pure functions, safe anywhere.
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SGRStatsTileKind) {
    SGRStatsTileUnknown = 0,
    SGRStatsTileMinutes,          // "Minuti di ascolto, 367. Sei il numero 2 tra gli amici"
    SGRStatsTileFavoriteArtist,   // "Artista preferito, 22simba,"
    SGRStatsTileFriendsArtists,   // "Gli artisti top con gli amici, 22simba"
    SGRStatsTileFriendsTracks,    // "I brani top con gli amici, Go. In ascesa"
    SGRStatsTileFavoriteTrack,    // "Brano preferito, Provinciali, Questo brano sale di 4 posizioni rispetto alla settimana scorsa"
};

@interface SGRStatsTile : NSObject
@property (nonatomic) SGRStatsTileKind kind;
@property (nonatomic, copy) NSString *title;    // the tile's own heading ("Artista preferito")
@property (nonatomic, copy) NSString *value;    // the name or title, or the minutes as Spotify wrote them ("1.353")
@property (nonatomic) NSInteger friendRank;     // Minutes: "Sei il numero N tra gli amici"; 0 when absent
@property (nonatomic) NSInteger movement;       // tracks: +4 rises four places, -2 falls two; 0 when there is none
@property (nonatomic) BOOL rising;              // "In ascesa", or a movement above zero
@end

// nil when the label is not one of the five tiles.
SGRStatsTile *SGRStatsParseTile(NSString *label);

@interface SGRStatsSummary : NSObject
@property (nonatomic, copy) NSString *number;   // "367", "1.353"
@property (nonatomic, copy) NSString *unit;     // "minuti", "brani", "artisti"
@end

// "Questa settimana hai ascoltato per 367 minuti." / "233 brani, ed è solo l'inizio." /
// "Hai ascoltato 95 artisti questa settimana". nil when the line has no count of minutes, songs or artists.
SGRStatsSummary *SGRStatsParseSummary(NSString *line);
