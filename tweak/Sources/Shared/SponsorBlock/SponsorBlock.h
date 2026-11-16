#import <Foundation/Foundation.h>

#define SGKeySponsorBlock @"spotifyglass.sponsorblock.enabled"

NSArray<NSString *> *SGSponsorBlockCategories(void);
BOOL SGSponsorBlockCategoryDefault(NSString *category);
NSString *SGSponsorBlockCategoryKey(NSString *category);
NSString *SGSponsorBlockEpisodeID(NSString *uri);
NSURLRequest *SGSponsorBlockRequest(NSString *episodeID, NSSet<NSString *> *categories);

@interface SGSponsorBlockSegment : NSObject
@property (nonatomic, readonly) double start, end;
@property (nonatomic, readonly, copy) NSString *category, *uuid;
@end

// nil means a failed/malformed response; 404 is an empty, successful result.
NSArray<SGSponsorBlockSegment *> *SGSponsorBlockParse(NSData *data, NSInteger status, NSString *episodeID);
typedef void (^SGSponsorBlockReply)(NSArray<SGSponsorBlockSegment *> *segments);
typedef void (^SGSponsorBlockFetch)(NSString *episodeID, NSSet<NSString *> *categories, SGSponsorBlockReply reply);
// Network and parsing off main; completion on main.
void SGSponsorBlockFetchSegments(NSString *episodeID, NSSet<NSString *> *categories, SGSponsorBlockReply reply);

// Main-thread session owner. The fetch, seek and notice blocks are the external boundaries.
@interface SGSponsorBlockSession : NSObject
- (instancetype)initWithCategories:(NSSet<NSString *> *)categories
                             fetch:(SGSponsorBlockFetch)fetch
                              seek:(void (^)(double seconds))seek
                            notice:(void (^)(SGSponsorBlockSegment *segment, dispatch_block_t undo))notice;
- (void)observeURI:(NSString *)uri position:(double)position duration:(double)duration
          playing:(BOOL)playing enabled:(BOOL)enabled;
@end

@class SGModSection;
SGModSection *SGSponsorBlockSettingsSection(void);
