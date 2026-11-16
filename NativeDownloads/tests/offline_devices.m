#import <Foundation/Foundation.h>
#import "OfflineDevices.h"
#import "WireProto.h"
#import "Localization.h"
#include <assert.h>
#include <stdlib.h>

#define CHECK(condition,message) do { if(!(condition)){fprintf(stderr,"FAIL: %s\n",message);exit(1);} } while(0)

// An in-memory Spotify registry. NSURLProtocol intercepts every HTTP request;
// these tests never authenticate to Spotify or change a real registration.
static NSMutableArray<NSMutableDictionary *> *devices;
static NSMutableArray *events,*requests;
static NSInteger maximum=5,freeSlots,failHTTP,nativeDeviceError;
static BOOL nativeMismatch,nativeDevicesUnavailable,ignoreDisable,malformedDevices,allowEnable=YES,enabledPlayback;
static NSUInteger commands,postCount;
static NSInteger failAfterPost=-1;
static NSDictionary *localOverride;
static NSString *lastError;
static NSDictionary *nativeState(void) {
    NSMutableArray *copy=[NSMutableArray array];
    for(NSDictionary *d in devices)[copy addObject:[d copy]];
    return @{@"status":@"complete",@"finished_at":@(NSDate.date.timeIntervalSince1970),@"sources":@{
        @"licenses":@{@"read_status":@"received",@"max_licenses":@(maximum),@"free_licenses":@(freeSlots+(nativeMismatch?1:0))},
        @"devices":@{@"read_status":nativeDevicesUnavailable?@"timeout":@"received",@"error":@(nativeDeviceError),@"devices":copy},
        @"local_device":@{@"read_status":@"received",@"device":localOverride?:[devices.lastObject copy]},
        @"playback":@{@"read_status":@"received",@"allowed":@(enabledPlayback)}}};
}
void SAPRefreshDownloadCompatibility(void (^reply)(NSDictionary *)) {reply(nativeState());}
void SAPJournalNoteAction(NSString *name,NSDictionary *facts) {[events addObject:@{@"name":name,@"facts":facts}];}
void SAPCallOfflineCommandOnce(NSString *method,NSData *payload,void (^reply)(NSData *,NSString *)) {
    assert([method isEqual:@"SetOfflinePlaybackAllowed"]);
    assert([payload isEqual:SAPProtoInteger(1,1)]);commands++;
    if(allowEnable){devices.lastObject[@"offline_enabled"]=@YES;enabledPlayback=YES;freeSlots--;}
    reply(SAPProtoInteger(1,1),nil);
}
static NSData *join(NSData *a,NSData *b) {NSMutableData *out=[a mutableCopy];[out appendData:b];return out;}
static NSData *string(unsigned field,NSString *value) {return SAPProtoBytes(field,[value dataUsingEncoding:NSUTF8StringEncoding]);}
static NSData *deviceResponse(void) {
    if(malformedDevices)return [NSData dataWithBytes:(uint8_t[]){0xff} length:1];
    NSMutableData *out=[NSMutableData data];
    for(NSDictionary *d in devices){
        NSData *body=join(string(1,d[@"device_id"]),string(2,d[@"cache_id"]));
        body=join(body,string(3,d[@"name"]));
        // Direct HTTPS schema differs from Esperanto: offline_enabled=6,
        // last_seen_at=10 (a nested Timestamp, not a bool).
        body=join(body,SAPProtoInteger(6,[d[@"offline_enabled"]boolValue]));
        body=join(body,SAPProtoBytes(10,SAPProtoInteger(1,1792520000)));
        [out appendData:SAPProtoBytes(1,body)];
    }
    return out;
}
@interface RegistryProtocol : NSURLProtocol @end
@implementation RegistryProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {return YES;}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {return request;}
- (void)startLoading {
    NSURLRequest *r=self.request;NSString *path=r.URL.path;
    assert([r.URL.host isEqual:@"spclient.wg.spotify.com"]);
    assert([[r valueForHTTPHeaderField:@"Authorization"]isEqual:@"Bearer TEST_ONLY_NOT_REAL"]);
    assert(![r valueForHTTPHeaderField:@"X-Private-Noise"]);
    [requests addObject:@{@"path":path,@"method":r.HTTPMethod}];
    NSInteger status=failHTTP?:200;NSData *data=NSData.data;
    if([r.HTTPMethod isEqual:@"POST"]){
        postCount++;assert([path hasSuffix:@"/disable"]);
        assert(r.HTTPBody.length==0);
        assert([r valueForHTTPHeaderField:@"Content-Type"]);
        NSArray *parts=path.pathComponents;
        assert(parts.count==8);
        if(!ignoreDisable && !failHTTP){
            BOOL found=NO;
            for(NSMutableDictionary *d in devices)if([d[@"device_id"]isEqual:parts[4]] && [d[@"cache_id"]isEqual:parts[6]]){
                assert([d[@"offline_enabled"]boolValue]);d[@"offline_enabled"]=@NO;freeSlots++;found=YES;
            }
            assert(found);
        }
        if(failAfterPost==(NSInteger)postCount)failHTTP=503;
        data=SAPProtoInteger(1,1);
    }else {
        assert([r.HTTPMethod isEqual:@"GET"]);
        if([path isEqual:@"/offline/v1/licenseStatus"])data=join(SAPProtoInteger(1,maximum),SAPProtoInteger(2,freeSlots));
        else {assert([path isEqual:@"/offline/v1/devices"]);data=deviceResponse();}
    }
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc]initWithURL:r.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"application/x-protobuf"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];[self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end
static void reset(NSUInteger active) {
    devices=[NSMutableArray array];events=[NSMutableArray array];requests=[NSMutableArray array];
    maximum=5;freeSlots=5-active;commands=postCount=0;failHTTP=nativeDeviceError=0;failAfterPost=-1;
    nativeMismatch=nativeDevicesUnavailable=ignoreDisable=malformedDevices=enabledPlayback=NO;allowEnable=YES;
    localOverride=nil;lastError=nil;
    for(NSUInteger i=0;i<active;i++)[devices addObject:[@{@"device_id":[NSString stringWithFormat:@"old-device-%lu",i],@"cache_id":[NSString stringWithFormat:@"old-cache-%lu",i],@"name":@"iPhone",@"offline_enabled":@YES}mutableCopy]];
    [devices addObject:[@{@"device_id":@"current-device",@"cache_id":@"current-cache",@"name":@"Current iPhone",@"offline_enabled":@NO}mutableCopy]];
    SAPOfflineDevicesTestEnvironment(RegistryProtocol.class,^(void (^reply)(NSDictionary *)){
        reply(@{@"Authorization":@"Bearer TEST_ONLY_NOT_REAL",@"X-Private-Noise":@"do not forward"});
    });
}
static void waitFor(BOOL (^condition)(void)) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
    while(!condition() && deadline.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
    assert(condition());
}
static NSDictionary *preview(BOOL success) {
    __block BOOL done=NO;__block NSDictionary *plan;__block NSString *error;
    SAPPreviewOfflineDeviceSlots(^(NSDictionary *p,NSString *e){plan=p;error=e;lastError=e;done=YES;});waitFor(^BOOL{return done;});
    assert(success?(plan!=nil && error==nil):(error!=nil));assert(postCount==0);return plan;
}
static NSDictionary *release(NSDictionary *plan,NSArray *ids,BOOL success) {
    __block BOOL done=NO;__block NSDictionary *result;__block NSString *error;
    SAPReleaseOfflineDeviceSlots(plan[@"id"],ids,^(NSDictionary *r,NSString *e){result=r;error=e;lastError=e;done=YES;});waitFor(^BOOL{return done;});
    if(success)assert(result!=nil && error==nil);else assert(error!=nil);
    return result;
}
static NSDictionary *enable(BOOL success) {
    __block BOOL done=NO;__block NSString *error;__block NSDictionary *result;
    SAPEnableOfflineOnCurrentDevice(^(NSDictionary *r,NSString *e){result=r;error=e;lastError=e;done=YES;});waitFor(^BOOL{return done;});
    assert(success?error==nil:error!=nil);
    return result;
}
static NSString *token(NSDictionary *plan,NSUInteger row) {return plan[@"active_devices"][row][@"selection_token"];}
static void exactSelection(void) {
    reset(2);devices[1][@"cache_id"]=@"old-cache-0";
    NSDictionary *plan=preview(YES);NSString *picked=token(plan,1);
    [devices exchangeObjectAtIndex:0 withObjectAtIndex:1];
    __block BOOL done=NO;__block NSString *selectionError;
    SAPReleaseOfflineDeviceSlots(plan[@"id"],@[picked],^(NSDictionary *r,NSString *e){selectionError=e;done=YES;});
    waitFor(^BOOL{return done;});
    CHECK(!selectionError && postCount==1 && ![devices[0][@"offline_enabled"]boolValue] && [devices[1][@"offline_enabled"]boolValue],
          "exact selection token disables only the picked device despite shared cache IDs and reordered registry");
    CHECK([requests[4][@"path"]isEqual:@"/offline/v1/devices/old-device-1/cache/old-cache-0/disable"],"POST uses the picked device/cache pair");
    NSString *text=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:events options:0 error:nil] encoding:NSUTF8StringEncoding];
    CHECK(![text containsString:picked] && ![text containsString:@"old-device"] && ![text containsString:@"old-cache"] &&
          ![text containsString:@"current-device"] && ![text containsString:@"TEST_ONLY_NOT_REAL"],"audit snapshots contain no selection tokens, identifiers or credentials");
    puts("PASS: exact selected pair survives shared cache IDs and reordering; diagnostic snapshots are identifier-free");
}
static BOOL deviceReadErrorBlocksRelease(BOOL afterReview) {
    reset(2);
    NSDictionary *plan=afterReview?preview(YES):nil;
    nativeDeviceError=7;
    __block BOOL done=NO;__block NSDictionary *result;__block NSString *error;
    void (^reply)(NSDictionary *,NSString *)=^(NSDictionary *r,NSString *e){result=r;error=e;done=YES;};
    if(afterReview)SAPReleaseOfflineDeviceSlots(plan[@"id"],@[token(plan,0)],reply);
    else SAPPreviewOfflineDeviceSlots(reply);
    waitFor(^BOOL{return done;});
    BOOL rejected=postCount==0 && error.length>0 && ![result[@"actions_allowed"]boolValue] &&
        [result[@"state_summary"]length]>0 && [error containsString:result[@"state_summary"]] &&
        [events.lastObject[@"facts"][@"state_snapshot"]isEqual:result[@"state_snapshot"]];
    for(NSDictionary *device in result[@"active_devices"])if(device[@"selection_token"])rejected=NO;
    if(!rejected)fprintf(stderr,"FAIL: GetDevices error with matching records must block %s and return an explanatory snapshot (POSTs=%lu)\n",
        afterReview?"fresh disable validation":"preview tokens",(unsigned long)postCount);
    return rejected;
}
int main(void) {@autoreleasepool {
    BOOL previewRejected=deviceReadErrorBlocksRelease(NO);
    BOOL disableRejected=deviceReadErrorBlocksRelease(YES);
    CHECK(previewRejected&&disableRejected,"device errors cannot authorize offline-device changes");
    puts("PASS: GetDevices errors with matching records block preview tokens and fresh disable validation with explanatory snapshots");
    exactSelection();
    reset(5);NSDictionary *plan=preview(YES);assert([plan[@"active_devices"]count]==5);
    assert([plan[@"active_devices"][0][@"last_seen_at"]longLongValue]==1792520000);
    assert(requests.count==2);
    NSDictionary *result=release(plan,@[token(plan,0)],YES);
    assert(postCount==1 && freeSlots==1 && [result[@"free_licenses"]integerValue]==1);
    release(plan,@[token(plan,0)],NO);assert(postCount==1); // Consumed once.
    enable(YES);assert(commands==1 && freeSlots==0);enable(YES);assert(commands==1);
    puts("PASS: preview is read-only; release requires fresh state and verified readback; enabling consumes one slot, with no duplicate command");

    reset(5);plan=preview(YES);
    NSMutableArray *ids=[NSMutableArray array];for(NSDictionary *d in plan[@"active_devices"])[ids addObject:d[@"selection_token"]];
    result=release(plan,ids,YES);assert(postCount==5 && freeSlots==5 && [result[@"released_cache_ids"]count]==5);
    NSData *audit=[NSJSONSerialization dataWithJSONObject:events options:0 error:nil];
    NSString *text=[[NSString alloc]initWithData:audit encoding:NSUTF8StringEncoding];
    assert(![text containsString:@"TEST_ONLY_NOT_REAL"] && ![text containsString:@"Authorization"]);
    puts("PASS: five real registry changes produce five verified free slots; credentials are absent from audit facts");

    reset(5);plan=preview(YES);ignoreDisable=YES;
    result=release(plan,@[token(plan,0)],NO);assert(postCount==1 && freeSlots==0 && [result[@"status"]isEqual:@"unconfirmed"]);
    CHECK([lastError containsString:@"Last observed state"] && [lastError containsString:@"This copy"],"disable failure explains the observed device state");
    CHECK([result[@"state_snapshot"][@"command_sent"]boolValue] && [result[@"state_snapshot"][@"direct_observed_after_command"]boolValue],"failure snapshot distinguishes command and readback");
    reset(5);plan=preview(YES);failAfterPost=1;
    result=release(plan,@[token(plan,0),token(plan,1)],NO);assert(postCount==1 && freeSlots==1);
    CHECK(![result[@"state_snapshot"][@"direct_observed_after_command"]boolValue],"failed readback must not look like a post-command observation");
    puts("PASS: HTTP acknowledgement without state change and failure after POST never become success or trigger another POST");

    reset(5);plan=preview(YES);devices[0][@"offline_enabled"]=@NO;freeSlots++;
    release(plan,@[token(plan,1)],NO);assert(postCount==0);
    reset(5);plan=preview(YES);release(plan,@[@"unreviewed"],NO);assert(postCount==0);
    reset(5);plan=preview(YES);release(plan,@[token(plan,0),token(plan,0)],NO);assert(postCount==0);
    reset(5);nativeMismatch=YES;result=preview(NO);assert(postCount==0);
    CHECK([result[@"state_snapshot"][@"free_licenses"]integerValue]==0 && [result[@"state_snapshot"][@"native_free_licenses"]integerValue]==1,"mismatch snapshot preserves both disagreeing quota observations");
    reset(5);nativeDevicesUnavailable=YES;result=preview(NO);
    CHECK([result[@"state_snapshot"][@"native_read_status"]isEqual:@"unavailable"],"missing native device observations must not be described as received");
    reset(5);devices.lastObject[@"name"]=@"PRIVATE_NAME";failHTTP=403;result=preview(NO);assert(postCount==0);
    text=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:events options:0 error:nil] encoding:NSUTF8StringEncoding];
    CHECK(![lastError containsString:@"PRIVATE_NAME"] && ![lastError containsString:@"current-cache"] &&
          ![text containsString:@"PRIVATE_NAME"] && ![text containsString:@"current-device"] && ![text containsString:@"TEST_ONLY_NOT_REAL"],
          "failure messages and diagnostic snapshots exclude private names, identifiers and credentials");
    reset(5);malformedDevices=YES;preview(NO);assert(postCount==0);
    reset(5);SAPOfflineDevicesTestEnvironment(RegistryProtocol.class,^(void (^reply)(NSDictionary *)){reply(@{});});preview(NO);assert(requests.count==0);
    puts("PASS: stale selection, unknown/duplicate IDs, native/direct mismatch, denied authentication and malformed replies block mutation");

    reset(5);enable(NO);assert(commands==0);
    reset(4);allowEnable=NO;result=enable(NO);assert(commands==1 && !enabledPlayback);
    CHECK([lastError containsString:@"This copy"] && [result[@"state_snapshot"][@"command_sent"]boolValue],"registration failure includes the last observed device state");
    CHECK([events.lastObject[@"facts"][@"state_snapshot"]isEqual:result[@"state_snapshot"]],"diagnostics record the same safe failure snapshot");
    puts("PASS: zero slots block enable; an acknowledged enable still needs confirmed registration and offline playback status");

    reset(2);plan=preview(YES);NSString *picked=token(plan,0);NSDictionary *fresh=preview(YES);
    release(fresh,@[picked],NO);CHECK(postCount==0,"a token from another preview cannot select a device");
    reset(2);plan=preview(YES);release(plan,@[@"old-cache-0"],NO);CHECK(postCount==0,"raw cache IDs cannot authorize a disable");
    reset(2);[devices addObject:[devices[0]mutableCopy]];preview(NO);CHECK(postCount==0,"duplicate device/cache identities cannot authorize mutation");
    reset(2);devices[0][@"device_id"]=@"a/b";devices[0][@"cache_id"]=@"c";
    plan=preview(YES);devices[0][@"device_id"]=@"a";devices[0][@"cache_id"]=@"b/c";
    release(plan,@[token(plan,0)],NO);CHECK(postCount==0,"delimiter collisions cannot disguise a replaced device/cache pair");
    puts("PASS: tokens are preview-bound; raw caches, duplicate identities and replaced pairs are rejected");

    reset(1);devices.lastObject[@"offline_enabled"]=@YES;freeSlots--;
    plan=preview(YES);
    CHECK([plan[@"active_devices"][1][@"is_current_device"]boolValue] && ![plan[@"active_devices"][0][@"is_current_device"]boolValue],"registered current copy is distinguished from other copies");
    reset(0);localOverride=[devices.lastObject copy];[devices removeAllObjects];
    plan=preview(YES);
    CHECK([plan[@"active_devices"]count]==0 && [plan[@"devices"]count]==1 &&
          [plan[@"devices"][0][@"registration_status"]isEqual:@"not_registered"] &&
          !plan[@"devices"][0][@"selection_token"] && [plan[@"state_summary"]containsString:@"Not registered"],
          "an unregistered local copy remains visible but cannot be selected");
    puts("PASS: current, other and unregistered copies remain visible, including an empty registry");
}return 0;}
