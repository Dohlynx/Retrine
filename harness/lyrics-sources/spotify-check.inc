static NSArray<SGKaraokeLine *> *spotifySyllables(NSArray *rows) {
    NSData *body = [NSJSONSerialization dataWithJSONObject:
        @{@"lyrics": @{@"syncType": @"SYLLABLE_SYNCED", @"lines": rows}} options:0 error:nil];
    return SGKaraokeLinesFromBody(body);
}

static void checkSpotifySyllables(void) {
    // numChars counts UTF-16 units, not UTF-8 bytes, scalars or composed characters.
    NSDictionary *row = @{
        @"words": @"你😀 e\u0301lan", @"startTimeMs": @"1000", @"endTimeMs": @"2400",
        @"syllables": @[
            @{@"numChars": @1, @"startTimeMs": @"1000", @"endTimeMs": @"1200"},
            @{@"numChars": @2, @"startTimeMs": @"1200", @"endTimeMs": @"1500"},
            @{@"numChars": @2, @"startTimeMs": @"1600", @"endTimeMs": @"1800"},
            @{@"numChars": @3, @"startTimeMs": @"1800", @"endTimeMs": @"2300"}]};
    NSArray<SGKaraokeLine *> *lines = spotifySyllables(@[row]);
    CHECK(lines.count == 1);
    SGKaraokeLine *line = lines[0];
    CHECK(line.timing == SGKaraokeTimingWords && line.start == 1000 && line.end == 2400);
    CHECK([SGKaraokeLineText(line) isEqual:@"你😀 e\u0301lan"]);
    CHECK(line.words.count == 3);
    CHECK([line.words[1].text isEqual:@"😀"] && line.words[1].joined);
    CHECK(line.words[1].start == 1200 && line.words[1].end == 1500);
    CHECK([line.words[2].text isEqual:@"e\u0301lan"] && !line.words[2].joined);
    CHECK(line.words[2].start == 1600 && line.words[2].end == 2300);

    // Spotify can omit syllable ends. Keep the real line start, without pretending
    // that zero-duration pieces are word timing; instrumental rows still bound it.
    NSDictionary *startOnly = @{@"words": @"Hello", @"startTimeMs": @"3000", @"endTimeMs": @"0",
        @"syllables": @[@{@"numChars": @5, @"startTimeMs": @"3000"}]};
    lines = spotifySyllables(@[startOnly, @{@"words": @"♪", @"startTimeMs": @"3500", @"syllables": @[]}]);
    CHECK(lines.count == 1 && lines[0].timing == SGKaraokeTimingLine);
    CHECK(lines[0].start == 3000 && lines[0].end == 3500);
    CHECK([SGKaraokeLineText(lines[0]) isEqual:@"Hello"]);
    for (NSDictionary *syllable in @[
        @{@"numChars": @5},
        @{@"numChars": @5, @"endTimeMs": @4000},
        @{@"numChars": @5, @"startTimeMs": @1000}]) {
        line = spotifySyllables(@[@{@"words": @"Hello", @"startTimeMs": @1000,
            @"endTimeMs": @5000, @"syllables": @[syllable]}]).firstObject;
        CHECK(line && line.timing == SGKaraokeTimingLine);
        CHECK([SGKaraokeLineText(line) isEqual:@"Hello"]);
        CHECK(line.start == 1000 && line.end == 5000);
        for (SGKaraokeWord *word in line.words)
            CHECK(word.start >= 1000 && word.end <= 5000);
    }
    line = spotifySyllables(@[@{@"words": @"Hello", @"startTimeMs": @1000,
        @"syllables": @[@{@"numChars": @5}]}]).firstObject;
    CHECK(line && line.timing == SGKaraokeTimingLine && line.start == 1000);
    CHECK([SGKaraokeLineText(line) isEqual:@"Hello"]);
    line = spotifySyllables(@[@{@"words": @"Hello", @"startTimeMs": @1000,
        @"endTimeMs": @1000, @"syllables": @[@{@"numChars": @5}]}]).firstObject;
    CHECK(line && line.start == 1000 && line.end == 1000);
    CHECK(line.words[0].start == 1000 && line.words[0].end == 1000);
    NSMutableDictionary *withoutStart = [row mutableCopy];
    [withoutStart removeObjectForKey:@"startTimeMs"];
    CHECK(spotifySyllables(@[withoutStart])[0].start == 1000);

    // A valid UTF-16 boundary inside a composed character cannot be shown as two
    // independently swept glyphs. Preserve the whole text with line timing.
    NSDictionary *combining = @{@"words": @"e\u0301", @"startTimeMs": @1000, @"syllables": @[
        @{@"numChars": @1, @"startTimeMs": @1000, @"endTimeMs": @1200},
        @{@"numChars": @1, @"startTimeMs": @1200, @"endTimeMs": @1400}]};
    line = spotifySyllables(@[combining]).firstObject;
    CHECK(line && line.timing == SGKaraokeTimingLine && line.start == 1000);
    CHECK([SGKaraokeLineText(line) isEqual:@"e\u0301"]);

    for (NSString *field in @[@"startTimeMs", @"endTimeMs", @"numChars"]) {
        for (id invalid in @[NSNull.null, @YES, @(-1), @1.5, @86400001, @"12oops", @"", @"9223372036854775807"]) {
            NSMutableDictionary *bad = [row mutableCopy];
            NSMutableArray *syllables = [row[@"syllables"] mutableCopy];
            NSMutableDictionary *syllable = [syllables[0] mutableCopy];
            syllable[field] = invalid;
            syllables[0] = syllable;
            bad[@"syllables"] = syllables;
            CHECK(!spotifySyllables(@[bad]));
            if (![field isEqual:@"numChars"]) {
                bad = [row mutableCopy]; bad[field] = invalid;
                CHECK(!spotifySyllables(@[bad]));
            }
        }
    }
    for (NSDictionary *syllable in @[
        @{@"numChars": @0, @"startTimeMs": @1000},
        @{@"numChars": @99, @"startTimeMs": @1000},
        @{@"numChars": @1, @"startTimeMs": @1000, @"endTimeMs": @999},
        @{@"numChars": @1, @"startTimeMs": @1000}]) {
        NSMutableDictionary *bad = [row mutableCopy]; bad[@"syllables"] = @[syllable];
        CHECK(!spotifySyllables(@[bad]));
    }
    CHECK(!spotifySyllables(@[@{@"words": @"😀", @"startTimeMs": @1000, @"syllables": @[
        @{@"numChars": @1, @"startTimeMs": @1000}, @{@"numChars": @1, @"startTimeMs": @1200}]}]));
    CHECK(!spotifySyllables(@[@{@"words": @"AB", @"startTimeMs": @1000, @"syllables": @[
        @{@"numChars": @1, @"startTimeMs": @1200}, @{@"numChars": @1, @"startTimeMs": @1100}]}]));
    CHECK(!spotifySyllables(@[@{@"words": @"Hello", @"syllables": @[]}]));
    CHECK(!spotifySyllables(@[@{@"words": @"Hello", @"startTimeMs": @1000, @"syllables": NSNull.null}]));
    CHECK(!spotifySyllables(@[NSNull.null]));
    puts("Spotify syllables: UTF-16 text, real word timing, line fallback and strict rejection passed");
}

static void checkSpotifyPublishedClock(void) {
    id oldPlayer = sg_player;
    SPTPlayerState *oldState = sg_fixtureState;
    HarnessPlayer *player = [HarnessPlayer new];
    HarnessLyricsState *outgoing = [HarnessLyricsState new], *incoming = [HarnessLyricsState new];
    outgoing.track = [HarnessLyricsTrack new]; outgoing.track.URI = @"spotify:track:outgoing";
    outgoing.position = 42;
    incoming.track = [HarnessLyricsTrack new]; incoming.track.URI = @"spotify:track:incoming";
    incoming.position = 3;
    sg_player = player; player.state = outgoing; sg_fixtureState = nil;
    CHECK([SGKaraokePlayingTrack() isEqual:@"outgoing"] && SGKaraokePositionMs() == 42000);
    sg_fixtureState = (id)outgoing;
    player.state = incoming; // Direct player leads the shared artwork/track report.
    CHECK([SGKaraokePlayingTrack() isEqual:@"outgoing"] && SGKaraokePositionMs() == 42000);
    sg_fixtureState = (id)incoming;
    CHECK([SGKaraokePlayingTrack() isEqual:@"incoming"] && SGKaraokePositionMs() == 3000);
    incoming.isPaused = YES; incoming.positionAsOfTimestamp = 2;
    CHECK(SGKaraokePositionMs() == 2000);
    sg_player = oldPlayer; sg_fixtureState = oldState;
    puts("Spotify clock: initial fallback and shared track/clock transition passed");
}
