/// Single source of truth for the shipped version.
///
/// Keep this in sync with `version:` in `pubspec.yaml`; the release script
/// compares the two and refuses to publish when they disagree.
library;

const String appVersion = '0.11.1';
const int appVersionCode = 25;

/// 打包当天的日期，用来肉眼确认「装上去的确实是新包」。
const String appBuildStamp = '2026-10-29';

const String appVersionLabel = 'v$appVersion';
