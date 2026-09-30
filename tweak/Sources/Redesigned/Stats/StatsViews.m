#import "Redesigned/Kit/SGRKit.h"
#import "StatsViews.h"

static const CGFloat kPad = 16;

static UIFont *rounded(UIFont *font) {
    UIFontDescriptor *design = [font.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    return design ? [UIFont fontWithDescriptor:design size:font.pointSize] : font;
}

static UILabel *makeLabel(UIFontTextStyle style, UIFontWeight weight, UIColor *color, NSInteger lines) {
    UILabel *label = [UILabel new];
    label.font = SGRFont(style, weight, UIContentSizeCategoryAccessibilityMedium);
    label.textColor = color;
    label.numberOfLines = lines;
    label.adjustsFontForContentSizeCategory = NO;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

#pragma mark - chip

// A small capsule of text and an optional symbol, on the solid white-16% fill (glass is for controls).
@interface SGRStatsChip : UIView
- (void)setText:(NSString *)text symbol:(NSString *)symbol tint:(UIColor *)tint filled:(BOOL)filled;
@end

@implementation SGRStatsChip {
    UILabel *_label;
    UIImageView *_icon;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        self.userInteractionEnabled = NO;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        _label = makeLabel(UIFontTextStyleCaption1, UIFontWeightSemibold, SGRPrimary(), 1);
        _icon = [UIImageView new];
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:_icon];
        [self addSubview:_label];
    }
    return self;
}

- (void)setText:(NSString *)text symbol:(NSString *)symbol tint:(UIColor *)tint filled:(BOOL)filled {
    _label.text = text;
    UIColor *ink = filled ? UIColor.blackColor : tint;
    _label.textColor = filled ? UIColor.blackColor : SGRPrimary();
    _icon.tintColor = ink;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightBold];
    _icon.image = symbol.length ? [UIImage systemImageNamed:symbol withConfiguration:config] : nil;
    self.backgroundColor = filled ? tint : SGRSolidGlassFill();
    [self setNeedsLayout];
}

- (CGSize)sizeThatFits:(CGSize)size {
    CGSize text = [_label sizeThatFits:CGSizeMake(MAX(0, size.width - 28), 30)];
    CGFloat icon = _icon.image ? 14 + 4 : 0;
    return CGSizeMake(MIN(size.width, ceil(text.width) + icon + 20), 26);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = self.bounds.size.height / 2;
    CGFloat x = 10;
    if (_icon.image) {
        _icon.frame = CGRectMake(x, (self.bounds.size.height - 14) / 2, 14, 14);
        x += 18;
    }
    _label.frame = CGRectMake(x, 0, MAX(0, self.bounds.size.width - x - 10), self.bounds.size.height);
}

@end

#pragma mark - tile card

@interface SGRStatsTileCard : UIView
- (void)configureWithTile:(SGRStatsTile *)tile image:(UIImage *)image;
@end

@implementation SGRStatsTileCard {
    SGRStatsTile *_tile;
    CAGradientLayer *_glow;
    UIImageView *_art;
    UILabel *_caption;
    UILabel *_value;
    UILabel *_unit;
    SGRStatsChip *_chip;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        self.layer.cornerRadius = SGRRadiusCard;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.backgroundColor = SGRElevated(UIColor.blackColor);

        _glow = [CAGradientLayer layer];
        _glow.startPoint = CGPointMake(0, 0);
        _glow.endPoint = CGPointMake(1, 1);
        [self.layer addSublayer:_glow];

        _art = [UIImageView new];
        _art.contentMode = UIViewContentModeScaleAspectFill;
        _art.clipsToBounds = YES;
        _art.layer.cornerCurve = kCACornerCurveContinuous;
        _art.backgroundColor = SGRSolidGlassFill();
        _art.tintColor = SGRTertiary();
        _caption = makeLabel(UIFontTextStyleCaption1, UIFontWeightSemibold, SGRSecondary(), 1);
        _value = makeLabel(UIFontTextStyleHeadline, UIFontWeightBold, SGRPrimary(), 2);
        _unit = makeLabel(UIFontTextStyleSubheadline, UIFontWeightSemibold, SGRSecondary(), 1);
        _chip = [SGRStatsChip new];
        for (UIView *view in @[_art, _caption, _value, _unit, _chip]) [self addSubview:view];
    }
    return self;
}

- (void)configureWithTile:(SGRStatsTile *)tile image:(UIImage *)image {
    _tile = tile;
    BOOL minutes = tile.kind == SGRStatsTileMinutes;
    _caption.text = tile.title;
    _value.text = tile.value;
    _unit.text = minutes ? @"minuti" : nil;
    _art.hidden = minutes;
    _art.image = image ?: [UIImage systemImageNamed:(tile.kind == SGRStatsTileFavoriteArtist || tile.kind == SGRStatsTileFriendsArtists) ? @"person.fill" : @"music.note"];
    _art.contentMode = image ? UIViewContentModeScaleAspectFill : UIViewContentModeCenter;

    UIColor *accent = SGRAccent();
    _glow.hidden = !minutes;
    _glow.colors = @[(id)[accent colorWithAlphaComponent:0.55].CGColor, (id)[accent colorWithAlphaComponent:0].CGColor];
    if (minutes) {
        _value.font = rounded(SGRMonospacedDigitsFont([UIFont systemFontOfSize:64 weight:UIFontWeightHeavy]));
        _value.numberOfLines = 1;
        _value.adjustsFontSizeToFitWidth = YES;
        _value.minimumScaleFactor = 0.5;
    } else {
        _value.font = SGRFont(UIFontTextStyleHeadline, UIFontWeightBold, UIContentSizeCategoryAccessibilityMedium);
        _value.numberOfLines = 2;
        _value.adjustsFontSizeToFitWidth = NO;
    }

    if (minutes && tile.friendRank > 0) {
        BOOL first = tile.friendRank == 1;
        [_chip setText:first ? @"Numero 1 tra gli amici" : [NSString stringWithFormat:@"Numero %ld tra gli amici", (long)tile.friendRank]
                symbol:first ? @"crown.fill" : @"person.2.fill" tint:accent filled:first];
        _chip.hidden = NO;
    } else if (tile.movement != 0) {
        BOOL up = tile.movement > 0;
        [_chip setText:[NSString stringWithFormat:@"%@ di %ld", up ? @"Sale" : @"Scende", (long)labs(tile.movement)]
                symbol:up ? @"arrow.up" : @"arrow.down" tint:up ? UIColor.systemGreenColor : UIColor.systemRedColor filled:NO];
        _chip.hidden = NO;
    } else if (tile.rising) {
        [_chip setText:@"In ascesa" symbol:@"chart.line.uptrend.xyaxis" tint:accent filled:NO];
        _chip.hidden = NO;
    } else {
        _chip.hidden = YES;
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    _glow.frame = self.bounds;
    if (w < 2 || h < 2) return;
    CGFloat inner = MAX(0, w - 2 * kPad);

    if (_tile.kind == SGRStatsTileMinutes) {
        _caption.frame = CGRectMake(kPad, kPad, inner, 20);
        CGSize chip = _chip.hidden ? CGSizeZero : [_chip sizeThatFits:CGSizeMake(inner, 26)];
        _chip.frame = CGRectMake(kPad, h - kPad - chip.height, chip.width, chip.height);
        CGFloat numberHeight = MIN(76, MAX(40, h - 20 - 2 * kPad - chip.height - 36));
        _value.frame = CGRectMake(kPad, CGRectGetMaxY(_caption.frame) + 4, inner, numberHeight);
        _unit.frame = CGRectMake(kPad, CGRectGetMaxY(_value.frame), inner, 22);
        return;
    }

    BOOL wide = w > h * 1.4;
    if (wide) {
        CGFloat side = MIN(h - 2 * 12, 72);
        _art.frame = CGRectMake(12, (h - side) / 2, side, side);
    } else {
        CGFloat side = MIN(inner, h * 0.56);
        _art.frame = CGRectMake(kPad, kPad, side, side);
    }
    BOOL round = _tile.kind == SGRStatsTileFavoriteArtist || _tile.kind == SGRStatsTileFriendsArtists;
    _art.layer.cornerRadius = round ? _art.bounds.size.width / 2 : SGRRadiusCover;

    CGFloat x = wide ? CGRectGetMaxX(_art.frame) + 12 : kPad;
    CGFloat textWidth = MAX(0, w - x - kPad);
    CGFloat y = wide ? 12 : CGRectGetMaxY(_art.frame) + 12;
    CGSize chip = _chip.hidden ? CGSizeZero : [_chip sizeThatFits:CGSizeMake(textWidth, 26)];
    CGFloat bottom = h - 12 - (chip.height ? chip.height + 6 : 0);
    _caption.frame = CGRectMake(x, y, textWidth, 16);
    CGFloat valueTop = CGRectGetMaxY(_caption.frame) + 2;
    _value.frame = CGRectMake(x, valueTop, textWidth, MAX(0, MIN(44, bottom - valueTop)));
    _chip.frame = CGRectMake(x, h - 12 - chip.height, chip.width, chip.height);
}

@end

#pragma mark - grid overlay

@implementation SGRStatsGridOverlay {
    NSMutableArray<SGRStatsTileCard *> *_cards;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.blackColor;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _cards = [NSMutableArray array];
    }
    return self;
}

- (void)setTiles:(NSArray<SGRStatsTile *> *)tiles frames:(NSArray<NSValue *> *)frames images:(NSArray *)images {
    while (_cards.count > tiles.count) {
        [_cards.lastObject removeFromSuperview];
        [_cards removeLastObject];
    }
    while (_cards.count < tiles.count) {
        SGRStatsTileCard *card = [SGRStatsTileCard new];
        [self addSubview:card];
        [_cards addObject:card];
    }
    for (NSUInteger i = 0; i < tiles.count; i++) {
        id image = i < images.count ? images[i] : nil;
        [_cards[i] configureWithTile:tiles[i] image:[image isKindOfClass:UIImage.class] ? image : nil];
        _cards[i].frame = frames[i].CGRectValue;
    }
}

@end

#pragma mark - summary overlay

@implementation SGRStatsSummaryOverlay {
    UILabel *_number;
    UILabel *_unit;
    UILabel *_range;
    SGRStatsChip *_chip;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.blackColor;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _number = makeLabel(UIFontTextStyleLargeTitle, UIFontWeightHeavy, SGRPrimary(), 1);
        _number.adjustsFontSizeToFitWidth = YES;
        _number.minimumScaleFactor = 0.5;
        _unit = makeLabel(UIFontTextStyleTitle3, UIFontWeightSemibold, SGRPrimary(), 1);
        _range = makeLabel(UIFontTextStyleFootnote, UIFontWeightMedium, SGRSecondary(), 1);
        _chip = [SGRStatsChip new];
        for (UIView *view in @[_number, _unit, _range, _chip]) [self addSubview:view];
    }
    return self;
}

- (void)setSummary:(SGRStatsSummary *)summary range:(NSString *)range comparison:(NSString *)comparison {
    _number.font = rounded(SGRMonospacedDigitsFont([UIFont systemFontOfSize:48 weight:UIFontWeightHeavy]));
    _number.text = summary.number;
    _unit.text = summary.unit;
    _range.text = range;
    _chip.hidden = comparison.length == 0;
    if (comparison.length) [_chip setText:comparison symbol:nil tint:SGRAccent() filled:NO];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    if (w < 2 || h < 2) return;
    CGFloat numberWidth = MIN(ceil([_number sizeThatFits:CGSizeMake(w, h)].width), w * 0.55);
    CGFloat numberHeight = MIN(58, h - 4);
    CGFloat top = MAX(0, (h - numberHeight) / 2);
    _number.frame = CGRectMake(0, top, numberWidth, numberHeight);
    CGFloat x = numberWidth + 10;
    CGFloat textWidth = MAX(0, w - x);
    _unit.frame = CGRectMake(x, top + numberHeight - 46, textWidth, 24);
    _range.frame = CGRectMake(x, CGRectGetMaxY(_unit.frame), textWidth, 18);
    if (!_chip.hidden) {
        CGSize chip = [_chip sizeThatFits:CGSizeMake(w, 26)];
        _chip.frame = CGRectMake(w - chip.width, MAX(0, top - 4), chip.width, chip.height);
    }
}

@end
