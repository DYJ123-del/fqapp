import 'dart:convert';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/source_policy.dart';
import 'package:fqapp/services/source_policy_controller.dart';
import 'package:fqapp/services/source_router.dart';
import 'package:fqapp/services/source_response_compare.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uri _u(String path) => Uri.parse('http://127.0.0.1:18921$path');

void main() {
  group('full response structure comparison', () {
    Map<String, dynamic> payload({
      bool relay = false,
      bool includeTitle = true,
    }) => {
      'code': 0,
      'msg': 'ok',
      if (relay) 'relay': {'protocol': 1, 'content_suffix': 'x'},
      'data': {
        'book_id': 'book-1',
        'item_infos': {
          'chapter-1': {
            if (includeTitle) 'title': 'title',
            'key': 'key',
            'content': 'content',
          },
        },
      },
    };

    test('ignores relay and values while matching fields and text shape', () {
      final comparison = compareFullChapterResponses(
        localPayload: payload(),
        remotePayload: payload(relay: true),
        itemId: 'chapter-1',
      );

      expect(comparison.matches, isTrue);
    });

    test('reports a field path without exposing the item id', () {
      final comparison = compareFullChapterResponses(
        localPayload: payload(),
        remotePayload: payload(includeTitle: false),
        itemId: 'chapter-1',
      );

      expect(comparison.mismatch, contains('item_infos.*.title'));
      expect(comparison.mismatch, isNot(contains('chapter-1')));
    });
  });

  group('classify', () {
    final cases = <String, SourceGroup>{
      // 小说正文
      '/api/v1/chapters/123': SourceGroup.novelContent,
      '/api/v1/chapters/batch?item_ids=1,2': SourceGroup.novelContent,
      '/api/v1/chapters/full?book_id=1&item_ids=2': SourceGroup.novelContent,
      '/api/v1/chapters/123/novel': SourceGroup.novelContent,
      '/api/v1/chapters/123/toutiao': SourceGroup.novelContent,
      // 小说元数据
      '/api/v1/books/123': SourceGroup.novelMeta,
      '/api/v1/books/123/detail': SourceGroup.novelMeta,
      '/api/v1/books/123/directory': SourceGroup.novelMeta,
      '/api/v1/books/123/reviews': SourceGroup.novelMeta,
      '/api/v1/books/123/chapters/summary': SourceGroup.novelMeta,
      '/api/v1/chapters/123/reviews': SourceGroup.novelMeta,
      '/api/v1/chapters/123/paragraphs/4/reviews': SourceGroup.novelMeta,
      '/api/v1/chapters/123/paragraphs/4/short-reviews': SourceGroup.novelMeta,
      '/api/v1/comments/9/replies': SourceGroup.novelMeta,
      '/api/v1/novels/55': SourceGroup.novelMeta,
      '/api/v1/items/1,2': SourceGroup.novelMeta,
      '/api/v1/authors/7': SourceGroup.novelMeta,
      '/api/v1/forum-id': SourceGroup.novelMeta,
      // 听书
      '/api/v1/audio/books/123': SourceGroup.audio,
      '/api/v1/audio/books/123/chapters/456': SourceGroup.audio,
      '/api/v1/audio/play?book_id=1&item_ids=2': SourceGroup.audio,
      '/api/v1/audio/wkcontent/123': SourceGroup.audio,
      '/api/v1/chapters/123/timeline': SourceGroup.audio,
      '/api/v1/chapters/123/timepoints': SourceGroup.audio,
      '/api/v1/books/123/tones': SourceGroup.audio,
      // 漫画
      '/api/v1/manga/123': SourceGroup.manga,
      '/api/v1/manga/videos/9': SourceGroup.manga,
      // 短剧
      '/api/v1/videos/123': SourceGroup.drama,
      '/api/v1/series/123': SourceGroup.drama,
      '/api/v1/series/123/comments': SourceGroup.drama,
      '/api/v1/videos/123/danmaku': SourceGroup.drama,
      '/api/v1/comments/9/digg': SourceGroup.drama,
      '/api/v1/comments/9/reply': SourceGroup.drama,
      '/api/v1/books/123/video-match': SourceGroup.novelMeta,
      // 搜索推荐
      '/api/v1/search?query=x': SourceGroup.discovery,
      '/api/v1/search/fanqie?query=x': SourceGroup.discovery,
      '/api/v1/search/cue': SourceGroup.discovery,
      '/api/v1/search/hot': SourceGroup.discovery,
      '/api/v1/recommend/homepage': SourceGroup.discovery,
      '/api/v1/recommend/series-feed': SourceGroup.discovery,
      '/api/v1/category?category_tab=1': SourceGroup.discovery,
      '/api/v1/rank/3': SourceGroup.discovery,
      // 书旗（整组，含正文）
      '/api/v1/shuqi/search?key=x': SourceGroup.shuqi,
      '/api/v1/shuqi/book?book_id=1': SourceGroup.shuqi,
      '/api/v1/shuqi/toc?book_id=1': SourceGroup.shuqi,
      '/api/v1/shuqi/chapter?book_id=1&chapter_id=2': SourceGroup.shuqi,
      // 账号
      '/api/v1/account/fanqie/library': SourceGroup.account,
      '/api/v1/account/fanqie/history': SourceGroup.account,
      // 系统
      '/health': SourceGroup.system,
      '/src/manga/abc.jpg': SourceGroup.system,
      // 未识别
      '/api/v1/what-is-this': SourceGroup.unclassified,
      '/somewhere/else': SourceGroup.unclassified,
    };
    for (final entry in cases.entries) {
      test('${entry.key} -> ${entry.value.name}', () {
        expect(SourceRouter.classify(_u(entry.key)), entry.value);
      });
    }
  });

  group('default config', () {
    final router = SourceRouter();

    test('every group resolves to local', () {
      for (final group in SourceGroup.values) {
        expect(
          router.config.configuredBackendFor(group),
          SourceBackend.local,
          reason: group.name,
        );
      }
    });

    test('representative paths all resolve to local and pass the guard', () {
      const paths = [
        '/api/v1/chapters/123',
        '/api/v1/books/123',
        '/api/v1/audio/books/123/chapters/456',
        '/api/v1/manga/123',
        '/api/v1/videos/123',
        '/api/v1/search?query=x',
        '/api/v1/shuqi/chapter?book_id=1&chapter_id=2',
        '/api/v1/account/fanqie/library',
        '/health',
        '/src/x.mp4',
      ];
      for (final path in paths) {
        expect(router.backendFor(_u(path)), SourceBackend.local, reason: path);
        expect(() => router.requireLocal(_u(path)), returnsNormally);
      }
    });

    test('no book uses the remote full pilot', () {
      expect(router.usesFullChapterPilot('123'), isFalse);
      expect(router.fullChapterEndpoint('123'), isNull);
    });

    test('no book uses the remote manga pilot', () {
      expect(router.usesMangaPilot('123'), isFalse);
      expect(router.mangaChapterEndpoint(), isNull);
    });
  });

  group('pinned local groups', () {
    final router = SourceRouter(
      config: const SourceRouterConfig(
        backends: {
          SourceGroup.account: SourceBackend.remote,
          SourceGroup.system: SourceBackend.remote,
          SourceGroup.drama: SourceBackend.remote,
        },
        remoteBaseUrl: 'https://example.invalid',
      ),
    );

    test('account stays local even when configured remote', () {
      final url = _u('/api/v1/account/fanqie/library');
      expect(router.backendFor(url), SourceBackend.local);
      expect(() => router.requireLocal(url), returnsNormally);
    });

    test('system stays local even when configured remote', () {
      for (final path in ['/health', '/src/manga/abc.jpg']) {
        final url = _u(path);
        expect(router.backendFor(url), SourceBackend.local, reason: path);
        expect(() => router.requireLocal(url), returnsNormally);
      }
    });

    test('a non-pinned group can be switched to remote by config', () {
      final url = _u('/api/v1/videos/123');
      expect(router.backendFor(url), SourceBackend.remote);
      expect(() => router.requireLocal(url), throwsStateError);
    });

    test('switching one group leaves the others local', () {
      final url = _u('/api/v1/chapters/123');
      expect(router.backendFor(url), SourceBackend.local);
      expect(() => router.requireLocal(url), returnsNormally);
    });
  });

  group('exact full-chapter pilot', () {
    final router = SourceRouter(
      config: const SourceRouterConfig(
        remoteBaseUrl: 'https://source.example.invalid',
        fullPilotBookIds: {'book-1', 'book-2'},
      ),
    );

    test('only the listed books use the remote full endpoint', () {
      expect(router.usesFullChapterPilot('book-1'), isTrue);
      expect(router.usesFullChapterPilot('book-3'), isFalse);
      expect(
        router.fullChapterEndpoint('book-2').toString(),
        'https://source.example.invalid/api/v1/chapters/full',
      );
    });

    test('the pilot does not move other novel-content paths', () {
      for (final path in [
        '/api/v1/chapters/123',
        '/api/v1/chapters/batch?item_ids=1,2',
        '/api/v1/chapters/123/novel',
        '/api/v1/chapters/123/toutiao',
        '/api/v1/chapters/full?book_id=book-1&item_ids=1',
      ]) {
        expect(router.backendFor(_u(path)), SourceBackend.local, reason: path);
        expect(() => router.requireLocal(_u(path)), returnsNormally);
      }
    });

    test('plain HTTP is accepted only for a loopback test service', () {
      final local = SourceRouter(
        config: const SourceRouterConfig(
          remoteBaseUrl: 'http://127.0.0.1:18921',
          fullPilotBookIds: {'book-1'},
        ),
      );
      expect(
        local.fullChapterEndpoint('book-1').toString(),
        'http://127.0.0.1:18921/api/v1/chapters/full',
      );

      final insecure = SourceRouter(
        config: const SourceRouterConfig(
          remoteBaseUrl: 'http://source.example.invalid',
          fullPilotBookIds: {'book-1'},
        ),
      );
      expect(() => insecure.fullChapterEndpoint('book-1'), throwsStateError);

      for (final base in [
        'http://127.example.invalid',
        'http://127.0.0.1.evil.invalid',
      ]) {
        final disguised = SourceRouter(
          config: SourceRouterConfig(
            remoteBaseUrl: base,
            fullPilotBookIds: const {'book-1'},
          ),
        );
        expect(
          () => disguised.fullChapterEndpoint('book-1'),
          throwsStateError,
          reason: base,
        );
      }
    });

    test('a base URL with a path or query is rejected', () {
      for (final base in [
        'https:',
        'https://source.example.invalid/prefix',
        'https://source.example.invalid?x=1',
      ]) {
        final invalid = SourceRouter(
          config: SourceRouterConfig(
            remoteBaseUrl: base,
            fullPilotBookIds: const {'book-1'},
          ),
        );
        expect(
          () => invalid.fullChapterEndpoint('book-1'),
          throwsStateError,
          reason: base,
        );
      }
    });
  });

  group('exact manga-chapter pilot', () {
    final router = SourceRouter(
      config: const SourceRouterConfig(
        remoteBaseUrl: 'https://source.example.invalid',
        mangaPilotBookIds: {'book-1', 'book-2'},
      ),
    );

    test('only the listed books use the remote manga endpoint', () {
      expect(router.usesMangaPilot('book-1'), isTrue);
      expect(router.usesMangaPilot('book-3'), isFalse);
      expect(
        router.mangaChapterEndpoint().toString(),
        'https://source.example.invalid/api/v1/manga/chapter',
      );
    });

    test('the pilot does not move the manga group or other manga paths', () {
      for (final path in [
        '/api/v1/manga/123',
        '/api/v1/manga/videos/9',
        '/api/v1/manga/chapter',
      ]) {
        expect(router.backendFor(_u(path)), SourceBackend.local, reason: path);
        expect(() => router.requireLocal(_u(path)), returnsNormally);
      }
    });

    test('plain HTTP is accepted only for a loopback test service', () {
      final local = SourceRouter(
        config: const SourceRouterConfig(
          remoteBaseUrl: 'http://127.0.0.1:18922',
          mangaPilotBookIds: {'book-1'},
        ),
      );
      expect(
        local.mangaChapterEndpoint().toString(),
        'http://127.0.0.1:18922/api/v1/manga/chapter',
      );

      final insecure = SourceRouter(
        config: const SourceRouterConfig(
          remoteBaseUrl: 'http://source.example.invalid',
          mangaPilotBookIds: {'book-1'},
        ),
      );
      expect(() => insecure.mangaChapterEndpoint(), throwsStateError);
    });

    test('a base URL with a path or query is rejected', () {
      for (final base in [
        'https:',
        'https://source.example.invalid/prefix',
        'https://source.example.invalid?x=1',
      ]) {
        final invalid = SourceRouter(
          config: SourceRouterConfig(
            remoteBaseUrl: base,
            mangaPilotBookIds: const {'book-1'},
          ),
        );
        expect(
          () => invalid.mangaChapterEndpoint(),
          throwsStateError,
          reason: base,
        );
      }
    });
  });

  group('runtime source routing', () {
    const buildConfig = SourceRouterConfig(
      remoteBaseUrl: 'https://source.example.invalid',
      fullPilotBookIds: {'build-full'},
      mangaPilotBookIds: {'build-manga'},
    );

    test('a missing runtime policy keeps the build-time pilot', () {
      final router = SourceRouter(config: buildConfig);

      expect(router.runtimeConfig.isPresent, isFalse);
      expect(router.usesFullChapterPilot('build-full'), isTrue);
      expect(router.usesMangaPilot('build-manga'), isTrue);
      expect(router.usesFullChapterPilot('other'), isFalse);
    });

    test('a remote scope without book ids covers every book', () {
      final router = SourceRouter(
        config: buildConfig,
        runtimeConfig: SourceRuntimeConfig.decode(
          '{"schema_version":1,"scopes":{'
          '"novel_full":{"backend":"remote"},'
          '"manga_chapter":{"backend":"local"}}}',
        ),
      );

      expect(router.usesFullChapterPilot('any-book'), isTrue);
      expect(router.usesFullChapterPilot('build-full'), isTrue);
      expect(router.usesMangaPilot('build-manga'), isFalse);
      expect(
        router.fullChapterEndpoint('any-book').toString(),
        'https://source.example.invalid/api/v1/chapters/full',
      );
    });

    test(
      'book ids restrict a remote scope, and an empty list selects none',
      () {
        final router = SourceRouter(
          config: buildConfig,
          runtimeConfig: SourceRuntimeConfig.decode(
            '{"schema_version":1,"scopes":{'
            '"novel_full":{"backend":"remote","book_ids":["book-1","book-2"]},'
            '"manga_chapter":{"backend":"remote","book_ids":[]}}}',
          ),
        );

        expect(router.usesFullChapterPilot('book-1'), isTrue);
        expect(router.usesFullChapterPilot('book-2'), isTrue);
        expect(router.usesFullChapterPilot('book-3'), isFalse);
        expect(router.usesFullChapterPilot('build-full'), isFalse);
        expect(router.usesMangaPilot('book-1'), isFalse);
      },
    );

    test(
      'an explicit local policy and the all-local policy override pilots',
      () {
        final explicitLocal = SourceRouter(
          config: buildConfig,
          runtimeConfig: SourceRuntimeConfig.decode(
            '{"schema_version":1,"scopes":{'
            '"novel_full":{"backend":"local"},'
            '"manga_chapter":{"backend":"remote"}}}',
          ),
        );
        expect(explicitLocal.usesFullChapterPilot('build-full'), isFalse);
        expect(explicitLocal.usesMangaPilot('any-manga'), isTrue);

        final allLocal = SourceRouter(
          config: buildConfig,
          runtimeConfig: const SourceRuntimeConfig.allLocal(),
        );
        expect(allLocal.usesFullChapterPilot('build-full'), isFalse);
        expect(allLocal.usesMangaPilot('build-manga'), isFalse);
      },
    );

    test('narrow runtime scopes never move broad or pinned-local paths', () {
      final router = SourceRouter(
        config: buildConfig,
        runtimeConfig: SourceRuntimeConfig.decode(
          '{"schema_version":1,"scopes":{'
          '"novel_full":{"backend":"remote"},'
          '"manga_chapter":{"backend":"remote"}}}',
        ),
      );

      for (final path in [
        '/api/v1/chapters/123',
        '/api/v1/chapters/batch?item_ids=1,2',
        '/api/v1/manga/123',
        '/api/v1/manga/videos/9',
        '/api/v1/account/fanqie/library',
        '/health',
        '/src/x.mp4',
      ]) {
        expect(router.backendFor(_u(path)), SourceBackend.local, reason: path);
        expect(() => router.requireLocal(_u(path)), returnsNormally);
      }
    });

    test('applyRuntimeConfig changes subsequent decisions immediately', () {
      final router = SourceRouter(config: buildConfig);
      expect(router.usesFullChapterPilot('build-full'), isTrue);

      router.applyRuntimeConfig(const SourceRuntimeConfig.allLocal());
      expect(router.usesFullChapterPilot('build-full'), isFalse);

      router.applyRuntimeConfig(
        SourceRuntimeConfig.decode(
          '{"schema_version":1,"scopes":{'
          '"novel_full":{"backend":"remote"}}}',
        ),
      );
      expect(router.usesFullChapterPilot('build-full'), isTrue);
      expect(router.usesFullChapterPilot('new-book'), isTrue);
    });

    test('an expired runtime policy stops selecting the remote scope', () {
      final router = SourceRouter(config: buildConfig)
        ..applyRuntimeConfig(
          SourceRuntimeConfig.decode(
            '{"schema_version":1,"scopes":{"novel_full":{"backend":"remote"}}}',
          ),
          expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
        );

      expect(router.usesFullChapterPilot('any-book'), isFalse);
    });

    test('runtime policy serialization preserves remote book restrictions', () {
      final config = SourceRuntimeConfig.decode(
        '{"schema_version":1,"scopes":{'
        '"novel_full":{"backend":"remote","book_ids":["book-2","book-1"]},'
        '"manga_chapter":{"backend":"remote","book_ids":[]}}}',
      );

      expect(
        SourceRuntimeConfig.fromJson(config.toJson()).toJson(),
        config.toJson(),
      );
      expect(config.toJson(), {
        'schema_version': 1,
        'scopes': {
          'novel_full': {
            'backend': 'remote',
            'book_ids': ['book-2', 'book-1'],
          },
          'manga_chapter': {'backend': 'remote', 'book_ids': <String>[]},
        },
      });
    });

    test('malformed or unknown runtime contract values are rejected', () {
      for (final raw in [
        '',
        '{',
        '{"schema_version":2,"scopes":{}}',
        '{"schema_version":1,"scopes":[]}',
        '{"schema_version":1,"scopes":{"account":{"backend":"remote"}}}',
        '{"schema_version":1,"scopes":{"novel_full":{"backend":"cloud"}}}',
        '{"schema_version":1,"scopes":{"novel_full":{"book_ids":[]}}}',
        '{"schema_version":1,"scopes":{'
            '"novel_full":{"backend":"local","book_ids":[]}}}',
        '{"schema_version":1,"scopes":{'
            '"novel_full":{"backend":"remote","book_ids":["book 1"]}}}',
        '{"schema_version":1,"scopes":{'
            '"novel_full":{"backend":"remote","book_ids":["book-1","book-1"]}}}',
        '{"schema_version":1,"scopes":{},'
            '"remote_base_url":"https://source.example.invalid"}',
      ]) {
        expect(
          () => SourceRuntimeConfig.decode(raw),
          throwsFormatException,
          reason: raw,
        );
      }
    });
  });

  group('remote source policy', () {
    final now = DateTime.now().toUtc();
    final future = now.add(const Duration(minutes: 5));

    Map<String, Object?> remotePolicy({
      required int expiresAt,
      String backend = 'remote',
      List<String> bookIds = const ['book-1'],
    }) => {
      'schema_version': 1,
      'expires_at': expiresAt,
      'scopes': {
        'novel_full': {
          'backend': backend,
          if (backend == 'remote') 'book_ids': bookIds,
        },
        'manga_chapter': {'backend': 'local'},
      },
    };

    http.Response jsonResponse(Object value) => http.Response(
      jsonEncode(value),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

    test('the policy envelope is strict and cannot name account routes', () {
      final expiresAt = future.millisecondsSinceEpoch ~/ 1000;
      for (final raw in <Object?>[
        {'schema_version': 1, 'scopes': <String, Object?>{}},
        {
          ...remotePolicy(expiresAt: expiresAt),
          'remote_base_url': 'https://source.example.invalid',
        },
        {...remotePolicy(expiresAt: expiresAt), 'schema_version': 2},
        {...remotePolicy(expiresAt: expiresAt), 'expires_at': '$expiresAt'},
        {
          'schema_version': 1,
          'expires_at': expiresAt,
          'scopes': {
            'account': {'backend': 'remote'},
          },
        },
        {
          'schema_version': 1,
          'expires_at': expiresAt,
          'scopes': {
            'novel_full': {'backend': 'local', 'book_ids': <String>[]},
          },
        },
      ]) {
        expect(
          () => RemoteSourcePolicy.fromJson(raw),
          throwsFormatException,
          reason: '$raw',
        );
      }
    });

    Future<SharedPreferences> preferences([
      Map<String, Object>? initial,
    ]) async {
      SharedPreferences.setMockInitialValues(initial ?? {});
      return SharedPreferences.getInstance();
    }

    ApiClient apiWith({
      required SourceRouter router,
      required http.Client remote,
    }) {
      final local = MockClient(
        (request) => Future<http.Response>.error(
          StateError('local core was called: ${request.url}'),
        ),
      );
      addTearDown(local.close);
      addTearDown(remote.close);
      return ApiClient(
        client: local,
        baseUrl: 'http://127.0.0.1:18921',
        remoteClient: remote,
        sourceRouter: router,
      );
    }

    test(
      'a normal build performs no policy request and remains local',
      () async {
        var requests = 0;
        final remote = MockClient((_) async {
          requests++;
          return jsonResponse(
            remotePolicy(expiresAt: future.millisecondsSinceEpoch ~/ 1000),
          );
        });
        final router = SourceRouter(config: const SourceRouterConfig());
        final api = apiWith(router: router, remote: remote);
        final controller = SourcePolicyController(
          api: api,
          preferences: await preferences(),
          now: () => now,
          observeLifecycle: false,
        );
        addTearDown(controller.dispose);

        controller.start();
        await controller.refresh();

        expect(requests, 0);
        expect(router.runtimeConfig.isPresent, isFalse);
        expect(router.usesFullChapterPilot('book-1'), isFalse);
      },
    );

    test('a valid policy is applied and cached before it is used', () async {
      final expiresAt = future.millisecondsSinceEpoch ~/ 1000;
      final remote = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/v1/client-policy');
        expect(request.bodyBytes, isEmpty);
        return jsonResponse(remotePolicy(expiresAt: expiresAt));
      });
      final router = SourceRouter(
        config: const SourceRouterConfig(
          remoteBaseUrl: 'http://127.0.0.1:18922',
        ),
      );
      final prefs = await preferences();
      final api = apiWith(router: router, remote: remote);
      final controller = SourcePolicyController(
        api: api,
        preferences: prefs,
        now: () => now,
        observeLifecycle: false,
      );
      addTearDown(controller.dispose);

      controller.start();
      await controller.refresh();

      expect(router.usesFullChapterPilot('book-1'), isTrue);
      expect(router.usesFullChapterPilot('book-2'), isFalse);
      final cached = RemoteSourcePolicy.decode(
        prefs.getString(SourcePolicyController.cachePreferenceKey)!,
      );
      expect(cached.expiresAt, expiresAt);
      expect(
        cached.runtimeConfig.backendFor(SourceRouteScope.novelFull),
        SourceBackend.remote,
      );
    });

    testWidgets('a foreground policy refreshes before it expires', (
      tester,
    ) async {
      var requests = 0;
      final shortExpiry = now.add(const Duration(seconds: 10));
      final remote = MockClient((_) async {
        requests++;
        return jsonResponse(
          remotePolicy(
            expiresAt: requests == 1
                ? shortExpiry.millisecondsSinceEpoch ~/ 1000
                : future.millisecondsSinceEpoch ~/ 1000,
          ),
        );
      });
      final router = SourceRouter(
        config: const SourceRouterConfig(
          remoteBaseUrl: 'http://127.0.0.1:18922',
        ),
      );
      final api = apiWith(router: router, remote: remote);
      final controller = SourcePolicyController(
        api: api,
        preferences: await preferences(),
        now: () => now,
      );

      controller.start();
      await controller.refresh();
      expect(requests, 1);
      expect(router.usesFullChapterPilot('book-1'), isTrue);

      await tester.pump(const Duration(seconds: 4));
      expect(requests, 1);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(requests, 2);
      expect(router.usesFullChapterPilot('book-1'), isTrue);

      controller.dispose();
      await tester.pump();
    });

    testWidgets('pausing stops the refresh and resuming refreshes at once', (
      tester,
    ) async {
      var requests = 0;
      final shortExpiry = now.add(const Duration(seconds: 10));
      final remote = MockClient((_) async {
        requests++;
        return jsonResponse(
          remotePolicy(
            expiresAt: requests == 1
                ? shortExpiry.millisecondsSinceEpoch ~/ 1000
                : future.millisecondsSinceEpoch ~/ 1000,
          ),
        );
      });
      final router = SourceRouter(
        config: const SourceRouterConfig(
          remoteBaseUrl: 'http://127.0.0.1:18922',
        ),
      );
      final api = apiWith(router: router, remote: remote);
      final controller = SourcePolicyController(
        api: api,
        preferences: await preferences(),
        now: () => now,
      );

      controller.start();
      await controller.refresh();
      expect(requests, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(minutes: 1));
      expect(requests, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(requests, 2);
      expect(router.usesFullChapterPilot('book-1'), isTrue);

      controller.dispose();
      await tester.pump();
    });

    test('an unexpired cached policy survives a refresh failure', () async {
      final expiresAt = future.millisecondsSinceEpoch ~/ 1000;
      final prefs = await preferences({
        SourcePolicyController.cachePreferenceKey: jsonEncode(
          remotePolicy(expiresAt: expiresAt),
        ),
      });
      final remote = MockClient((_) async => http.Response('unavailable', 503));
      final router = SourceRouter(
        config: const SourceRouterConfig(
          remoteBaseUrl: 'http://127.0.0.1:18922',
        ),
      );
      final api = apiWith(router: router, remote: remote);
      final controller = SourcePolicyController(
        api: api,
        preferences: prefs,
        now: () => now,
        observeLifecycle: false,
      );
      addTearDown(controller.dispose);

      controller.start();
      await controller.refresh();

      expect(router.usesFullChapterPilot('book-1'), isTrue);
      expect(
        prefs.getString(SourcePolicyController.cachePreferenceKey),
        isNotNull,
      );
    });

    test('an expired cache and failed refresh fail closed to local', () async {
      final expiredAt =
          now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/
          1000;
      final prefs = await preferences({
        SourcePolicyController.cachePreferenceKey: jsonEncode(
          remotePolicy(expiresAt: expiredAt),
        ),
      });
      final remote = MockClient((_) async => http.Response('unavailable', 503));
      final router = SourceRouter(
        config: const SourceRouterConfig(
          remoteBaseUrl: 'http://127.0.0.1:18922',
        ),
      );
      final api = apiWith(router: router, remote: remote);
      final controller = SourcePolicyController(
        api: api,
        preferences: prefs,
        now: () => now,
        observeLifecycle: false,
      );
      addTearDown(controller.dispose);

      controller.start();
      await controller.refresh();

      expect(router.usesFullChapterPilot('book-1'), isFalse);
      expect(router.runtimeConfig.isPresent, isTrue);
      expect(
        router.runtimeConfig.backendFor(SourceRouteScope.novelFull),
        SourceBackend.local,
      );
      expect(
        prefs.getString(SourcePolicyController.cachePreferenceKey),
        isNull,
      );
    });

    test('a downloaded all-local policy is the kill switch', () async {
      final expiresAt = future.millisecondsSinceEpoch ~/ 1000;
      final remote = MockClient(
        (_) async =>
            jsonResponse(remotePolicy(expiresAt: expiresAt, backend: 'local')),
      );
      final router = SourceRouter(
        config: const SourceRouterConfig(
          remoteBaseUrl: 'http://127.0.0.1:18922',
          fullPilotBookIds: {'build-book'},
        ),
      );
      final api = apiWith(router: router, remote: remote);
      final controller = SourcePolicyController(
        api: api,
        preferences: await preferences(),
        now: () => now,
        observeLifecycle: false,
      );
      addTearDown(controller.dispose);

      expect(router.usesFullChapterPilot('build-book'), isTrue);
      controller.start();
      await controller.refresh();

      expect(router.usesFullChapterPilot('build-book'), isFalse);
      expect(router.usesFullChapterPilot('book-1'), isFalse);
    });

    test(
      'a local override beats both the cache and the server policy',
      () async {
        var requests = 0;
        final remote = MockClient((_) async {
          requests++;
          return jsonResponse(
            remotePolicy(
              expiresAt: future.millisecondsSinceEpoch ~/ 1000,
              backend: 'local',
            ),
          );
        });
        final router = SourceRouter(
          config: const SourceRouterConfig(
            remoteBaseUrl: 'http://127.0.0.1:18922',
            fullPilotBookIds: {'build-book'},
          ),
        );
        final api = apiWith(router: router, remote: remote);
        final prefs = await preferences({
          SourceRuntimeConfig.preferenceKey:
              '{"schema_version":1,"scopes":{"novel_full":{"backend":"local"}}}',
        });
        final controller = SourcePolicyController(
          api: api,
          preferences: prefs,
          now: () => now,
          observeLifecycle: false,
        );
        addTearDown(controller.dispose);

        controller.start();
        await controller.refresh();

        expect(requests, 0);
        expect(router.usesFullChapterPilot('build-book'), isFalse);
      },
    );
  });
}
