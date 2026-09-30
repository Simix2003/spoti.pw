// The account sheet that replaces Spotify's left SideDrawer while Redesigned UI is on. The avatar on
// Home, Search and Library still opens Spotify's drawer; that drawer is kept out of sight and the sheet
// is read off its profile header and list, then each row is fired through Spotify's own ListRow.
//
//     AccountSheet.m   the page sheet: profile header, Mod Settings, then Spotify's account rows
//     AccountMenu.x    watches the avatar, claims the drawer, scrapes and fires
//
// Always on in the redesign. No settings of its own.
#import <UIKit/UIKit.h>

// One row of Spotify's drawer list the sheet can show and fire. `control` is the live ListRow; it is
// nil for a cached row opened before the scrape lands.
@interface SGRAccountRow : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *symbol;   // SF Symbol when Spotify's glyph cannot be scraped
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, weak) UIView *control;
@end

@interface SGRAccountSheet : UIViewController
@property (nonatomic, copy) void (^onProfile)(void);
@property (nonatomic, copy) void (^onModSettings)(void);
@property (nonatomic, copy) void (^onRow)(SGRAccountRow *row);
@property (nonatomic, copy) void (^onDismissed)(void);
- (void)setProfileName:(NSString *)name subtitle:(NSString *)subtitle avatar:(UIImage *)avatar;
- (void)setRows:(NSArray<SGRAccountRow *> *)rows;
@end
