// The actual Gemini job must return usable advice without replacing an explicit model.
static void checkGeminiGuidance(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id keptModel = [defaults objectForKey:SGKeyLyricsGeminiModel];
    NSSet *keptKeys = testKeys;
    testKeys = [NSSet setWithObject:@"Vitrine.Gemini"];
    [defaults setObject:@"gemini-3.8-flash" forKey:SGKeyLyricsGeminiModel];
    CHECK([NSURLProtocol registerClass:SGGeminiTitleProtocol.class]);
    NSArray *lines = SGKaraokeEstimatedLines(@[@0], @[@"Blue robot"]);
    NSArray *failures = @[
        @{@"error": @{@"message": @"Unknown model"}},
        [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]
    ];
    for (id failure in failures) {
        BOOL timeout = [failure isKindOfClass:NSError.class];
        geminiTitleStatus = timeout ? 0 : 404;
        geminiTitleReplies = [NSMutableArray arrayWithObject:failure];
        __block BOOL finished = NO;
        __block NSString *problem;
        SGLyricsTranslateWithGemini(nil, lines, @"ko", ^(NSArray *answer, NSString *error) {
            CHECK(NSThread.isMainThread && !answer);
            problem = error;
            finished = YES;
        });
        waitFor(^BOOL { return finished; });
        CHECK([problem containsString:timeout ? @"timed out" : @"unavailable"]);
        CHECK([problem containsString:@"model"] && [problem containsString:@"Mod Settings"]);
        CHECK([lastGeminiRequest.URL.path isEqual:@"/v1beta/models/gemini-3.8-flash:generateContent"]);
        CHECK([[defaults objectForKey:SGKeyLyricsGeminiModel] isEqual:@"gemini-3.8-flash"]);
    }
    [NSURLProtocol unregisterClass:SGGeminiTitleProtocol.class];
    geminiTitleStatus = 0;
    geminiTitleReplies = nil;
    if (keptModel) [defaults setObject:keptModel forKey:SGKeyLyricsGeminiModel];
    else [defaults removeObjectForKey:SGKeyLyricsGeminiModel];
    testKeys = keptKeys;
    resetCredentialCaches();
    puts("Gemini guidance: 404 and timeout advise a model change and preserve the explicit choice");
}
