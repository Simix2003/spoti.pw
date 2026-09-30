#import "SGLog.h"
#import <os/lock.h>
#import <stdatomic.h>
#import <time.h>

NSNotificationName const SGLogExportDidChangeNotification = @"SGLogExportDidChange";

static const NSUInteger kMaxLogBytes = 1024 * 1024;
static const NSUInteger kKeepLogBytes = 768 * 1024;
static const NSUInteger kMaxPending = 250;
static const NSUInteger kMaxLine = 8000;

static os_unfair_lock sg_lock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<NSString *> *sg_inbox;
static BOOL sg_draining;
static _Atomic uint64_t sg_bytes;

static dispatch_queue_t logQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("pw.spoti.log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString *logPath(void) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!dir.length) dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return dir.length ? [dir stringByAppendingPathComponent:@"spotifyplus-log.txt"] : nil;
}

static NSString *stamped(NSString *text) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm date;
    localtime_r(&ts.tv_sec, &date);
    char buf[32];
    strftime(buf, sizeof buf, "%Y-%m-%d %H:%M:%S", &date);
    return [NSString stringWithFormat:@"%s.%03ld %@\n", buf, ts.tv_nsec / 1000000L, text];
}

static void storeSize(uint64_t size) {
    atomic_store_explicit(&sg_bytes, size, memory_order_relaxed);
}

static void writeAtomically(NSString *path, NSData *data) {
    [data writeToFile:path options:NSDataWritingAtomic error:nil];
    storeSize(data.length);
}

// Keep the newest bytes. The cut moves forward to a newline so a line is not split in half.
static void trimAndWrite(NSString *path, NSData *incoming) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    unsigned long long size = 0;
    @try { size = handle.seekToEndOfFile; }
    @catch (NSException *ex) { size = 0; }
    unsigned long long keep = MIN(size, (unsigned long long)kMaxLogBytes);
    NSData *existing = nil;
    @try {
        [handle seekToFileOffset:size > keep ? size - keep : 0];
        existing = [handle readDataToEndOfFile];
    } @catch (NSException *ex) {
        existing = nil;
    }
    [handle closeFile];
    NSMutableData *combined = [NSMutableData dataWithData:existing ?: [NSData data]];
    [combined appendData:incoming];
    if (combined.length > kMaxLogBytes) {
        NSUInteger drop = combined.length - kKeepLogBytes;
        const uint8_t *bytes = combined.bytes;
        NSUInteger start = drop;
        NSUInteger limit = MIN(combined.length, drop + 8192);
        for (NSUInteger i = drop; i < limit; i++) {
            if (bytes[i] == '\n') {
                start = i + 1;
                break;
            }
        }
        while (start < combined.length && (((const uint8_t *)combined.bytes)[start] & 0xC0) == 0x80) start++;
        if (start >= combined.length) combined = [NSMutableData data];
        else if (start > 0) combined = [[combined subdataWithRange:NSMakeRange(start, combined.length - start)] mutableCopy];
    }
    writeAtomically(path, combined);
}

static void appendData(NSData *data) {
    if (!data.length) return;
    NSString *path = logPath();
    if (!path) return;
    @try {
        NSFileManager *files = NSFileManager.defaultManager;
        NSString *dir = path.stringByDeletingLastPathComponent;
        if (dir.length) [files createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSDictionary *attrs = [files attributesOfItemAtPath:path error:nil];
        unsigned long long size = [attrs fileSize];
        if (!attrs || size + data.length <= kMaxLogBytes) {
            if (!attrs) {
                writeAtomically(path, data);
                return;
            }
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!handle) {
                writeAtomically(path, data);
                return;
            }
            @try {
                [handle seekToEndOfFile];
                [handle writeData:data];
            } @catch (NSException *ex) {
                [handle closeFile];
                return;
            }
            [handle closeFile];
            storeSize(size + data.length);
            return;
        }
        trimAndWrite(path, data);
    } @catch (NSException *ex) {
        // A log line must not take the app down.
    }
}

static void drain(void) {
    for (;;) {
        os_unfair_lock_lock(&sg_lock);
        NSArray<NSString *> *batch = sg_inbox;
        sg_inbox = [NSMutableArray array];
        if (batch.count == 0) {
            sg_draining = NO;
            os_unfair_lock_unlock(&sg_lock);
            return;
        }
        os_unfair_lock_unlock(&sg_lock);
        NSMutableData *joined = [NSMutableData data];
        for (NSString *line in batch) {
            NSData *part = [line dataUsingEncoding:NSUTF8StringEncoding];
            if (part) [joined appendData:part];
        }
        appendData(joined);
    }
}

void SGLogLine(NSString *text) {
    if (![text isKindOfClass:NSString.class]) text = @"";
    const char *utf = text.UTF8String;
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "[spotifyglass] %{public}s", utf ?: "");
    if (text.length > kMaxLine) text = [[text substringToIndex:kMaxLine] stringByAppendingString:@"…"];
    NSString *copy = stamped(text);
    BOOL start = NO;
    os_unfair_lock_lock(&sg_lock);
    if (!sg_inbox) sg_inbox = [NSMutableArray array];
    [sg_inbox addObject:copy];
    if (sg_inbox.count > kMaxPending) {
        [sg_inbox removeObjectsInRange:NSMakeRange(0, sg_inbox.count - kMaxPending)];
    }
    if (!sg_draining) {
        sg_draining = YES;
        start = YES;
    }
    os_unfair_lock_unlock(&sg_lock);
    if (!start) return;
    dispatch_async(logQueue(), ^{ drain(); });
}

// The unified log cuts a message at about 1 KB, so long dumps go out as numbered parts.
void SGLogLong(NSString *tag, NSString *text) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSMutableString *current = [NSMutableString string];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (current.length && [current lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + [line lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 900) {
            [parts addObject:[current copy]];
            [current setString:@""];
        }
        [current appendFormat:@"%@\n", line];
    }
    if (current.length) [parts addObject:current];
    [parts enumerateObjectsUsingBlock:^(NSString *part, NSUInteger i, BOOL *stop) {
        SGLog(@"%@ %lu/%lu\n%@", tag, (unsigned long)i + 1, (unsigned long)parts.count, part);
    }];
}

void SGRequireClasses(NSArray<NSString *> *names) {
    for (NSString *name in names) {
        if (!NSClassFromString(name)) SGLog(@"class %@ not found, its hooks are inactive", name);
    }
}

NSURL *SGLogExportFileURL(void) {
    NSString *path = logPath();
    return path ? [NSURL fileURLWithPath:path] : nil;
}

uint64_t SGLogExportByteCount(void) {
    return atomic_load_explicit(&sg_bytes, memory_order_relaxed);
}

static void postChange(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:SGLogExportDidChangeNotification object:nil];
    });
}

void SGLogExportClear(void) {
    dispatch_async(logQueue(), ^{
        os_unfair_lock_lock(&sg_lock);
        [sg_inbox removeAllObjects];
        os_unfair_lock_unlock(&sg_lock);
        @try {
            NSString *path = logPath();
            if (path) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        } @catch (NSException *ex) {
        }
        storeSize(0);
        postChange();
    });
}

void SGLogExportSnapshot(void (^completion)(NSURL *url)) {
    if (!completion) return;
    dispatch_async(logQueue(), ^{
        NSURL *url = nil;
        @try {
            NSString *path = logPath();
            if (path && [NSFileManager.defaultManager fileExistsAtPath:path]) {
                NSString *dest = [NSTemporaryDirectory() stringByAppendingPathComponent:@"spotifyplus-log.txt"];
                [NSFileManager.defaultManager removeItemAtPath:dest error:nil];
                if ([NSFileManager.defaultManager copyItemAtPath:path toPath:dest error:nil]) url = [NSURL fileURLWithPath:dest];
            }
        } @catch (NSException *ex) {
            url = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(url); });
    });
}

__attribute__((constructor)) static void SGLogExportPrime(void) {
    dispatch_async(logQueue(), ^{
        @try {
            NSString *path = logPath();
            NSDictionary *attrs = path ? [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] : nil;
            storeSize([attrs fileSize]);
        } @catch (NSException *ex) {
            storeSize(0);
        }
        postChange();
    });
}
