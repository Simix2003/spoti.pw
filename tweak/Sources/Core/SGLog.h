#import <Foundation/Foundation.h>
#import <os/log.h>

// %{public}s so idevicesyslog on the Mac sees the text instead of <private>.
// The same line is copied, with a timestamp, into Documents/spotifyplus-log.txt.
// That copy is asynchronous and capped; os_log is unchanged.
#define SGLog(fmt, ...) SGLogLine([NSString stringWithFormat:(fmt), ##__VA_ARGS__])

void SGLogLine(NSString *text);

// Long dumps, split into numbered parts under the unified log's size cap.
void SGLogLong(NSString *tag, NSString *text);
// Logs every class of the list that this Spotify does not have; a feature calls it from its %ctor.
void SGRequireClasses(NSArray<NSString *> *names);

// The on-phone copy of SGLog. Share and clear run from Mod settings; the writer never touches the main thread.
extern NSNotificationName const SGLogExportDidChangeNotification;
NSURL *SGLogExportFileURL(void);
uint64_t SGLogExportByteCount(void);
void SGLogExportClear(void);
// Copies the current file to a temp URL and calls back on the main queue. Nil when there is nothing to share.
void SGLogExportSnapshot(void (^completion)(NSURL *url));
