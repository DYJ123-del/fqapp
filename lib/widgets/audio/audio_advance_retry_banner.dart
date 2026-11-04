import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/audio_page_theme.dart';

/// 连播失败后自动重试的状态条。
///
/// 用户要求：下一集起播失败不要停下来等用户手点，先自动重试。条子只负责
/// 把「正在重试第 N 次」讲清楚，避免用户以为听书卡死了；重试用尽后由页面
/// 的失败文案接管。
class AudioAdvanceRetryBanner extends StatelessWidget {
  /// 第几次重试（从 1 开始）。
  final int attempt;

  /// 最多重试几次。
  final int limit;

  const AudioAdvanceRetryBanner({
    super.key,
    required this.attempt,
    required this.limit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = AudioPageThemeScope.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 2),
      child: Container(
        key: const Key('audio_advance_retry'),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: theme.card,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.skip_forward, size: 16, color: theme.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '下一集播放失败，正在自动重试（第 $attempt/$limit 次）',
                key: const Key('audio_advance_retry_text'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.ink, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
