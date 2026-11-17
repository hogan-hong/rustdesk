import 'dart:convert';

import 'package:flutter/material.dart' hide Dialog;
import 'package:flutter_hbb/common/widgets/peer_card.dart';
import 'package:flutter_hbb/common/widgets/peers_view.dart';
import 'package:flutter_hbb/models/peer_tab_model.dart';

import '../../common.dart';
import '../../models/peer_model.dart';
import '../../models/platform_model.dart';

const String kOptionLocalAbGroups = 'local-ab-groups';

class LocalAbGroup {
  String name;
  final List<String> peers;
  LocalAbGroup({required this.name, List<String>? peers})
      : peers = peers ?? [];

  Map<String, dynamic> toJson() => {'name': name, 'peers': peers};
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
                peers: (m['peers'] as List<dynamic>)
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

Dialog _wrapDialog(Widget child) {
  return Dialog(
    child: Padding(
      padding: const EdgeInsets.all(16.0),
      child: child,
    ),
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
        return _wrapDialog(Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              isDense: true,
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
        ));
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
                      isDense: true,
                      decoration: const InputDecoration(
                        hintText: '新建分组名',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '新建分组',
                    icon: const Icon(Icons.add),
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
                    },
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

/// dialog: manage local groups (create / delete)
Future<void> manageLocalAbGroupsDialog(BuildContext context) async {
  final groups = LocalAbStore.load();
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
                '分组管理',
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: groups.isEmpty
                    ? Text(
                        '暂无分组',
                        style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(ctx).textTheme.titleLarge?.color
                                ?.withOpacity(0.6)),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: groups
                            .map((g) => Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${g.name} (${g.peers.length})',
                                        style:
                                            const TextStyle(fontSize: 14),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '删除分组',
                                      visualDensity: VisualDensity.compact,
                                      icon: const Icon(Icons.delete_outline,
                                          size: 18),
                                      onPressed: () {
                                        setState(() {
                                          groups.remove(g);
                                        });
                                      },
                                    ),
                                  ],
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
                      isDense: true,
                      decoration: const InputDecoration(
                        hintText: '新建分组名',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '新建分组',
                    icon: const Icon(Icons.add),
                    onPressed: () {
                      final text = newGroupController.text.trim();
                      if (text.isEmpty) {
                        return;
                      }
                      setState(() {
                        groups.add(LocalAbGroup(name: _uniqueName(groups, text)));
                        newGroupController.clear();
                      });
                    },
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
    final ids = LocalAbStore.load()
        .where((g) => g.name == group)
        .expand((g) => g.peers)
        .toSet();
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
      setState(() {});
    }
  }

  Widget _buildChip(String label, bool selected, GestureTapCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 13)),
        selected: selected,
        visualDensity: VisualDensity.compact,
        onSelected: (_) => onTap(),
      ),
    );
  }

  Widget _buildGroupBar(List<LocalAbGroup> groups) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4, top: 4),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildChip('全部', selectedGroup.isEmpty, () {
                    setState(() => selectedGroup = '');
                  }),
                  ...groups.map((g) => _buildChip(g.name,
                      selectedGroup == g.name, () {
                    setState(() => selectedGroup = g.name);
                  })),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: '新建分组',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add, size: 18),
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
          IconButton(
            tooltip: '分组管理',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.settings_outlined, size: 18),
            onPressed: () => manageLocalAbGroupsDialog(context),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = LocalAbStore.load();
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
}
