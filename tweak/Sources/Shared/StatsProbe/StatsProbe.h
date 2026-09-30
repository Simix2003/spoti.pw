// A read-only dump of the listening-stats page that is on screen.
// Nothing here fetches, joins, or changes playback. The pill calls SGStatsProbeShareLast's
// sibling in StatsProbe.m; this header is the Settings row.
#import <UIKit/UIKit.h>

void SGStatsProbeShareLast(void);
