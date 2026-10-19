import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Move only our known preference files when the Windows product name changes.
/// Export destinations inside workspace.json remain unchanged.
Future<Directory> appSupportDirectory() async {
  final current = await getApplicationSupportDirectory();
  if (Platform.isWindows) {
    final legacy = Directory(p.join(p.dirname(current.path), 'Hongguo Studio'));
    if (p.normalize(legacy.path) != p.normalize(current.path) &&
        await legacy.exists()) {
      await current.create(recursive: true);
      for (final entry in {
        'workspace.json': 1048576,
        'search-visitor.json': 4096,
        'catalogue-v1.json': 20971520,
      }.entries) {
        final from = File(p.join(legacy.path, entry.key));
        final to = File(p.join(current.path, entry.key));
        if (!await to.exists() &&
            await from.exists() &&
            await from.length() <= entry.value) {
          await from.copy(to.path);
        }
      }
    }
  }
  return current;
}
