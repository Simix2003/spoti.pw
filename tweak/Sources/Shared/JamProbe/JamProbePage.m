#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "JamProbe.h"

UIViewController *SGJamProbePage(void) {
    SGModRow *run = SGActionRow(@"Run Jam probe now", @"Waits 5 seconds, then reads the screen", ^{ SGJamProbeRun(); });
    SGModRow *share = SGActionRow(@"Share last probe", @"The newest dump file in Documents", ^{ SGJamProbeShareLast(); });
    return [[SGModPage alloc] initWithTitle:@"Jam probe" intro:nil sections:@[
        SGNotedSection(@"Jam probe", @[
            SGWithSymbol(run, @"dot.viewfinder"),
            SGWithSymbol(share, @"square.and.arrow.up"),
        ], @"Read-only. Nothing is joined, skipped, or sent off the phone. Tap Run, then switch back to the Jam within 5 seconds. A toast shows when the file is saved."),
    ] footer:nil];
}
