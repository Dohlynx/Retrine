// build-sim.sh battery: real player-state handler, worker, ring and motion registration;
// no download, model prediction, hardware, or instrumentation on the render thread.
#import <unistd.h>
#import <stdatomic.h>
#import "../../harness-fail.h"
static atomic_uint polls;
static int workerSleep(useconds_t delay) {
    atomic_fetch_add(&polls, 1);
    return usleep(delay);
}
#define usleep workerSleep
#import "SGSingEngine.m"
#undef usleep

#import "Sing.h"
#import "SGSingLoader.h"
static SGSingSeparator *loaded;
#define SGSingModelCurrentState() SGSingModelReady
#define SGSingLoaderSeparator() loaded
#import "Sing.m"

static OSStatus tone(void *unused, UInt32 frames, float *l, float *r, UInt32 *sounding) {
    for (UInt32 i = 0; i < frames; ++i) l[i] = r[i] = 0.25f;
    if (sounding) *sounding = frames;
    return noErr;
}

@interface HalfVocal : SGSingSeparator
@end
@implementation HalfVocal
- (BOOL)separateLeft:(const float *)left right:(const float *)right vocalsLeft:(float *)vl vocalsRight:(float *)vr error:(NSError **)error {
    for (unsigned i = 0; i < kSGSingWindowFrames; ++i) {
        vl[i] = 0.5f * left[i];
        vr[i] = 0.5f * right[i];
    }
    return YES;
}
@end

static bool mixed(const float *l, const float *r) {
    for (unsigned i = 0; i < 1024; ++i)
        if (!(fabsf(l[i] - 0.125f) < 1e-6f && fabsf(r[i] - 0.125f) < 1e-6f)) return false;
    return true;
}

void HarnessSingBattery(NSSet *listeners) {
    loaded = [[HalfVocal alloc] initWithModel:nil];
    SGSetEnabled(SGKeySingSpatial, YES);
    SGSetSingLevel(0);
    SGSetSingOn(YES);
    SGSingEngine *engine = atomic_load(&sg_engine);
    SGSingTrackWatcher *watcher = [SGSingTrackWatcher new];
    SPTPlayerState *state = SGPlayerState();
    NSSet *both = [NSSet setWithArray:@[@"gestures", @"sing"]], *gestures = [NSSet setWithObject:@"gestures"];
    HARNESS_CHECK([listeners isEqual:both]);
    float l[1024], r[1024];
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 5;
    do {
        SGSingEngineRender(engine, 1024, l, r, tone, NULL);
        if (mixed(l, r)) break;
        usleep(2000); // let the real worker consume the windows as we feed them
    } while (CFAbsoluteTimeGetCurrent() < deadline);
    HARNESS_CHECK(mixed(l, r));
    double lead = SGSingHeldLead();
    HARNESS_CHECK(lead > 0.05);
    for (int i = 0; i < 100 && !atomic_load(&polls); ++i) usleep(5000);
    HARNESS_CHECK(atomic_load(&polls));
    [state setValue:@YES forKey:@"isPaused"];
    [watcher playerStateDidChange:state];
    unsigned before = atomic_load(&polls);
    usleep(200000);
    HARNESS_CHECK(atomic_load(&polls) - before <= 1 && SGSingHeldLead() == lead);
    HARNESS_CHECK([listeners isEqual:gestures]);
    [state setValue:@NO forKey:@"isPaused"];
    [watcher playerStateDidChange:state];
    before = atomic_load(&polls);
    for (int i = 0; i < 100 && atomic_load(&polls) == before; ++i) usleep(5000);
    HARNESS_CHECK(atomic_load(&polls) > before && SGSingHeldLead() == lead);
    SGSingEngineRender(engine, 1024, l, r, tone, NULL);
    HARNESS_CHECK(mixed(l, r));
    HARNESS_CHECK([listeners isEqual:both]);
    sg_hot = YES;
    apply();
    HARNESS_CHECK([listeners isEqual:gestures]);
    sg_hot = NO;
    apply();
    HARNESS_CHECK([listeners isEqual:both]);
    sg_elsewhere = YES;
    [watcher playerStateDidChange:state];
    HARNESS_CHECK([listeners isEqual:gestures]);
    sg_elsewhere = NO;
    [watcher playerStateDidChange:state];
    HARNESS_CHECK([listeners isEqual:both]);
    puts("PASS engaged pause parks the worker and preserves buffered output; heat and remote withdraw only Sing motion");
}
