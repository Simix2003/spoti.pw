#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "StatsProbe.h"

UIViewController *SGStatsProbePage(void) {
    SGModRow *pill = SGOptionRow(@"Show Probe pill", @"Lower-right on every screen until you turn it off", SGKeyStatsProbe);
    SGModRow *share = SGActionRow(@"Share last probe", @"The newest dump file in Documents", ^{ SGStatsProbeShareLast(); });
    return [[SGModPage alloc] initWithTitle:@"Stats probe" intro:SGRestartNote sections:@[
        SGNotedSection(@"Stats probe", @[
            SGWithSymbol(pill, @"chart.bar.xaxis"),
            SGWithSymbol(share, @"square.and.arrow.up"),
        ], @"Read-only. Off by default. Turn it on, restart, open Statistiche di ascolto, tap Probe, share the file, then turn it off and restart. The pill stays on every screen while the switch is on — Spotify hosts that page without a matching title."),
    ] footer:nil];
}
