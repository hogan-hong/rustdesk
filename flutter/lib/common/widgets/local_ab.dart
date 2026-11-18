import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/peer_card.dart';
import 'package:flutter_hbb/common/widgets/peers_view.dart';
import 'package:flutter_hbb/models/peer_tab_model.dart';

import '../../common.dart' hide Dialog;
import '../../models/peer_model.dart';
import '../../models/platform_model.dart';

const String kOptionLocalAbGroups = 'local-ab-groups';

class LocalAbGroup {
  String name;

  /// parent group name; empty means top level
  String parent;
  final List<String> peers;
  LocalAbGroup({required this.name, this.parent = '', List<String>? peers})
      : peers = peers ?? [];

  Map<String, dynamic> toJson() =>
      {'name': name, 'parent': parent, 'peers': peers};
}

class LocalAbStore {
  /// notify listeners that groups changed
  static final ValueNotifier<int> version = ValueNotifier<int>(0);

  static List<LocalAbGroup> load() {
    try {
      final s = bind.mainGetLocalOption(key: kOptionLocalAbGroups);
      if (s.isEmpty) {
        return [];
      }
      final list = jsonDecode(s) as List<dynamic>;
      return list
          .map((e) {
            try {
              final m = e as Map<String, dynamic>;
              return LocalAbGroup(
                name: m['name'] as String,
                parent: (m['parent'] as String?) ?? '',
                peers: ((m['peers'] as List<dynamic>?) ?? const [])
                    .map((e) => e.toString())
                    .toList(),
              );
            } catch (e) {
              debugPrint('bad local ab group entry: $e');
              return null;
            }
          })
          .whereType<LocalAbGroup>()
          .toList();
    } catch (e) {
      debugPrint('failed to load local ab groups: $e');
      return [];
    }
  }

  /// drop the given peer ids from every group (used when peers are deleted)
  static Future<void> removePeersFromGroups(Iterable<String> ids) async {
    final idSet = ids.toSet();
    if (idSet.isEmpty) return;
    final groups = load();
    var changed = false;
    for (final g in groups) {
      final before = g.peers.length;
      g.peers.removeWhere(idSet.contains);
      if (g.peers.length != before) changed = true;
    }
    if (changed) {
      await save(groups);
    }
  }

  /// direct children of [parent] ('' = top level), keeping stored order
  static List<LocalAbGroup> childrenOf(
      List<LocalAbGroup> groups, String parent) {
    final names = groups.map((g) => g.name).toSet();
    return groups
        .where((g) => parent.isEmpty
            ? (g.parent.isEmpty || !names.contains(g.parent))
            : g.parent == parent)
        .toList();
  }

  /// group names under [name] including itself, depth first (cycle safe)
  static List<String> descendantsOf(List<LocalAbGroup> groups, String name) {
    final out = <String>[];
    final seen = <String>{};
    void walk(String n) {
      if (!seen.add(n)) return;
      out.add(n);
      for (final c in groups.where((g) => g.parent == n)) {
        walk(c.name);
      }
    }

    walk(name);
    return out;
  }

  /// peer ids of [name] and all nested groups below it
  static Set<String> peerIdsOfGroup(List<LocalAbGroup> groups, String name) {
    final names = descendantsOf(groups, name).toSet();
    return groups
        .where((g) => names.contains(g.name))
        .expand((g) => g.peers)
        .toSet();
  }

  /// remove [name] and re-parent its children to its own parent
  static Future<void> deleteGroup(String name) async {
    final groups = load();
    LocalAbGroup? target;
    for (final g in groups) {
      if (g.name == name) {
        target = g;
        break;
      }
    }
    if (target == null) return;
    final newParent = target.parent;
    groups.removeWhere((g) => g.name == name);
    for (final g in groups) {
      if (g.parent == name) g.parent = newParent;
    }
    await save(groups);
  }

  static String exportJson() => jsonEncode({
        'type': 'rustdesk-local-ab',
        'version': 1,
        'groups': load().map((g) => g.toJson()).toList(),
      });

  /// merge an exported snapshot; returns [newGroups, newPeers]
  static Future<List<int>> importJson(String raw,
      {bool replace = false}) async {
    final decoded = jsonDecode(raw);
    List<dynamic> list;
    if (decoded is Map && decoded['groups'] is List) {
      list = decoded['groups'] as List;
    } else if (decoded is List) {
      list = decoded;
    } else {
      throw const FormatException('无法识别的文件格式');
    }
    final incoming = <LocalAbGroup>[];
    for (final e in list) {
      if (e is! Map) continue;
      final name = (e['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      incoming.add(LocalAbGroup(
        name: name,
        parent: (e['parent'] ?? '').toString(),
        peers: ((e['peers'] as List?) ?? const [])
            .map((x) => x.toString())
            .toList(),
      ));
    }
    if (incoming.isEmpty) {
      throw const FormatException('文件里没有可导入的分组');
    }
    final groups = replace ? <LocalAbGroup>[] : load();
    final order = groups.map((g) => g.name).toSet();
    final importedNames = <String, String>{};
    var newGroups = 0;
    var newPeers = 0;
    for (final inc in incoming) {
      var name = inc.name;
      LocalAbGroup? existing;
      for (final g in groups) {
        if (g.name == name) {
          existing = g;
          break;
        }
      }
      if (existing == null) {
        var finalName = name;
        if (order.contains(finalName)) {
          var i = 2;
          while (order.contains('$name($i)')) {
            i++;
          }
          finalName = '$name($i)';
        }
        var parent = inc.parent;
        if (parent.isNotEmpty) {
          parent = importedNames[parent] ?? parent;
          if (!groups.any((g) => g.name == parent)) parent = '';
        }
        groups.add(LocalAbGroup(
            name: finalName, parent: parent, peers: inc.peers.toList()));
        order.add(finalName);
        importedNames[inc.name] = finalName;
        newGroups++;
        newPeers += inc.peers.length;
      } else {
        importedNames[inc.name] = existing.name;
        for (final id in inc.peers) {
          if (!existing.peers.contains(id)) {
            existing.peers.add(id);
            newPeers++;
          }
        }
      }
    }
    await save(groups);
    return [newGroups, newPeers];
  }

  static Future<bool> save(List<LocalAbGroup> groups) async {
    try {
      final s = jsonEncode(groups.map((g) => g.toJson()).toList());
      await bind.mainSetLocalOption(key: kOptionLocalAbGroups, value: s);
      version.value++;
      return true;
    } catch (e) {
      debugPrint('failed to save local ab groups: $e');
      return false;
    }
  }
}

/// compact icon button with a small rounded hover background instead of
/// Material's oversized 48px circular ripple
class MiniIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;

  const MiniIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  @override
  State<MiniIconButton> createState() => _MiniIconButtonState();
}

class _MiniIconButtonState extends State<MiniIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final iconColor =
        widget.color ?? Theme.of(context).textTheme.titleLarge?.color;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover ? iconColor?.withOpacity(0.10) : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(widget.icon, size: 18, color: iconColor),
          ),
        ),
      ),
    );
  }
}

Dialog _wrapDialog(Widget child, {double? width}) {
  final content = Padding(
    padding: const EdgeInsets.all(16.0),
    child: child,
  );
  return Dialog(
    child: width == null
        ? ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: content,
          )
        : SizedBox(width: width, child: content),
  );
}

Future<void> _showTextInputDialog({
  required BuildContext context,
  required String title,
  required String hint,
  required void Function(BuildContext dialogContext, String text) onOk,
}) async {
  final controller = TextEditingController();
  await showDialog(
      context: context,
      builder: (dialogContext) {
        return _wrapDialog(
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: hint,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('取消')),
                    const SizedBox(width: 8),
                    FilledButton(
                        onPressed: () {
                          final text = controller.text.trim();
                          if (text.isEmpty) {
                            return;
                          }
                          onOk(dialogContext, text);
                          Navigator.pop(dialogContext);
                        },
                        child: const Text('确定')),
                  ],
                ),
              ],
            ),
            width: 320);
      });
}

/// add a new group, return the actual name (may be de-duplicated)
String _uniqueName(List<LocalAbGroup> groups, String name) {
  String candidate = name;
  int i = 2;
  while (groups.any((g) => g.name == candidate)) {
    candidate = '$name($i)';
    i++;
  }
  return candidate;
}

/// dialog: choose which groups the peer belongs to
Future<void> putPeerToGroupDialog(BuildContext context, String peerId) async {
  final groups = LocalAbStore.load();
  final selected = <String>{};
  for (final g in groups) {
    if (g.peers.contains(peerId)) {
      selected.add(g.name);
    }
  }
  final newGroupController = TextEditingController();
  await showDialog(
      context: context,
      builder: (dialogContext) {
        return _wrapDialog(StatefulBuilder(builder: (ctx, setState) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '移到分组',
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: groups.isEmpty
                    ? Text(
                        '暂无分组，可在下方新建',
                        style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(ctx).textTheme.titleLarge?.color
                                ?.withOpacity(0.6)),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: groups
                            .map((g) => CheckboxListTile(
                                  dense: true,
                                  value: selected.contains(g.name),
                                  title: Text(
                                      '${g.name} (${g.peers.length})',
                                      style: const TextStyle(fontSize: 14)),
                                  onChanged: (v) {
                                    setState(() {
                                      if (v == true) {
                                        selected.add(g.name);
                                      } else {
                                        selected.remove(g.name);
                                      }
                                    });
                                  },
                                ))
                            .toList(),
                      ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: newGroupController,
                      decoration: const InputDecoration(
                        hintText: '新建分组名',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  MiniIconButton(
                    tooltip: '新建分组',
                    icon: Icons.add,
                    onPressed: () {
                      final text = newGroupController.text.trim();
                      if (text.isEmpty) {
                        return;
                      }
                      setState(() {
                        final name = _uniqueName(groups, text);
                        groups.add(LocalAbGroup(name: name));
                        selected.add(name);
                        newGroupController.clear();
                      });
                    }
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('取消')),
                  const SizedBox(width: 8),
                  FilledButton(
                      onPressed: () async {
                        for (final g in groups) {
                          if (selected.contains(g.name)) {
                            if (!g.peers.contains(peerId)) {
                              g.peers.add(peerId);
                            }
                          } else {
                            g.peers.remove(peerId);
                          }
                        }
                        await LocalAbStore.save(groups);
                        showToast('已保存');
                        if (dialogContext.mounted) {
                          Navigator.pop(dialogContext);
                        }
                      },
                      child: const Text('确定')),
                ],
              ),
            ],
          );
        }));
      });
}

/// export the local address book (groups + hierarchy) to a JSON file
Future<String?> _exportLocalAb(BuildContext context) async {
  try {
    final ts = DateTime.now();
    final stamp = '${ts.year}${ts.month.toString().padLeft(2, '0')}'
        '${ts.day.toString().padLeft(2, '0')}';
    String? path = await FilePicker.platform.saveFile(
      dialogTitle: '导出通讯录',
      fileName: 'rustdesk_ab_$stamp.json',
      allowedExtensions: ['json'],
      type: FileType.custom,
    );
    if (path == null || path.isEmpty) return null;
    if (!path.toLowerCase().endsWith('.json')) {
      path = '$path.json';
    }
    final data = LocalAbStore.exportJson();
    await File(path).writeAsString(data, encoding: utf8);
    showToast('已导出到 $path');
    return path;
  } catch (e) {
    showToast('导出失败: $e');
    return null;
  }
}

/// import a JSON address book; returns (groups, peers) summary on success
Future<List<int>?> _importLocalAb(BuildContext context) async {
  try {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json', 'txt'],
      withData: true,
    );
    if (res == null || res.files.isEmpty) return null;
    final f = res.files.first;
    String raw;
    if (f.bytes != null) {
      raw = utf8.decode(f.bytes!, allowMalformed: true);
    } else if (f.path != null) {
      raw = await File(f.path!).readAsString(encoding: utf8);
    } else {
      return null;
    }
    final summary = await LocalAbStore.importJson(raw);
    showToast(
        '导入完成：新增 ${summary[0]} 个分组，${summary[1]} 台设备');
    return summary;
  } catch (e) {
    showToast('导入失败: $e');
    return null;
  }
}

/// dialog: manage local groups (create / rename / delete / reorder / nesting)
Future<void> manageLocalAbGroupsDialog(BuildContext context) async {
  final groups = LocalAbStore.load();
  final newGroupController = TextEditingController();
  String newGroupParent = '';
  int? editingIndex;
  final renameController = TextEditingController();
  final dragKeys = {for (final g in groups) g: UniqueKey()};
  Key keyFor(LocalAbGroup g) => dragKeys.putIfAbsent(g, () => UniqueKey());
  String pathOf(LocalAbGroup g) {
    final parts = <String>[];
    var cur = g.parent;
    var guard = 0;
    while (cur.isNotEmpty && guard++ < 16) {
      final p = groups.where((x) => x.name == cur).toList();
      if (p.isEmpty) break;
      parts.insert(0, cur);
      cur = p.first.parent;
    }
    return parts.join(' / ');
  }

  await showDialog(
      context: context,
      builder: (dialogContext) {
        return _wrapDialog(StatefulBuilder(builder: (ctx, setState) {
          final sub =
              Theme.of(ctx).textTheme.titleLarge?.color?.withOpacity(0.6);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '分组管理',
                    style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w500),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _exportLocalAb(context),
                    child: const Text('导出'),
                  ),
                  TextButton(
                    onPressed: () async {
                      final res = await _importLocalAb(context);
                      if (res != null && dialogContext.mounted) {
                        Navigator.pop(dialogContext);
                      }
                    },
                    child: const Text('导入'),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: groups.isEmpty
                    ? Text('暂无分组', style: TextStyle(fontSize: 14, color: sub))
                    : ReorderableListView(
                        shrinkWrap: true,
                        buildDefaultDragHandles: false,
                        onReorder: (oldIndex, newIndex) {
                          setState(() {
                            if (newIndex > oldIndex) newIndex -= 1;
                            final g = groups.removeAt(oldIndex);
                            groups.insert(newIndex, g);
                            if (editingIndex == oldIndex) {
                              editingIndex = newIndex;
                            }
                          });
                        },
                        children: List.generate(groups.length, (index) {
                          final g = groups[index];
                          if (editingIndex == index) {
                            return Row(
                              key: keyFor(g),
                              children: [
                                ReorderableDragStartListener(
                                  index: index,
                                  child: Icon(Icons.drag_indicator, size: 16),
                                ),
                                Expanded(
                                  child: TextField(
                                    controller: renameController,
                                    autofocus: true,
                                    decoration: const InputDecoration(
                                      isDense: true,
                                      hintText: '新分组名',
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                ),
                                MiniIconButton(
                                  tooltip: '确认改名',
                                  icon: Icons.check,
                                  onPressed: () {
                                    final text = renameController.text.trim();
                                    if (text.isEmpty) return;
                                    var name = text;
                                    var j = 2;
                                    while (groups.any((g2) =>
                                        !identical(g2, g) &&
                                        g2.name == name)) {
                                      name = '$text($j)';
                                      j++;
                                    }
                                    final oldName = g.name;
                                    setState(() {
                                      g.name = name;
                                      // re-parent children pointing at old name
                                      for (final c in groups) {
                                        if (c.parent == oldName) {
                                          c.parent = name;
                                        }
                                      }
                                      editingIndex = null;
                                    });
                                  },
                                ),
                                MiniIconButton(
                                  tooltip: '取消',
                                  icon: Icons.close,
                                  onPressed: () =>
                                      setState(() => editingIndex = null),
                                ),
                              ],
                            );
                          }
                          final path = pathOf(g);
                          return Row(
                            key: keyFor(g),
                            children: [
                              ReorderableDragStartListener(
                                index: index,
                                child: Icon(
                                  Icons.drag_indicator,
                                  size: 16,
                                  color: sub,
                                ),
                              ),
                              Expanded(
                                child: Row(
                                  children: [
                                    if (path.isNotEmpty) ...[
                                      Text('$path / ',
                                          style: TextStyle(
                                              fontSize: 13, color: sub)),
                                    ],
                                    Flexible(
                                      child: Text(
                                        g.name,
                                        style:
                                            const TextStyle(fontSize: 15),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              PopupMenuButton<String>(
                                tooltip: '设置上级分组',
                                enabled: true,
                                padding: EdgeInsets.zero,
                                onSelected: (v) {
                                  setState(() {
                                    if (v == '__root__') {
                                      g.parent = '';
                                    } else if (v != g.name) {
                                      g.parent = v;
                                    }
                                  });
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                    value: '__root__',
                                    height: 32,
                                    child: Text('顶级分组',
                                        style: const TextStyle(fontSize: 14)),
                                  ),
                                  ...groups
                                      .where((x) =>
                                          x.name != g.name &&
                                          !LocalAbStore.descendantsOf(
                                                  groups, g.name)
                                              .contains(x.name))
                                      .map((x) => PopupMenuItem(
                                            value: x.name,
                                            height: 32,
                                            child: Text('归入 ${x.name}',
                                                style: const TextStyle(
                                                    fontSize: 14)),
                                          )),
                                ],
                                child: Icon(Icons.account_tree_outlined,
                                    size: 18,
                                    color: g.parent.isEmpty
                                        ? sub
                                        : MyTheme.accent),
                              ),
                              MiniIconButton(
                                tooltip: '重命名分组',
                                icon: Icons.edit,
                                onPressed: () {
                                  setState(() {
                                    editingIndex = index;
                                    renameController.text = g.name;
                                  });
                                },
                              ),
                              MiniIconButton(
                                tooltip: '删除分组',
                                icon: Icons.delete_outline,
                                onPressed: () {
                                  setState(() {
                                    if (editingIndex == index) {
                                      editingIndex = null;
                                    }
                                    final newParent = g.parent;
                                    groups.remove(g);
                                    for (final c in groups) {
                                      if (c.parent == g.name) {
                                        c.parent = newParent;
                                      }
                                    }
                                  });
                                },
                              ),
                            ],
                          );
                        }),
                      ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: newGroupController,
                      decoration: const InputDecoration(
                        hintText: '新建分组名',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  MiniIconButton(
                    tooltip: '新建分组',
                    icon: Icons.add,
                    onPressed: () {
                      final text = newGroupController.text.trim();
                      if (text.isEmpty) return;
                      setState(() {
                        groups.add(LocalAbGroup(
                            name: _uniqueName(groups, text),
                            parent: newGroupParent));
                        newGroupController.clear();
                      });
                    },
                  ),
                ],
              ),
              Row(
                children: [
                  Text('上级：',
                      style: TextStyle(fontSize: 13, color: sub)),
                  DropdownButton<String>(
                    value: newGroupParent,
                    isDense: true,
                    underline: const SizedBox(),
                    style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(ctx)
                            .textTheme
                            .titleLarge
                            ?.color
                            ?.withOpacity(0.8)),
                    items: [
                      const DropdownMenuItem(
                          value: '', child: Text('顶级分组',
                              style: TextStyle(fontSize: 13))),
                      ...groups.map((g) => DropdownMenuItem(
                            value: g.name,
                            child: Text(g.name,
                                style: const TextStyle(fontSize: 13)),
                          )),
                    ],
                    onChanged: (v) =>
                        setState(() => newGroupParent = v ?? ''),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('取消')),
                  const SizedBox(width: 8),
                  FilledButton(
                      onPressed: () async {
                        await LocalAbStore.save(groups);
                        showToast('已保存');
                        if (dialogContext.mounted) {
                          Navigator.pop(dialogContext);
                        }
                      },
                      child: const Text('确定')),
                ],
              ),
            ],
          );
        }));
      });
}

class LocalAbPeersView extends BasePeersView {
  LocalAbPeersView({
    String? group,
    EdgeInsets? menuPadding,
    Key? key,
  }) : super(
          key: key,
          peerTabIndex: PeerTabIndex.recent,
          peerFilter: group == null ? null : _makeGroupFilter(group),
          peerCardBuilder: (Peer peer) => RecentPeerCard(
            peer: peer,
            menuPadding: menuPadding,
          ),
        );

  static PeerFilter _makeGroupFilter(String group) {
    final ids = LocalAbStore.peerIdsOfGroup(LocalAbStore.load(), group);
    return (Peer peer) => ids.contains(peer.id);
  }

  @override
  Widget build(BuildContext context) {
    final widget = super.build(context);
    bind.mainLoadRecentPeers();
    return widget;
  }
}

class LocalAddressBook extends StatefulWidget {
  final EdgeInsets? menuPadding;
  const LocalAddressBook({this.menuPadding, Key? key}) : super(key: key);

  @override
  State<LocalAddressBook> createState() => _LocalAddressBookState();
}

class _LocalAddressBookState extends State<LocalAddressBook> {
  /// '' means all peers
  String selectedGroup = '';

  /// group names whose children are hidden
  final Set<String> _collapsed = <String>{};

  @override
  void initState() {
    super.initState();
    LocalAbStore.version.addListener(_onGroupsChanged);
  }

  @override
  void dispose() {
    LocalAbStore.version.removeListener(_onGroupsChanged);
    super.dispose();
  }

  _onGroupsChanged() {
    if (mounted) {
      setState(() {
        // selected group may have been renamed or removed elsewhere
        if (selectedGroup.isNotEmpty &&
            !LocalAbStore.load().any((g) => g.name == selectedGroup)) {
          selectedGroup = '';
        }
      });
    }
  }

  Widget _buildChip(String label, bool selected, GestureTapCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? MyTheme.accent : Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color:
                  selected ? MyTheme.accent : Theme.of(context).dividerColor),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected
                ? Colors.white
                : Theme.of(context).textTheme.titleLarge?.color?.withOpacity(0.8),
          ),
        ),
      ),
    );
  }

  Widget _buildGroupBar(List<LocalAbGroup> groups) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4, bottom: 4, top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _buildChip('全部', selectedGroup.isEmpty, () {
                  setState(() => selectedGroup = '');
                }),
                ...groups.map((g) => _buildChip(g.name, selectedGroup == g.name,
                    () {
                  setState(() => selectedGroup = g.name);
                })),
              ],
            ),
          ),
          MiniIconButton(
            tooltip: '新建分组',
            icon: Icons.add,
            onPressed: () {
              _showTextInputDialog(
                  context: context,
                  title: '新建分组',
                  hint: '分组名',
                  onOk: (dialogContext, text) async {
                    final groups = LocalAbStore.load();
                    final name = _uniqueName(groups, text);
                    groups.add(LocalAbGroup(name: name));
                    await LocalAbStore.save(groups);
                    setState(() => selectedGroup = name);
                  });
            },
          ),
          MiniIconButton(
            tooltip: '分组管理',
            icon: Icons.settings_outlined,
            onPressed: () => manageLocalAbGroupsDialog(context),
          ),
        ],
      ),
    );
  }

  Widget _buildSideItem(
    String name, {
    required bool selected,
    required int depth,
    required bool hasChildren,
    required bool expanded,
    required GestureTapCallback onTap,
    GestureTapCallback? onToggle,
  }) {
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.only(
              left: 4.0 + depth * 14.0, right: 8, top: 6, bottom: 6),
          decoration: BoxDecoration(
            color: selected ? MyTheme.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                child: hasChildren
                    ? InkWell(
                        onTap: onToggle,
                        child: Icon(
                          expanded
                              ? Icons.keyboard_arrow_down
                              : Icons.keyboard_arrow_right,
                          size: 16,
                          color: selected
                              ? Colors.white
                              : textColor?.withOpacity(0.6),
                        ),
                      )
                    : null,
              ),
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    fontSize: 13,
                    color: selected ? Colors.white : textColor?.withOpacity(0.8),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// flatten the group tree into side-bar rows honouring collapsed state
  List<Widget> _buildTreeRows(List<LocalAbGroup> groups, String parent, int depth) {
    final rows = <Widget>[];
    if (depth > 12) return rows;
    for (final g in LocalAbStore.childrenOf(groups, parent)) {
      final children = LocalAbStore.childrenOf(groups, g.name);
      final expanded = !_collapsed.contains(g.name);
      rows.add(_buildSideItem(
        g.name,
        selected: selectedGroup == g.name,
        depth: depth,
        hasChildren: children.isNotEmpty,
        expanded: expanded,
        onTap: () => setState(() => selectedGroup = g.name),
        onToggle: () => setState(() {
          if (expanded) {
            _collapsed.add(g.name);
          } else {
            _collapsed.remove(g.name);
          }
        }),
      ));
      if (expanded && children.isNotEmpty) {
        rows.addAll(_buildTreeRows(groups, g.name, depth + 1));
      }
    }
    return rows;
  }

  Widget _buildGroupSidebar(List<LocalAbGroup> groups) {
    return SizedBox(
      width: 278,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 10, top: 6, right: 2),
            child: Row(
              children: [
                Text(
                  '分组',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.color
                        ?.withOpacity(0.6),
                  ),
                ),
                const Spacer(),
                MiniIconButton(
                  tooltip: '新建分组',
                  icon: Icons.add,
                  onPressed: () {
                    _showTextInputDialog(
                        context: context,
                        title: '新建分组',
                        hint: '分组名',
                        onOk: (dialogContext, text) async {
                          final groups = LocalAbStore.load();
                          final name = _uniqueName(groups, text);
                          groups.add(LocalAbGroup(
                              name: name, parent: selectedGroup));
                          if (selectedGroup.isNotEmpty) {
                            _collapsed.remove(selectedGroup);
                          }
                          await LocalAbStore.save(groups);
                          setState(() => selectedGroup = name);
                        });
                  },
                ),
                MiniIconButton(
                  tooltip: '分组管理',
                  icon: Icons.settings_outlined,
                  onPressed: () => manageLocalAbGroupsDialog(context),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              children: [
                _buildSideItem(
                  '全部',
                  selected: selectedGroup.isEmpty,
                  depth: 0,
                  hasChildren: false,
                  expanded: false,
                  onTap: () => setState(() => selectedGroup = ''),
                ),
                ..._buildTreeRows(groups, '', 0),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = LocalAbStore.load();
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < 400) {
        // narrow window: fall back to stacked chips layout
        return Column(
          children: [
            _buildGroupBar(groups),
            Expanded(
              child: LocalAbPeersView(
                group: selectedGroup.isEmpty ? null : selectedGroup,
                menuPadding: widget.menuPadding,
              ),
            ),
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildGroupSidebar(groups),
          Container(
            width: 1,
            margin: const EdgeInsets.symmetric(vertical: 10),
            color: Theme.of(context).dividerColor,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 10),
              child: LocalAbPeersView(
                group: selectedGroup.isEmpty ? null : selectedGroup,
                menuPadding: widget.menuPadding,
              ),
            ),
          ),
        ],
      );
    });
  }
}
