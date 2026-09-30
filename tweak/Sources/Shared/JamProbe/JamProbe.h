// A read-only look at whatever Jam data the Spotify process already has loaded.
// Nothing here joins a room, edits a queue, or sends a request. SGJamProbeRun waits, then
// walks classes and the screen on the main thread and writes one file under Documents.
#import <UIKit/UIKit.h>

void SGJamProbeRun(void);
void SGJamProbeShareLast(void);
UIViewController *SGJamProbePage(void);
