import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/services/btr_proxy/range_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class BtrLogPage extends StatefulWidget {
  const BtrLogPage({super.key});

  @override
  State<BtrLogPage> createState() => _BtrLogPageState();
}

class _BtrLogPageState extends State<BtrLogPage> {
  final ScrollController _scrollController = ScrollController();
  late List<String> _logs;

  @override
  void initState() {
    super.initState();
    _logs = BtrLog.snapshot();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
  }

  Future<void> _copyAll() async {
    if (_logs.isEmpty) {
      SmartDialog.showToast('暂无日志可复制');
      return;
    }
    final text = _logs.join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    SmartDialog.showToast('已复制 ${_logs.length} 行日志到剪贴板');
  }

  void _clear() {
    if (_logs.isEmpty) return;
    BtrLog.clear();
    setState(() {
      _logs = BtrLog.snapshot();
    });
    SmartDialog.showToast('日志已清空');
  }

  void _refresh() {
    setState(() {
      _logs = BtrLog.snapshot();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
    SmartDialog.showToast('已刷新，当前 ${_logs.length} 行');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SimpleScaffold(
      appBar: AppBar(
        title: Text('BTR 日志 (${_logs.length})'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_outlined),
            onPressed: _refresh,
          ),
          TextButton.icon(
            onPressed: _copyAll,
            icon: const Icon(Icons.copy_all_outlined, size: 18),
            label: const Text('复制全部'),
          ),
          TextButton.icon(
            onPressed: _clear,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('清空'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '保留最近 2000 行诊断日志（已自动脱敏敏感签名）。\n点击右上角「复制全部」后可直接粘贴到反馈里。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1),
          Expanded(
            child: _logs.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.article_outlined,
                          size: 48,
                          color: theme.colorScheme.outline.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '暂无 BTR 日志\n（进入视频播放后将自动记录）',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: theme.colorScheme.outline,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  )
                : SelectionArea(
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            _logs[index],
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
