import 'dart:convert';

import 'source_router.dart';

/// A downloaded, versioned runtime source policy.
///
/// The envelope adds only `expires_at` to the strict
/// [SourceRuntimeConfig] schema. No remote origin, credential, account route
/// or system route can be expressed here.
class RemoteSourcePolicy {
  const RemoteSourcePolicy({
    required this.expiresAt,
    required this.runtimeConfig,
  });

  static const int schemaVersion = 1;
  static const Set<String> _keys = {'schema_version', 'expires_at', 'scopes'};

  /// Unix seconds after which the policy must not affect routing.
  final int expiresAt;
  final SourceRuntimeConfig runtimeConfig;

  factory RemoteSourcePolicy.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('source policy must be an object');
    }
    if (raw.length != _keys.length ||
        raw.keys.any((key) => key is! String || !_keys.contains(key))) {
      throw const FormatException('source policy must contain exact keys');
    }
    if (raw['schema_version'] != schemaVersion) {
      throw const FormatException('unsupported source policy schema version');
    }
    final rawExpiresAt = raw['expires_at'];
    if (rawExpiresAt is! int || rawExpiresAt <= 0) {
      throw const FormatException('source policy expires_at is invalid');
    }
    final runtimeConfig = SourceRuntimeConfig.fromJson({
      'schema_version': schemaVersion,
      'scopes': raw['scopes'],
    });
    return RemoteSourcePolicy(
      expiresAt: rawExpiresAt,
      runtimeConfig: runtimeConfig,
    );
  }

  static RemoteSourcePolicy decode(String raw) {
    if (raw.trim().isEmpty) {
      throw const FormatException('source policy is empty');
    }
    return RemoteSourcePolicy.fromJson(jsonDecode(raw));
  }

  Map<String, Object?> toJson() {
    final serialized = runtimeConfig.toJson();
    return {
      'schema_version': schemaVersion,
      'expires_at': expiresAt,
      'scopes': serialized['scopes'],
    };
  }

  String encode() => jsonEncode(toJson());

  bool isExpiredAt(DateTime now) =>
      expiresAt <= now.millisecondsSinceEpoch ~/ 1000;
}
