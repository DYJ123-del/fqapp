import 'dart:convert';

/// Result of comparing a local and a remote response without retaining values.
class SourceResponseComparison {
  const SourceResponseComparison.match() : mismatch = null;
  const SourceResponseComparison.mismatch(this.mismatch);

  /// Null when the structures agree. Otherwise a safe path such as
  /// `json:$.data.item_infos.*.title`.
  final String? mismatch;

  bool get matches => mismatch == null;
}

/// Compares the local and remote `chapters/full` response shapes.
///
/// Only fields and value types are compared; content values are never read or
/// returned. `relay` is remote-only protocol metadata, and the item-id keys
/// under `item_infos` are replaced by `*` so a mismatch path can be logged
/// without a book or chapter id.
SourceResponseComparison compareFullChapterResponses({
  required Map<String, dynamic> localPayload,
  required Map<String, dynamic> remotePayload,
  required String itemId,
}) {
  final localShape = _responseShape(localPayload, itemId);
  final remoteShape = _responseShape(remotePayload, itemId);
  final jsonMismatch = _firstDifference(localShape, remoteShape, r'$');
  if (jsonMismatch != null) {
    return SourceResponseComparison.mismatch('json:$jsonMismatch');
  }
  return const SourceResponseComparison.match();
}

Object? _responseShape(Map<String, dynamic> payload, String itemId) {
  final shape = <String, Object?>{};
  final keys = payload.keys.where((key) => key != 'relay').toList()..sort();
  for (final key in keys) {
    final value = payload[key];
    shape[key] = key == 'data' ? _dataShape(value, itemId) : _shape(value);
  }
  return shape;
}

Object? _dataShape(Object? value, String itemId) {
  if (value is! Map) return _shape(value);
  final shape = <String, Object?>{};
  final keys = value.keys.whereType<String>().toList()..sort();
  for (final key in keys) {
    final child = value[key];
    if (key == 'item_infos' && child is Map) {
      shape['item_infos.*'] = _shape(child[itemId]);
    } else {
      shape[key] = _shape(child);
    }
  }
  return shape;
}

Object? _shape(Object? value, [int depth = 0]) {
  if (depth > 8) return 'deep';
  if (value is Map) {
    final shape = <String, Object?>{};
    final dynamicShapes = <String, Object?>{};
    final entries = value.entries.toList()
      ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
    for (final entry in entries) {
      final key = entry.key.toString();
      final child = _shape(entry.value, depth + 1);
      if (_dynamicKey.hasMatch(key)) {
        dynamicShapes[jsonEncode(child)] = child;
      } else {
        shape[key] = child;
      }
    }
    if (dynamicShapes.isNotEmpty) {
      final keys = dynamicShapes.keys.toList()..sort();
      shape['*'] = [for (final key in keys) dynamicShapes[key]];
    }
    return shape;
  }
  if (value is List) {
    final distinct = <String, Object?>{};
    for (final item in value) {
      final itemShape = _shape(item, depth + 1);
      distinct[jsonEncode(itemShape)] = itemShape;
    }
    final keys = distinct.keys.toList()..sort();
    return {
      '[]': [for (final key in keys) distinct[key]],
    };
  }
  if (value == null) return 'null';
  if (value is String) return 'string';
  if (value is bool) return 'bool';
  if (value is int) return 'int';
  if (value is double) return 'double';
  return 'unknown';
}

final RegExp _dynamicKey = RegExp(
  r'^(?:\d{1,24}|[0-9a-fA-F]{8,64}|[A-Za-z0-9_-]{24,128})$',
);

String? _firstDifference(Object? local, Object? remote, String path) {
  if (local is Map && remote is Map) {
    final keys = <String>{
      ...local.keys.whereType<String>(),
      ...remote.keys.whereType<String>(),
    }.toList()..sort();
    for (final key in keys) {
      final childPath = '$path.$key';
      if (!local.containsKey(key) || !remote.containsKey(key)) {
        return childPath;
      }
      final difference = _firstDifference(local[key], remote[key], childPath);
      if (difference != null) return difference;
    }
    return null;
  }
  if (local is List && remote is List) {
    if (local.length != remote.length) return '$path[]';
    for (var index = 0; index < local.length; index++) {
      final difference = _firstDifference(
        local[index],
        remote[index],
        '$path[$index]',
      );
      if (difference != null) return difference;
    }
    return null;
  }
  return local.runtimeType == remote.runtimeType ? null : path;
}
