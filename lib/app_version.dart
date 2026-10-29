/// Single source of truth for the shipped version.
///
/// Keep this in sync with `version:` in `pubspec.yaml`; the release script
/// compares the two and refuses to publish when they disagree.
library;

const String appVersion = '0.11.0';
const int appVersionCode = 24;

const String appVersionLabel = 'v$appVersion';
