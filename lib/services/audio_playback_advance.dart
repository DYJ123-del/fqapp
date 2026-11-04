part of '../pages/audio_page.dart';

/// 章末连播：本集播完直接接下一集，起播失败自动重试。
///
/// 本地改造（1.0.205），与上游的差别只有两处，都收在这个文件里：
///
/// 1. [kAdvanceCountdownEnabled] 为假 → 不进 3 秒倒计时窗口
///    （`AudioAdvanceBanner`），`_onChapterFinished` 走这里立刻开下一章；
/// 2. 开章失败不再停在错误上等用户手点：先丢掉该章的取流缓存（签名链接
///    可能已经过期）再重试，最多 [kAdvanceRetryLimit] 次，界面用
///    `AudioAdvanceRetryBanner` 显示「正在自动重试」。
void _requestAdvance(_AudioPlaybackController c) {
  if (!kAdvanceCountdownEnabled) {
    unawaited(_advanceToNextChapter(c));
    return;
  }
  _beginAdvanceCountdown(c);
}

/// 打开下一章；失败则丢弃该章的取流缓存重试。
///
/// 退出条件：会话/页面已关、用户自己换到别的章、重试次数用尽（此时把带
/// 次数的失败文案留在界面上，用户仍可手点「下一集」）。
Future<void> _advanceToNextChapter(_AudioPlaybackController c) async {
  if (c._closed) return;
  final target = c._index + 1;
  if (target >= c._chapters.length) return;
  c._advanceTargetIndex = target;
  c._advanceAttempts = 0;
  c._publishAdvanceRetry();
  while (!c._closed && c._advanceTargetIndex == target) {
    // 重试前换一条新地址：取流缓存没有 TTL，同一份过期链接重试也没用。
    if (c._advanceAttempts > 0) c._evictSourceCacheAt(target);
    await c._openChapter(target);
    if (c._closed) break;
    // 用户在这期间自己点了别的章：让出控制权，别把人拽回来。
    if (c._index != target) {
      c._advanceTargetIndex = null;
      c._advanceAttempts = 0;
      c._publishAdvanceRetry();
      return;
    }
    if (c._advanceTargetIndex != target) break;
    if (c._error == null) break;
    if (c._advanceAttempts >= kAdvanceRetryLimit) {
      final tries = c._advanceAttempts;
      _endAdvanceRetry(c, target);
      c._update(() => c._error = '${c._error}（已自动重试 $tries 次）');
      return;
    }
    c._advanceAttempts += 1;
    // 重试窗口只显示「正在自动重试」，别把上一轮的失败文案同时挂着。
    c._update(() => c._error = null);
    c._publishAdvanceRetry();
    await Future<void>.delayed(kAdvanceRetryDelay);
  }
  _endAdvanceRetry(c, target);
}

/// 连播重试的收尾：只在指针还停在这一轮时才清状态。
void _endAdvanceRetry(_AudioPlaybackController c, int target) {
  if (c._advanceTargetIndex != target) return;
  c._advanceTargetIndex = null;
  c._advanceAttempts = 0;
  c._publishAdvanceRetry();
}

/// 连播重试的状态读写。
///
/// 用 extension 而不是往控制器加方法：控制器文件已顶到行数预算，这里只是
/// 对既有私有状态的薄封装（同 `audio_playback_guard.dart` 的做法）。
extension _AdvanceRetryState on _AudioPlaybackController {
  /// 界面读数：正在进行第几次自动重试；null = 没在重试。
  ValueNotifier<int?> get advanceRetry => _advanceRetry;

  void _publishAdvanceRetry() {
    final attempt = _advanceTargetIndex != null && _advanceAttempts > 0
        ? _advanceAttempts
        : null;
    if (_advanceRetry.value != attempt) _advanceRetry.value = attempt;
  }

  /// 丢掉某一章的取流缓存，逼下一次重新取签名地址。
  void _evictSourceCacheAt(int index) {
    if (index < 0 || index >= _chapters.length) return;
    _audioSourceCache.remove('${_chapters[index].itemId}|$_toneId');
  }
}
