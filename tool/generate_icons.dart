import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('render code-native launcher resources', () async {
    final sizes = {16, 24, 32, 48, 64, 72, 96, 128, 144, 192, 256};
    final pngs = <int, Uint8List>{};
    for (final size in sizes) {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.scale(size / 256);
      final red = ui.Paint()..color = const ui.Color(0xffe55264);
      final white = ui.Paint()..color = const ui.Color(0xffffffff);
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(
          const ui.Rect.fromLTWH(0, 0, 256, 256),
          const ui.Radius.circular(56),
        ),
        red,
      );
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(
          const ui.Rect.fromLTWH(52, 72, 152, 116),
          const ui.Radius.circular(16),
        ),
        white,
      );
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(
          const ui.Rect.fromLTWH(68, 88, 120, 84),
          const ui.Radius.circular(4),
        ),
        red,
      );
      canvas.drawPath(
        ui.Path()
          ..moveTo(110, 104)
          ..lineTo(110, 156)
          ..lineTo(152, 130)
          ..close(),
        white,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(size, size);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      pngs[size] = data!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
    }
    const densities = {
      'mdpi': 48,
      'hdpi': 72,
      'xhdpi': 96,
      'xxhdpi': 144,
      'xxxhdpi': 192,
    };
    for (final entry in densities.entries) {
      await File(
        'android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png',
      ).writeAsBytes(pngs[entry.value]!);
    }
    final entries = [16, 24, 32, 48, 64, 128, 256];
    final header = ByteData(6 + 16 * entries.length);
    header.setUint16(2, 1, Endian.little);
    header.setUint16(4, entries.length, Endian.little);
    var offset = header.lengthInBytes;
    for (var i = 0; i < entries.length; i++) {
      final size = entries[i], at = 6 + 16 * i;
      header.setUint8(at, size == 256 ? 0 : size);
      header.setUint8(at + 1, size == 256 ? 0 : size);
      header.setUint16(at + 4, 1, Endian.little);
      header.setUint16(at + 6, 32, Endian.little);
      header.setUint32(at + 8, pngs[size]!.length, Endian.little);
      header.setUint32(at + 12, offset, Endian.little);
      offset += pngs[size]!.length;
    }
    await File('windows/runner/resources/app_icon.ico').writeAsBytes([
      ...header.buffer.asUint8List(),
      for (final size in entries) ...pngs[size]!,
    ]);
  });
}
