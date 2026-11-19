// Adapted from EeveeSpotifyReincarnated (GPL-3), SponsorBlockAPI/Hash/Segment/Options/
// Skipper at 0d9feaa (SponsorBlock also touched in 51cb2dc). Reporting and voting are not ported.
#import "SponsorBlock.h"
#import "Core/SGLog.h"
#import <CommonCrypto/CommonDigest.h>
#import <math.h>

NSArray<NSString *> *SGSponsorBlockCategories(void) {
    return @[@"sponsor", @"selfpromo", @"interaction", @"intro", @"outro", @"preview",
             @"hook", @"filler", @"exclusive_access"];
}

BOOL SGSponsorBlockCategoryDefault(NSString *category) {
    return [@[@"sponsor", @"selfpromo", @"interaction"] containsObject:category];
}

NSString *SGSponsorBlockCategoryKey(NSString *category) {
    return [@"spotifyglass.sponsorblock.category." stringByAppendingString:category];
}

NSString *SGSponsorBlockEpisodeID(NSString *uri) {
    if (![uri isKindOfClass:NSString.class]) return nil;
    NSString *identifier;
    if ([uri hasPrefix:@"spotify:episode:"]) identifier = [uri substringFromIndex:@"spotify:episode:".length];
    else {
        NSURLComponents *url = [NSURLComponents componentsWithString:uri];
        NSArray *parts = url.path.pathComponents;
        if (![url.scheme isEqualToString:@"https"] || ![url.host isEqualToString:@"open.spotify.com"] ||
            parts.count != 3 || ![parts[1] isEqualToString:@"episode"]) return nil;
        identifier = parts[2];
    }
    NSCharacterSet *base62 = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"];
    return identifier.length == 22 && [identifier rangeOfCharacterFromSet:base62.invertedSet].location == NSNotFound ? identifier : nil;
}

// Same six-second bound as Retrine's lyrics-source requests; this independent transport sends no
// Spotify headers, cookies or credentials, and refuses redirects.
static const NSTimeInterval kRequestTimeoutSeconds = 6;

NSURLRequest *SGSponsorBlockRequest(NSString *episodeID, NSSet<NSString *> *categories) {
    NSData *input = [episodeID dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(input.bytes, (CC_LONG)input.length, digest);
    NSString *prefix = [NSString stringWithFormat:@"%02x%02x%x", digest[0], digest[1], digest[2] >> 4];
    NSMutableArray *selected = [NSMutableArray array];
    for (NSString *category in SGSponsorBlockCategories())
        if ([categories containsObject:category]) [selected addObject:category];
    if (!selected.count) return nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:selected options:0 error:nil];
    NSURLComponents *url = [NSURLComponents componentsWithString:
        [@"https://sponsor.ajay.app/api/skipSegments/" stringByAppendingString:prefix]];
    url.queryItems = @[[NSURLQueryItem queryItemWithName:@"service" value:@"Spotify"],
        [NSURLQueryItem queryItemWithName:@"categories" value:[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url.URL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:kRequestTimeoutSeconds];
    request.HTTPShouldHandleCookies = NO;
    [request setValue:@"Retrine-SponsorBlock/1" forHTTPHeaderField:@"X-CLIENT-NAME"];
    return request;
}

@interface SGSponsorBlockSegment ()
@property (nonatomic) double start, end;
@property (nonatomic, copy) NSString *category, *uuid;
@end
@implementation SGSponsorBlockSegment
@end

static BOOL secondsValue(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]) && [value doubleValue] >= 0;
}

NSArray<SGSponsorBlockSegment *> *SGSponsorBlockParse(NSData *data, NSInteger status, NSString *episodeID) {
    if (status == 404) return @[];
    if (status < 200 || status >= 300 || !data.length) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id entry in json) {
        if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"videoID"] isEqual:episodeID]) continue;
        id segments = entry[@"segments"];
        if (![segments isKindOfClass:NSArray.class]) return nil;
        for (id row in segments) {
            if (![row isKindOfClass:NSDictionary.class]) continue;
            id pair = row[@"segment"], category = row[@"category"], uuid = row[@"UUID"];
            if (![pair isKindOfClass:NSArray.class] || [pair count] != 2 ||
                !secondsValue(pair[0]) || !secondsValue(pair[1]) ||
                ![category isKindOfClass:NSString.class] || ![SGSponsorBlockCategories() containsObject:category] ||
                ![uuid isKindOfClass:NSString.class] || ![uuid length] ||
                ![row[@"actionType"] isEqual:@"skip"] || [seen containsObject:uuid]) continue;
            double start = [pair[0] doubleValue], end = [pair[1] doubleValue];
            if (end <= start) continue;
            SGSponsorBlockSegment *segment = [SGSponsorBlockSegment new];
            segment.start = start; segment.end = end; segment.category = category; segment.uuid = uuid;
            [result addObject:segment];
            [seen addObject:uuid];
        }
    }
    return [result sortedArrayUsingComparator:^NSComparisonResult(SGSponsorBlockSegment *a, SGSponsorBlockSegment *b) {
        return a.start < b.start ? NSOrderedAscending : a.start > b.start ? NSOrderedDescending : NSOrderedSame;
    }];
}

// Eevee's minimum duration, end guard, seek padding and Undo lead-in, in seconds.
static const double kMinimumSegmentSeconds = 1, kEndGuardSeconds = 0.25;
static const double kSeekPaddingSeconds = 0.05, kUndoLeadSeconds = 0.25;

static BOOL selectedSegment(SGSponsorBlockSegment *segment, NSSet<NSString *> *categories, double duration) {
    return [categories containsObject:segment.category] &&
        segment.end - segment.start >= kMinimumSegmentSeconds && segment.end <= duration;
}

@implementation SGSponsorBlockSession {
    NSSet<NSString *> *_categories;
    SGSponsorBlockFetch _fetch;
    void (^_seek)(double);
    void (^_notice)(SGSponsorBlockSegment *, dispatch_block_t);
    NSMutableDictionary<NSString *, NSArray<SGSponsorBlockSegment *> *> *_cache;
    NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *_handled;
    NSMutableSet<NSString *> *_pending;
    NSString *_episode;
    NSUInteger _generation;
    BOOL _enabled;
    double _pendingSkipTargetSeconds;
}

- (instancetype)initWithCategories:(NSSet<NSString *> *)categories fetch:(SGSponsorBlockFetch)fetch
                              seek:(void (^)(double))seek
                            notice:(void (^)(SGSponsorBlockSegment *, dispatch_block_t))notice {
    if ((self = [super init])) {
        _categories = [categories copy]; _fetch = [fetch copy]; _seek = [seek copy]; _notice = [notice copy];
        _cache = [NSMutableDictionary dictionary]; _handled = [NSMutableDictionary dictionary];
        _pending = [NSMutableSet set];
        _pendingSkipTargetSeconds = NAN;
    }
    return self;
}

- (void)observeURI:(NSString *)uri position:(double)position duration:(double)duration
          playing:(BOOL)playing enabled:(BOOL)enabled {
    NSString *episode = SGSponsorBlockEpisodeID(uri);
    if (![_episode isEqual:episode] && (_episode || episode)) {
        _episode = episode;
        _generation++;
        _pendingSkipTargetSeconds = NAN;
    }
    _enabled = enabled;
    if (!enabled || !episode || !_categories.count) return;
    if (!_cache[episode] && ![_pending containsObject:episode]) {
        [_pending addObject:episode];
        __weak typeof(self) weakSelf = self;
        _fetch(episode, _categories, ^(NSArray<SGSponsorBlockSegment *> *segments) {
            typeof(self) self = weakSelf;
            if (!self) return;
            [self->_pending removeObject:episode];
            // Cache misses and failures too: one request and at most one failure log per episode/session.
            self->_cache[episode] = segments ?: @[];
            if (!segments) SGLog(@"SponsorBlock: request failed; this episode will not be retried this session");
        });
    }
    if (!playing || !isfinite(position) || position < 0 || !isfinite(duration) || duration <= 0) return;
    if (isfinite(_pendingSkipTargetSeconds)) {
        // Seeking is asynchronous. Only a report at/past the requested target settles it;
        // earlier positions cannot trigger another skip, including in disjoint older segments.
        if (position < _pendingSkipTargetSeconds) return;
        _pendingSkipTargetSeconds = NAN;
    }
    NSMutableSet *handled = _handled[episode];
    if (!handled) _handled[episode] = handled = [NSMutableSet set];
    NSArray<SGSponsorBlockSegment *> *segments = _cache[episode];
    for (NSUInteger i = 0; i < segments.count;) {
        SGSponsorBlockSegment *segment = segments[i++];
        if (!selectedSegment(segment, _categories, duration)) continue;
        double start = segment.start, end = segment.end;
        NSMutableSet *covered = [NSMutableSet setWithObject:segment.uuid];
        BOOL allHandled = [handled containsObject:segment.uuid];
        // The parser sorts by start. Include handled members too so a range's boundaries
        // never shrink after Undo; unselected/invalid segments cannot bridge separate ranges.
        while (i < segments.count && segments[i].start <= end) {
            SGSponsorBlockSegment *next = segments[i++];
            if (!selectedSegment(next, _categories, duration)) continue;
            end = MAX(end, next.end);
            [covered addObject:next.uuid];
            allHandled = allHandled && [handled containsObject:next.uuid];
        }
        if (allHandled || position < start || position >= end - kEndGuardSeconds) continue;
        // Mark the entire union before seeking. The target is ahead of this report and,
        // after the settlement gate above, cannot be behind an outstanding skip's target.
        [handled unionSet:covered];
        NSUInteger generation = _generation;
        _pendingSkipTargetSeconds = MIN(duration, end + kSeekPaddingSeconds);
        _seek(_pendingSkipTargetSeconds);
        __weak typeof(self) weakSelf = self;
        _notice(segment, ^{
            typeof(self) self = weakSelf;
            if (!self || !self->_enabled || self->_generation != generation || ![self->_episode isEqual:episode]) return;
            // Undo supersedes the forward seek. Every member remains handled for the session,
            // guaranteeing playthrough of the whole covered range, not just its first segment.
            self->_pendingSkipTargetSeconds = NAN;
            self->_seek(MAX(0, start - kUndoLeadSeconds));
        });
        return;
    }
}
@end
