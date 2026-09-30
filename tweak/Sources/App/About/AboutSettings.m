#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "About.h"
#import "App/Onboarding/Onboarding.h"
#import "Shared/JamProbe/JamProbe.h"

// Makefile passes these. A build that doesn't still compiles, and the row says unknown.
#ifndef SG_BUILD
#define SG_BUILD "unknown"
#endif
#ifndef SG_BUILD_BRANCH
#define SG_BUILD_BRANCH "unknown"
#endif

// Branch and short commit, separate from SG_VERSION so a fork build is not identical to upstream beta.
static NSString *SGBuildLabel(void) {
    NSString *branch = @SG_BUILD_BRANCH;
    NSString *build = @SG_BUILD;
    if (!branch.length) branch = @"unknown";
    if (!build.length) build = @"unknown";
    if ([branch isEqualToString:@"unknown"] && [build isEqualToString:@"unknown"]) return @"unknown";
    return [NSString stringWithFormat:@"%@ %@", branch, build];
}

__attribute__((constructor)) static void SGLogBuildIdentity(void) {
    SGLog(@"build: %@", SGBuildLabel());
}

// Every key of the mod's is under one prefix, so a reset is a sweep of the defaults with the stock
// marker of SGPrefs.h left behind; the hooks read them at launch, so it ends in a restart.
static void resetAll(void) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    NSUInteger removed = 0;
    for (NSString *key in [store persistentDomainForName:NSBundle.mainBundle.bundleIdentifier].allKeys) {
        if (![key hasPrefix:@"spotifyglass."]) continue;
        [store removeObjectForKey:key];
        removed++;
    }
    [store setBool:YES forKey:SGKeyStock];
    SGLog(@"reset: removed %lu keys", (unsigned long)removed);
    SGRestartSpotify();
}

static void confirmReset(void) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset all settings?"
                                                                  message:@"Every switch goes off, flag overrides and the tab bar layout are cleared, and Spotify restarts as it came, with the mod doing nothing until asked. Spotify's own settings are untouched."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset and restart" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { resetAll(); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static SGModRow *withSymbol(SGModRow *row, NSString *symbol) {
    row.symbol = symbol;
    return row;
}

static NSString *logSizeLabel(void) {
    uint64_t bytes = SGLogExportByteCount();
    if (bytes < 1024) return [NSString stringWithFormat:@"%llu B", (unsigned long long)bytes];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", bytes / 1024.0];
    return [NSString stringWithFormat:@"%.2f MB", bytes / (1024.0 * 1024.0)];
}

static void shareLogs(void) {
    SGLogExportSnapshot(^(NSURL *url) {
        UIViewController *top = SGTopController();
        if (!url || !top) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No logs yet" message:@"Use Spotify for a moment, then share the log file." preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [SGTopController() presentViewController:alert animated:YES completion:nil];
            return;
        }
        UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        sheet.popoverPresentationController.sourceView = top.view;
        [top presentViewController:sheet animated:YES completion:nil];
    });
}

static void confirmClearLogs(void) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear logs?" message:@"The on-phone log file is deleted. Spotify keeps running." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear logs" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { SGLogExportClear(); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

// Which build this is, whether GitHub has a newer release, and where to reach the mod: without these
// rows a build that is already installed has no way of telling its user that anything moved on.
UIViewController *SGAboutPage(void) {
    SGModRow *reset = withSymbol(SGActionRow(@"Reset all settings", nil, ^{ confirmReset(); }), @"trash");
    reset.color = SGRed();
    NSString *spotify = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
    // The row reads out where the build stands and opens the changelog of everything newer than it.
    SGModRow *updates = SGPageRow(@"Updates", ^UIViewController *{ return SGUpdatePage(); });
    updates.value = ^NSString *{ return SGUpdateStatus(); };
    NSMutableArray<SGModSection *> *sections = [NSMutableArray arrayWithObject:SGSection(nil, @[
        updates,
        SGStatRow(@"Version", ^NSString *{ return @(SG_VERSION); }),
        SGStatRow(@"Build", ^NSString *{ return SGBuildLabel(); }),
        SGStatRow(@"Spotify", ^NSString *{ return spotify; }),
    ])];
    SGModRow *logFile = SGStatRow(@"Log file", ^NSString *{ return logSizeLabel(); });
    logFile.subtitle = [NSString stringWithFormat:@"Build %@", SGBuildLabel()];
    logFile.refreshOn = SGLogExportDidChangeNotification;
    [sections addObject:SGSection(@"Debug", @[
        withSymbol(SGPageRow(@"Jam probe", ^UIViewController *{ return SGJamProbePage(); }), @"ladybug"),
        logFile,
        withSymbol(SGActionRow(@"Share logs", @"AirDrop, Files, or Messages", ^{ shareLogs(); }), @"square.and.arrow.up"),
        withSymbol(SGActionRow(@"Clear logs", nil, ^{ confirmClearLogs(); }), @"trash"),
    ])];
    SGModRow *appIcon = SGAppIconRow();
    if (appIcon) [sections addObject:SGSection(nil, @[withSymbol(appIcon, @"app")])];
    [sections addObjectsFromArray:@[
        SGSection(nil, @[
            withSymbol(SGLinkRow(@"Website", nil, SGSiteURL), @"safari"),
            withSymbol(SGLinkRow(@"Discord", nil, SGDiscordURL), @"bubble.left.and.bubble.right"),
            withSymbol(SGLinkRow(@"GitHub", nil, SGRepoURL), @"chevron.left.forwardslash.chevron.right"),
            withSymbol(SGPageRow(@"Licenses", ^UIViewController *{ return SGLicensesPage(); }), @"doc.text"),
            withSymbol(SGActionRow(@"Welcome tour", nil, ^{ SGShowOnboarding(); }), @"map"),
        ]),
        SGSection(nil, @[
            withSymbol(SGActionRow(@"Export settings", nil, ^{ SGExportSettings(); }), @"square.and.arrow.up"),
            withSymbol(SGActionRow(@"Import settings", nil, ^{ SGImportSettings(); }), @"square.and.arrow.down"),
        ]),
        SGSection(nil, @[reset]),
    ]];
    return [[SGModPage alloc] initWithTitle:@"Mod" intro:nil sections:sections footer:nil];
}
