#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "LyricsTranslation.h"

NSString *SGLyricsTranslationDefaultPrompt(void) {
    return @"Use natural, idiomatic phrasing while preserving each line's meaning, tone, imagery, and level of formality. Do not add, omit, or move meaning between lines.";
}

static NSString *validatedPrompt(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] > SGLyricsTranslationPromptMaxLength) return nil;
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

NSString *SGLyricsTranslationPromptTemplate(void) {
    NSString *text = validatedPrompt([NSUserDefaults.standardUserDefaults objectForKey:SGKeyLyricsTranslationPrompt]);
    return text.length ? text : SGLyricsTranslationDefaultPrompt();
}

BOOL SGLyricsTranslationSetPrompt(NSString *text) {
    NSString *clean = validatedPrompt(text);
    if (!clean) return NO;
    if (!clean.length || [clean isEqualToString:SGLyricsTranslationDefaultPrompt()])
        [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyLyricsTranslationPrompt];
    else [NSUserDefaults.standardUserDefaults setObject:clean forKey:SGKeyLyricsTranslationPrompt];
    return YES;
}

@interface SGLyricsPromptEditor : SGPage <UITextViewDelegate>
@end

@implementation SGLyricsPromptEditor {
    UITextView *_text;
    UILabel *_limit;
    UIBarButtonItem *_save;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = SGL(@"settings.translation.prompt.title", @"Translation prompt");
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    // SGPage supplies Spotify's page protocol; this editor scrolls its own content, not table rows.
    self.tableView.scrollEnabled = NO;
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _save = [[UIBarButtonItem alloc] initWithTitle:SGL(@"common.save", @"Save")
        style:UIBarButtonItemStylePlain target:self action:@selector(save)];
    self.navigationItem.rightBarButtonItem = _save;

    _text = [UITextView new];
    _text.text = SGLyricsTranslationPromptTemplate();
    _text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _text.adjustsFontForContentSizeCategory = YES;
    _text.textColor = UIColor.labelColor;
    _text.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    _text.textContainerInset = UIEdgeInsetsMake(16, 16, 16, 16);
    _text.alwaysBounceVertical = YES;
    _text.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _text.accessibilityLabel = self.title;
    _text.delegate = self;

    UILabel *note = [UILabel new];
    note.text = SGL(@"settings.translation.prompt.help", @"{language} is replaced with the target language. The app adds the reply format and line-preservation rules. Applies to lyric translation with all three AI services, not pronunciation or notes.");
    note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    note.adjustsFontForContentSizeCategory = YES;
    note.textColor = UIColor.secondaryLabelColor;
    note.numberOfLines = 0;
    _limit = [UILabel new];
    _limit.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _limit.adjustsFontForContentSizeCategory = YES;
    _limit.numberOfLines = 0;
    UIButton *restore = [UIButton buttonWithType:UIButtonTypeSystem];
    [restore setTitle:SGL(@"settings.translation.prompt.restore", @"Restore default") forState:UIControlStateNormal];
    restore.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    restore.titleLabel.adjustsFontForContentSizeCategory = YES;
    restore.titleLabel.numberOfLines = 0;
    [restore addTarget:self action:@selector(restore) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *footer = [[UIStackView alloc] initWithArrangedSubviews:@[note, _limit, restore]];
    footer.axis = UILayoutConstraintAxisVertical;
    footer.spacing = 8;
    [restore.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    UIScrollView *scroll = [UIScrollView new];
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[_text, footer]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 12;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];
    [self.view addSubview:scroll];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    // At accessibility sizes the footer can scroll instead of squeezing the editor behind the keyboard.
    NSLayoutConstraint *fill = [content.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor constant:-20];
    fill.priority = UILayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:12],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-8],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:16],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32],
        [_text.heightAnchor constraintGreaterThanOrEqualToConstant:160], fill,
    ]];
    [self textViewDidChange:_text];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 0;
}
- (void)textViewDidChange:(UITextView *)textView {
    _save.enabled = validatedPrompt(textView.text) != nil;
    _limit.text = [NSString stringWithFormat:SGL(@"settings.translation.prompt.limit", @"%lu / %lu characters"),
                   (unsigned long)textView.text.length, (unsigned long)SGLyricsTranslationPromptMaxLength];
    _limit.textColor = _save.enabled ? UIColor.secondaryLabelColor : UIColor.systemRedColor;
}
- (void)restore {
    _text.text = SGLyricsTranslationDefaultPrompt();
    [self textViewDidChange:_text];
}
- (void)save {
    if (SGLyricsTranslationSetPrompt(_text.text)) [self.navigationController popViewControllerAnimated:YES];
}
@end

SGModRow *SGLyricsTranslationPromptRow(void) {
    SGModRow *row = SGPageRow(SGL(@"settings.translation.prompt.title", @"Translation prompt"), ^UIViewController *{
        return [SGLyricsPromptEditor new];
    });
    row.subtitle = SGL(@"settings.translation.prompt.footer", @"Shared by Gemini, Claude and OpenAI-compatible. Use Translate Again in the lyrics menu to replace a saved translation.");
    row.value = ^NSString *{
        return [SGLyricsTranslationPromptTemplate() isEqualToString:SGLyricsTranslationDefaultPrompt()]
            ? SGL(@"settings.translation.prompt.default", @"Default") : SGL(@"settings.translation.prompt.edited", @"Edited");
    };
    row.searchIdentifier = SGKeyLyricsTranslationPrompt;
    return row;
}
