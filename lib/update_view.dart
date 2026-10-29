import 'dart:io';

import 'package:flutter/material.dart';

import 'app_version.dart';
import 'services/update_service.dart';

/// Checks the update bucket, downloads the installer and hands it to the
/// platform installer. Every state is shown honestly: an unreachable bucket is
/// reported as a failed check, never as "already current".
Future<void> showUpdateDialog(BuildContext context, {UpdateService? service}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _UpdateDialog(service: service ?? UpdateService()),
  );
}

enum _Phase { checking, current, available, downloading, ready, failed }

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.service});

  final UpdateService service;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  _Phase _phase = _Phase.checking;
  UpdateInfo? _info;
  UpdateCheck? _result;
  File? _file;
  DownloadProgress? _progress;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() {
      _phase = _Phase.checking;
      _error = null;
      _info = null;
      _file = null;
      _progress = null;
    });
    final result = await widget.service.check(currentVersionCode: appVersionCode);
    if (!mounted) return;
    setState(() {
      _result = result;
      if (result.hasError) {
        _phase = _Phase.failed;
        _error = result.error;
      } else if (result.isAvailable) {
        _phase = _Phase.available;
        _info = result.update;
      } else {
        _phase = _Phase.current;
      }
    });
  }

  Future<void> _download() async {
    final info = _info;
    if (info == null) return;
    setState(() {
      _phase = _Phase.downloading;
      _error = null;
      _busy = true;
    });
    try {
      final file = await widget.service.download(
        info,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _file = file;
        _phase = _Phase.ready;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = '$error';
        _busy = false;
      });
    }
  }

  Future<void> _install() async {
    final file = _file;
    if (file == null) return;
    setState(() => _busy = true);
    try {
      await widget.service.install(file);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('检查更新'),
      content: SizedBox(width: 460, child: _body(context)),
      actions: _actions(context),
    );
  }

  Widget _body(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall;
    switch (_phase) {
      case _Phase.checking:
        return const Row(
          children: [
            SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 14),
            Expanded(child: Text('正在检查更新…')),
          ],
        );
      case _Phase.current:
        return Text('当前已是线上最新版本（$appVersionLabel）。');
      case _Phase.available:
        final info = _info!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('发现新版本 ${info.version}（当前 $appVersion）'),
            const SizedBox(height: 4),
            Text('安装包 ${info.sizeLabel} · ${info.kind == 'exe' ? 'Windows 安装程序' : 'Android 安装包'}', style: muted),
            if (info.notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final note in info.notes) Text('· $note'),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        );
      case _Phase.downloading:
        final progress = _progress;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('正在下载 ${_info?.version ?? ''}…'),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress?.fraction),
            const SizedBox(height: 8),
            Text(
              progress == null
                  ? '正在连接…'
                  : '${(progress.received / 1048576).toStringAsFixed(1)} / '
                      '${(progress.total / 1048576).toStringAsFixed(1)} MB',
              style: muted,
            ),
          ],
        );
      case _Phase.ready:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${_info?.version ?? ''} 下载完成，校验值一致。'),
            const SizedBox(height: 6),
            Text(
              Platform.isAndroid ? '点“立即安装”后由系统安装器接管。' : '点“立即安装”后运行安装程序，按提示完成即可。',
              style: muted,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        );
      case _Phase.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error ?? '检查更新失败'),
            if (_result?.isAvailable ?? false) ...[
              const SizedBox(height: 8),
              Text('线上版本：${_info?.version ?? ''}', style: muted),
            ],
          ],
        );
    }
  }

  List<Widget> _actions(BuildContext context) {
    switch (_phase) {
      case _Phase.checking:
      case _Phase.downloading:
        return const <Widget>[];
      case _Phase.available:
        return [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('稍后')),
          FilledButton(onPressed: _busy ? null : _download, child: const Text('下载并安装')),
        ];
      case _Phase.ready:
        return [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('稍后')),
          FilledButton(onPressed: _busy ? null : _install, child: const Text('立即安装')),
        ];
      case _Phase.current:
      case _Phase.failed:
        return [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('关闭')),
          FilledButton(onPressed: _busy ? null : _check, child: const Text('重新检查')),
        ];
    }
  }
}
