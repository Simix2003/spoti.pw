// Account sheet: a Music-style page sheet over the (hidden) SideDrawer. Black field, hairlines under
// rows, glass nowhere behind the list. Profile header at the top; Mod Settings first among the rows;
// Spotify's scraped account / plan / navigation rows after that.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Account.h"

static const CGFloat kAvatar = 64;
static const CGFloat kRowHeight = 52;
static const CGFloat kIcon = 22;
static const CGFloat kHeaderBottom = 20;
static NSString *const kCellId = @"row";

static NSString *symbolFor(NSString *identifier) {
    if ([identifier isEqualToString:@"AccountSwitching.AddAccountRow"]) return @"person.badge.plus";
    if ([identifier isEqualToString:@"Components.UI.YourPlanRowSideDrawer"]) return @"crown";
    if ([identifier isEqualToString:@"Components.UI.NavigationRowSideDrawer"]) return @"chevron.forward.circle";
    return @"circle";
}

@implementation SGRAccountRow
@end

@interface SGRAccountSheet () <UITableViewDataSource, UITableViewDelegate, UISheetPresentationControllerDelegate>
@end

@implementation SGRAccountSheet {
    UITableView *_table;
    UIView *_header;
    UIImageView *_avatar;
    UILabel *_name;
    UILabel *_subtitle;
    UIControl *_profileTap;
    NSArray<SGRAccountRow *> *_rows;
    BOOL _closing;
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = self.sheetPresentationController;
    sheet.detents = @[
        [UISheetPresentationControllerDetent mediumDetent],
        [UISheetPresentationControllerDetent largeDetent],
    ];
    sheet.prefersGrabberVisible = YES;
    sheet.prefersScrollingExpandsWhenScrolledToEdge = YES;
    sheet.delegate = self;
    _rows = @[];
    return self;
}

- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    view.backgroundColor = SGRNeutralField();
    self.view = view;

    _table = [[UITableView alloc] initWithFrame:view.bounds style:UITableViewStylePlain];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.backgroundColor = UIColor.clearColor;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.rowHeight = kRowHeight;
    _table.dataSource = self;
    _table.delegate = self;
    _table.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    [_table registerClass:UITableViewCell.class forCellReuseIdentifier:kCellId];
    [view addSubview:_table];

    _header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, view.bounds.size.width, kAvatar + kHeaderBottom + 56)];
    _profileTap = [[UIControl alloc] initWithFrame:_header.bounds];
    _profileTap.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_profileTap addTarget:self action:@selector(profileTapped) forControlEvents:UIControlEventTouchUpInside];
    [_header addSubview:_profileTap];

    _avatar = [[UIImageView alloc] initWithFrame:CGRectMake(SGRSideMargin, 8, kAvatar, kAvatar)];
    _avatar.contentMode = UIViewContentModeScaleAspectFill;
    _avatar.clipsToBounds = YES;
    _avatar.layer.cornerRadius = kAvatar / 2;
    _avatar.backgroundColor = [SGRSecondary() colorWithAlphaComponent:0.2];
    _avatar.userInteractionEnabled = NO;
    [_header addSubview:_avatar];

    _name = [UILabel new];
    _name.textColor = SGRPrimary();
    _name.font = SGRFont(UIFontTextStyleTitle2, UIFontWeightBold, UIContentSizeCategoryAccessibilityLarge);
    _name.numberOfLines = 1;
    _name.userInteractionEnabled = NO;
    [_header addSubview:_name];

    _subtitle = [UILabel new];
    _subtitle.textColor = SGRSecondary();
    _subtitle.font = SGRFont(UIFontTextStyleSubheadline, UIFontWeightRegular, UIContentSizeCategoryAccessibilityLarge);
    _subtitle.numberOfLines = 1;
    _subtitle.userInteractionEnabled = NO;
    [_header addSubview:_subtitle];

    _table.tableHeaderView = _header;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = _header.bounds.size.width;
    CGFloat textX = SGRSideMargin + kAvatar + SGRGrid * 1.5;
    CGFloat textW = MAX(0, width - textX - SGRSideMargin);
    CGFloat nameH = ceil(_name.font.lineHeight);
    CGFloat subH = ceil(_subtitle.font.lineHeight);
    CGFloat textBlock = nameH + (_subtitle.text.length ? 4 + subH : 0);
    CGFloat textY = _avatar.frame.origin.y + (_avatar.bounds.size.height - textBlock) / 2;
    _name.frame = CGRectMake(textX, textY, textW, nameH);
    _subtitle.frame = CGRectMake(textX, CGRectGetMaxY(_name.frame) + 4, textW, subH);
    _subtitle.hidden = _subtitle.text.length == 0;
    CGFloat height = CGRectGetMaxY(_avatar.frame) + kHeaderBottom;
    if (_header.bounds.size.height != height) {
        CGRect frame = _header.frame;
        frame.size.height = height;
        _header.frame = frame;
        _table.tableHeaderView = _header;
    }
}

- (void)setProfileName:(NSString *)name subtitle:(NSString *)subtitle avatar:(UIImage *)avatar {
    _name.text = name.length ? name : @" ";
    _subtitle.text = subtitle ?: @"";
    if (avatar) _avatar.image = avatar;
    else if (!_avatar.image) {
        // Initial disc when Spotify has no picture yet.
        NSString *initial = name.length ? [[name substringToIndex:1] uppercaseString] : @"?";
        _avatar.image = [self initialImage:initial];
    }
    [self.view setNeedsLayout];
}

- (UIImage *)initialImage:(NSString *)letter {
    CGSize size = CGSizeMake(kAvatar, kAvatar);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[SGRSecondary() colorWithAlphaComponent:0.25] setFill];
        UIRectFill(CGRectMake(0, 0, size.width, size.height));
        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:28 weight:UIFontWeightSemibold],
            NSForegroundColorAttributeName: SGRPrimary(),
        };
        CGSize text = [letter sizeWithAttributes:attrs];
        [letter drawAtPoint:CGPointMake((size.width - text.width) / 2, (size.height - text.height) / 2) withAttributes:attrs];
    }];
}

- (void)setRows:(NSArray<SGRAccountRow *> *)rows {
    _rows = [rows copy] ?: @[];
    [_table reloadData];
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1 + (NSInteger)_rows.count; // Mod Settings + scraped
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellId forIndexPath:indexPath];
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIBackgroundConfiguration *bg = [UIBackgroundConfiguration clearConfiguration];
    cell.backgroundConfiguration = bg;
    cell.contentConfiguration = nil;

    for (UIView *sub in [cell.contentView.subviews copy]) [sub removeFromSuperview];
    NSArray<CALayer *> *layers = [cell.contentView.layer.sublayers copy];
    for (CALayer *layer in layers) {
        if ([layer.name isEqualToString:@"hairline"]) [layer removeFromSuperlayer];
    }

    NSString *title;
    NSString *subtitle;
    UIImage *image;
    NSString *symbol;
    if (indexPath.row == 0) {
        title = @"Mod Settings";
        symbol = @"slider.horizontal.3";
    } else {
        SGRAccountRow *row = _rows[(NSUInteger)indexPath.row - 1];
        title = row.title;
        subtitle = row.subtitle;
        image = row.image;
        symbol = symbolFor(row.identifier);
    }

    UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(SGRSideMargin, (kRowHeight - kIcon) / 2, kIcon, kIcon)];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    if (image) {
        icon.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    } else {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
        icon.image = [[UIImage systemImageNamed:symbol ?: @"chevron.right" withConfiguration:config]
                      imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    icon.tintColor = SGRPrimary();
    [cell.contentView addSubview:icon];

    UILabel *label = [UILabel new];
    label.text = title;
    label.textColor = SGRPrimary();
    label.font = SGRFont(UIFontTextStyleBody, UIFontWeightRegular, UIContentSizeCategoryAccessibilityLarge);
    label.numberOfLines = 1;
    [cell.contentView addSubview:label];

    UILabel *detail = nil;
    if (subtitle.length) {
        detail = [UILabel new];
        detail.text = subtitle;
        detail.textColor = SGRSecondary();
        detail.font = SGRFont(UIFontTextStyleSubheadline, UIFontWeightRegular, UIContentSizeCategoryAccessibilityLarge);
        detail.textAlignment = NSTextAlignmentRight;
        detail.numberOfLines = 1;
        [cell.contentView addSubview:detail];
    }

    UIImageView *chevron = [[UIImageView alloc] initWithImage:
        [[UIImage systemImageNamed:@"chevron.right"
                withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold]]
         imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    chevron.tintColor = SGRTertiary();
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    [cell.contentView addSubview:chevron];

    CGFloat width = tableView.bounds.size.width;
    CGFloat chevronW = 12, chevronH = 14;
    CGFloat chevronX = width - SGRSideMargin - chevronW;
    chevron.frame = CGRectMake(chevronX, (kRowHeight - chevronH) / 2, chevronW, chevronH);
    CGFloat textX = SGRSideMargin + kIcon + SGRGrid * 1.5;
    CGFloat detailW = 0;
    if (detail) {
        detailW = MIN(120, [detail sizeThatFits:CGSizeMake(120, kRowHeight)].width);
        detail.frame = CGRectMake(chevronX - SGRGrid - detailW, 0, detailW, kRowHeight);
    }
    CGFloat textW = MAX(0, (detail ? CGRectGetMinX(detail.frame) : chevronX) - SGRGrid - textX);
    label.frame = CGRectMake(textX, 0, textW, kRowHeight);

    CALayer *line = [CALayer layer];
    line.name = @"hairline";
    line.backgroundColor = SGRHairline().CGColor;
    CGFloat thickness = 1.0 / MAX(1, tableView.window.screen.scale ?: UIScreen.mainScreen.scale);
    line.frame = CGRectMake(textX, kRowHeight - thickness, width - textX - SGRSideMargin, thickness);
    [cell.contentView.layer addSublayer:line];

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    _closing = YES;
    if (indexPath.row == 0) {
        if (self.onModSettings) self.onModSettings();
        return;
    }
    SGRAccountRow *row = _rows[(NSUInteger)indexPath.row - 1];
    if (self.onRow) self.onRow(row);
}

- (void)profileTapped {
    _closing = YES;
    if (self.onProfile) self.onProfile();
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    if (_closing) return;
    if (self.onDismissed) self.onDismissed();
}

@end
