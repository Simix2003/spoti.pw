// The Statistiche di ascolto redesign: Spotify's listening stats kept, with its controllers, its list
// and its cells, and its week tiles and summary lines drawn again in the Kit's look. No settings of its own.
//
//     StatsParse.m   the copy of the five tiles and of a summary line, read off their accessibility
//                    labels (Italian, the language of the recorded page) into typed values
//     StatsViews.m   the cards: a hero of minutes with the friend rank, artwork tiles with their
//                    movement chips, and a detail page's big number with its unit and week
//     StatsPage.x    the hook on the list's cells, which finds the tiles, takes their frames and the
//                    artwork Spotify loaded, and lays the cards over them
//
// The cards take no touches and sit at the frames of the tiles they cover, so Spotify's tiles stay the
// ones that are tapped. A tile or label that cannot be read leaves its cell as Spotify drew it.
//
// Every hook installs only while Redesigned UI is on (SGRedesignedUI).
// Threading: main thread only.
#import "StatsParse.h"
#import "StatsViews.h"
