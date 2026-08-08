# Contributing to NextUp 3

Thanks for helping out! A few things keep contributions smooth.

## Bug reports

Please include:

- iOS version and device, jailbreak type (rootful / rootless / roothide) and
  the injection platform (ElleKit, Substrate, ...)
- The media app and its version, if the bug involves one (App Store version for
  Spotify / YouTube Music)
- What goes wrong and where (Lock Screen, Control Center, Dynamic Island,
  Settings, ...), and what you expected instead

A quick check before reporting: other tweaks that touch the now-playing UI are
the most common source of conflicts. If you can, reproduce with them disabled.

## Pull requests

- Read the "For developers" section of the [README](README.md) first; the
  architecture and the add-an-app checklist live there. [AGENTS.md](AGENTS.md)
  has a more detailed file map.
- Comment style: write comments that explain *why* the code is the way it is,
  e.g. where a magic number comes from, or which iOS version breaks without
  this workaround. Good: `// 14pt matches Apple's own artwork inset`. Bad:
  `// changed this because the old version crashed`, or comments that just
  restate what the next line does.
- Test at least one build variant (`make package ROOTLESS=1 FINALPACKAGE=1`)
  before opening the PR, and say which device/iOS you tested on.
- Small, focused PRs are much easier to review than big ones.
- LLM-generated PRs are welcome, as long as a human has actually run and
  verified the changes on a real device. Untested AI output wastes everyone's
  time.

## Adding support for a new media app

Follow the six-step checklist in the README ("Adding support for another
app"). Step 3 (the prefs state bit) is the one everyone forgets; it fails
silently.
