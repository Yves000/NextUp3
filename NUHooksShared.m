// Single definitions of the cross-file shared symbols declared in NUHooksShared.h.
// Each associated-object key must have ONE address seen by every hook file, so it
// is defined here (not as a per-file static) — see the header for why.
#import "NUHooksShared.h"

UIView * __weak gLSMediaPlatter = nil;

void * const kNUHostViewKey    = (void *)&kNUHostViewKey;
void * const kNULayoutClampKey = (void *)&kNULayoutClampKey;
void * const kNUDIRowShownKey  = (void *)&kNUDIRowShownKey;
void * const kNUCCExpandedKey  = (void *)&kNUCCExpandedKey;
void * const kNUShowStateKey   = (void *)&kNUShowStateKey;
void * const kNURouteOpeningKey = (void *)&kNURouteOpeningKey;
void * const kNURouteClosingKey = (void *)&kNURouteClosingKey;
