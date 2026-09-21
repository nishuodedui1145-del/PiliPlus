import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:PiliPlus/services/btr_proxy/cdn_racer.dart';
import 'package:PiliPlus/services/btr_proxy/proxy_server.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

/// 播放页快捷菜单里「BTR 多线程加速」的结果动作
enum BtrQuickAction {
  /// 已保存设置（需重进视频 / 切画质生效）
  saved,

  /// 已保存设置，并立即重载当前视频
  savedAndReload,
}

/// BTR 快速设置面板（**内容 widget**，由播放页的 `showBottomSheet` 承载）
///
/// ⚠️ 千万不要改成 `showDialog` / `Get.dialog`：
/// 本 App 用 `FlutterSmartDialog.init` 作 MaterialApp.builder，播放器「更多」面板
/// 渲染在 SmartDialog 的 overlay 内，那里的 Navigator **没有 MaterialLocalizations**，
/// 在其中调用 `showDialog` 会抛 `No MaterialLocalizations found`，且界面毫无反应
/// （2026-09-20 已用真机日志确认两次）。播放页同面板的「选择画质」用的就是
/// `Get.back(); showBottomSheet(...)`，本面板照此实现。
///
/// 关闭面板由调用方负责（`onDone` 里调 `Get.back()`），本 widget 只负责改设置。
class BtrQuickSettingSheet extends StatefulWidget {
  const BtrQuickSettingSheet({super.key, required this.onDone});

  /// 用户点了「保存」或「保存并重载」后的回调（设置已写入）
  final void Function(BtrQuickAction action) onDone;

  @override
  State<BtrQuickSettingSheet> createState() => _BtrQuickSettingSheetState();
}

class _BtrQuickSettingSheetState extends State<BtrQuickSettingSheet> {
  late bool _enabled = Pref.btrEnabled;
  late int _concurrency = Pref.btrConcurrency;
  late bool _cdnRaceEnabled = Pref.btrCdnRace;
  static const List<int> _options = [4, 8, 16, 32];
  bool _busy = false;
  bool _reRacing = false;

  Future<void> _save(BtrQuickAction action) async {
    if (_busy) return;
    setState(() => _busy = true);
    await GStorage.setting.put(SettingBoxKey.btrEnabled, _enabled);
    await GStorage.setting.put(SettingBoxKey.btrConcurrency, _concurrency);
    await GStorage.setting.put(SettingBoxKey.btrCdnRace, _cdnRaceEnabled);
    Pref.btrCdnRace = _cdnRaceEnabled;
    BtrProxyServer.instance.cdnRaceEnabled = _cdnRaceEnabled;
    if (!_cdnRaceEnabled) {
      BtrProxyServer.instance.clearAllRacerHints();
    }
    if (!mounted) return;
    widget.onDone(action);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // ⚠️ 必须自己包 Material + 可滚动容器：
    // 这个面板被 PageUtils.showVideoBottomSheet 插进视频页下方那块区域，
    // 那里**没有 Material 祖先**，直接放 ListTile/SwitchListTile 会报
    // "No Material widget found."；且该区域高度无界，不滚动会 BOTTOM OVERFLOWED。
    // （参照同页「选择画质」 showSetVideoQa 的写法）
    // ⚠️ 除了 Material，还必须补 MaterialLocalizations：
    // 该区域（SmartDialog 的 overlay）没有 Localizations 祖先，ChoiceChip/RawChip
    // 之类组件会报 "No MaterialLocalizations found"。这里复用 App 自己的 delegate
    // （main.dart:279 用的就是 GlobalMaterialLocalizations.delegates）。
    return Localizations(
      locale: const Locale('zh', 'CN'),
      delegates: GlobalMaterialLocalizations.delegates,
      child: Padding(
        padding: const EdgeInsets.all(12),
        // Align 用来打破这块面板区域的"紧约束"：showVideoBottomSheet 给的是整块
        // 固定高度（平时放评论的位置），不打破约束的话 Material 会被拉满，
        // 内容下方就出现一大片空白。
        child: Align(
          alignment: Alignment.topCenter,
          child: Material(
            clipBehavior: Clip.hardEdge,
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.bolt_outlined,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text('BTR 多线程加速', style: theme.textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _enabled,
                    title: const Text('开启多 Range 并发拉取'),
                    subtitle: const Text('本地代理分片并发，缓解单连接限速导致的卡顿'),
                    onChanged: (value) => setState(() => _enabled = value),
                  ),
                  const SizedBox(height: 6),
                  Text('并发上限', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final option in _options)
                        ChoiceChip(
                          label: Text('$option'),
                          selected: _concurrency == option,
                          onSelected: _enabled
                              ? (_) => setState(() => _concurrency = option)
                              : null,
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _enabled
                        ? '官方建议 8 起步，缓冲跟不上再试 16，32 以上反而可能更慢'
                              '（连接/调度开销与节点限流）。实际并发会按实测速度自适应下探。'
                        : '开启后视频走本地代理并发拉取；直播、仅音频模式与离线播放不受影响。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  const Divider(height: 24),
                  Row(
                    children: [
                      Icon(
                        Icons.speed,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text('BTR CDN 自动竞速', style: theme.textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _cdnRaceEnabled,
                    title: const Text('开启自动竞速'),
                    subtitle: const Text('进入视频时快速选出最快节点，TTL 内免去重复探测'),
                    onChanged: _enabled
                        ? (value) => setState(() => _cdnRaceEnabled = value)
                        : null,
                  ),
                  const SizedBox(height: 4),
                  Builder(
                    builder: (context) {
                      final racer = BtrProxyServer.instance.racer;
                      final cached = racer.cached ?? racer.lastResult;
                      if (cached == null) {
                        return Text(
                          '当前暂无竞速数据（播放视频时自动竞速）',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        );
                      }
                      final ageSec = (DateTime.now().millisecondsSinceEpoch -
                              cached.measuredAtMs) ~/
                          1000;
                      final ageStr = ageSec < 60
                          ? '$ageSec 秒前'
                          : '${(ageSec / 60).round()} 分钟前';
                      final speedStr =
                          '${(cached.bytesPerSec / (1024 * 1024)).toStringAsFixed(2)} MB/s';
                      return Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '最优节点: ${cached.host}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '实测速度: $speedStr · 测于 $ageStr',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      icon: _reRacing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, size: 16),
                      label: const Text('立即重新竞速'),
                      onPressed: (!_enabled || !_cdnRaceEnabled || _reRacing)
                          ? null
                          : () async {
                              setState(() => _reRacing = true);
                              try {
                                final reraceRes =
                                    await BtrProxyServer.instance.rerace();
                                if (mounted) {
                                  switch (reraceRes.outcome) {
                                    case CdnRaceOutcome.ok:
                                      final res = reraceRes.result!;
                                      SmartDialog.showToast(
                                        '竞速完成: 最优=${res.host} (${(res.bytesPerSec / 1048576).toStringAsFixed(2)} MB/s)',
                                      );
                                    case CdnRaceOutcome.noSample:
                                      SmartDialog.showToast(
                                        '还没有走代理的播放样本：请先重新进入视频（或切画质）让 BTR 生效后再试',
                                      );
                                    case CdnRaceOutcome.noWinner:
                                      SmartDialog.showToast(
                                        '竞速完成：候选节点全部超时/失败，未改变现役节点',
                                      );
                                    case CdnRaceOutcome.failed:
                                      SmartDialog.showToast(
                                        '竞速失败（网络/鉴权异常），详见日志',
                                      );
                                  }
                                }
                              } finally {
                                if (mounted) {
                                  setState(() => _reRacing = false);
                                }
                              }
                            },
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '改动需重新进入视频（或切画质）生效；「保存并重载」会立即生效',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _save(BtrQuickAction.savedAndReload),
                        child: const Text('保存并重载'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _busy
                            ? null
                            : () => _save(BtrQuickAction.saved),
                        child: const Text('保存'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
