// NULocalization.h — .strings lookup for the tweak dylib, which has no bundle
// of its own. The tables live in NUPrefs.bundle (shipped in the same deb), so
// one .lproj tree serves both the prefs pane and the row UI. The bundle path is
// derived from our own dylib path (same dladdr pattern as NUApplySandbox in
// NUShared.h), which resolves on rootful, rootless (/var/jb) and roothide
// (randomised jbroot) alike.
#import <Foundation/Foundation.h>
#import <dlfcn.h>

static inline NSBundle *NULocalizationBundle(void) {
    static NSBundle *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info; memset(&info, 0, sizeof(info));
        if (!dladdr((const void *)&NULocalizationBundle, &info) || !info.dli_fname) return;
        NSString *dylib = @(info.dli_fname);
        // …/Library/MobileSubstrate/DynamicLibraries/NextUp3.dylib (rootful/rootless)
        // …/<jbroot>/usr/lib/TweakInject/NextUp3.dylib             (roothide)
        NSString *root = nil;
        NSRange r = [dylib rangeOfString:@"/Library/MobileSubstrate/" options:NSBackwardsSearch];
        if (r.location != NSNotFound) {
            root = [dylib substringToIndex:r.location];
        } else {
            r = [dylib rangeOfString:@"/usr/lib/" options:NSBackwardsSearch];
            if (r.location != NSNotFound) root = [dylib substringToIndex:r.location];
        }
        if (root)
            bundle = [NSBundle bundleWithPath:
                [root stringByAppendingString:@"/Library/PreferenceBundles/NUPrefs.bundle"]];
    });
    return bundle;
}

// Never surfaces a raw key: if the bundle is missing/unreadable or the language
// has no entry, the compiled-in English fallback wins.
static inline NSString *NULocalizedString(NSString *key, NSString *fallback) {
    NSBundle *b = NULocalizationBundle();
    NSString *s = b ? [b localizedStringForKey:key value:fallback table:@"Localizable"] : nil;
    return s.length ? s : fallback;
}
