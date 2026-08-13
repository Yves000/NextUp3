#import "NUPrefsRootListController.h"
#import "NUPrefsHeaderView.h"
#import "NUPrefs.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>

// Renders another installed app's icon. Present and stable across the deployed iOS range
// (15–18) inside Preferences.app; guarded with -respondsToSelector: so a future rename
// just drops the icon rather than crashing Settings.
@interface UIImage (NUAppIcons)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier
                                               format:(int)format
                                                scale:(CGFloat)scale;
@end

// LaunchServices, resolved via NSClassFromString so we don't link the private framework.
// LSApplicationProxy answers "is this app installed"; LSApplicationWorkspace lets us observe
// installs/uninstalls live so the pane can refresh without being reopened.
@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSString *shortVersionString;
@end

@protocol LSApplicationWorkspaceObserverProtocol <NSObject>
@optional
- (void)applicationsDidInstall:(NSArray *)apps;
- (void)applicationsDidUninstall:(NSArray *)apps;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (void)addObserver:(id)observer;
- (void)removeObserver:(id)observer;
@end

// UIKit's model of the sensor housing: the cutout this panel has, in screen points. On iPhone
// the shape is a UISDisplaySingleRectShape, i.e. it also conforms to _UIDisplayInfoRectShape
// and answers -rect; a device without a cutout has no exclusion area at all. Present since
// iOS 16 and still there on 26, but guarded with -respondsToSelector: either way.
@interface UIScreen (NUDisplayInfo)
- (id)_exclusionArea;
- (unsigned long long)_artworkSubtype;
@end

@protocol NUDisplayInfoRectShape <NSObject>
- (CGRect)rect;
@end

// Per-app toggle key → its app's bundle id. The single source of truth for the app bundle
// ids. The master switch and the interface rows return nil (kept as-is, no icon, never hidden).
static NSString *NUBundleIDForKey(NSString *key) {
    if ([key isEqualToString:@"enabledMusic"])        return @"com.apple.Music";
    if ([key isEqualToString:@"enabledPodcasts"])     return @"com.apple.podcasts";
    if ([key isEqualToString:@"enabledYouTubeMusic"]) return @"com.google.ios.youtubemusic";
    if ([key isEqualToString:@"enabledYouTube"])      return @"com.google.ios.youtube";
    if ([key isEqualToString:@"enabledSpotify"])      return @"com.spotify.client";
    return nil;
}

// The five app-toggle keys, in display order — the canonical iteration list for the
// install-state signature below.
static NSArray<NSString *> *NUAppToggleKeys(void) {
    return @[@"enabledMusic", @"enabledPodcasts", @"enabledYouTubeMusic", @"enabledYouTube", @"enabledSpotify"];
}

// YES if the app is installed on this device. Fails OPEN — if LaunchServices is unavailable
// we return YES so a real app's toggle is never hidden by mistake; only a definitive
// "not installed" hides a row. shortVersionString is the reliable indicator:
// applicationProxyForIdentifier: can hand back a placeholder proxy (no version) for an app
// that was previously installed. (Same check Hush uses.)
static BOOL NUAppInstalled(NSString *bundleID) {
    if (!bundleID) return YES;                               // non-app row: always keep
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (!proxyClass) return YES;                             // LS unavailable → fail open
    LSApplicationProxy *proxy = [proxyClass applicationProxyForIdentifier:bundleID];
    return [proxy respondsToSelector:@selector(shortVersionString)]
        && [proxy shortVersionString].length > 0;
}

// Order-stable signature (e.g. "1101") of which of our apps are installed right now, so a
// workspace callback can cheaply tell whether anything RELEVANT changed before reloading —
// installing/removing an unrelated app must not thrash the pane.
static NSString *NUInstalledSignature(void) {
    NSMutableString *sig = [NSMutableString string];
    for (NSString *key in NUAppToggleKeys())
        [sig appendFormat:@"%d", NUAppInstalled(NUBundleIDForKey(key)) ? 1 : 0];
    return sig;
}

// MobileGestalt's one-argument query, resolved via dlsym so this bundle links nothing
// private: libMobileGestalt is already loaded in every UIKit process, so RTLD_DEFAULT
// finds it. A missing symbol or an unanswerable question yields -1 below.
typedef CFTypeRef (*NUMGCopyAnswer)(CFStringRef);

// The display-artwork subtype — the panel's pixel height (2532 = iPhone 14, 2556 = 14 Pro …) —
// as MobileGestalt has it, or -1 if it won't answer.
//
// The question is "ArtworkTraits", NOT "ArtworkDeviceSubType": the answer is a dictionary that
// carries the subtype alongside idiom, scale and gamut. There is no scalar question named after
// the subtype — asking for one returns nothing at all, on every device.
//
// MobileGestalt is asked rather than UIKit or the panel geometry because this cache entry is
// what the tweaks that bring the island to older devices rewrite: VisibleIsland stores
// {ArtworkDeviceSubType = 2556} under the hashed ArtworkTraits key in CacheExtra. It is the only
// signal a spoofed island moves.
static NSInteger NUMobileGestaltArtworkSubType(void) {
    NUMGCopyAnswer copyAnswer = (NUMGCopyAnswer)dlsym(RTLD_DEFAULT, "MGCopyAnswer");
    if (!copyAnswer) return -1;
    CFTypeRef answer = copyAnswer(CFSTR("ArtworkTraits"));
    if (!answer) return -1;
    id traits = (__bridge id)answer;
    NSInteger subType = -1;
    if ([traits isKindOfClass:NSDictionary.class]) {
        id value = ((NSDictionary *)traits)[@"ArtworkDeviceSubType"];
        if ([value respondsToSelector:@selector(integerValue)]) subType = [value integerValue];
    }
    CFRelease(answer);
    return subType;
}

// The artwork subtype from whichever source will state it, or -1 if none will. MobileGestalt
// comes first because that is where a spoof is written; UIKit's resolved value is the same
// number read back out of the frameworks, and is equally spoof-aware — a spoofed cache is what
// UIKit resolved it from.
static NSInteger NUArtworkSubType(void) {
    NSInteger subType = NUMobileGestaltArtworkSubType();
    if (subType > 0) return subType;
    UIScreen *screen = UIScreen.mainScreen;
    if ([screen respondsToSelector:@selector(_artworkSubtype)]) {
        unsigned long long fromUIKit = [screen _artworkSubtype];
        if (fromUIKit > 0) return (NSInteger)fromUIKit;
    }
    return -1;
}

// YES if this device shows a Dynamic Island, i.e. whether the "Dynamic Island" row is worth
// offering at all. iOS 16 is the floor — that is where the system aperture arrived — and the
// rest takes three steps, because no single signal covers both real and spoofed islands:
//
//  1. An artwork subtype known to carry an island wins outright. This is the only step a spoof
//     can move, so it runs first — a notched phone or an iPad spoofed into an island keeps its
//     toggle, even though step 2 would call its panel islandless.
//  2. Otherwise the panel decides: a notch is cut into the top edge (exclusion area at y = 0),
//     an island floats below it (y = 14 on an iPhone 17), a home-button device has no exclusion
//     area at all. Physical, so it needs no table and stays right on unknown hardware.
//  3. Only if UIKit won't say either: fail open on phones, like NUAppInstalled does — a real
//     island must never lose its toggle — but never on iPad, which has no aperture to speak of.
static BOOL NUDeviceHasDynamicIsland(void) {
    static BOOL hasIsland = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 16) return;
        static const NSInteger islandSubTypes[] = {
            2556,   // 14 Pro / 15 / 15 Pro / 16 / 16e
            2622,   // 16 Pro / 17 / 17 Pro
            2796,   // 14 Pro Max / 15 Plus / 15 Pro Max / 16 Plus
            2868,   // 16 Pro Max / 17 Pro Max
        };
        NSInteger subType = NUArtworkSubType();
        for (size_t i = 0; i < sizeof(islandSubTypes) / sizeof(*islandSubTypes); i++)
            if (subType == islandSubTypes[i]) { hasIsland = YES; return; }

        UIScreen *screen = UIScreen.mainScreen;
        if ([screen respondsToSelector:@selector(_exclusionArea)]) {
            id<NUDisplayInfoRectShape> cutout = [screen _exclusionArea];
            if (!cutout) return;                                    // no cutout → no island
            if ([cutout respondsToSelector:@selector(rect)]) {
                hasIsland = [cutout rect].origin.y > 0.0;
                return;
            }
        }
        hasIsland = (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone);
    });
    return hasIsland;
}

// Fetch an app's icon and mask it to the classic Settings app-icon look (~29pt squircle).
// Returns nil if the artwork can't be produced, in which case the row just stays text-only.
static UIImage *NUAppIconImage(NSString *bundleID) {
    if (!bundleID) return nil;
    if (![UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)])
        return nil;

    CGFloat scale = UIScreen.mainScreen.scale;
    UIImage *raw = nil;
    // Variant 2 is the home-screen-sized (best quality) artwork; fall down the variants in
    // case a given iOS doesn't vend it, and downscale to the cell size for a crisp result.
    for (int variant = 2; variant >= 0 && !raw; variant--)
        raw = [UIImage _applicationIconImageForBundleIdentifier:bundleID format:variant scale:scale];
    if (!raw) return nil;

    CGFloat side = 29.0;   // classic Settings icon point size
    CGRect rect = CGRectMake(0, 0, side, side);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:rect.size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        // 0.2237 · side ≈ the iOS icon corner radius; a plain rounded rect is indistinguishable
        // from the true squircle at this size.
        [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:side * 0.2237] addClip];
        [raw drawInRect:rect];
    }];
}

// The name shown in the header and, once it scrolls away, in the navigation bar. Root.plist's
// title is the source; this is only the fallback for the window before Preferences has applied
// it.
static NSString *const kNUPaneTitle = @"NextUp 3";

// Target of the Source Code row. Kept in step with control's Homepage field.
static NSString *const kNURepositoryURL = @"https://github.com/Yves000/NextUp3";

static void *kNUContentOffsetContext = &kNUContentOffsetContext;

// The mark on the Source Code row: a custom SF Symbol from the asset catalog compiled into this
// bundle (see the actool step in the Makefile). It has to be a symbol — Root.plist's `icon` key
// names a file that Preferences rasterises at a size of its own choosing, where a symbol is drawn
// by UIKit at the row's own metric. Body font for that metric so it follows Dynamic Type, at the
// large scale so it sits slightly above the label rather than level with it.
static UIImage *NUGitHubRowIcon(NSBundle *bundle) {
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration
        configurationWithFont:[UIFont preferredFontForTextStyle:UIFontTextStyleBody]
                        scale:UIImageSymbolScaleLarge];
    UIImage *symbol = [UIImage imageNamed:@"github" inBundle:bundle withConfiguration:configuration];
    return [symbol imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// The Source Code row's label, localised against the table Preferences itself localises
// Root.plist with — keyed by the English source string, the convention that table uses. Read here
// rather than off the specifier so it does not depend on the specifiers having loaded, and so the
// header's icon and the row can never announce two different things.
static NSString *NUSourceCodeRowTitle(void) {
    NSString *fallback = @"Source Code";
    NSBundle *bundle = [NSBundle bundleForClass:NUPrefsRootListController.class];
    NSString *value = [bundle localizedStringForKey:fallback value:fallback table:@"Root"];
    return value.length ? value : fallback;
}

@interface NUPrefsRootListController () <LSApplicationWorkspaceObserverProtocol> {
    NSString *_installedSignature;   // NUInstalledSignature() as of the last specifier build
    NUPrefsHeaderView *_headerView;
    UITableView *_observedTable;
    BOOL _navigationTitleShown;
}
@end

@implementation NUPrefsRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSArray *loaded = [self loadSpecifiersFromPlistName:@"Root" target:self];
        // Keep every row except the toggle of an app that isn't installed and the Dynamic
        // Island row on a device without one; give the surviving app rows their real icon.
        // Built once (the guard above keeps it from re-running until -reloadSpecifiers clears
        // the cache on an install/uninstall).
        UIImage *mark = NUGitHubRowIcon([NSBundle bundleForClass:self.class]);
        NSMutableArray *kept = [NSMutableArray arrayWithCapacity:loaded.count];
        for (PSSpecifier *spec in loaded) {
            NSString *key = [spec propertyForKey:@"key"];
            if ([key isEqualToString:@"showDynamicIsland"] && !NUDeviceHasDynamicIsland())
                continue;                                          // no island → no toggle
            NSString *bundleID = NUBundleIDForKey(key);
            if (bundleID && !NUAppInstalled(bundleID)) continue;   // app not on device → drop it
            UIImage *icon = NUAppIconImage(bundleID);
            if (icon) [spec setProperty:icon forKey:@"iconImage"];
            // Set here rather than in the plist for the same reason the app icons are: the `icon`
            // key takes a file name, so it can only name a bitmap.
            if (mark && [spec.identifier isEqualToString:@"sourceCode"])
                [spec setProperty:mark forKey:@"iconImage"];
            [kept addObject:spec];
        }
        // If dropping apps emptied a section, remove its now-dangling header (a group cell with
        // no rows before the next group / end of list). Music + Podcasts are normally present so
        // the Apps group survives, but both are user-removable on iOS 14+, so handle it.
        for (NSInteger i = (NSInteger)kept.count - 1; i >= 0; i--) {
            if (((PSSpecifier *)kept[i]).cellType != PSGroupCell) continue;
            BOOL hasRows = (i + 1 < (NSInteger)kept.count) &&
                           ((PSSpecifier *)kept[i + 1]).cellType != PSGroupCell;
            if (!hasRows) [kept removeObjectAtIndex:i];
        }
        _specifiers = kept;
        _installedSignature = NUInstalledSignature();   // baseline for live change detection
    }
    return _specifiers;
}

#pragma mark - Source Code row

- (void)openSourceRepository {
    NSURL *url = [NSURL URLWithString:kNURepositoryURL];
    if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    // Otherwise the row stays highlighted while Safari is in front.
    NSIndexPath *selected = self.table.indexPathForSelectedRow;
    if (selected) [self.table deselectRowAtIndexPath:selected animated:YES];
}

// A template image takes its view's tint, which in a Settings table is the accent colour; the
// mark reads as text, so it takes the label colour. The app icons above are not templates and
// are unaffected.
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    if ([spec.identifier isEqualToString:@"sourceCode"])
        cell.imageView.tintColor = UIColor.labelColor;
    return cell;
}

#pragma mark - Header and navigation title

// Also observes app installs/uninstalls so the list updates live (e.g. installing YouTube Music
// from the App Store makes its toggle appear here without reopening the pane). addObserver:
// doesn't retain us, so -dealloc still runs and unregisters.
- (void)viewDidLoad {
    [super viewDidLoad];
    Class ws = NSClassFromString(@"LSApplicationWorkspace");
    if (ws) [[ws defaultWorkspace] addObserver:self];

    NSString *version = [[NSBundle bundleForClass:self.class]
                            objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"";
    _headerView = [[NUPrefsHeaderView alloc] initWithTitle:self.title ?: kNUPaneTitle
                                                   version:version];
    // The icon is the pane's picture of the tweak, so it goes where the Source Code row goes —
    // the same selector, so the two can never drift to different repositories.
    [_headerView setIconTarget:self
                        action:@selector(openSourceRepository)
            accessibilityLabel:NUSourceCodeRowTitle()];
    self.table.tableHeaderView = _headerView;

    // The offset is observed rather than taken from -scrollViewDidScroll:, which needs this
    // controller to be the table's delegate — Preferences does not promise that, and a missed
    // callback would strand the title hidden.
    _observedTable = self.table;
    [_observedTable addObserver:self
                     forKeyPath:@"contentOffset"
                        options:NSKeyValueObservingOptionNew
                        context:kNUContentOffsetContext];

    self.navigationItem.title = @"";
}

- (void)dealloc {
    Class ws = NSClassFromString(@"LSApplicationWorkspace");
    if (ws) [[ws defaultWorkspace] removeObserver:self];
    [_observedTable removeObserver:self forKeyPath:@"contentOffset" context:kNUContentOffsetContext];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if (context != kNUContentOffsetContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    [self updateNavigationTitleForScrollView:_observedTable animated:YES];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    UITableView *table = self.table;
    if (table.tableHeaderView != _headerView) return;

    // A table header view is not laid out by the table; it has to be measured and reassigned,
    // and only on an actual change — an unconditional reassignment inside a layout pass is a
    // relayout loop.
    CGFloat width = table.bounds.size.width;
    if (width <= 0.0) return;
    CGFloat height = [_headerView sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height;
    CGRect frame = _headerView.frame;
    if (fabs(frame.size.width - width) > 0.5 || fabs(frame.size.height - height) > 0.5) {
        _headerView.frame = CGRectMake(0.0, 0.0, width, height);
        table.tableHeaderView = _headerView;
    }
    [self updateNavigationTitleForScrollView:table animated:NO];
}

// The navigation bar takes the title over exactly when the header's own title has passed under
// it, so the name is on screen once and never twice.
//
// It goes through -navigationItem.title, not a titleView: Preferences renders the controller's
// own title and leaves a titleView unused. -title stays untouched — Preferences reads it
// elsewhere.
- (void)updateNavigationTitleForScrollView:(UIScrollView *)scrollView animated:(BOOL)animated {
    if (!_headerView || !scrollView) return;

    CGFloat top = scrollView.contentOffset.y + scrollView.adjustedContentInset.top;
    BOOL shown = top >= _headerView.titleBottom;
    if (shown == _navigationTitleShown) return;
    _navigationTitleShown = shown;

    UINavigationBar *bar = animated ? self.navigationController.navigationBar : nil;
    if (!bar) {
        [self applyNavigationTitle];
        return;
    }
    // A title string cannot hold an alpha, so the bar itself carries the fade.
    [UIView transitionWithView:bar
                      duration:0.2
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{ [self applyNavigationTitle]; }
                    completion:nil];
}

- (void)applyNavigationTitle {
    NSString *title = self.title.length ? self.title : kNUPaneTitle;
    self.navigationItem.title = _navigationTitleShown ? title : @"";
}

// Safety net for the common flow "leave to the App Store, install, come back": while
// Preferences is backgrounded its workspace callback can be deferred or dropped, so re-check
// on the way back in. Guarded on _specifiers so the very first appearance (pane not built
// yet) falls through to the normal lazy build instead of rebuilding twice.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (_specifiers) [self _nuReloadIfRelevantAppsChanged];
    // Preferences may only have applied the plist title after -viewDidLoad.
    _headerView.title = self.title.length ? self.title : kNUPaneTitle;
    [self applyNavigationTitle];
}

// Rebuild the pane only when the install-state of one of OUR apps actually flipped — an
// unrelated app's install/uninstall leaves the signature unchanged and is ignored.
- (void)_nuReloadIfRelevantAppsChanged {
    NSString *now = NUInstalledSignature();
    if ([now isEqualToString:_installedSignature]) return;
    _installedSignature = now;
    _specifiers = nil;              // drop the cache so -specifiers re-runs the detection
    [self reloadSpecifiers];        // re-reads specifiers and reloads the table
}

// Workspace callbacks arrive off the main thread; hop before touching UIKit.
- (void)applicationsDidInstall:(NSArray *)apps {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf _nuReloadIfRelevantAppsChanged]; });
}

- (void)applicationsDidUninstall:(NSArray *)apps {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf _nuReloadIfRelevantAppsChanged]; });
}

// Write the value the normal way (CFPreferences, persisted), then publish the packed
// state token — the token, not CFPreferences, is the live channel (see NUPrefs.h).
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    NUPrefsPublishState();
}

@end
