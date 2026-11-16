// Hash-prefix lookup adapted from EeveeSpotifyReincarnated's GPL-3 SponsorBlockAPI (0d9feaa).
#import "SponsorBlock.h"

static const NSUInteger kMaximumResponseBytes = 2 * 1024 * 1024;

@interface SGSponsorBlockTransfer : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, copy) NSString *episodeID;
@property (nonatomic, copy) SGSponsorBlockReply reply;
@property (nonatomic, strong) NSMutableData *body;
@property (nonatomic) NSInteger status;
@end

@implementation SGSponsorBlockTransfer
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completion {
    completion(nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    self.status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    completion(response.expectedContentLength > (int64_t)kMaximumResponseBytes ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (data.length > kMaximumResponseBytes - self.body.length) { [task cancel]; return; }
    [self.body appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSArray *segments = error ? nil : SGSponsorBlockParse(self.body, self.status, self.episodeID);
    SGSponsorBlockReply reply = self.reply;
    self.reply = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ reply(segments); });
    [session finishTasksAndInvalidate];
}
@end

void SGSponsorBlockFetchSegments(NSString *episodeID, NSSet<NSString *> *categories, SGSponsorBlockReply reply) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSURLRequest *request = SGSponsorBlockRequest(episodeID, categories);
        if (!request) { dispatch_async(dispatch_get_main_queue(), ^{ reply(@[]); }); return; }
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.HTTPCookieStorage = nil;
        config.URLCredentialStorage = nil;
        config.URLCache = nil;
        config.timeoutIntervalForRequest = config.timeoutIntervalForResource = request.timeoutInterval;
        SGSponsorBlockTransfer *transfer = [SGSponsorBlockTransfer new];
        transfer.episodeID = episodeID; transfer.reply = reply; transfer.body = [NSMutableData data];
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:transfer delegateQueue:nil];
        [[session dataTaskWithRequest:request] resume];
    });
}
