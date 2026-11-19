#import <Foundation/Foundation.h>
#import "Shared/SponsorBlock/SponsorBlock.h"
#import <math.h>

static NSString *const kEpisode = @"0123456789ABCDEFGHIJKL";
static NSString *const kURI = @"spotify:episode:0123456789ABCDEFGHIJKL";
static NSData *fixture;
#define CHECK(test, message) do { if (!(test)) { NSLog(@"FAIL: %s", message); return NO; } } while (0)

// Only the external fetch, seek and notice boundaries are doubled; parser and session are production.
@interface SBProbe : NSObject
@property (nonatomic, strong) SGSponsorBlockSession *session;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *seeks;
@property (nonatomic, strong) NSMutableArray<NSString *> *requests;
@property (nonatomic, copy) dispatch_block_t undo;
@property (nonatomic, copy) SGSponsorBlockReply pendingReply;
@property (nonatomic) BOOL deferReply;
- (instancetype)initWithStatus:(NSInteger)status categories:(NSSet *)categories body:(NSData *)body;
- (void)at:(double)position;
@end
@implementation SBProbe
- (instancetype)initWithStatus:(NSInteger)status categories:(NSSet *)categories body:(NSData *)body {
    if ((self = [super init])) {
        _seeks = [NSMutableArray array]; _requests = [NSMutableArray array];
        __weak SBProbe *weak = self;
        _session = [[SGSponsorBlockSession alloc] initWithCategories:categories
            fetch:^(NSString *episode, NSSet *selected, SGSponsorBlockReply reply) {
                SBProbe *probe = weak;
                [probe.requests addObject:episode];
                if (probe.deferReply) probe.pendingReply = reply;
                else reply(SGSponsorBlockParse(body, status, episode));
            } seek:^(double seconds) { [weak.seeks addObject:@(seconds)]; }
            notice:^(SGSponsorBlockSegment *segment, dispatch_block_t undo) { weak.undo = undo; }];
    }
    return self;
}
- (void)at:(double)position {
    [self.session observeURI:kURI position:position duration:120 playing:YES enabled:YES];
}
@end

static SBProbe *probe(NSInteger status) {
    return [[SBProbe alloc] initWithStatus:status categories:[NSSet setWithObject:@"sponsor"] body:fixture];
}

static SBProbe *probeWithRanges(NSArray<NSArray<NSNumber *> *> *ranges) {
    NSMutableArray *segments = [NSMutableArray array];
    for (NSArray *range in ranges) {
        [segments addObject:@{@"segment": range, @"category": @"sponsor", @"actionType": @"skip",
                              @"UUID": [NSString stringWithFormat:@"segment-%lu", (unsigned long)segments.count]}];
    }
    NSData *body = [NSJSONSerialization dataWithJSONObject:@[@{@"videoID": kEpisode, @"segments": segments}]
        options:0 error:nil];
    return [[SBProbe alloc] initWithStatus:200 categories:[NSSet setWithObject:@"sponsor"] body:body];
}

static BOOL overlappingStaleReport(void) {
    SBProbe *p = probeWithRanges(@[@[@10, @30], @[@15, @20]]);
    [p at:16];
    dispatch_block_t undo = p.undo;
    [p at:16];
    CHECK([p.seeks isEqual:@[@30.05]] && p.undo == undo,
          "nested overlap plus stale report must not rewind playback or replace Undo");
    return YES;
}

static BOOL pendingSkipTarget(void) {
    SBProbe *p = probeWithRanges(@[@[@1, @8], @[@10, @30], @[@50, @60]]);
    [p at:16];
    [p at:4];
    CHECK([p.seeks isEqual:@[@30.05]], "pending forward seek ignores stale positions in an older unhandled range");
    [p at:30.05];
    [p at:50];
    CHECK(([p.seeks isEqual:@[@30.05, @60.05]]), "settled skip permits a later forward skip");
    return YES;
}

static BOOL mergedChain(void) {
    SBProbe *p = probeWithRanges(@[@[@10, @30], @[@28, @40]]);
    [p at:16];
    CHECK([p.seeks isEqual:@[@40.05]], "overlapping chain skips once to its furthest end plus existing seek padding");
    return YES;
}

static BOOL adjacentChain(void) {
    SBProbe *p = probeWithRanges(@[@[@10, @30], @[@28, @40], @[@40, @45]]);
    [p at:16];
    CHECK([p.seeks isEqual:@[@45.05]], "adjacent selected segment extends the full transitive range");
    return YES;
}

static BOOL mergedUndo(void) {
    SBProbe *p = probeWithRanges(@[@[@10, @30], @[@28, @40]]);
    [p at:16];
    [p at:40.05];
    p.undo();
    [p at:9.75]; [p at:16]; [p at:29]; [p at:35]; [p at:40.05];
    CHECK(([p.seeks isEqual:@[@40.05, @9.75]]), "Undo of a settled merged skip plays through both segments");
    return YES;
}

static BOOL laterSegmentAfterUndo(void) {
    SBProbe *p = probeWithRanges(@[@[@10, @30], @[@28, @40], @[@50, @60]]);
    [p at:16];
    p.undo();
    [p at:16]; [p at:35]; [p at:40.05]; [p at:50];
    CHECK(([p.seeks isEqual:@[@40.05, @9.75, @60.05]]),
          "Undo supersedes pending seek but does not suppress a non-overlapping later segment");
    return YES;
}

static BOOL parsing(void) {
    NSArray<SGSponsorBlockSegment *> *segments = SGSponsorBlockParse(fixture, 200, kEpisode);
    CHECK(segments.count == 4, "parser rejects malformed, non-skip and duplicate segments");
    CHECK(([[segments valueForKey:@"uuid"] isEqual:@[@"sponsor", @"intro", @"too-short", @"selfpromo"]]),
          "segments sorted by start, only full episode-ID matches");
    CHECK(segments[0].start == 10 && segments[0].end == 20, "API seconds survive parsing");
    CHECK(!SGSponsorBlockParse([@"{}" dataUsingEncoding:NSUTF8StringEncoding], 200, kEpisode),
          "malformed API envelope fails closed");
    return YES;
}

static BOOL categories(void) {
    SBProbe *p = probe(200);
    [p at:30];
    CHECK(!p.seeks.count, "unselected intro category does not skip");
    [p at:10];
    CHECK([p.seeks isEqual:@[@20.05]], "selected sponsor category skips");
    return YES;
}

static BOOL segmentStart(void) {
    SBProbe *p = probe(200);
    [p at:9.99];
    CHECK(!p.seeks.count, "does not skip before segment start");
    [p at:10];
    CHECK([p.seeks isEqual:@[@20.05]] && p.undo != nil, "segment start seeks and offers Undo");
    return YES;
}

static BOOL undoOnce(void) {
    SBProbe *p = probe(200);
    [p at:10];
    p.undo();
    [p at:10]; [p at:11];
    CHECK(([p.seeks isEqual:@[@20.05, @9.75]]), "Undo seeks back and never re-skips the segment");
    return YES;
}

static BOOL staleReports(void) {
    SBProbe *p = probe(200);
    [p at:10]; [p at:10]; [p at:11];
    [p.session observeURI:@"spotify:track:abcdefghijklmnopqrstuv" position:10 duration:120 playing:YES enabled:YES];
    [p at:10];
    CHECK([p.seeks isEqual:@[@20.05]], "stale reports and episode revisits cannot repeat a skip");
    CHECK([p.requests isEqual:@[kEpisode]], "episode revisit reuses session response");
    return YES;
}

static BOOL offAndMusic(void) {
    SBProbe *p = probe(200);
    [p.session observeURI:kURI position:10 duration:120 playing:YES enabled:NO];
    [p.session observeURI:@"spotify:track:0123456789ABCDEFGHIJKL" position:10 duration:120 playing:YES enabled:YES];
    [p.session observeURI:@"https://example.com/episode/0123456789ABCDEFGHIJKL" position:10 duration:120 playing:YES enabled:YES];
    CHECK(!p.requests.count && !p.seeks.count, "off and non-episodes send no requests and never seek");
    return YES;
}

static BOOL failure(void) {
    SBProbe *p = probe(503);
    [p at:10]; [p at:11];
    [p.session observeURI:nil position:0 duration:0 playing:NO enabled:YES];
    [p at:10];
    CHECK(!p.seeks.count && !p.undo, "API failure cannot skip or show a notice");
    CHECK([p.requests isEqual:@[kEpisode]], "failed request stays cached across revisits");
    return YES;
}

static BOOL emptyResponse(void) {
    SBProbe *p = probe(404);
    [p at:10]; [p at:11];
    CHECK(!p.seeks.count && [p.requests isEqual:@[kEpisode]], "404 is a cached empty response");
    return YES;
}

static BOOL staleReplyAndUndo(void) {
    SBProbe *p = probe(200);
    p.deferReply = YES;
    [p at:10];
    [p.session observeURI:@"spotify:track:abcdefghijklmnopqrstuv" position:10 duration:120 playing:YES enabled:YES];
    p.pendingReply(SGSponsorBlockParse(fixture, 200, kEpisode));
    CHECK(!p.seeks.count, "late episode response cannot seek music");
    [p at:10];
    dispatch_block_t oldUndo = p.undo;
    [p.session observeURI:@"spotify:episode:abcdefghijklmnopqrstuv" position:10 duration:120 playing:YES enabled:YES];
    oldUndo();
    [p at:10];
    oldUndo();
    CHECK([p.seeks isEqual:@[@20.05]], "Undo cannot act on another episode or a later visit");
    return YES;
}

static BOOL safetyBoundaries(void) {
    SBProbe *p = probe(200);
    [p at:19.75]; [p at:50];
    [p.session observeURI:kURI position:10 duration:120 playing:NO enabled:YES];
    [p.session observeURI:kURI position:10 duration:15 playing:YES enabled:YES];
    [p at:NAN];
    CHECK(!p.seeks.count, "end guard, short segment, pause, duration mismatch and invalid clock never skip");
    return YES;
}

static BOOL requestPrivacy(void) {
    CHECK([SGSponsorBlockEpisodeID(@"https://open.spotify.com/episode/0123456789ABCDEFGHIJKL?si=tracking") isEqual:kEpisode],
          "Spotify web episode URL maps to bare ID");
    NSURLRequest *request = SGSponsorBlockRequest(kEpisode, [NSSet setWithObject:@"sponsor"]);
    CHECK([request.URL.path isEqual:@"/api/skipSegments/83fc0"], "request sends five SHA-256 hex characters, not episode ID");
    NSURLComponents *url = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in url.queryItems) query[item.name] = item.value;
    CHECK(([query isEqual:@{@"service": @"Spotify", @"categories": @"[\"sponsor\"]"}]), "request contains only required mapping and categories");
    CHECK(!request.HTTPShouldHandleCookies && request.HTTPBody == nil &&
          [request.allHTTPHeaderFields isEqual:@{@"X-CLIENT-NAME": @"Retrine-SponsorBlock/1"}],
          "no account headers, cookies or request body");
    return YES;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2 || !(fixture = [NSData dataWithContentsOfFile:@(argv[1])])) {
            NSLog(@"FAIL: API fixture required"); return 1;
        }
        BOOL (*tests[])(void) = {parsing, categories, segmentStart, undoOnce, staleReports, offAndMusic,
                                failure, emptyResponse, staleReplyAndUndo, safetyBoundaries, requestPrivacy,
                                overlappingStaleReport, pendingSkipTarget, mergedChain, adjacentChain,
                                mergedUndo, laterSegmentAfterUndo};
        NSUInteger failed = 0;
        for (NSUInteger i = 0; i < sizeof(tests) / sizeof(*tests); i++) if (!tests[i]()) failed++;
        NSLog(@"SponsorBlock: %lu checks, %lu failed", (unsigned long)(sizeof(tests) / sizeof(*tests)), (unsigned long)failed);
        return failed ? 1 : 0;
    }
}
