part of '../pages/audio_page.dart';

/// 章末连播 + 取流缓存 + 下一集预取（本地改造，全部收在这个文件里）。
///
/// 与上游的差别只有三处：
///
/// 1. [kAdvanceCountdownEnabled] 为假 → 不进 3 秒倒计时窗口
///    （`AudioAdvanceBanner`），`_onChapterFinished` 走这里立刻开下一章；
/// 2. 开章失败不再停在错误上等用户手点：先丢掉该章的取流地址（签名链接
///    可能在长章节里过期）再重试，最多 [kAdvanceRetryLimit] 次，界面用
///    `AudioAdvanceRetryBanner` 显示「正在自动重试」；**章末几秒的失败**
///    同样按「本章播完」处理，直接续播下一集，不弹错误；
/// 3. 取流地址缓存带有效期（[kAudioSourceTtl]），下一集预取只在
///    [kPrefetchWindow] 内触发一次——开播就取会放到过期，也白占一次请求。

/// 取流地址缓存有效期。签名地址可用时间远大于它，取 10 分钟既覆盖最长
/// 章节，又不会把「快过期的地址」带进章末连播。
const Duration kAudioSourceTtl = Duration(minutes: 10);

/// 距离章末还有多久时预取下一集：够覆盖一次取地址，又不至于放到过期。
const Duration kPrefetchWindow = Duration(seconds: 45);

/// 章末窗口：最后这么多秒内的播放错误按「本章播完」处理（没配片尾跳过时）。
const Duration kEndOfChapterWindow = Duration(seconds: 8);

/// 一条带获取时间的取流地址。
class _CachedSource {
  const _CachedSource(this.source, this.at);

  final AudioSource source;
  final DateTime at;

  bool isFresh(DateTime now) => now.difference(at) < kAudioSourceTtl;
}

void _requestAdvance(_AudioPlaybackController c) {
  if (!kAdvanceCountdownEnabled) {
    // 后台播放已关闭又已经退到后台：不自动连播（省流量、省电），留到用户
    // 回到前台再续。上游在倒计时窗口里靠生命周期事件取消，我们直接连播，
    // 没有那个窗口，所以必须在这里判一次（audio_listening_boundaries_test
    // 的「chapter countdown respects background playback」盯的就是这条）。
    if (!c._appActive && !AudioPreferences.instance.backgroundPlayback.value) {
      return;
    }
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
  AppLog.i('audio', '连播下一集：第 ${target + 1} 章');
  c._advanceTargetIndex = target;
  c._advanceAttempts = 0;
  c._publishAdvanceRetry();
  while (!c._closed && c._advanceTargetIndex == target) {
    // 重试前换一条新地址：同一份过期链接重试也没用。
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
      AppLog.w('audio', '连播失败：第 ${target + 1} 章重试 $tries 次仍失败');
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

/// 连播重试 / 取流缓存 / 失败归因的状态读写。
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

  /// 读缓存：过期就丢弃，逼调用方重取。
  AudioSource? _cachedSource(String cacheKey) {
    final entry = _audioSourceCache[cacheKey];
    if (entry == null) return null;
    if (entry.isFresh(DateTime.now())) return entry.source;
    _audioSourceCache.remove(cacheKey);
    return null;
  }

  void _storeSource(String cacheKey, AudioSource source) {
    _audioSourceCache[cacheKey] = _CachedSource(source, DateTime.now());
    while (_audioSourceCache.length > 5) {
      _audioSourceCache.remove(_audioSourceCache.keys.first);
    }
  }

  /// 播放失败发生时，是否该当作「本章播完」接着播下一集。
  ///
  /// 判据：自动连播开着、不在连播流程里（否则交给连播自己的重试）、
  /// 还有下一章、且失败位置已经在章末窗口内。
  bool _failedAtChapterEnd() {
    if (_closed || !_autoAdvance) return false;
    if (_advanceTargetIndex != null) return false;
    if (_index + 1 >= _chapters.length) return false;
    final duration = _duration;
    if (duration <= Duration.zero) return false;
    final remaining = duration - _position.value;
    final outro = Duration(seconds: _skipPoints.outroSeconds);
    final window = outro > kEndOfChapterWindow ? outro : kEndOfChapterWindow;
    return remaining <= window;
  }
}

/// 把异常压成一行可读文案，用于「设置 → 日志」。
///
/// 隐私纪律：只留类型与首段消息，且把 URL 抹掉——签名地址不能进日志。
String _describeAudioError(Object error) {
  var message = error is ApiException ? error.message : error.toString();
  message = message.replaceAll(RegExp(r'https?://\S+'), '<url>');
  if (message.length > 180) message = '${message.substring(0, 180)}…';
  return '${error.runtimeType}: $message';
}
