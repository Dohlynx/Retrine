// Capture the row's dispatch delay without replacing its timer or Now Playing setter.
#import <Foundation/Foundation.h>
extern int64_t harnessRowDelay;
static dispatch_time_t rowTime(dispatch_time_t start, int64_t delta) {
    harnessRowDelay = delta;
    return dispatch_time(start, delta);
}
#define dispatch_time rowTime
extern NSUInteger harnessRowFires;
static void rowHandler(dispatch_source_t source, dispatch_block_t block) {
    dispatch_source_set_event_handler(source, ^{ harnessRowFires++; block(); });
}
#define dispatch_source_set_event_handler rowHandler
#include "LockScreenLyrics.m"
