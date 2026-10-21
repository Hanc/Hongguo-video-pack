import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'app_updater.dart';

/// Check the packaged version reader and live public metadata without installing.
Future<void> runUpdateAcceptance() async {
  final path = Platform.environment['HONGPUTAO_UPDATE_TEST_DIRECTORY'];
  if (path == null || !p.isAbsolute(path)) {
    throw StateError('Choose an absolute diagnostic directory');
  }
  final directory = await Directory(path).create(recursive: true);
  final updater = AppUpdater();
  try {
    await updater.check();
    if (updater.error.isNotEmpty ||
        updater.release == null ||
        StableVersion.parse(updater.currentVersion) == null) {
      throw StateError('Public update metadata check failed');
    }
    await File(p.join(directory.path, 'update-result.json')).writeAsString(
      jsonEncode({
        'passed': true,
        'platform': Platform.operatingSystem,
        'currentVersion': updater.currentVersion,
        'latestStable': updater.release!.version.toString(),
        'hasUpdate': updater.hasUpdate,
        'source': updater.release!.source,
        'platformInstaller': updater.release!.installer?.name,
      }),
    );
  } finally {
    updater.dispose();
  }
}
