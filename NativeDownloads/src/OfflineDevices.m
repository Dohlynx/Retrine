#import "Localization.h"
#import "OfflineDevices.h"
#import "DownloadCompatibility.h"
#import "TrackDownload.h"
#import "TrackJournal.h"
#import "WireProto.h"
#import "Deadline.h"
#import "DiagnosticTrace.h"
#import <dlfcn.h>

// Route fragments and POST are verified in the supplied Spotify 9.1.90:
// device path 0x105458100, /disable 0x101d0346c, caller 0x10224bd78.
// No local LicenseStatus response or device identifier is rewritten.
static NSDictionary *lastPlan;
static BOOL slotOperationActive;
static const NSTimeInterval reviewLifetimeSeconds=90;
static const NSUInteger maxIdentityLength=512;
static NSString *deviceKey(NSDictionary *device);
static NSDictionary *deviceSnapshot(NSDictionary *registry,NSDictionary *native,BOOL actionable);
static NSDictionary *safeSnapshot(NSDictionary *snapshot);
static NSString *snapshotSummary(NSDictionary *snapshot);
#ifdef SAP_TESTING
static Class testProtocol;
static void (^testHeaders)(void (^)(NSDictionary *));
void SAPOfflineDevicesTestEnvironment(Class protocolClass,void (^provider)(void (^)(NSDictionary *))) {
    testProtocol=protocolClass;testHeaders=[provider copy];
}
#endif
@interface SAPSlotRequest : NSObject <NSURLSessionTaskDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSDictionary *headers,*native,*plan,*registry;
@property(nonatomic,strong) dispatch_source_t deadline;
@property(nonatomic,copy) void (^completion)(NSDictionary *,NSString *);
@property(nonatomic) BOOL finished;
@property(nonatomic,strong) NSMutableArray *released;
@property(nonatomic,strong) NSArray *selected;
@property(nonatomic) NSUInteger index;
@property(nonatomic) SAPTraceID traceOperation;
@property(nonatomic) BOOL commandSent,registryAfterCommand;
- (void)finish:(NSDictionary *)result error:(NSString *)error;
- (void)request:(NSString *)path method:(NSString *)method completion:(void (^)(NSData *,NSInteger,NSString *))reply;
@end
static NSMutableSet<SAPSlotRequest *> *slotRequests;
@implementation SAPSlotRequest
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    // These fixed account-management routes must not forward credentials or a
    // POST to an unreviewed redirect, even on another Spotify hostname.
    completionHandler(nil);
}
- (void)finish:(NSDictionary *)result error:(NSString *)error {
    if(self.finished)return;self.finished=YES;
    if(self.deadline){dispatch_source_cancel(self.deadline);self.deadline=nil;}
    [self.session invalidateAndCancel];self.session=nil;self.headers=nil;
    slotOperationActive=NO;
    NSDictionary *snapshot=result[@"actions_allowed"]?result:
        (self.registry||self.native?deviceSnapshot(self.registry,self.native,NO):self.plan?:deviceSnapshot(nil,nil,NO));
    NSMutableDictionary *safe=[safeSnapshot(snapshot) mutableCopy];
    safe[@"command_sent"]=@(self.commandSent);
    safe[@"direct_observed_after_command"]=@(self.registryAfterCommand);
    safe[@"selected_count"]=@(self.selected.count);safe[@"released_count"]=@(self.released.count);
    NSMutableDictionary *value=[(result?:@{}) mutableCopy];
    value[@"state_snapshot"]=safe;
    value[@"state_summary"]=snapshotSummary(snapshot);
    if(error)error=[NSString stringWithFormat:@"%@\n\n%@",error,value[@"state_summary"]];
    NSDictionary *facts=@{@"error":error?:@"",@"state_snapshot":safe};
    SAP_TRACE("offline_devices","operation_finished",self.traceOperation,facts);
    SAPJournalNoteAction(@"offline_slot_operation_finished",facts);
    void (^done)(NSDictionary *,NSString *)=self.completion;self.completion=nil;
    [slotRequests removeObject:self];if(done)done(value,error);
}
- (void)request:(NSString *)path method:(NSString *)method completion:(void (^)(NSData *,NSInteger,NSString *))reply {
    if(self.finished)return;
    NSURL *url=[NSURL URLWithString:[@"https://spclient.wg.spotify.com/"stringByAppendingString:path]];
    if(![url.host isEqual:@"spclient.wg.spotify.com"] || ![url.scheme isEqual:@"https"]){reply(nil,0,SAPL(@"settings.pixie.devices.error.invalid_url",@"Invalid management URL"));return;}
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12];
    request.HTTPMethod=method;
    [self.headers enumerateKeysAndObjectsUsingBlock:^(id key,id value,BOOL *stop){
        if([key isKindOfClass:NSString.class]&&[value isKindOfClass:NSString.class])[request setValue:value forHTTPHeaderField:key];
    }];
    [request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Accept"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    if([method isEqual:@"POST"]){request.HTTPBody=NSData.data;[request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];}
    NSString *route=[method isEqual:@"POST"]?@"offline/v1/devices/<device>/cache/<cache>/disable":path;
    SAPJournalNoteAction(@"offline_slot_http_sent",@{@"method":method,@"path":route});
    __block SAPTraceID trace=0;
    SAPTraceWithOperation(self.traceOperation,^{if(SAPTraceIsActive())trace=SAPTraceBegin(@"management_https_request",@"pixie",@{@"method":method,@"host":@"spclient.wg.spotify.com",@"path":route,@"mutating":@([method isEqual:@"POST"]),@"automatic_replay":@NO});});
    __weak SAPSlotRequest *weakSelf=self;
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{
            SAPSlotRequest *self=weakSelf;if(!self||self.finished)return;
            NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;
            SAPJournalNoteAction(@"offline_slot_http_reply",@{@"method":method,@"path":route,@"http_status":@(status),@"bytes":@(data.length),@"error_domain":error.domain?:@"",@"error_code":@(error.code)});
            SAP_TRACE("http","management_completion",trace,@{@"http_status":@(status),@"bytes":@(data.length),@"error_domain":error.domain?:@"",@"error_code":@(error.code),@"authenticated_headers_logged":@NO});
            if(error || status<200 || status>=300 || data.length>8*1024*1024) {
                reply(nil,status,[NSString stringWithFormat:SAPL(@"settings.pixie.devices.error.http_format",@"Spotify management request %@ returned HTTP %ld (%@). No success inferred."),method,(long)status,error?SAPDeviceL(@"transport_error"):SAPL(@"settings.pixie.devices.error.no_transport_error",@"no transport error")]);return;
            }
            reply(data?:NSData.data,status,nil);
        });
    }]resume];
}
@end

static SAPSlotRequest *beginSlots(void (^completion)(NSDictionary *,NSString *)) {
    if(slotOperationActive){if(completion)completion(nil,SAPL(@"settings.pixie.devices.error.operation_in_progress",@"Another offline-device operation is in progress."));return nil;}
    slotOperationActive=YES;
    SAPSlotRequest *op=[SAPSlotRequest new];op.completion=completion;op.released=[NSMutableArray array];
    op.traceOperation=SAPTraceCurrentOperation();if(!op.traceOperation&&SAPTraceIsActive())op.traceOperation=SAPTraceBegin(@"offline_device_management",@"pixie_ui",@{});
    if(!slotRequests)slotRequests=[NSMutableSet set];[slotRequests addObject:op];
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.URLCache=nil;configuration.HTTPCookieStorage=nil;configuration.HTTPShouldSetCookies=NO;
#ifdef SAP_TESTING
    if(testProtocol)configuration.protocolClasses=@[testProtocol];
#endif
    op.session=[NSURLSession sessionWithConfiguration:configuration delegate:op delegateQueue:nil];
    __weak SAPSlotRequest *weakOp=op;
    op.deadline=SAPScheduleDeadline(dispatch_get_main_queue(),60,^{
        SAPSlotRequest *op=weakOp;if(op)[op finish:@{@"released_cache_ids":op.released?:@[],@"status":@"unconfirmed"} error:SAPL(@"settings.pixie.devices.error.timeout",@"Offline-device operation timed out. No command is automatically retried; refresh to see the actual state.")];
    });
    return op;
}
static void withHeaders(SAPSlotRequest *op,void (^ready)(SAPSlotRequest *)) {
    SAP_TRACE("offline_devices","waiting_for_existing_authentication",op.traceOperation,@{@"credentials_logged":@NO});
    __weak SAPSlotRequest *weakOp=op;
    void (^received)(NSDictionary *)=^(NSDictionary *headers){
        dispatch_async(dispatch_get_main_queue(),^{
            SAPSlotRequest *op=weakOp;if(!op||op.finished||op.headers)return;
            NSMutableDictionary *allowed=[NSMutableDictionary dictionary];
            NSSet *names=[NSSet setWithArray:@[@"authorization",@"client-token",@"spotify-app-version",@"app-platform",@"user-agent"]];
            for(id key in headers)if([key isKindOfClass:NSString.class]&&[names containsObject:[key lowercaseString]]&&[headers[key]isKindOfClass:NSString.class])allowed[key]=headers[key];
            BOOL authenticated=NO;
            for(NSString *key in allowed)if([key caseInsensitiveCompare:@"Authorization"]==NSOrderedSame&&[allowed[key]hasPrefix:@"Bearer "])authenticated=YES;
            if(!authenticated){[op finish:nil error:SAPL(@"settings.pixie.devices.error.auth_missing",@"Spotify's existing authenticated headers are not available. Play a track online and try again.")];return;}
            SAP_TRACE("offline_devices","existing_authentication_available",op.traceOperation,@{@"credentials_logged":@NO});
            op.headers=allowed;ready(op);
        });
    };
#ifdef SAP_TESTING
    if(testHeaders){testHeaders(received);return;}
#endif
    void (*provider)(void (^)(NSDictionary *))=dlsym(RTLD_DEFAULT,"SGSpclientHeaders");
    if(!provider){[op finish:nil error:SAPL(@"settings.pixie.devices.error.auth_provider_unavailable",@"Vitrine's authenticated request provider is unavailable.")];return;}
    provider(received);
}
static NSArray *activeDevices(NSArray *devices) {
    NSMutableArray *result=[NSMutableArray array];
    for(NSDictionary *device in devices)if([device[@"offline_enabled"]boolValue])[result addObject:device];
    return result;
}
static NSString *deviceKey(NSDictionary *device) {
    for(NSString *name in @[@"device_id",@"cache_id"]) {
        id value=device[name];
        if(![value isKindOfClass:NSString.class]||![value length]||[value length]>maxIdentityLength)return nil;
    }
    return [NSString stringWithFormat:@"%lu:%@%@",(unsigned long)[device[@"device_id"]length],device[@"device_id"],device[@"cache_id"]];
}
static NSSet *deviceKeys(NSArray *devices) {
    NSMutableSet *keys=[NSMutableSet set];
    for(NSDictionary *device in devices){NSString *key=deviceKey(device);if(!key||[keys containsObject:key])return nil;[keys addObject:key];}
    return keys;
}
static void readRegistry(SAPSlotRequest *op,void (^reply)(NSDictionary *,NSString *)) {
    [op request:@"offline/v1/licenseStatus" method:@"GET" completion:^(NSData *data,NSInteger status,NSString *error){
        if(error){reply(nil,error);return;}
        NSArray *fields=SAPProtoFields(data);int32_t maximum=(int32_t)SAPProtoNumber(fields,1,0),free=(int32_t)SAPProtoNumber(fields,2,0);
        if(!fields||maximum<=0||maximum>1000||free<0||free>maximum){reply(nil,SAPL(@"settings.pixie.devices.error.license_invalid_protobuf",@"The direct license response is not a valid LicenseStatus protobuf; the current state cannot be confirmed."));return;}
        [op request:@"offline/v1/devices" method:@"GET" completion:^(NSData *data,NSInteger status,NSString *error){
            if(error){reply(nil,error);return;}
            NSArray *fields=SAPProtoFields(data);if(!fields){reply(nil,SAPL(@"settings.pixie.devices.error.device_invalid_protobuf",@"The direct device response is not valid protobuf; the current state cannot be confirmed."));return;}
            NSMutableArray *devices=[NSMutableArray array];
            for(NSDictionary *field in fields)if([field[@"number"]unsignedIntValue]==1&&[field[@"wire"]unsignedIntValue]==2) {
                NSArray *f=SAPProtoFields(field[@"value"]);NSString *identifier=SAPProtoString(f,1),*cache=SAPProtoString(f,2);
                if(!identifier.length||!cache.length||identifier.length>maxIdentityLength||cache.length>maxIdentityLength){reply(nil,SAPL(@"settings.pixie.devices.error.identifiers_incomplete",@"The direct device response has incomplete identifiers; the current state cannot be confirmed."));return;}
                NSArray *seen=SAPProtoFields(SAPProtoData(f,10));
                [devices addObject:@{@"device_id":identifier,@"cache_id":cache,@"name":SAPProtoString(f,3)?:SAPL(@"settings.pixie.devices.fallback.device_name",@"Spotify device"),
                    @"offline_enabled":@(SAPProtoNumber(f,6,0)!=0),@"last_seen_at":@(SAPProtoNumber(seen,1,0))}];
            }
            if(!deviceKeys(devices)){reply(nil,SAPDeviceL(@"invalid_identities"));return;}
            NSDictionary *value=@{@"max_licenses":@(maximum),@"free_licenses":@(free),@"devices":devices,@"observed_at":@(NSDate.date.timeIntervalSince1970),@"source":@"direct_https_response"};
            op.registry=value;op.registryAfterCommand=op.commandSent;
            NSDictionary *safe=safeSnapshot(deviceSnapshot(value,op.native,NO));
            SAPJournalNoteAction(@"offline_slot_registry_read",safe);SAP_TRACE("offline_devices","registry_readback",op.traceOperation,safe);reply(value,nil);
        }];
    }];
}
static BOOL registryMatchesNative(NSDictionary *registry,NSDictionary *native) {
    NSDictionary *s=native[@"sources"],*local=s[@"local_device"][@"device"];
    double age=NSDate.date.timeIntervalSince1970-[native[@"finished_at"]doubleValue];
    if(age<0||age>reviewLifetimeSeconds)return NO;
    if(![native[@"status"]isEqual:@"complete"] || ![s[@"devices"][@"read_status"]isEqual:@"received"] ||
       ![s[@"local_device"][@"read_status"]isEqual:@"received"] || !deviceKey(local) ||
       ![s[@"licenses"][@"read_status"]isEqual:@"received"] ||
       [s[@"devices"][@"error"]longLongValue] || [s[@"licenses"][@"error"]longLongValue])return NO;
    if(![registry[@"max_licenses"]isEqual:s[@"licenses"][@"max_licenses"]]||![registry[@"free_licenses"]isEqual:s[@"licenses"][@"free_licenses"]])return NO;
    if(![deviceKeys(registry[@"devices"])isEqual:deviceKeys(s[@"devices"][@"devices"])])return NO;
    if(![deviceKeys(activeDevices(registry[@"devices"]))isEqual:deviceKeys(activeDevices(s[@"devices"][@"devices"]))])return NO;
    for(NSDictionary *device in registry[@"devices"])if([deviceKey(device)isEqual:deviceKey(local)])
        return [device[@"offline_enabled"]boolValue]==[local[@"offline_enabled"]boolValue];
    return ![local[@"offline_enabled"]boolValue];
}
static NSDictionary *deviceSnapshot(NSDictionary *registry,NSDictionary *native,BOOL actionable) {
    NSDictionary *sources=native[@"sources"],*local=sources[@"local_device"][@"device"];
    BOOL localValid=[sources[@"local_device"][@"read_status"]isEqual:@"received"]&&deviceKey(local)!=nil;
    double age=NSDate.date.timeIntervalSince1970-[native[@"finished_at"]doubleValue];
    BOOL nativeComplete=[native[@"status"]isEqual:@"complete"]&&localValid&&age>=0&&age<=reviewLifetimeSeconds;
    for(NSString *name in @[@"devices",@"licenses"])
        if(![sources[name][@"read_status"]isEqual:@"received"])nativeComplete=NO;
    NSMutableArray *records=[NSMutableArray array];BOOL listed=NO;
    for(NSDictionary *device in registry?registry[@"devices"]:sources[@"devices"][@"devices"]) {
        NSMutableDictionary *copy=[device mutableCopy];
        BOOL current=localValid&&[deviceKey(device)isEqual:deviceKey(local)];
        copy[@"is_current_device"]=@(current);listed|=current;
        if(actionable)copy[@"selection_token"]=NSUUID.UUID.UUIDString;
        [records addObject:copy];
    }
    if(localValid&&!listed) {
        NSMutableDictionary *copy=[local mutableCopy];copy[@"is_current_device"]=@YES;
        copy[@"synthetic_record"]=@YES;
        copy[@"registration_status"]=actionable?@"not_registered":@"unconfirmed";
        [records addObject:copy];
    }
    NSMutableDictionary *snapshot=[@{@"id":NSUUID.UUID.UUIDString,@"created_at":@(NSDate.date.timeIntervalSince1970),
        @"devices":records,@"active_devices":activeDevices(records),@"local_device":localValid?local:@{},
        @"actions_allowed":@(actionable),@"native_read_status":nativeComplete?@"complete":@"unavailable",
        @"direct_read_status":registry?@"received":@"unavailable"}mutableCopy];
    if([sources[@"licenses"][@"read_status"]isEqual:@"received"]) {
        snapshot[@"native_free_licenses"]=sources[@"licenses"][@"free_licenses"];
        snapshot[@"native_max_licenses"]=sources[@"licenses"][@"max_licenses"];
    }
    NSDictionary *quota=registry?:sources[@"licenses"];
    if(registry||[quota[@"read_status"]isEqual:@"received"]) {
        if(quota[@"free_licenses"])snapshot[@"free_licenses"]=quota[@"free_licenses"];
        if(quota[@"max_licenses"])snapshot[@"max_licenses"]=quota[@"max_licenses"];
    }
    return snapshot;
}
static NSDictionary *safeSnapshot(NSDictionary *snapshot) {
    NSMutableArray *records=[NSMutableArray array];
    for(NSDictionary *device in snapshot[@"devices"])
        [records addObject:@{@"is_current_device":device[@"is_current_device"]?:@NO,
            @"offline_enabled":@([device[@"offline_enabled"]boolValue]),@"synthetic_record":@([device[@"synthetic_record"]boolValue])}];
    return @{@"devices":records,@"free_licenses":snapshot[@"free_licenses"]?:NSNull.null,
        @"max_licenses":snapshot[@"max_licenses"]?:NSNull.null,
        @"native_free_licenses":snapshot[@"native_free_licenses"]?:NSNull.null,
        @"native_max_licenses":snapshot[@"native_max_licenses"]?:NSNull.null,
        @"native_read_status":snapshot[@"native_read_status"],@"direct_read_status":snapshot[@"direct_read_status"]};
}
static NSString *snapshotSummary(NSDictionary *snapshot) {
    NSMutableArray *lines=[NSMutableArray arrayWithObject:[NSString stringWithFormat:SAPDeviceL(@"snapshot_format"),
        snapshot[@"free_licenses"]?:@"?",snapshot[@"max_licenses"]?:@"?",
        snapshot[@"native_free_licenses"]?:@"?",snapshot[@"native_max_licenses"]?:@"?",
        SAPDeviceL([snapshot[@"native_read_status"]isEqual:@"complete"]?@"received":@"unavailable"),
        SAPDeviceL([snapshot[@"direct_read_status"]isEqual:@"received"]?@"received":@"unavailable")]];
    for(NSDictionary *device in snapshot[@"devices"])
        [lines addObject:[NSString stringWithFormat:@"%@ · %@",SAPDeviceL([device[@"is_current_device"]boolValue]?@"this_copy":@"other_copy"),
            SAPDeviceL([device[@"synthetic_record"]boolValue]?([device[@"registration_status"]isEqual:@"not_registered"]?@"not_registered":@"unconfirmed"):
                ([device[@"offline_enabled"]boolValue]?@"enabled":@"disabled"))]];
    return [lines componentsJoinedByString:@"\n"];
}
void SAPPreviewOfflineDeviceSlots(void (^completion)(NSDictionary *,NSString *)) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{SAPPreviewOfflineDeviceSlots(completion);});return;}
    SAPSlotRequest *op=beginSlots(completion);if(!op)return;lastPlan=nil;
    SAPRefreshDownloadCompatibility(^(NSDictionary *native){
        if(op.finished)return;op.native=native;
        withHeaders(op,^(SAPSlotRequest *request){readRegistry(request,^(NSDictionary *registry,NSString *error){
            if(error){[request finish:nil error:error];return;}
            if(!registryMatchesNative(registry,native)){[request finish:nil error:SAPL(@"settings.pixie.devices.error.state_mismatch",@"The authenticated direct API and this Spotify instance do not report the same registration state. Nothing was changed.")];return;}
            NSDictionary *plan=deviceSnapshot(registry,native,YES);
            lastPlan=plan;[request finish:plan error:nil];
        });});
    });
}
static NSString *pathComponent(NSString *value) {
    return [value stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"]];
}
static void releaseNext(SAPSlotRequest *op,NSDictionary *before) {
    if(op.finished)return;
    if(op.index>=op.selected.count) {
        [op finish:@{@"status":@"verified",@"released_cache_ids":[op.released copy],@"free_licenses":before[@"free_licenses"],@"max_licenses":before[@"max_licenses"]} error:nil];return;
    }
    NSDictionary *device=op.selected[op.index];
    NSString *path=[NSString stringWithFormat:@"offline/v1/devices/%@/cache/%@/disable",pathComponent(device[@"device_id"]),pathComponent(device[@"cache_id"])];
    op.commandSent=YES;op.registryAfterCommand=NO;
    [op request:path method:@"POST" completion:^(NSData *data,NSInteger status,NSString *error){
        if(error){[op finish:@{@"status":@"unconfirmed",@"released_cache_ids":[op.released copy]} error:error];return;}
        readRegistry(op,^(NSDictionary *after,NSString *error){
            if(error){[op finish:nil error:error];return;}
            BOOL stillEnabled=[deviceKeys(activeDevices(after[@"devices"]))containsObject:deviceKey(device)];
            if(stillEnabled || ![after[@"max_licenses"]isEqual:before[@"max_licenses"]] || [after[@"free_licenses"]integerValue]<[before[@"free_licenses"]integerValue]+1) {
                [op finish:@{@"status":@"unconfirmed",@"released_cache_ids":[op.released copy],@"observed_registry":after} error:SAPL(@"settings.pixie.devices.error.slot_not_freed",@"Spotify acknowledged the command, but a freed slot was not confirmed. No command will be repeated automatically; refresh the state before trying again.")];return;
            }
            [op.released addObject:device[@"cache_id"]];op.index++;
            releaseNext(op,after);
        });
    }];
}
void SAPReleaseOfflineDeviceSlots(NSString *planID,NSArray<NSString *> *selectionTokens,void (^completion)(NSDictionary *,NSString *)) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{SAPReleaseOfflineDeviceSlots(planID,selectionTokens,completion);});return;}
    SAPSlotRequest *op=beginSlots(completion);if(!op)return;
    NSDictionary *plan=lastPlan;lastPlan=nil;op.plan=plan;
    if(![plan[@"id"]isEqual:planID] || !selectionTokens.count || [NSSet setWithArray:selectionTokens].count!=selectionTokens.count ||
       NSDate.date.timeIntervalSince1970-[plan[@"created_at"]doubleValue]>reviewLifetimeSeconds || NSDate.date.timeIntervalSince1970<[plan[@"created_at"]doubleValue]) {
        [op finish:nil error:SAPL(@"settings.pixie.devices.error.selection_invalid",@"The reviewed device selection is missing, expired or invalid. Refresh it before changing registrations.")];return;
    }
    NSMutableArray *selected=[NSMutableArray array];
    for(NSDictionary *device in plan[@"active_devices"])if(![device[@"synthetic_record"]boolValue]&&[selectionTokens containsObject:device[@"selection_token"]])[selected addObject:device];
    if(selected.count!=selectionTokens.count){[op finish:nil error:SAPL(@"settings.pixie.devices.error.selection_not_in_plan",@"The selected registrations were not in the reviewed list. Nothing was changed.")];return;}
    op.plan=plan;op.selected=selected;
    SAPJournalNoteAction(@"offline_slot_release_confirmed",@{@"selected_count":@(selected.count)});
    // Authenticate afresh and compare with the reviewed snapshot before any POST.
    SAPRefreshDownloadCompatibility(^(NSDictionary *native){
    if(op.finished)return;op.native=native;
    withHeaders(op,^(SAPSlotRequest *request){readRegistry(request,^(NSDictionary *registry,NSString *error){
        if(error){[request finish:nil error:error];return;}
        if(!registryMatchesNative(registry,native) || ![deviceKey(native[@"sources"][@"local_device"][@"device"])isEqual:deviceKey(plan[@"local_device"])] ||
           ![deviceKeys(activeDevices(registry[@"devices"]))isEqual:deviceKeys(plan[@"active_devices"])] ||
           ![registry[@"free_licenses"]isEqual:plan[@"free_licenses"]] || ![registry[@"max_licenses"]isEqual:plan[@"max_licenses"]]) {
            [request finish:nil error:SAPL(@"settings.pixie.devices.error.state_changed_after_review",@"The registration state changed after review. Nothing was changed; refresh the list.")];return;
        }
        releaseNext(request,registry);
    });});
    });
}
void SAPEnableOfflineOnCurrentDevice(void (^completion)(NSDictionary *,NSString *)) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{SAPEnableOfflineOnCurrentDevice(completion);});return;}
    SAPSlotRequest *op=beginSlots(completion);if(!op)return;lastPlan=nil;
    SAPRefreshDownloadCompatibility(^(NSDictionary *before){
        if(op.finished)return;op.native=before;
        NSDictionary *sources=before[@"sources"],*local=sources[@"local_device"][@"device"];
        if(![before[@"status"]isEqual:@"complete"] || ![sources[@"local_device"][@"read_status"]isEqual:@"received"] || !deviceKey(local)) {
            [op finish:nil error:SAPL(@"settings.pixie.devices.error.current_device_unreadable",@"The current device and license state could not be read. No enable command was sent.")];return;
        }
        if([local[@"offline_enabled"]boolValue]&&[sources[@"playback"][@"allowed"]boolValue]) {
            [op finish:before error:nil];return;
        }
        if([sources[@"licenses"][@"error"]longLongValue] || [sources[@"licenses"][@"free_licenses"]integerValue]<=0) {
            [op finish:before error:SAPL(@"settings.pixie.devices.error.no_free_slots",@"No free offline-device slot was reported. Release a reviewed old registration first. No enable command was sent.")];return;
        }
        op.commandSent=YES;
        SAPCallOfflineCommandOnce(@"SetOfflinePlaybackAllowed",SAPProtoInteger(1,1),^(NSData *data,NSString *error){
            if(op.finished)return;
            NSArray *fields=data?SAPProtoFields(data):nil;
            if(error || !fields || SAPProtoNumber(fields,1,0)!=1) {
                [op finish:nil error:SAPL(@"settings.pixie.devices.error.enable_unconfirmed",@"Spotify did not confirm the enable command. It was sent once and will not be repeated automatically.")];return;
            }
            SAPRefreshDownloadCompatibility(^(NSDictionary *after){
                if(op.finished)return;op.native=after;
                BOOL registered=[after[@"status"]isEqual:@"complete"] &&
                    [after[@"sources"][@"local_device"][@"read_status"]isEqual:@"received"] &&
                    [deviceKey(local)isEqual:deviceKey(after[@"sources"][@"local_device"][@"device"])] &&
                    [after[@"sources"][@"local_device"][@"device"][@"offline_enabled"]boolValue] &&
                    [after[@"sources"][@"playback"][@"read_status"]isEqual:@"received"] && [after[@"sources"][@"playback"][@"allowed"]boolValue];
                [op finish:after error:registered?nil:SAPL(@"settings.pixie.devices.error.enable_pending_refresh",@"Spotify acknowledged the command, but this copy's offline registration is not confirmed yet. Refresh the state; no enable command will be repeated automatically.")];
            });
        });
    });
}
