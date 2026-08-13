#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>

// A link row whose icon sits closer to its label than the stock cell allows.
//
// UITableViewCell reserves a fixed slot for -imageView and starts the text after
// it, so a symbol narrower than that slot leaves a gap. The stock layout runs
// first and only the label is moved afterwards, so separator inset, disclosure
// and editing behaviour are untouched.
@interface NUIconLinkCell : PSTableCell
@end
