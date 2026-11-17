// Production Objective-C event/admission owner; Go and Spotify import admission are boundaries.
#import "Shared/WireGuard/SGWGCore.m"

static unsigned notices, rebinds;
static BOOL admitted = YES, patches = YES;
static dispatch_semaphore_t admissionEntered, admissionContinue;
#define CHECK(value) do { if (!(value)) { fprintf(stderr, "FAIL readiness:%d %s\n", __LINE__, #value); exit(1); } } while (0)

BOOL SGWGInstallNativePatches(void) { return patches; }
BOOL SGWGAdmissionReady(void) {
    BOOL result = admitted;
    if (admissionEntered) {
        dispatch_semaphore_signal(admissionEntered);
        dispatch_semaphore_wait(admissionContinue, DISPATCH_TIME_FOREVER);
    }
    return result;
}
void SGWGInstallTransportPatches(void) {}
NSArray *SGWGNativeReportLines(void) { return @[]; }
NSArray *SGWGTransportReportLines(void) { return @[]; }
NSArray *SGWGScanTransportClasses(void) { return @[]; }
NSArray *SGWGAdmissionReportLines(void) { return @[]; }
void SGWGNotifyRecovery(void) { notices++; CHECK(!SGWGReady()); }
int SGWGRebind(void) { rebinds++; return 0; }
static void unexpected(void) { fputs("FAIL unexpected profile/Go status access\n", stderr); exit(1); }
char *SGWGInspect(char *text) { unexpected(); return NULL; }
int SGWGStart(char *text, char *user, char *pass, int fd, int port) { unexpected(); return -1; }
char *SGWGStatus(void) { unexpected(); return NULL; }
char *SGWGLookup(char *host) { unexpected(); return NULL; }
char *SGWGResolve(char *host) { unexpected(); return NULL; }
char *SGWGRedact(char *text) { unexpected(); return NULL; }
void SGWGFree(char *text) { free(text); }
void SGWGSetStateCallback(uintptr_t callback) { unexpected(); }

static void drain(void) { dispatch_sync(gQueue, ^{}); }

static void checkStaleRefresh(void) {
    for (NSNumber *event in @[@1, @2, @0]) {
        patches = YES;
        EngineChanged(1);
        drain();
        CHECK(SGWGReady());
        admissionEntered = dispatch_semaphore_create(0);
        admissionContinue = dispatch_semaphore_create(0);
        dispatch_semaphore_t refreshed = dispatch_semaphore_create(0);
        dispatch_semaphore_t finish = dispatch_semaphore_create(0);
        dispatch_async(gQueue, ^{
            SGWGRefreshReadiness();
            dispatch_semaphore_signal(refreshed);
            // Inspect the old publication before any queued recovery can overwrite it.
            dispatch_semaphore_wait(finish, DISPATCH_TIME_FOREVER);
        });
        dispatch_semaphore_wait(admissionEntered, DISPATCH_TIME_FOREVER);
        EngineChanged(2);
        patches = NO;
        ImageChanged(NULL, 0);
        if (event.intValue != 2) EngineChanged(event.intValue);
        CHECK(!SGWGReady());
        dispatch_semaphore_signal(admissionContinue);
        dispatch_semaphore_wait(refreshed, DISPATCH_TIME_FOREVER);
        CHECK(!SGWGReady());
        admissionEntered = admissionContinue = nil;
        dispatch_semaphore_signal(finish);
        drain();
        CHECK(!SGWGReady());
        patches = YES;
        ImageChanged(NULL, 0);
        EngineChanged(1);
        drain();
        CHECK(SGWGReady());
    }
    puts("PASS in-flight guard validation cannot restore readiness across recovery, unavailable or stopped events");
}

int main(void) {
    @autoreleasepool {
        CHECK(SGWGIsSupportedOS());
        gActive = YES;
        gKind = SGWGKindWireGuard;
        gSessionGuards = YES;
        EngineChanged(1);
        drain();
        CHECK(SGWGReady() && SGWGCurrentState() == SGWGStateRunning);
        EngineChanged(3);
        drain();
        CHECK(SGWGReady() && notices == 0);

        // A blocked Go rebind must not delay revocation or the failure notice behind gQueue.
        dispatch_suspend(gQueue);
        EngineChanged(2);
        CHECK(!SGWGReady() && SGWGCurrentState() == SGWGStateFailed && notices == 1);
        dispatch_resume(gQueue);
        drain();
        SGWGRequestRebind(@"fixture recovery");
        drain();
        CHECK(rebinds == 1);
        EngineChanged(3);
        drain();
        CHECK(!SGWGReady() && notices == 1);
        EngineChanged(1);
        drain();
        CHECK(SGWGReady() && SGWGCurrentState() == SGWGStateRunning);
        patches = NO;
        EngineChanged(1);
        drain();
        CHECK(!SGWGReady());
        EngineChanged(0);
        drain();
        SGWGRequestRebind(@"stopped is not recoverable");
        drain();
        CHECK(!SGWGReady() && rebinds == 1);
        checkStaleRefresh();
        puts("PASS structural failure revokes readiness immediately, recovery restores guards, destination failure is informational");
    }
}
