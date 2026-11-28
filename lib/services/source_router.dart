/// Source routing layer (architecture separation, steps A1 and A3).
///
/// Every content request the app makes converges on `ApiClient._get`, which
/// asks this router where the request should go before dispatching it. The
/// router classifies the request path into a [SourceGroup] and resolves the
/// group to a [SourceBackend] through an injectable [SourceRouterConfig].
///
/// The shipping default remains every group on the local in-process core.
/// A3 adds one explicit pilot exception outside the group switch:
/// `/api/v1/chapters/full` may use the remote source service for a configured
/// book. It does not move the rest of [SourceGroup.novelContent].
/// A4-M adds a second, independent pilot exception for
/// `/api/v1/manga/chapter`; it does not move [SourceGroup.manga].
///
/// A5 adds a validated runtime policy for exactly those two narrow scopes. It
/// can switch them between local and remote, or fail closed to all-local, but
/// it cannot select a whole [SourceGroup].
///
/// Selecting [SourceBackend.remote] for a whole group still makes
/// [SourceRouter.requireLocal] throw a [StateError] instead of silently
/// falling back, because the general remote executor is not implemented.
///
/// Two groups are pinned to local in code, not in configuration: [SourceGroup.account]
/// carries the user's real account cookie (read-only Fanqie import) and must
/// never transit a relay server, and [SourceGroup.system] is process-local
/// plumbing (health probe, `/src` file service). Configuration cannot reroute
/// either one - see [SourceRouter.backendFor].
library;

import 'dart:convert';

/// Where one request group is served from.
enum SourceBackend { local, remote }

/// Request groups, aligned with the endpoint groups of the core's route
/// table (`rust/src/endpoints/router.rs`) and the API contract inventory.
enum SourceGroup {
  /// Chapter bodies: `/chapters/{id}`, `/chapters/batch`, `/chapters/full`,
  /// `/chapters/{id}/novel|toutiao`.
  novelContent,

  /// Book/chapter ancillary data: `/books/...`, `/novels/...`, `/items/...`,
  /// `/authors/...`, chapter/book reviews and comment threads.
  novelMeta,

  /// Audiobooks: `/audio/...`, plus the speech timeline endpoints that live
  /// under `/chapters/{id}/timeline|timepoints`.
  audio,

  /// Comics: `/manga/...`.
  manga,

  /// Short dramas: `/videos/...`, `/series/...`, and the playlet comment
  /// writes under `/comments/{id}/digg|reply`.
  drama,

  /// Search and feeds: `/search/...`, `/recommend/...`, `/category`,
  /// `/rank/...`.
  discovery,

  /// The independent Shuqi source: `/shuqi/...` (whole group, body included -
  /// it shares nothing with the Fanqie device pool).
  shuqi,

  /// Real-account endpoints: `/account/...`. Pinned local, see [SourceRouter].
  account,

  /// Process-local plumbing: `/health`, `/src/...`. Pinned local.
  system,

  /// Anything the classifier does not recognize. Defaults to local; a path
  /// landing here after a core route change is a signal to extend the
  /// classifier, not a routing decision.
  unclassified,
}

/// Injectable routing configuration: one backend per group, plus the remote
/// base URL the (future) remote executor will talk to.
///
/// The default is [SourceRouterConfig.allLocal]. Nothing in A1 reads remote
/// configuration from the network or from disk; callers (tests, later steps)
/// construct a config and hand it to [SourceRouter].
class SourceRouterConfig {
  const SourceRouterConfig({
    this.backends = const {},
    this.remoteBaseUrl,
    this.fullPilotBookIds = const {},
    this.mangaPilotBookIds = const {},
    this.installToken,
    this.installSigningKey,
    this.compareFullResponses = false,
  });

  /// Every group on the local core - the shipping default for A1.
  const SourceRouterConfig.allLocal()
    : backends = const {},
      remoteBaseUrl = null,
      fullPilotBookIds = const {},
      mangaPilotBookIds = const {},
      installToken = null,
      installSigningKey = null,
      compareFullResponses = false;

  /// Reads the A3/A4-M build-only pilot configuration.
  ///
  /// No value is read from the network, preferences or the repository. Passing
  /// these defines to a build is what enables the single-path pilot; a normal
  /// build keeps the all-local default.
  factory SourceRouterConfig.fromEnvironment() {
    const rawBaseUrl = String.fromEnvironment('FQ_REMOTE_BASE_URL');
    const rawFullBookIds = String.fromEnvironment('FQ_FULL_PILOT_BOOK_IDS');
    const rawMangaBookIds = String.fromEnvironment('FQ_MANGA_PILOT_BOOK_IDS');
    const token = String.fromEnvironment('FQ_INSTALL_TOKEN');
    const signingKey = String.fromEnvironment('FQ_INSTALL_SIGNING_KEY');
    const compareFullResponses = bool.fromEnvironment(
      'FQ_COMPARE_FULL_RESPONSES',
    );
    final baseUrl = rawBaseUrl.trim();
    return SourceRouterConfig(
      remoteBaseUrl: baseUrl.isEmpty ? null : baseUrl,
      fullPilotBookIds: _parseIds(rawFullBookIds),
      mangaPilotBookIds: _parseIds(rawMangaBookIds),
      installToken: token.isEmpty ? null : token,
      installSigningKey: signingKey.isEmpty ? null : signingKey,
      compareFullResponses: compareFullResponses,
    );
  }

  final Map<SourceGroup, SourceBackend> backends;

  /// Origin of the remote source service. It is dereferenced only for the
  /// configured A3/A4-M pilot paths.
  final String? remoteBaseUrl;

  /// Exact book ids allowed to use the remote full-chapter pilot.
  final Set<String> fullPilotBookIds;

  /// Exact book ids allowed to use the remote manga-chapter pilot.
  final Set<String> mangaPilotBookIds;

  /// Pre-provisioned A3 test credentials. They are supplied by build defines
  /// and never checked into the repository.
  final String? installToken;
  final String? installSigningKey;

  /// A5 validation only: fetch the local `full` response after a successful
  /// remote one and compare JSON fields and text structure. Disabled in normal
  /// builds because it doubles the chapter request.
  final bool compareFullResponses;

  /// The configured backend for [group], before the router's pinned-local
  /// overrides. Unlisted groups default to [SourceBackend.local].
  SourceBackend configuredBackendFor(SourceGroup group) =>
      backends[group] ?? SourceBackend.local;
}

/// A narrow route that may be switched independently of its broad
/// [SourceGroup].
///
/// A5 reuses only the paths whose remote response protocol is already
/// implemented. It must not expose [SourceGroup.novelContent] or
/// [SourceGroup.manga], because those groups also contain paths that still
/// require the local core.
enum SourceRouteScope { novelFull, mangaChapter }

/// Validated runtime routing policy for the A5 scopes.
///
/// JSON schema version 1 has exactly this shape:
///
/// ```json
/// {
///   "schema_version": 1,
///   "scopes": {
///     "novel_full": {"backend": "remote", "book_ids": ["123"]},
///     "manga_chapter": {"backend": "local"}
///   }
/// }
/// ```
///
/// `book_ids` is optional for a remote scope. Omitting it makes every book in
/// that scope eligible; supplying it, including an empty list, restricts the
/// scope to those exact ids. A local scope may not carry `book_ids`.
///
/// Unknown keys, scopes, schema versions and backend values reject the whole
/// document. The caller therefore applies [allLocal] instead of a partial
/// policy. This type deliberately cannot express the account or system groups,
/// a remote base URL, or install credentials.
class SourceRuntimeConfig {
  const SourceRuntimeConfig.none()
    : _present = false,
      _backends = const {},
      _bookIds = const {};

  const SourceRuntimeConfig.allLocal()
    : _present = true,
      _backends = const {},
      _bookIds = const {};

  SourceRuntimeConfig._({
    required Map<SourceRouteScope, SourceBackend> backends,
    required Map<SourceRouteScope, Set<String>> bookIds,
  }) : _present = true,
       _backends = Map.unmodifiable(backends),
       _bookIds = Map.unmodifiable(bookIds);

  /// SharedPreferences key for controlled local overrides. The stored value
  /// contains no secrets and takes priority over a downloaded policy.
  static const String preferenceKey = 'source_routing_config_v1';

  factory SourceRuntimeConfig.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('source routing config must be an object');
    }
    _requireKeys(raw, const {
      'schema_version',
      'scopes',
    }, 'source routing config');
    if (raw['schema_version'] != 1) {
      throw const FormatException('unsupported source routing schema version');
    }
    final rawScopes = raw['scopes'];
    if (rawScopes is! Map) {
      throw const FormatException('source routing scopes must be an object');
    }

    final backends = <SourceRouteScope, SourceBackend>{};
    final bookIds = <SourceRouteScope, Set<String>>{};
    for (final entry in rawScopes.entries) {
      final rawScope = entry.key;
      if (rawScope is! String) {
        throw const FormatException('source routing scope must be a string');
      }
      final scope = _scopeFromWire(rawScope);
      final rawPolicy = entry.value;
      if (rawPolicy is! Map) {
        throw FormatException('$rawScope policy must be an object');
      }
      _requireKeys(rawPolicy, const {
        'backend',
        'book_ids',
      }, '$rawScope policy');

      final backend = switch (rawPolicy['backend']) {
        'local' => SourceBackend.local,
        'remote' => SourceBackend.remote,
        _ => throw FormatException('$rawScope backend is invalid'),
      };
      final rawBookIds = rawPolicy['book_ids'];
      if (backend == SourceBackend.local) {
        if (rawBookIds != null) {
          throw FormatException('$rawScope local scope cannot list book ids');
        }
        backends[scope] = backend;
        continue;
      }

      backends[scope] = backend;
      if (rawBookIds == null) continue;
      if (rawBookIds is! List) {
        throw FormatException('$rawScope book_ids must be a list');
      }
      final ids = <String>{};
      for (final rawId in rawBookIds) {
        if (rawId is! String ||
            rawId.trim() != rawId ||
            !_bookIdPattern.hasMatch(rawId)) {
          throw FormatException('$rawScope contains an invalid book id');
        }
        if (!ids.add(rawId)) {
          throw FormatException('$rawScope contains a duplicate book id');
        }
      }
      bookIds[scope] = Set.unmodifiable(ids);
    }

    return SourceRuntimeConfig._(backends: backends, bookIds: bookIds);
  }

  /// Decodes the JSON value stored under [preferenceKey].
  ///
  /// Throws [FormatException] for empty text, malformed JSON or any contract
  /// violation. The startup loader turns that failure into [allLocal].
  static SourceRuntimeConfig decode(String raw) {
    if (raw.trim().isEmpty) {
      throw const FormatException('source routing config is empty');
    }
    return SourceRuntimeConfig.fromJson(jsonDecode(raw));
  }

  /// Whether a runtime policy was supplied. A missing policy ([none]) leaves
  /// the build-time A3/A4-M pilot configuration in effect; an explicit
  /// [allLocal] policy is the kill switch and overrides it.
  final bool _present;
  final Map<SourceRouteScope, SourceBackend> _backends;
  final Map<SourceRouteScope, Set<String>> _bookIds;

  bool get isPresent => _present;

  SourceBackend backendFor(SourceRouteScope scope) =>
      _backends[scope] ?? SourceBackend.local;

  bool allowsBook(SourceRouteScope scope, String bookId) {
    final ids = _bookIds[scope];
    return ids == null || ids.contains(bookId);
  }

  /// Serializes this policy without an envelope expiry. Remote policy caching
  /// adds `expires_at` in `RemoteSourcePolicy`.
  Map<String, Object?> toJson() {
    if (!_present) {
      throw StateError('a missing runtime source policy cannot be serialized');
    }
    final scopes = <String, Object?>{};
    for (final scope in SourceRouteScope.values) {
      final backend = backendFor(scope);
      if (backend == SourceBackend.local) {
        scopes[_scopeToWire(scope)] = {'backend': 'local'};
        continue;
      }
      final ids = _bookIds[scope];
      scopes[_scopeToWire(scope)] = {
        'backend': 'remote',
        if (ids != null) 'book_ids': ids.toList(growable: false),
      };
    }
    return {'schema_version': 1, 'scopes': scopes};
  }

  static SourceRouteScope _scopeFromWire(String value) => switch (value) {
    'novel_full' => SourceRouteScope.novelFull,
    'manga_chapter' => SourceRouteScope.mangaChapter,
    _ => throw const FormatException('unknown source routing scope'),
  };

  static String _scopeToWire(SourceRouteScope scope) => switch (scope) {
    SourceRouteScope.novelFull => 'novel_full',
    SourceRouteScope.mangaChapter => 'manga_chapter',
  };

  static void _requireKeys(Map raw, Set<String> allowed, String label) {
    for (final key in raw.keys) {
      if (key is! String || !allowed.contains(key)) {
        throw FormatException('$label contains an unknown key');
      }
    }
  }
}

/// Classifies request paths and resolves them to a backend.
class SourceRouter {
  SourceRouter({SourceRouterConfig? config, SourceRuntimeConfig? runtimeConfig})
    : _config = config ?? SourceRouterConfig.fromEnvironment(),
      _runtimeConfig = runtimeConfig ?? const SourceRuntimeConfig.none();

  final SourceRouterConfig _config;
  SourceRuntimeConfig _runtimeConfig;
  DateTime? _runtimeExpiresAt;

  SourceRouterConfig get config => _config;
  SourceRuntimeConfig get runtimeConfig => _runtimeConfig;

  static const String remoteFullPath = '/api/v1/chapters/full';
  static const String remoteMangaChapterPath = '/api/v1/manga/chapter';
  static const String remoteClientPolicyPath = '/api/v1/client-policy';

  /// Groups that configuration may never move off the local core.
  static const Set<SourceGroup> pinnedLocal = {
    SourceGroup.account,
    SourceGroup.system,
  };

  /// Applies a validated runtime policy to subsequent routing decisions.
  ///
  /// An in-flight remote request keeps the decision it already made; new
  /// requests observe [config] immediately. Passing
  /// [SourceRuntimeConfig.allLocal] is the one-step circuit breaker back to the
  /// local core.
  void applyRuntimeConfig(SourceRuntimeConfig config, {DateTime? expiresAt}) {
    _runtimeConfig = config;
    _runtimeExpiresAt = expiresAt;
  }

  /// Resolves the backend for [url]: the configured backend for its group,
  /// except [pinnedLocal] groups, which always resolve to local.
  SourceBackend backendFor(Uri url) {
    final group = classify(url);
    if (pinnedLocal.contains(group)) return SourceBackend.local;
    return _config.configuredBackendFor(group);
  }

  /// A1 dispatch guard used at the `ApiClient` funnel: returns normally when
  /// [url] routes to the local core (always, under the default config) and
  /// throws a [StateError] when configuration selected the remote backend,
  /// whose executor is not implemented yet.
  void requireLocal(Uri url) {
    if (backendFor(url) == SourceBackend.remote) {
      throw StateError(
        'SourceRouter: ${classify(url).name} is configured for the remote '
        'backend, which is not implemented yet (A1)',
      );
    }
  }

  /// Whether [bookId] may use the exact remote full-chapter path.
  ///
  /// This is deliberately narrower than [backendFor]: it never changes the
  /// backend of the rest of [SourceGroup.novelContent]. Without a runtime
  /// policy this is the A3 build-time pilot allowlist; an A5 policy replaces
  /// that decision for this scope.
  bool usesFullChapterPilot(String bookId) =>
      _usesRemoteScope(SourceRouteScope.novelFull, bookId);

  /// Whether [bookId] may use the exact remote manga-chapter path.
  ///
  /// This is deliberately narrower than [backendFor]: it never changes the
  /// backend of the rest of [SourceGroup.manga]. Without a runtime policy this
  /// is the A4-M build-time pilot allowlist; an A5 policy replaces that
  /// decision for this scope.
  bool usesMangaPilot(String bookId) =>
      _usesRemoteScope(SourceRouteScope.mangaChapter, bookId);

  bool _usesRemoteScope(SourceRouteScope scope, String bookId) {
    if (bookId.isEmpty || _config.remoteBaseUrl == null) return false;
    if (_runtimeConfig.isPresent) {
      final expiresAt = _runtimeExpiresAt;
      if (expiresAt != null && !DateTime.now().isBefore(expiresAt)) {
        return false;
      }
      return _runtimeConfig.backendFor(scope) == SourceBackend.remote &&
          _runtimeConfig.allowsBook(scope, bookId);
    }
    return switch (scope) {
      SourceRouteScope.novelFull => _config.fullPilotBookIds.contains(bookId),
      SourceRouteScope.mangaChapter => _config.mangaPilotBookIds.contains(
        bookId,
      ),
    };
  }

  /// Resolves the remote full-chapter endpoint for [bookId], or null when the
  /// book is not in the pilot.
  ///
  /// A configured build must use HTTPS. Plain HTTP is accepted only for a
  /// loopback test service so the A3 controlled test cannot accidentally send
  /// chapter key material over a non-local cleartext network.
  Uri? fullChapterEndpoint(String bookId) {
    if (!usesFullChapterPilot(bookId)) return null;
    return _validatedRemoteEndpoint(remoteFullPath);
  }

  /// Resolves the remote manga-chapter endpoint, or null when no remote source
  /// is configured. Book membership is checked by [usesMangaPilot].
  Uri? mangaChapterEndpoint() {
    if (_config.remoteBaseUrl == null) return null;
    return _validatedRemoteEndpoint(remoteMangaChapterPath);
  }

  /// Whether this build has an explicitly configured remote origin.
  bool get hasRemoteSource => _config.remoteBaseUrl != null;

  /// Resolves the signed runtime-policy endpoint. No policy is fetched when a
  /// build has no remote origin.
  Uri? clientPolicyEndpoint() {
    if (!hasRemoteSource) return null;
    return _validatedRemoteEndpoint(remoteClientPolicyPath);
  }

  /// Shared validation for the two exact pilot endpoints. The remote service
  /// must be an origin; only a loopback test service may use plain HTTP.
  Uri? _validatedRemoteEndpoint(String path) {
    final rawBaseUrl = _config.remoteBaseUrl;
    if (rawBaseUrl == null) return null;
    final base = Uri.tryParse(rawBaseUrl);
    if (base == null ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        (base.path.isNotEmpty && base.path != '/')) {
      throw StateError('SourceRouter: invalid remote source base URL');
    }
    final loopback = _isLoopbackHost(base.host);
    if (base.scheme != 'https' && !(base.scheme == 'http' && loopback)) {
      throw StateError('SourceRouter: remote source must use HTTPS');
    }
    return base.replace(path: path, query: null, fragment: null);
  }

  static bool _isLoopbackHost(String host) {
    final normalized = host.toLowerCase();
    if (normalized == 'localhost' || normalized == '::1') return true;
    final parts = normalized.split('.');
    if (parts.length != 4 || !parts.every(_isDecimalOctet)) return false;
    return int.parse(parts.first) == 127;
  }

  /// Classifies [url] by its path. Query and host are irrelevant: the same
  /// path shape means the same group on either backend.
  static SourceGroup classify(Uri url) {
    var path = url.path;
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (path == '/health' ||
        path.startsWith('/src/') ||
        path.startsWith('/_session/')) {
      return SourceGroup.system;
    }
    const prefix = '/api/v1/';
    if (!path.startsWith(prefix)) return SourceGroup.unclassified;
    final parts = path
        .substring(prefix.length)
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return SourceGroup.unclassified;
    switch (parts[0]) {
      case 'account':
        return SourceGroup.account;
      case 'shuqi':
        return SourceGroup.shuqi;
      case 'search':
      case 'recommend':
      case 'category':
      case 'rank':
        return SourceGroup.discovery;
      case 'audio':
        return SourceGroup.audio;
      case 'manga':
        return SourceGroup.manga;
      case 'videos':
      case 'series':
        return SourceGroup.drama;
      case 'chapters':
        return _classifyChapters(parts);
      case 'books':
        // The tone list under a book is audiobook data; everything else
        // under /books is novel metadata.
        return parts.length >= 3 && parts[2] == 'tones'
            ? SourceGroup.audio
            : SourceGroup.novelMeta;
      case 'comments':
        // /comments/{id}/digg and /comments/{id}/reply are playlet writes;
        // the remaining comment threads belong to novels.
        return parts.length >= 3 && (parts[2] == 'digg' || parts[2] == 'reply')
            ? SourceGroup.drama
            : SourceGroup.novelMeta;
      case 'novels':
      case 'items':
      case 'authors':
      case 'articles':
      case 'forum-id':
        return SourceGroup.novelMeta;
      default:
        return SourceGroup.unclassified;
    }
  }

  /// `/chapters/...` mixes three groups: chapter bodies (novel content), the
  /// speech timeline endpoints (audio) and chapter reviews (novel metadata).
  static SourceGroup _classifyChapters(List<String> parts) {
    // parts[0] == 'chapters'; shapes: [chapters, batch|full],
    // [chapters, {id}], [chapters, {id}, novel|toutiao|timeline|timepoints|
    // reviews], [chapters, {id}, paragraphs, {n}, reviews|short-reviews].
    if (parts.length >= 3) {
      final leaf = parts[2];
      if (leaf == 'timeline' || leaf == 'timepoints') {
        return SourceGroup.audio;
      }
      if (leaf == 'reviews' || leaf == 'paragraphs') {
        return SourceGroup.novelMeta;
      }
    }
    return SourceGroup.novelContent;
  }
}

Set<String> _parseIds(String raw) => Set.unmodifiable(
  raw
      .split(',')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty),
);

final RegExp _bookIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

bool _isDecimalOctet(String value) {
  if (value.isEmpty || value.length > 3) return false;
  for (final codeUnit in value.codeUnits) {
    if (codeUnit < 0x30 || codeUnit > 0x39) return false;
  }
  return int.parse(value) <= 255;
}
