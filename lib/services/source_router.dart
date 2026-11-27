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
    this.installToken,
    this.installSigningKey,
  });

  /// Every group on the local core - the shipping default for A1.
  const SourceRouterConfig.allLocal()
    : backends = const {},
      remoteBaseUrl = null,
      fullPilotBookIds = const {},
      installToken = null,
      installSigningKey = null;

  /// Reads the A3 build-only pilot configuration.
  ///
  /// No value is read from the network, preferences or the repository. Passing
  /// these defines to a build is what enables the single-path pilot; a normal
  /// build keeps the all-local default.
  factory SourceRouterConfig.fromEnvironment() {
    const rawBaseUrl = String.fromEnvironment('FQ_REMOTE_BASE_URL');
    const rawBookIds = String.fromEnvironment('FQ_FULL_PILOT_BOOK_IDS');
    const token = String.fromEnvironment('FQ_INSTALL_TOKEN');
    const signingKey = String.fromEnvironment('FQ_INSTALL_SIGNING_KEY');
    final baseUrl = rawBaseUrl.trim();
    return SourceRouterConfig(
      remoteBaseUrl: baseUrl.isEmpty ? null : baseUrl,
      fullPilotBookIds: _parseIds(rawBookIds),
      installToken: token.isEmpty ? null : token,
      installSigningKey: signingKey.isEmpty ? null : signingKey,
    );
  }

  final Map<SourceGroup, SourceBackend> backends;

  /// Origin of the remote source service. A3 only dereferences it for the
  /// configured full-chapter pilot books.
  final String? remoteBaseUrl;

  /// Exact book ids allowed to use the remote full-chapter pilot.
  final Set<String> fullPilotBookIds;

  /// Pre-provisioned A3 test credentials. They are supplied by build defines
  /// and never checked into the repository.
  final String? installToken;
  final String? installSigningKey;

  /// The configured backend for [group], before the router's pinned-local
  /// overrides. Unlisted groups default to [SourceBackend.local].
  SourceBackend configuredBackendFor(SourceGroup group) =>
      backends[group] ?? SourceBackend.local;
}

/// Classifies request paths and resolves them to a backend.
class SourceRouter {
  SourceRouter({SourceRouterConfig? config})
    : _config = config ?? SourceRouterConfig.fromEnvironment();

  final SourceRouterConfig _config;

  SourceRouterConfig get config => _config;

  static const String remoteFullPath = '/api/v1/chapters/full';

  /// Groups that configuration may never move off the local core.
  static const Set<SourceGroup> pinnedLocal = {
    SourceGroup.account,
    SourceGroup.system,
  };

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

  /// Whether [bookId] may use the exact A3 remote full-chapter path.
  ///
  /// This is deliberately narrower than [backendFor]: it never changes the
  /// backend of the rest of [SourceGroup.novelContent].
  bool usesFullChapterPilot(String bookId) =>
      bookId.isNotEmpty &&
      _config.remoteBaseUrl != null &&
      _config.fullPilotBookIds.contains(bookId);

  /// Resolves the remote full-chapter endpoint for [bookId], or null when the
  /// book is not in the pilot.
  ///
  /// A configured build must use HTTPS. Plain HTTP is accepted only for a
  /// loopback test service so the A3 controlled test cannot accidentally send
  /// chapter key material over a non-local cleartext network.
  Uri? fullChapterEndpoint(String bookId) {
    if (!usesFullChapterPilot(bookId)) return null;
    final base = Uri.tryParse(_config.remoteBaseUrl!);
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
    return base.replace(path: remoteFullPath, query: null, fragment: null);
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

bool _isDecimalOctet(String value) {
  if (value.isEmpty || value.length > 3) return false;
  for (final codeUnit in value.codeUnits) {
    if (codeUnit < 0x30 || codeUnit > 0x39) return false;
  }
  return int.parse(value) <= 255;
}
