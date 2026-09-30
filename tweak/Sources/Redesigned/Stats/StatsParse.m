#import "StatsParse.h"

@implementation SGRStatsTile
@end

@implementation SGRStatsSummary
@end

static NSString *trimmed(NSString *text) {
    NSString *out = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([out hasSuffix:@","] || [out hasSuffix:@"."]) {
        out = [[out substringToIndex:out.length - 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    return out;
}

static NSString *group(NSRegularExpression *regex, NSString *text, NSUInteger index) {
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match || index >= match.numberOfRanges) return nil;
    NSRange range = [match rangeAtIndex:index];
    return range.location == NSNotFound ? nil : [text substringWithRange:range];
}

static NSRegularExpression *pattern(NSString *source) {
    return [NSRegularExpression regularExpressionWithPattern:source options:NSRegularExpressionCaseInsensitive error:nil];
}

SGRStatsTile *SGRStatsParseTile(NSString *label) {
    if (![label isKindOfClass:NSString.class] || label.length < 8) return nil;
    SGRStatsTile *tile = [SGRStatsTile new];

    if ([label hasPrefix:@"Minuti di ascolto, "]) {
        static NSRegularExpression *minutes, *rank;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            minutes = pattern(@"^Minuti di ascolto,\\s*(\\d[\\d.,]*)");
            rank = pattern(@"numero\\s+(\\d+)");
        });
        NSString *value = trimmed(group(minutes, label, 1) ?: @"");
        if (!value.length) return nil;
        tile.kind = SGRStatsTileMinutes;
        tile.title = @"Minuti di ascolto";
        tile.value = value;
        tile.friendRank = [group(rank, label, 1) integerValue];
        return tile;
    }

    if ([label hasPrefix:@"Artista preferito, "]) {
        NSString *name = trimmed([label substringFromIndex:@"Artista preferito, ".length]);
        if (!name.length) return nil;
        tile.kind = SGRStatsTileFavoriteArtist;
        tile.title = @"Artista preferito";
        tile.value = name;
        return tile;
    }

    if ([label hasPrefix:@"Gli artisti top con gli amici, "]) {
        NSString *name = trimmed([label substringFromIndex:@"Gli artisti top con gli amici, ".length]);
        if (!name.length) return nil;
        tile.kind = SGRStatsTileFriendsArtists;
        tile.title = @"Artisti top con gli amici";
        tile.value = name;
        return tile;
    }

    if ([label hasPrefix:@"I brani top con gli amici, "]) {
        NSString *rest = [label substringFromIndex:@"I brani top con gli amici, ".length];
        NSRange rising = [rest rangeOfString:@". In ascesa" options:NSBackwardsSearch | NSAnchoredSearch | NSCaseInsensitiveSearch];
        if (rising.location != NSNotFound) {
            tile.rising = YES;
            rest = [rest substringToIndex:rising.location];
        }
        NSString *title = trimmed(rest);
        if (!title.length) return nil;
        tile.kind = SGRStatsTileFriendsTracks;
        tile.title = @"Brani top con gli amici";
        tile.value = title;
        return tile;
    }

    if ([label hasPrefix:@"Brano preferito, "]) {
        static NSRegularExpression *move;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ move = pattern(@",\\s*Questo brano (sale|scende) di (\\d+) posizion"); });
        NSString *rest = [label substringFromIndex:@"Brano preferito, ".length];
        NSTextCheckingResult *match = [move firstMatchInString:rest options:0 range:NSMakeRange(0, rest.length)];
        if (match) {
            NSInteger places = [[rest substringWithRange:[match rangeAtIndex:2]] integerValue];
            BOOL up = [[[rest substringWithRange:[match rangeAtIndex:1]] lowercaseString] isEqualToString:@"sale"];
            tile.movement = up ? places : -places;
            tile.rising = up;
            rest = [rest substringToIndex:match.range.location];
        }
        NSString *title = trimmed(rest);
        if (!title.length) return nil;
        tile.kind = SGRStatsTileFavoriteTrack;
        tile.title = @"Brano preferito";
        tile.value = title;
        return tile;
    }
    return nil;
}

SGRStatsSummary *SGRStatsParseSummary(NSString *line) {
    if (![line isKindOfClass:NSString.class] || line.length < 4 || line.length > 120) return nil;
    static NSRegularExpression *count;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ count = pattern(@"(\\d[\\d.,]*)\\s+(minuti|brani|artisti)\\b"); });
    NSString *number = group(count, line, 1);
    NSString *unit = group(count, line, 2);
    if (!number.length || !unit.length) return nil;
    SGRStatsSummary *summary = [SGRStatsSummary new];
    summary.number = trimmed(number);
    summary.unit = unit.lowercaseString;
    return summary;
}
