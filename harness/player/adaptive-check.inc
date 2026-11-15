// A Spotify-unit fixture, driven through the same hooked layout callbacks as the phone scenarios.
static UIButton *lyricsMenuIn(UIView *stage) {
    __block UIButton *menu = nil;
    SGForEachView(stage, ^(UIView *view) {
        if ([view isKindOfClass:UIButton.class] && ((UIButton *)view).showsMenuAsPrimaryAction && !view.hidden) menu = (UIButton *)view;
    });
    return menu;
}

- (void)runOpeningChecks {
    HARNESS_CHECK(self.window.bounds.size.width > self.window.bounds.size.height);
    HARNESS_CHECK(SGRPlayerIPadRegular(_host) && SGPlayerState().isPlaying);
    UIView *bottom = SGRFindByIdentifier(_host, @"npv.bottomStackView", NULL);
    CGFloat fullHeight = self.window.rootViewController.view.bounds.size.height;
    NSArray<NSNumber *> *heights = getenv("HARNESS_SHORT") ? @[@200, @320, @480] :
                                                             @[@200, @320, @480, @720, @(fullHeight)];
    __block NSUInteger step = 0;
    [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
        CGFloat height = heights[step++].doubleValue;
        self->_host.frame = CGRectMake(0, 0, self->_host.bounds.size.width, height);
        self->_openingSingleFrame = CGRectMake(0, height - bottom.bounds.size.height - 61.33,
                                               self->_host.bounds.size.width, bottom.bounds.size.height);
        bottom.frame = self->_openingSingleFrame;
        [self layOut];
        if (step != heights.count) return;
        [timer invalidate];
        [self checkOpeningSettles];
    }];
}

- (void)checkOpeningSettles {
    __block unsigned lastPasses = atomic_load(&openingLayoutPasses);
    __block CFTimeInterval quietSince = CACurrentMediaTime();
    [NSTimer scheduledTimerWithTimeInterval:0.01 repeats:YES block:^(NSTimer *timer) {
        unsigned passes = atomic_load(&openingLayoutPasses);
        if (passes != lastPasses) {
            lastPasses = passes;
            quietSince = CACurrentMediaTime();
            return;
        }
        // Observe an idle window, not merely the synchronous return from the last layout callback.
        if (CACurrentMediaTime() - quietSince < 0.2) return;
        [timer invalidate];
        NSLog(@"[harness] opening settled: %u host layout passes", passes);
        if (getenv("HARNESS_NO_ARTWORK")) HARNESS_CHECK(SGRNowPlayingArtwork(NULL, NULL) == nil);
        if (getenv("HARNESS_NO_ARTWORK") || getenv("HARNESS_SHORT")) {
            HARNESS_CHECK(!SGRPlayerTwoColumns());
            // An unchanged Spotify layout notification must not start another layout transaction.
            [self->_units.lastObject viewDidLayoutSubviews];
            [self->_host layoutIfNeeded];
            unsigned extra = atomic_load(&openingLayoutPasses) - passes;
            if (extra) HARNESS_FAIL(@"unchanged fallback caused %u extra host layouts", extra);
        } else {
            HARNESS_CHECK(SGRPlayerTwoColumns());
            UIView *bottom = SGRFindByIdentifier(self->_host, @"npv.bottomStackView", NULL);
            CGRect moved = bottom.frame;
            moved.origin.y -= 12;
            moved.size.height += 8;
            bottom.frame = moved;
            [self layOut];
            CGRect expected = self->_openingSingleFrame;
            expected.origin.y -= 12;
            expected.size.height += 8;
            self.window.traitOverrides.horizontalSizeClass = UIUserInterfaceSizeClassCompact;
            [self layOut];
            if (!CGRectEqualToRect(bottom.frame, expected)) {
                HARNESS_FAIL(@"vertical-change restoration %@, expected %@", NSStringFromCGRect(bottom.frame), NSStringFromCGRect(expected));
            }
        }
        dispatch_semaphore_signal(openingFinished);
        NSLog(@"[harness] adaptive checks: PASS (opening)");
        fflush(stdout);
    }];
}

- (void)runAdaptiveChecks {
    runScript(@[
        @[^BOOL {
            return SGRNowPlayingArtwork(NULL, NULL) != nil;
        }, ^{
            [self layOut];
            [self layOut];
            BOOL wide = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad && !getenv("HARNESS_COMPACT");
            UIView *bottom = SGRFindByIdentifier(self->_host, @"npv.bottomStackView", NULL);
            if (!wide) {
                HARNESS_CHECK(!SGRPlayerTwoColumns());
                HARNESS_CHECK(fabs(bottom.frame.size.width - self->_host.bounds.size.width) < 1);
                HARNESS_CHECK(!SGRPlayerLyricsOpen());
            } else {
                HARNESS_CHECK(SGRPlayerTwoColumns());
                HARNESS_CHECK(getenv("HARNESS_NO_LYRICS") ? SGRPlayerQueueSideShown() : SGRPlayerLyricsOpen());
                UIView *overlay = firstOfClass(self->_host, @"SGRPlayerLyricsOverlay");
                UIView *stage = [overlay valueForKey:@"stage"], *cover = [overlay valueForKey:@"thumb"];
                CGRect art = [cover convertRect:cover.bounds toView:self->_host];
                CGRect side = [stage convertRect:stage.bounds toView:self->_host];
                CGRect controls = [bottom convertRect:bottom.bounds toView:self->_host];
                BOOL rtl = getenv("HARNESS_RTL") != NULL;
                HARNESS_CHECK(art.size.width >= 72 && fabs(art.size.width - art.size.height) < 1);
                HARNESS_CHECK(CGRectGetMaxY(art) <= CGRectGetMinY(controls));
                HARNESS_CHECK(rtl ? CGRectGetMaxX(side) <= CGRectGetMinX(controls) :
                                   CGRectGetMaxX(controls) <= CGRectGetMinX(side));
                HARNESS_CHECK(CGRectContainsRect(self->_host.bounds, side));
                HARNESS_CHECK(CGRectContainsRect(self->_host.bounds, art));
                HARNESS_CHECK(CGRectContainsRect(self.window.rootViewController.view.bounds, self->_host.frame));
                HARNESS_CHECK([self->_host.accessibilityElements indexOfObject:bottom] <
                              [self->_host.accessibilityElements indexOfObject:overlay]);
                SGRGlyphButton *queue = (id)SGRFindByIdentifier(self->_host, @"vitrine.player.queue", NULL);
                HARNESS_CHECK(queue && queue.accessibilityLabel.length && queue.bounds.size.width >= 44);
                queue.onTap();
                HARNESS_CHECK(SGRPlayerQueueSideShown());
                UITableView *list = (id)SGRFindByIdentifier(stage, @"vitrine.queue", NULL);
                HARNESS_CHECK(list && list.window && list.bounds.size.height > 100);
                HARNESS_CHECK([list numberOfSections] > 0);
                SGRPlayerToggleLyrics();
                HARNESS_CHECK(getenv("HARNESS_NO_LYRICS") ? SGRPlayerQueueSideShown() : SGRPlayerLyricsOpen());
                self.window.traitOverrides.horizontalSizeClass = UIUserInterfaceSizeClassCompact;
                [self layOut];
                HARNESS_CHECK(!SGRPlayerTwoColumns() && !overlay.superview);
                HARNESS_CHECK(fabs(bottom.frame.size.width - self->_host.bounds.size.width) < 1);
                CGRect singleControls = bottom.frame;
                self.window.traitOverrides.horizontalSizeClass = UIUserInterfaceSizeClassRegular;
                [self layOut];
                [self layOut];
                HARNESS_CHECK(SGRPlayerTwoColumns());
                if (getenv("HARNESS_SHRINK")) {
                    CGRect fullHost = self->_host.frame;
                    // A short, regular-width window leaves no artwork band over Spotify's control units.
                    CGRect shortHost = fullHost;
                    shortHost.size.height = 480;
                    self->_host.frame = shortHost;
                    CGRect singleColumn = CGRectMake(0, 140, fullHost.size.width, 280);
                    bottom.frame = singleColumn;
                    [self layOut];
                    HARNESS_CHECK(self.window.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular);
                    HARNESS_CHECK(!SGRPlayerTwoColumns() && !overlay.superview && !SGRPlayerLyricsOpen());
                    if (!CGRectEqualToRect(bottom.frame, singleColumn)) {
                        HARNESS_FAIL(@"shrunken controls %@, expected %@", NSStringFromCGRect(bottom.frame), NSStringFromCGRect(singleColumn));
                    }
                    HARNESS_CHECK(self->_covers.alpha == 1);
                    [self layOut];
                    HARNESS_CHECK(CGRectEqualToRect(bottom.frame, singleColumn) && !overlay.superview);
                    self->_host.frame = fullHost;
                    bottom.frame = singleControls;
                    [self layOut];
                    HARNESS_CHECK(SGRPlayerTwoColumns());
                    NSLog(@"[harness] regular-width shrink restores single-column frames: PASS");
                }
                NSLog(@"[harness] adaptive frames: artwork %@ controls %@ side %@", NSStringFromCGRect(art),
                      NSStringFromCGRect(controls), NSStringFromCGRect(side));
            }
        }],
        @[^BOOL {
            if (!SGRPlayerTwoColumns() || SGRPlayerQueueSideShown()) return YES;
            UIView *overlay = firstOfClass(self->_host, @"SGRPlayerLyricsOverlay");
            UIView *lyrics = [overlay valueForKey:@"madeLyrics"];
            CALayer *drawn = lyrics.layer.presentationLayer;
            return drawn && drawn.opacity > 0.99 && lyricsMenuIn([overlay valueForKey:@"stage"]) != nil;
        }, ^{
            if (SGRPlayerTwoColumns()) {
                CGRect safe = self.window.safeAreaLayoutGuide.layoutFrame;
                UIView *footer = self->_units[5].view;
                CGRect row = [footer convertRect:footer.bounds toView:self.window];
                if (!CGRectContainsRect(safe, row)) HARNESS_FAIL(@"footer %@ outside window safe area %@", NSStringFromCGRect(row), NSStringFromCGRect(safe));
                UIView *overlay = firstOfClass(self->_host, @"SGRPlayerLyricsOverlay");
                UIView *stage = [overlay valueForKey:@"stage"];
                CGRect side = [stage convertRect:stage.bounds toView:self.window];
                HARNESS_CHECK(CGRectContainsRect(safe, side));
                if (SGRPlayerLyricsOpen()) {
                    UIButton *options = lyricsMenuIn(stage);
                    HARNESS_CHECK(options != nil && options.accessibilityLabel.length > 0);
                    CGRect frame = [options convertRect:options.bounds toView:self.window];
                    HARNESS_CHECK(CGRectContainsRect(side, frame) && CGRectContainsRect(safe, frame));
                    HARNESS_CHECK(!CGRectIntersectsRect(row, frame));
                }
                NSLog(@"[harness] safe footer %@ lyrics column %@", NSStringFromCGRect(row), NSStringFromCGRect(side));
            }
            NSLog(@"[harness] adaptive checks: PASS");
            fflush(stdout);
        }]
    ], 0);
}
