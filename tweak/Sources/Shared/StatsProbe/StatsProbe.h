// A read-only dump of the listening-stats page that is on screen.
// Nothing here fetches, joins, or changes playback. The Probe pill is off until
// Mod → Debug → Stats probe turns it on (restart). Share last works either way.
#import <UIKit/UIKit.h>

#define SGKeyStatsProbe @"spotifyglass.statsProbe"

void SGStatsProbeShareLast(void);
UIViewController *SGStatsProbePage(void);
