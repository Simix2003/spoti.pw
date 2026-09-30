#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "StatsProbe.h"

UIViewController *SGStatsProbePage(void) {
    SGModRow *pill = SGOptionRow(@"Show Probe pills", @"Probe (views) and Deep (models) on every screen", SGKeyStatsProbe);
    SGModRow *share = SGActionRow(@"Share last probe", @"Newest UI or Deep dump in Documents", ^{ SGStatsProbeShareLast(); });
    return [[SGModPage alloc] initWithTitle:@"Stats probe" intro:SGRestartNote sections:@[
        SGNotedSection(@"Stats probe", @[
            SGWithSymbol(pill, @"chart.bar.xaxis"),
            SGWithSymbol(share, @"square.and.arrow.up"),
        ], @"Read-only. Off by default. Turn on, restart, open each Statistiche di ascolto screen and tap Deep — that walks HighlightsStats ElementKit Props/ivars for a redesign. Probe is the lighter view-tree dump. Turn off and restart when done."),
    ] footer:nil];
}
