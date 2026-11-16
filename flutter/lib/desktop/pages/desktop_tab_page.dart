import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/desktop_home_page.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/main.dart' show kBootArgs;
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';
// import 'package:flutter/services.dart';

import '../../common/shared_state.dart';

class DesktopTabPage extends StatefulWidget {
  const DesktopTabPage({Key? key}) : super(key: key);

  @override
  State<DesktopTabPage> createState() => _DesktopTabPageState();

  static void onAddSetting(
      {SettingsTabKey initialPage = SettingsTabKey.general}) {
    try {
      DesktopTabController tabController = Get.find<DesktopTabController>();
      tabController.add(TabInfo(
          key: kTabLabelSettingPage,
          label: kTabLabelSettingPage,
          selectedIcon: Icons.build_sharp,
          unselectedIcon: Icons.build_outlined,
          page: DesktopSettingPage(
            key: const ValueKey(kTabLabelSettingPage),
            initialTabkey: initialPage,
          )));
    } catch (e) {
      debugPrintStack(label: '$e');
    }
  }
}

class _DesktopTabPageState extends State<DesktopTabPage> {
  final tabController = DesktopTabController(tabType: DesktopTabType.main);

  _DesktopTabPageState() {
    RemoteCountState.init();
    Get.put<DesktopTabController>(tabController);
    tabController.add(TabInfo(
        key: kTabLabelHomePage,
        label: kTabLabelHomePage,
        selectedIcon: Icons.home_sharp,
        unselectedIcon: Icons.home_outlined,
        closable: false,
        page: DesktopHomePage(
          key: const ValueKey(kTabLabelHomePage),
        )));
    // Internal build: `--config` boot arg opens the settings tab for
    // incoming-only hosts that normally hide the settings entry.
    if (kBootArgs.contains('--config')) {
      if (bind.isIncomingOnly()) {
        // Settings entry requires admin password verification first.
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final ctx = globalKey.currentContext;
          if (ctx == null) {
            DesktopTabPage.onAddSetting();
            return;
          }
          final ok = await showAdminAuthDialog(ctx);
          if (ok) {
            DesktopTabPage.onAddSetting();
          }
        });
      } else {
        DesktopTabPage.onAddSetting();
      }
    }
    if (bind.isIncomingOnly()) {
      tabController.onSelected = (key) {
        if (key == kTabLabelHomePage) {
          windowManager.setSize(getIncomingOnlyHomeSize());
          setResizable(false);
        } else {
          windowManager.setSize(getIncomingOnlySettingsSize());
          setResizable(true);
        }
      };
    }
  }

  void _onTailSettingsTap() {
    if (bind.isIncomingOnly()) {
      // The tail icon is only visible for `--config` boots; still require the
      // admin password again so cancelling the startup dialog cannot bypass it.
      final ctx = globalKey.currentContext;
      if (ctx == null) {
        DesktopTabPage.onAddSetting();
        return;
      }
      showAdminAuthDialog(ctx).then((ok) {
        if (ok) DesktopTabPage.onAddSetting();
      });
      return;
    }
    DesktopTabPage.onAddSetting();
  }

  @override
  void initState() {
    super.initState();
    // HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  /*
  bool _handleKeyEvent(KeyEvent event) {
    if (!mouseIn && event is KeyDownEvent) {
      print('key down: ${event.logicalKey}');
      shouldBeBlocked(_block, canBeBlocked);
    }
    return false; // allow it to propagate
  }
  */

  @override
  void dispose() {
    // HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    Get.delete<DesktopTabController>();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabWidget = Container(
        child: Scaffold(
            backgroundColor: Theme.of(context).colorScheme.background,
            body: DesktopTab(
              controller: tabController,
              tail: Offstage(
                offstage: bind.isDisableSettings() ||
                    (bind.isIncomingOnly() && !kBootArgs.contains('--config')),
                child: ActionIcon(
                  message: 'Settings',
                  icon: IconFont.menu,
                  onTap: () => _onTailSettingsTap(),
                  isClose: false,
                ),
              ),
            )));
    return isMacOS || kUseCompatibleUiMode
        ? tabWidget
        : Obx(
            () => DragToResizeArea(
              resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
              enableResizeEdges: windowManagerEnableResizeEdges,
              child: tabWidget,
            ),
          );
  }
}

/// Internal build: admin password gate for the settings entry (tray → Settings
/// boots the UI with `--config`; incoming-only builds must verify first).
Future<bool> showAdminAuthDialog(BuildContext ctx) async {
  final controller = TextEditingController();
  var confirmed = false;
  await showDialog(
    context: ctx,
    barrierDismissible: false,
    builder: (dialogCtx) {
      var error = '';
      // Hand-rolled layout instead of AlertDialog: the incoming-only main
      // window is very narrow and AlertDialog crams the actions into the
      // content line.
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: StatefulBuilder(
          builder: (dialogCtx, setState) {
            Future<void> submit() async {
              if (controller.text.isEmpty) return;
              final ok = bind.mainVerifyAdminPassword(password: controller.text);
              if (ok) {
                confirmed = true;
                if (dialogCtx.mounted) Navigator.pop(dialogCtx);
              } else {
                setState(() => error = '密码错误，请重新输入');
              }
            }

            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('管理员验证',
                      style:
                          TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  const Text('请输入管理员密码以进入设置',
                      style: TextStyle(fontSize: 13)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    obscureText: true,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: '管理员密码',
                      isDense: true,
                      errorText: error.isEmpty ? null : error,
                    ),
                    onSubmitted: (_) => submit(),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogCtx),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: submit,
                        child: const Text('确认'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      );
    },
  );
  controller.dispose();
  return confirmed;
}
