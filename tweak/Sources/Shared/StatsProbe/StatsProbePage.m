#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "StatsProbe.h"

UIViewController *SGStatsProbePage(void) {
    SGModRow *pill = SGOptionRow(@"Show Probe pill", @"On Statistiche di ascolto and its sub-pages only", SGKeyStatsProbe);
    SGModRow *share = SGActionRow(@"Share last probe", @"The newest dump file in Documents", ^{ SGStatsProbeShareLast(); });
    return [[SGModPage alloc] initWithTitle:@"Stats probe" intro:SGRestartNote sections:@[
        SGNotedSection(@"Stats probe", @[
            SGWithSymbol(pill, @"chart.bar.xaxis"),
            SGWithSymbol(share, @"square.and.arrow.up"),
        ], @"Read-only. Off by default: the pill used to hook every screen and crash Spotify. Turn it on only when you need a dump, restart, open Statistiche di ascolto, tap Probe, then turn it off again."),
    ] footer:nil];
}
