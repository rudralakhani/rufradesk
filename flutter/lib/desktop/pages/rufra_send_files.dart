import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;

const Duration _kConnectTimeout = Duration(seconds: 30);

/// Picks files on this PC and sends them to the Desktop of every chosen PC.
/// [peers] maps peer id to its label in the grid.
Future<void> showRufraSendFiles(
    BuildContext context, Map<String, String> peers) async {
  if (peers.isEmpty) return;
  final picked = await FilePicker.platform.pickFiles(allowMultiple: true);
  final files = picked?.files
          .map((f) => f.path)
          .whereType<String>()
          .where((path) => File(path).existsSync())
          .toList() ??
      [];
  if (files.isEmpty || !context.mounted) return;
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => _SendFilesDialog(files: files, peers: peers),
  );
}

enum _SendState { waiting, connecting, sending, done, failed }

class _PeerSend {
  final String id;
  final String label;
  bool selected = true;
  _SendState state = _SendState.waiting;
  double progress = 0;
  String error = '';
  // Folder the files were written to on that PC.
  String savedTo = '';

  _PeerSend(this.id, this.label);
}

/// Where the files go on each PC. The named folders are inside that PC's user
/// folder; [custom] is a path typed by the user.
enum _Destination { desktop, documents, downloads, custom }

extension on _Destination {
  String get label {
    switch (this) {
      case _Destination.desktop:
        return translate('Desktop');
      case _Destination.documents:
        return translate('Documents');
      case _Destination.downloads:
        return translate('Downloads');
      case _Destination.custom:
        return translate('Custom folder');
    }
  }

  String get folderName {
    switch (this) {
      case _Destination.desktop:
        return 'Desktop';
      case _Destination.documents:
        return 'Documents';
      case _Destination.downloads:
        return 'Downloads';
      case _Destination.custom:
        return '';
    }
  }
}

class _SendFilesDialog extends StatefulWidget {
  final List<String> files;
  final Map<String, String> peers;

  const _SendFilesDialog({required this.files, required this.peers});

  @override
  State<_SendFilesDialog> createState() => _SendFilesDialogState();
}

class _SendFilesDialogState extends State<_SendFilesDialog> {
  late final List<_PeerSend> _peers =
      widget.peers.entries.map((e) => _PeerSend(e.key, e.value)).toList();
  bool _started = false;
  final List<FFI> _sessions = [];
  _Destination _destination = _Destination.desktop;
  final _customFolder = TextEditingController();
  String? _customError;

  bool get _running => _peers.any(
      (p) => p.state == _SendState.connecting || p.state == _SendState.sending);

  @override
  void dispose() {
    for (final ffi in _sessions) {
      _closeSession(ffi);
    }
    _customFolder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_destination == _Destination.custom &&
        _customFolder.text.trim().isEmpty) {
      setState(() => _customError = translate('Enter a folder'));
      return;
    }
    setState(() => _started = true);
    // Each PC gets its own file-transfer connection; they run side by side.
    await Future.wait(
        _peers.where((p) => p.selected).map((peer) => _sendTo(peer)));
  }

  void _update(_PeerSend peer, void Function() change) {
    if (mounted) setState(change);
  }

  Future<void> _sendTo(_PeerSend peer) async {
    _update(peer, () => peer.state = _SendState.connecting);
    final ffi = FFI(null);
    _sessions.add(ffi);
    final tag = 'ft_${peer.id}';
    try {
      // Uses the password saved for this PC; there is no one here to type it.
      ffi.start(peer.id, isFileTransfer: true);
      Get.put<FFI>(ffi, tag: tag);
      final remote = ffi.fileModel.remoteController;
      final ready = await _waitFor(
          () => ffi.ffiModel.pi.isSet.isTrue && remote.homePath.isNotEmpty);
      if (!ready) {
        throw translate(
            'Could not connect. Check that the PC is online and its password is saved.');
      }
      final isWindows = ffi.ffiModel.pi.platform == kPeerPlatformWindows;
      final targetDir = _targetDir(remote.homePath, isWindows);
      _update(peer, () => peer.savedTo = targetDir);
      final jobs = ffi.fileModel.jobController;
      final jobIds = <int>[];
      for (final path in widget.files) {
        final entry = Entry()
          ..path = path
          ..name = p.basename(path)
          ..size = File(path).lengthSync();
        jobIds.add(jobs.addTransferJob(entry, false));
      }
      // Replace files of the same name without asking; nobody can answer a
      // dialog in this background connection.
      jobs.registerTransferConflictBatch(jobIds);
      jobs.rememberTransferConflictBatch(jobIds.first, true);
      for (var i = 0; i < jobIds.length; i++) {
        bind.sessionSendFiles(
            sessionId: ffi.sessionId,
            actId: jobIds[i],
            path: widget.files[i],
            to: PathUtil.join(
                targetDir, p.basename(widget.files[i]), isWindows),
            fileNum: 0,
            includeHidden: false,
            isRemote: false,
            isDir: false);
      }
      _update(peer, () => peer.state = _SendState.sending);
      final error = await _waitForJobs(peer, jobs, jobIds);
      if (error != null) throw error;
      _update(peer, () {
        peer.state = _SendState.done;
        peer.progress = 1;
      });
    } catch (e) {
      _update(peer, () {
        peer.state = _SendState.failed;
        peer.error = e.toString();
      });
    } finally {
      _sessions.remove(ffi);
      await _closeSession(ffi);
      if (Get.isRegistered<FFI>(tag: tag)) await Get.delete<FFI>(tag: tag);
    }
  }

  /// A custom folder that is not a full path is taken as inside the user folder.
  String _targetDir(String home, bool isWindows) {
    if (_destination != _Destination.custom) {
      return PathUtil.join(home, _destination.folderName, isWindows);
    }
    final folder = _customFolder.text.trim();
    final context = isWindows ? p.windows : p.posix;
    return context.isAbsolute(folder)
        ? context.normalize(folder)
        : PathUtil.join(home, folder, isWindows);
  }

  Future<bool> _waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(_kConnectTimeout);
    while (!condition()) {
      if (!mounted || DateTime.now().isAfter(deadline)) return false;
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return true;
  }

  /// Returns null when every job finished, or the first error.
  Future<String?> _waitForJobs(
      _PeerSend peer, JobController jobs, List<int> ids) async {
    while (mounted) {
      final list = ids
          .map((id) => jobs.jobTable.firstWhereOrNull((j) => j.id == id))
          .toList();
      final failed = list.firstWhereOrNull((j) => j?.state == JobState.error);
      if (failed != null) {
        return failed.err.isEmpty ? translate('Transfer failed') : failed.err;
      }
      final total = list.fold<int>(0, (s, j) => s + (j?.totalSize ?? 0));
      final done = list.fold<int>(0, (s, j) => s + (j?.finishedSize ?? 0));
      _update(peer, () => peer.progress = total > 0 ? done / total : 0);
      if (list.every((j) => j?.state == JobState.done)) return null;
      await Future.delayed(const Duration(milliseconds: 400));
    }
    return translate('Cancelled');
  }

  Future<void> _closeSession(FFI ffi) async {
    try {
      await ffi.fileModel.close();
      await ffi.close();
    } catch (e) {
      debugPrint('Failed to close file transfer session: $e');
    }
  }

  Widget _status(BuildContext context, _PeerSend peer) {
    final theme = Theme.of(context);
    switch (peer.state) {
      case _SendState.waiting:
        return Text(translate('Ready'),
            style: TextStyle(color: theme.hintColor));
      case _SendState.connecting:
        return Text(translate('Connecting...'),
            style: TextStyle(color: theme.hintColor));
      case _SendState.sending:
        return SizedBox(
          width: 120,
          child: LinearProgressIndicator(value: peer.progress),
        );
      case _SendState.done:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.check_circle, color: Colors.green, size: 18),
          const SizedBox(width: 4),
          Text(translate('Sent')),
        ]);
      case _SendState.failed:
        return Tooltip(
          message: peer.error,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error, size: 18),
            const SizedBox(width: 4),
            Text(translate('Failed'),
                style: TextStyle(color: theme.colorScheme.error)),
          ]),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final names = widget.files.map((f) => p.basename(f)).join(', ');
    final finished = _started && !_running;
    return AlertDialog(
      title: Text(translate('Send files to PCs')),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.files.length} ${translate('file(s)')}: $names',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(translate('Save to')),
                const SizedBox(width: 12),
                DropdownButton<_Destination>(
                  value: _destination,
                  isDense: true,
                  onChanged: _started
                      ? null
                      : (v) => setState(() {
                            _destination = v ?? _Destination.desktop;
                            _customError = null;
                          }),
                  items: _Destination.values
                      .map((d) =>
                          DropdownMenuItem(value: d, child: Text(d.label)))
                      .toList(),
                ),
              ],
            ),
            if (_destination == _Destination.custom)
              TextField(
                controller: _customFolder,
                enabled: !_started,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: r'D:\Shared',
                  helperText: translate(
                      "A full path, or a folder inside the PC's user folder. It is created if missing."),
                  errorText: _customError,
                ),
                onChanged: (_) {
                  if (_customError != null) setState(() => _customError = null);
                },
              ),
            const SizedBox(height: 4),
            Text(
              translate('Files with the same name are replaced.'),
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView(
                shrinkWrap: true,
                children: _peers.map((peer) {
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Checkbox(
                      value: peer.selected,
                      onChanged: _started
                          ? null
                          : (v) => setState(() => peer.selected = v ?? false),
                    ),
                    title: Text(peer.label, overflow: TextOverflow.ellipsis),
                    subtitle: peer.savedTo.isEmpty
                        ? null
                        : SelectableText(peer.savedTo,
                            style: Theme.of(context).textTheme.bodySmall),
                    trailing: _status(context, peer),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (!_started) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(translate('Cancel')),
          ),
          ElevatedButton.icon(
            onPressed: _peers.any((p) => p.selected) ? _start : null,
            icon: const Icon(Icons.send, size: 16),
            label: Text(translate('Send')),
          ),
        ] else
          ElevatedButton(
            // Closing while sending stops the remaining transfers.
            onPressed: () => Navigator.of(context).pop(),
            child: Text(finished ? translate('Close') : translate('Stop')),
          ),
      ],
    );
  }
}
