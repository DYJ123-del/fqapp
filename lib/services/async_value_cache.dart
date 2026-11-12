import 'dart:async';

/// 带 TTL 的「拉一次，短期内复用」缓存，用来把装饰性接口的延迟挪到用户
/// 还没走到那一步之前（预热）。
///
/// 典型用法：听书起播前要定音色，而 `/tones` 冷启动要 1~2 秒。页面一打开就
/// [warm] 一次，真正要用的时候 [fetch] 是内存命中。
///
/// 约定：
///  * 同一个 key 的并发调用合并成一次请求（预热与真正的读取常常同时发生）；
///  * 只有 [isUsable] 认可的结果才会入缓存（比如「音色表为空」说明接口挂了，
///    不该把空壳缓存十分钟）；
///  * 失败不缓存，下次还能重试。
class AsyncValueCache<T> {
  AsyncValueCache({
    required this.ttl,
    required this.isUsable,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration ttl;
  final bool Function(T value) isUsable;
  final DateTime Function() _now;

  final Map<String, T> _values = <String, T>{};
  final Map<String, DateTime> _storedAt = <String, DateTime>{};
  final Map<String, Future<T>> _inflight = <String, Future<T>>{};

  /// 缓存里仍然有效的那份，没有就 null。
  T? read(String key) {
    final value = _values[key];
    final at = _storedAt[key];
    if (value == null || at == null) return null;
    if (_now().difference(at) > ttl) {
      _values.remove(key);
      _storedAt.remove(key);
      return null;
    }
    return value;
  }

  /// 命中缓存直接返回，否则按 [loader] 拉一次。
  Future<T> fetch(String key, Future<T> Function() loader) {
    final cached = read(key);
    if (cached != null) return Future<T>.value(cached);
    final running = _inflight[key];
    if (running != null) return running;
    late final Future<T> future;
    future = loader().then((value) {
      if (isUsable(value)) {
        _values[key] = value;
        _storedAt[key] = _now();
      }
      return value;
    }).whenComplete(() {
      if (identical(_inflight[key], future)) _inflight.remove(key);
    });
    _inflight[key] = future;
    return future;
  }

  /// 预热：失败静默（真要用的时候还会再拉一次）。
  void warm(String key, Future<T> Function() loader) {
    unawaited(
      fetch(key, loader).then<void>((_) {}).catchError((Object _) {}),
    );
  }

  /// 丢掉这个 key 的缓存。
  void invalidate(String key) {
    _values.remove(key);
    _storedAt.remove(key);
  }

  /// 清空（测试用）。
  void clear() {
    _values.clear();
    _storedAt.clear();
    _inflight.clear();
  }
}
