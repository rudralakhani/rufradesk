import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/desktop/widgets/remote_toolbar.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:get/get.dart';

/// Window argument that turns a remote-desktop sub window into the grid view.
const String kRufraGridArg = 'rufra_grid';

const String _kGridStateOption = 'rufra-grid-state';
const int _kMaxTiles = 10;
const List<int> _kLayouts = [1, 2, 4, 6, 9, 10];
const Map<int, int> _kLayoutColumns = {1: 1, 2: 2, 4: 2, 6: 3, 9: 3, 10: 5};

int? _gridWindowId;

/// Opens the grid window, or brings it to the front if it is already open.
Future<void> openRufraGridWindow() async {
  final existing = _gridWindowId;
  if (existing != null) {
    final ids = await DesktopMultiWindow.getAllSubWindowIds();
    if (ids.contains(existing)) {
      await WindowController.fromWindowId(existing).show();
      await windowOnTop(existing);
      return;
    }
  }
  final msg = jsonEncode({
    'type': WindowType.RemoteDesktop.index,
    kRufraGridArg: true,
  });
  final controller = await DesktopMultiWindow.createWindow(msg);
  if (isWindows) {
    controller.setInitBackgroundColor(Colors.black);
  }
  controller
    ..setFrame(const Offset(0, 0) & const Size(1400, 860))
    ..center()
    ..setTitle('${bind.mainGetAppNameSync()} - ${translate('Grid view')}');
  _gridWindowId = controller.windowId;
}

/// The "Grid view" button shown next to "Connect" on the home page.
Widget buildRufraGridButton(BuildContext context) {
  return SizedBox(
    height: 28.0,
    child: OutlinedButton.icon(
      onPressed: () async {
        if (await _unlockGrid(context)) {
          await openRufraGridWindow();
        }
      },
      icon: Icon(
          _isGridLocked() ? Icons.lock_outline : Icons.grid_view_rounded,
          size: 16),
      label: Text(translate('Grid view')),
    ),
  );
}

// Grid lock: a per-PC password that guards opening the grid view.
// Only a salted, iterated SHA-256 hash is stored in the local config.
const String _kGridLockOption = 'rufra-grid-lock';
const int _kGridLockIterations = 20000;
const int _kGridLockMinLength = 4;

String _hashGridPassword(String password, String salt) {
  final saltBytes = utf8.encode(salt);
  var digest = sha256.convert([...saltBytes, ...utf8.encode(password)]).bytes;
  for (var i = 1; i < _kGridLockIterations; i++) {
    digest = sha256.convert([...digest, ...saltBytes]).bytes;
  }
  return base64.encode(digest);
}

Map<String, dynamic>? _readGridLock() {
  final s = bind.mainGetLocalOption(key: _kGridLockOption);
  if (s.isEmpty) return null;
  try {
    final m = jsonDecode(s) as Map<String, dynamic>;
    if (m['salt'] is String && m['hash'] is String) return m;
  } catch (e) {
    debugPrint('Failed to read grid lock: $e');
  }
  return null;
}

bool _isGridLocked() => _readGridLock() != null;

bool _verifyGridPassword(String password) {
  final lock = _readGridLock();
  if (lock == null) return true;
  final expected = lock['hash'] as String;
  final actual = _hashGridPassword(password, lock['salt'] as String);
  if (expected.length != actual.length) return false;
  var diff = 0;
  for (var i = 0; i < expected.length; i++) {
    diff |= expected.codeUnitAt(i) ^ actual.codeUnitAt(i);
  }
  return diff == 0;
}

Future<void> _setGridPassword(String? password) async {
  if (password == null || password.isEmpty) {
    await bind.mainSetLocalOption(key: _kGridLockOption, value: '');
    return;
  }
  final random = Random.secure();
  final salt = base64.encode(List.generate(16, (_) => random.nextInt(256)));
  await bind.mainSetLocalOption(
      key: _kGridLockOption,
      value: jsonEncode(
          {'salt': salt, 'hash': _hashGridPassword(password, salt)}));
}

/// Asks for the grid password when one is set. Returns true when the grid may open.
Future<bool> _unlockGrid(BuildContext context) async {
  if (!_isGridLocked()) return true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => const _UnlockGridDialog(),
  );
  return ok == true;
}

class _UnlockGridDialog extends StatefulWidget {
  const _UnlockGridDialog({Key? key}) : super(key: key);

  @override
  State<_UnlockGridDialog> createState() => _UnlockGridDialogState();
}

class _UnlockGridDialogState extends State<_UnlockGridDialog> {
  final _controller = TextEditingController();
  String? _error;
  bool _checking = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_checking) return;
    setState(() => _checking = true);
    final ok = _verifyGridPassword(_controller.text);
    if (!ok) {
      // Slow down repeated guessing.
      await Future.delayed(const Duration(seconds: 1));
    }
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _checking = false;
        _error = translate('Wrong password');
        _controller.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(children: [
        const Icon(Icons.lock_outline, size: 20),
        const SizedBox(width: 8),
        Text(translate('Grid view is locked')),
      ]),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: _controller,
          autofocus: true,
          obscureText: true,
          enabled: !_checking,
          decoration: InputDecoration(
            labelText: translate('Grid password'),
            errorText: _error,
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(translate('Cancel')),
        ),
        ElevatedButton(
          onPressed: _checking ? null : _submit,
          child: Text(translate('Unlock')),
        ),
      ],
    );
  }
}

/// Sets, changes or removes the grid password. Changing or removing needs the current one.
class _GridPasswordDialog extends StatefulWidget {
  const _GridPasswordDialog({Key? key}) : super(key: key);

  @override
  State<_GridPasswordDialog> createState() => _GridPasswordDialogState();
}

class _GridPasswordDialogState extends State<_GridPasswordDialog> {
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  late final bool _locked = _isGridLocked();
  String? _currentError;
  String? _newError;
  String? _confirmError;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save({required bool remove}) async {
    setState(() {
      _currentError = null;
      _newError = null;
      _confirmError = null;
    });
    if (_locked && !_verifyGridPassword(_current.text)) {
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) {
        setState(() => _currentError = translate('Wrong password'));
      }
      return;
    }
    if (!remove) {
      if (_new.text.length < _kGridLockMinLength) {
        setState(() => _newError =
            '${translate('Use at least')} $_kGridLockMinLength ${translate('characters')}');
        return;
      }
      if (_new.text != _confirm.text) {
        setState(() => _confirmError = translate('Passwords do not match'));
        return;
      }
    }
    await _setGridPassword(remove ? null : _new.text);
    if (mounted) Navigator.of(context).pop(true);
  }

  Widget _field(TextEditingController c, String label, String? error,
          {bool autofocus = false}) =>
      TextField(
        controller: c,
        obscureText: true,
        autofocus: autofocus,
        decoration: InputDecoration(labelText: label, errorText: error),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(translate('Grid password')),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              translate(
                  'Anyone opening Grid view on this PC must enter this password.'),
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
            if (_locked)
              _field(_current, translate('Current password'), _currentError,
                  autofocus: true),
            _field(_new, translate('New password'), _newError,
                autofocus: !_locked),
            _field(_confirm, translate('Confirm new password'), _confirmError),
          ],
        ),
      ),
      actions: [
        if (_locked)
          TextButton(
            onPressed: () => _save(remove: true),
            child: Text(translate('Remove password'),
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(translate('Cancel')),
        ),
        ElevatedButton(
          onPressed: () => _save(remove: false),
          child: Text(translate('Save')),
        ),
      ],
    );
  }
}

/// Window body for the grid view: a title bar with window controls and the grid.
class RufraGridTabPage extends StatefulWidget {
  final Map<String, dynamic> params;

  const RufraGridTabPage({Key? key, required this.params}) : super(key: key);

  @override
  State<RufraGridTabPage> createState() => _RufraGridTabPageState();
}

class _RufraGridTabPageState extends State<RufraGridTabPage> {
  late final DesktopTabController tabController;
  final _gridKey = GlobalKey<_RufraGridState>();

  @override
  void initState() {
    super.initState();
    tabController =
        Get.put(DesktopTabController(tabType: DesktopTabType.remoteScreen));
    tabController.add(TabInfo(
      key: kRufraGridArg,
      label: translate('Grid view'),
      selectedIcon: Icons.grid_view_rounded,
      unselectedIcon: Icons.grid_view_outlined,
      closable: false,
      page: _RufraGrid(key: _gridKey),
    ));
    rustDeskWinManager.setMethodHandler((call, fromWindowId) async {
      if (call.method == "onDestroy") {
        _gridKey.currentState?.closeAll();
      } else if (call.method == kWindowActionRebuild) {
        reloadCurrentWindow();
      }
    });
  }

  int get _windowId => widget.params['windowId'];

  @override
  Widget build(BuildContext context) {
    final child = Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: DesktopTab(
        controller: tabController,
        onWindowCloseButton: () async {
          _gridKey.currentState?.closeAll();
          // Let the tiles dispose and close their sessions before the window goes.
          await Future.delayed(const Duration(milliseconds: 300));
          return true;
        },
        selectedBorderColor: MyTheme.accent,
        labelGetter: DesktopTab.tablabelGetter,
      ),
    );
    final tabWidget = isLinux
        ? buildVirtualWindowFrame(
            context,
            Scaffold(
                backgroundColor: Theme.of(context).colorScheme.background,
                body: child),
          )
        : workaroundWindowBorder(
            context,
            Container(
              decoration: BoxDecoration(
                  border: Border.all(color: MyTheme.color(context).border!)),
              child: child,
            ));
    return isMacOS || kUseCompatibleUiMode
        ? tabWidget
        : Obx(
            () => SubWindowDragToResizeArea(
              child: tabWidget,
              resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
              enableResizeEdges: subWindowManagerEnableResizeEdges,
              windowId: _windowId,
            ),
          );
  }
}

class _RufraGrid extends StatefulWidget {
  const _RufraGrid({Key? key}) : super(key: key);

  @override
  State<_RufraGrid> createState() => _RufraGridState();
}

class _RufraGridState extends State<_RufraGrid>
    with AutomaticKeepAliveClientMixin {
  int _layout = 4;
  List<String?> _tiles = List.filled(_kMaxTiles, null);
  final Map<String, ToolbarState> _toolbarStates = {};
  // One stable key per peer, so a layout change moves the live session
  // instead of closing it and reconnecting.
  final Map<String, GlobalKey> _sessionKeys = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  bool get wantKeepAlive => true;

  void _load() {
    try {
      final s = bind.mainGetLocalOption(key: _kGridStateOption);
      if (s.isEmpty) return;
      final m = jsonDecode(s) as Map<String, dynamic>;
      final layout = m['layout'];
      if (layout is int && _kLayouts.contains(layout)) {
        _layout = layout;
      }
      final tiles = m['tiles'];
      if (tiles is List) {
        for (var i = 0; i < min(tiles.length, _kMaxTiles); i++) {
          final id = tiles[i];
          _tiles[i] = id is String && id.isNotEmpty ? id : null;
        }
      }
    } catch (e) {
      debugPrint('Failed to load grid state: $e');
    }
  }

  void _save() {
    bind.mainSetLocalOption(
        key: _kGridStateOption,
        value: jsonEncode({'layout': _layout, 'tiles': _tiles}));
  }

  void closeAll() {
    if (!mounted) return;
    setState(() => _tiles = List.filled(_kMaxTiles, null));
  }

  void _setLayout(int layout) {
    setState(() => _layout = layout);
    _save();
  }

  void _setTile(int index, String? id) {
    setState(() {
      if (id != null) {
        // A peer can only run one session per window, so move it instead of duplicating.
        final old = _tiles.indexOf(id);
        if (old >= 0) _tiles[old] = null;
      }
      _tiles[index] = id;
    });
    _save();
  }

  Future<void> _choosePeer(int index) async {
    final id = await showDialog<String>(
      context: context,
      builder: (context) => _ChoosePeerDialog(inGrid: _tiles.toSet()),
    );
    if (id != null && id.isNotEmpty) {
      _setTile(index, id);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Container(
      color: Theme.of(context).colorScheme.background,
      child: Column(
        children: [
          _buildToolbar(context),
          Expanded(child: _buildGrid(context)),
        ],
      ),
    );
  }

  Widget _buildToolbar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          Text(translate('Layout'),
              style: TextStyle(color: Theme.of(context).hintColor)),
          const SizedBox(width: 8),
          SegmentedButton<int>(
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            segments: _kLayouts
                .map((n) => ButtonSegment<int>(value: n, label: Text('$n')))
                .toList(),
            selected: {_layout},
            onSelectionChanged: (s) => _setLayout(s.first),
          ),
          const Spacer(),
          Text(
            '${_tiles.take(_layout).where((e) => e != null).length} / $_layout',
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: translate('Grid password'),
            visualDensity: VisualDensity.compact,
            icon: Icon(
                _isGridLocked() ? Icons.lock_outline : Icons.lock_open_outlined,
                size: 18),
            onPressed: () async {
              await showDialog<bool>(
                context: context,
                builder: (context) => const _GridPasswordDialog(),
              );
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(BuildContext context) {
    final columns = _kLayoutColumns[_layout]!;
    final rows = (_layout / columns).ceil();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Column(
        children: List.generate(rows, (r) {
          return Expanded(
            child: Row(
              children: List.generate(columns, (c) {
                final index = r * columns + c;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: index < _layout
                        ? _buildTile(context, index)
                        : const SizedBox.shrink(),
                  ),
                );
              }),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildTile(BuildContext context, int index) {
    final id = _tiles[index];
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: kColorCanvas,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: MyTheme.color(context).border!),
      ),
      child: Column(
        children: [
          Expanded(
            child: id == null
                ? _buildEmptyTile(context, index)
                : RemotePage(
                    key: _sessionKeys.putIfAbsent(id, () => GlobalKey()),
                    id: id,
                    toolbarState:
                        _toolbarStates.putIfAbsent(id, () => ToolbarState()),
                  ),
          ),
          _buildTileBar(context, index, id),
        ],
      ),
    );
  }

  Widget _buildEmptyTile(BuildContext context, int index) {
    return Center(
      child: OutlinedButton.icon(
        onPressed: () => _choosePeer(index),
        icon: const Icon(Icons.add, size: 16),
        label: Text(translate('Choose PC')),
      ),
    );
  }

  Widget _buildTileBar(BuildContext context, int index, String? id) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: Theme.of(context).cardColor,
      child: Row(
        children: [
          if (id != null) ...[
            _StatusDot(id: id),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _peerLabel(id),
                overflow: TextOverflow.ellipsis,
                style: style?.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
            _tileButton(Icons.swap_horiz, translate('Change PC'),
                () => _choosePeer(index)),
            _tileButton(Icons.close, translate('Remove from grid'),
                () => _setTile(index, null)),
          ] else
            Expanded(
              child: Text('${translate('Tile')} ${index + 1}',
                  style: style?.copyWith(color: Theme.of(context).hintColor)),
            ),
        ],
      ),
    );
  }

  Widget _tileButton(IconData icon, String tooltip, VoidCallback onPressed) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 16),
        ),
      ),
    );
  }
}

String _peerAlias(String id) =>
    bind.mainGetPeerOptionSync(id: id, key: 'alias').trim();

String _peerLabel(String id) {
  final alias = _peerAlias(id);
  return alias.isEmpty ? id : '$alias ($id)';
}

class _StatusDot extends StatelessWidget {
  final String id;

  const _StatusDot({Key? key, required this.id}) : super(key: key);

  Widget _dot(Color color) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );

  @override
  Widget build(BuildContext context) {
    if (!Get.isRegistered<FFI>(tag: id)) return _dot(Colors.grey);
    final ffi = Get.find<FFI>(tag: id);
    return Obx(() => _dot(ffi.ffiModel.pi.isSet.isTrue
        ? Colors.green
        : Colors.orange.withOpacity(0.8)));
  }
}

/// Picks a PC for a tile from the favorites, or by typing a remote ID.
/// A typed ID is added to the favorites so it is offered next time.
class _ChoosePeerDialog extends StatefulWidget {
  final Set<String?> inGrid;

  const _ChoosePeerDialog({Key? key, required this.inGrid}) : super(key: key);

  @override
  State<_ChoosePeerDialog> createState() => _ChoosePeerDialogState();
}

class _ChoosePeerDialogState extends State<_ChoosePeerDialog> {
  final _idController = TextEditingController();
  List<String> _favs = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    bind.mainGetFav().then((favs) {
      if (mounted) setState(() => _favs = favs);
    });
  }

  @override
  void dispose() {
    _idController.dispose();
    super.dispose();
  }

  Future<void> _addTypedId() async {
    final id = _idController.text.replaceAll(RegExp(r'\s'), '');
    if (id.isEmpty) {
      setState(() => _error = translate('Enter a remote ID'));
      return;
    }
    if (!_favs.contains(id)) {
      await bind.mainStoreFav(favs: [..._favs, id]);
    }
    if (mounted) Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(translate('Choose PC')),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _idController,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: translate('Remote ID'),
                      errorText: _error,
                      isDense: true,
                    ),
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    onSubmitted: (_) => _addTypedId(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _addTypedId,
                  child: Text(translate('Add')),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(translate('Favorites'),
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: _favs.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                          translate(
                              'No favorites yet. Type a remote ID above to add one.'),
                          style:
                              TextStyle(color: Theme.of(context).hintColor)),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: _favs.map((id) {
                        final alias = _peerAlias(id);
                        final shown = widget.inGrid.contains(id);
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.computer, size: 20),
                          title: Text(alias.isEmpty ? id : alias),
                          subtitle: alias.isEmpty ? null : Text(id),
                          trailing: shown
                              ? Text(translate('In grid'),
                                  style: TextStyle(
                                      color: Theme.of(context).hintColor))
                              : null,
                          onTap: () => Navigator.of(context).pop(id),
                        );
                      }).toList(),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(translate('Cancel')),
        ),
      ],
    );
  }
}
