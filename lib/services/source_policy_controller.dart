import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'app_log.dart';
import 'source_policy.dart';
import 'source_router.dart';

/// Loads, caches and refreshes the narrow A5 routing policy.
///
/// Precedence is:
/// 1. the local debug override under [SourceRuntimeConfig.preferenceKey];
/// 2. a valid, unexpired cached remote policy;
/// 3. all-local when a remote origin is configured but no valid policy exists.
///
/// A build without a remote origin keeps its all-local default and performs no
/// network request.
class SourcePolicyController with WidgetsBindingObserver {
  SourcePolicyController({
    required this.api,
    required this.preferences,
    DateTime Function()? now,
    this.observeLifecycle = true,
  }) : _now = now ?? DateTime.now;

  static const String cachePreferenceKey = 'source_routing_policy_v1';
  static const Duration _refreshRetry = Duration(seconds: 15);
  static const int _minLeadSeconds = 5;
  static const int _maxLeadSeconds = 60;

  final ApiClient api;
  final SharedPreferences preferences;
  final DateTime Function() _now;
  final bool observeLifecycle;

  bool _started = false;
  bool _localOverride = false;
  RemoteSourcePolicy? _appliedPolicy;
  Future<void>? _refreshFlight;
  Timer? _refreshTimer;

  void start() {
    if (_started) return;
    _started = true;
    if (observeLifecycle) {
      WidgetsBinding.instance.addObserver(this);
    }

    final overrideRaw = preferences.getString(
      SourceRuntimeConfig.preferenceKey,
    );
    if (overrideRaw != null) {
      _localOverride = true;
      try {
        api.applyRuntimeSourceConfig(SourceRuntimeConfig.decode(overrideRaw));
      } catch (error, stack) {
        api.applyRuntimeSourceConfig(const SourceRuntimeConfig.allLocal());
        AppLog.w(
          'source-policy',
          '本地路由覆盖非法，已全部回退本地',
          error: error,
          stack: stack,
        );
      }
      return;
    }

    if (!api.hasRemoteSource) return;

    final cached = _readCachedPolicy();
    if (cached != null) {
      _apply(cached);
    } else {
      api.applyRuntimeSourceConfig(const SourceRuntimeConfig.allLocal());
    }
    unawaited(refresh());
  }

  Future<void> refresh() {
    if (!_started || _localOverride || !api.hasRemoteSource) {
      return Future<void>.value();
    }
    final active = _refreshFlight;
    if (active != null) return active;

    final future = _refreshOnce();
    _refreshFlight = future;
    return future.whenComplete(() {
      if (identical(_refreshFlight, future)) _refreshFlight = null;
    });
  }

  Future<void> _refreshOnce() async {
    final current = _appliedPolicy;
    if (current != null && current.isExpiredAt(_now())) {
      _appliedPolicy = null;
      api.applyRuntimeSourceConfig(const SourceRuntimeConfig.allLocal());
    }

    try {
      final policy = await api.fetchRemoteSourcePolicy();
      if (policy.isExpiredAt(_now())) {
        throw const FormatException('source policy is already expired');
      }
      await preferences.setString(cachePreferenceKey, policy.encode());
      _apply(policy);
      AppLog.d('source-policy', '远程源策略已应用 expires_at=${policy.expiresAt}');
    } catch (error, stack) {
      final fallback = _appliedPolicy;
      if (fallback == null || fallback.isExpiredAt(_now())) {
        _appliedPolicy = null;
        api.applyRuntimeSourceConfig(const SourceRuntimeConfig.allLocal());
      }
      AppLog.w(
        'source-policy',
        '远程源策略刷新失败，保留${fallback != null && !fallback.isExpiredAt(_now()) ? '未过期旧策略' : '本地'}',
        error: error,
        stack: stack,
      );
      _scheduleRefresh(retrySoon: true);
    }
  }

  void _apply(RemoteSourcePolicy policy) {
    _appliedPolicy = policy;
    api.applyRuntimeSourceConfig(
      policy.runtimeConfig,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        policy.expiresAt * 1000,
        isUtc: true,
      ),
    );
    _scheduleRefresh();
  }

  /// Refreshes before expiry so a foreground session never silently ages out
  /// of the remote policy. Failures retry quickly while the last good policy is
  /// still valid; once it expires the router already fails closed to local.
  void _scheduleRefresh({bool retrySoon = false}) {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (!_started ||
        !observeLifecycle ||
        _localOverride ||
        !api.hasRemoteSource) {
      return;
    }

    var delay = _refreshRetry;
    final policy = _appliedPolicy;
    if (!retrySoon && policy != null) {
      final remaining =
          policy.expiresAt - _now().millisecondsSinceEpoch ~/ 1000;
      if (remaining > 0) {
        var lead = remaining ~/ 5;
        if (lead < _minLeadSeconds) lead = _minLeadSeconds;
        if (lead > _maxLeadSeconds) lead = _maxLeadSeconds;
        final untilRefresh = remaining - lead;
        delay = untilRefresh > 0
            ? Duration(seconds: untilRefresh)
            : Duration.zero;
      }
    }

    _refreshTimer = Timer(delay, () {
      _refreshTimer = null;
      unawaited(refresh());
    });
  }

  RemoteSourcePolicy? _readCachedPolicy() {
    final raw = preferences.getString(cachePreferenceKey);
    if (raw == null) return null;
    try {
      final policy = RemoteSourcePolicy.decode(raw);
      if (policy.isExpiredAt(_now())) {
        unawaited(preferences.remove(cachePreferenceKey));
        return null;
      }
      return policy;
    } catch (_) {
      unawaited(preferences.remove(cachePreferenceKey));
      return null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshTimer?.cancel();
      _refreshTimer = null;
      unawaited(refresh());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    }
  }

  void dispose() {
    _started = false;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (observeLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
    }
  }
}
