import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/app_log.dart';
import 'package:fqapp/services/source_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';

const _testInstallToken = 'fixture';
const _testInstallSigningKey = 'fixtureSigningKey';

void main() {
  test(
    'series detail forwards the requested id to upstream record selection',
    () async {
      final requests = <http.Request>[];
      final transport = MockClient((request) async {
        requests.add(request);
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 0,
              'data': {
                'video-id': {
                  'series_id_str': 'series-42',
                  'series_title': 'Fixture series',
                  'episode_cnt': 12,
                },
              },
            }),
          ),
          200,
        );
      });
      addTearDown(transport.close);
      final api = ApiClient(
        client: transport,
        baseUrl: 'http://localhost:9000',
      );

      final detail = await api.seriesDetail('series-42');

      expect(detail.title, 'Fixture series');
      expect(detail.episodeCount, 12);
      expect(requests.single.url.path, '/api/v1/series/series-42');
    },
  );

  test(
    'series detail strict failures preserve legacy best-effort callers',
    () async {
      for (final response in [
        http.Response('offline', 503),
        http.Response('{"code":0,"data":{}}', 200),
        http.Response('{"code":500,"message":"unavailable"}', 200),
      ]) {
        final transport = MockClient((_) async => response);
        addTearDown(transport.close);
        final api = ApiClient(
          client: transport,
          baseUrl: 'http://localhost:9000',
        );
        expect((await api.seriesDetail('s1')).isEmpty, isTrue);
        await expectLater(
          api.seriesDetail('s1', strict: true),
          throwsA(isA<ApiException>()),
        );
      }
    },
  );

  const special = 'id &mode=changed#+/中文%';

  group('paragraph comments from saved catalogues', () {
    for (final savedVersion in ['', 'saved-version']) {
      test(
        'resolves only missing versions before loading comments ($savedVersion)',
        () async {
          final requests = <Uri>[];
          final transport = MockClient((request) async {
            requests.add(request.url);
            final payload = request.url.path.endsWith('/directory')
                ? {
                    'code': 200,
                    'data': {
                      'item_data_list': [
                        {
                          'item_id': 'other',
                          'title': '第一章',
                          'version': 'other-version',
                        },
                        {
                          'item_id': 'chapter',
                          'title': '第二章',
                          'version': 'fresh-version',
                        },
                      ],
                    },
                  }
                : {
                    'code': 0,
                    'data': {
                      'common_list_info': {'total': 522},
                      'data_list': [
                        {
                          'comment': {
                            'comment_id': 'c1',
                            'common': {
                              'content': {'text': '实际段评'},
                            },
                          },
                        },
                      ],
                    },
                  };
            return http.Response.bytes(utf8.encode(jsonEncode(payload)), 200);
          });
          addTearDown(transport.close);
          final api = ApiClient(
            client: transport,
            baseUrl: 'http://localhost:9000',
          );
          final page = await api.paragraphComments(
            'book',
            'chapter',
            itemVersion: savedVersion,
            paraIndex: 4,
          );
          expect(requests.length, savedVersion.isEmpty ? 2 : 1);
          expect(
            requests.last.queryParameters['item_version'],
            savedVersion.isEmpty ? 'fresh-version' : savedVersion,
          );
          expect(requests.last.queryParameters['group_id'], 'chapter');
          expect(requests.last.queryParameters['para_index'], '4');
          // 38 is the paragraph-comment channel that matches the idea count
          // on every tested book; 43/39 are empty or partial.
          expect(requests.last.queryParameters['server_channel'], '38');
          // The first page sends no cursor: the request must stay byte for
          // byte identical with the verified recipe.
          expect(requests.last.queryParameters.containsKey('cursor'), isFalse);
          expect(page.totalCount, 522);
          expect(page.comments.single.text, '实际段评');
        },
      );
    }

    test(
      'a missing chapter version is retryable failure, not an empty list',
      () async {
        final requests = <Uri>[];
        final transport = MockClient((request) async {
          requests.add(request.url);
          return http.Response('{"code":200,"data":{}}', 200);
        });
        addTearDown(transport.close);
        final api = ApiClient(
          client: transport,
          baseUrl: 'http://localhost:9000',
        );
        await expectLater(
          api.paragraphComments(
            'book',
            'missing',
            itemVersion: '',
            paraIndex: 0,
          ),
          throwsA(isA<ApiException>()),
        );
        expect(requests.single.path, contains('/directory'));
      },
    );

    test('the cursor token is forwarded so the panel can page', () async {
      final requests = <Uri>[];
      final transport = MockClient((request) async {
        requests.add(request.url);
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 0,
              'data': {
                'common_list_info': {
                  'total': 522,
                  'has_more': false,
                  'cursor': '40',
                },
                'data_list': [
                  {
                    'comment': {
                      'comment_id': 'c2',
                      'common': {
                        'content': {'text': '第二页的段评'},
                      },
                    },
                  },
                ],
              },
            }),
          ),
          200,
        );
      });
      addTearDown(transport.close);
      final api = ApiClient(
        client: transport,
        baseUrl: 'http://localhost:9000',
      );
      final page = await api.paragraphComments(
        'book',
        'chapter',
        itemVersion: 'v',
        paraIndex: 0,
        cursor: '20',
      );
      expect(requests.single.queryParameters['cursor'], '20');
      expect(page.comments.single.text, '第二页的段评');
      expect(page.hasMore, isFalse);
      expect(page.nextOffset, 40);
    });
  });

  for (final wrapped in [false, true]) {
    test(
      'typed search isolates its source before splitting manju ($wrapped)',
      () async {
        late Uri sent;
        final payload = {
          'code': 0,
          'search_tabs': [
            {
              'title': '综合',
              'tab_type': 1,
              'has_more': true,
              'next_offset': 99,
              'data': [
                {'video_id': 'other', 'title': '其他栏目的漫剧', 'kind': 'manju'},
              ],
            },
            {
              'title': '短剧',
              'tab_type': '11',
              'has_more': true,
              'next_offset': '27',
              'data': [
                {'video_id': 'live', 'title': '本栏短剧'},
                {'video_id': 'animated', 'title': '本栏漫剧', 'kind': 'manju'},
              ],
            },
          ],
        };
        final transport = MockClient((request) async {
          sent = request.url;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(wrapped ? {'code': 200, 'data': payload} : payload),
            ),
            200,
          );
        });
        addTearDown(transport.close);
        final api = ApiClient(
          client: transport,
          baseUrl: 'http://localhost:9000',
        );

        final tabs = await api.searchTabs('作品', tabType: 11, offset: 14);
        expect(sent.path, '/api/v1/search');
        expect(sent.queryParameters, {
          'query': '作品',
          'tab_type': '11',
          'offset': '14',
          'count': '10',
        });
        expect(tabs.map((tab) => tab.title), ['短剧', '漫剧']);
        expect(tabs[0].items.single.id, 'live');
        expect(tabs[1].items.single.id, 'animated');
        expect(
          tabs.every((tab) => tab.hasMore == true && tab.nextOffset == 27),
          isTrue,
        );
      },
    );
  }

  test('query values survive all API request builders unchanged', () async {
    late Uri sent;
    final transport = MockClient((request) async {
      sent = request.url;
      return http.Response('{"code":200,"data":{}}', 200);
    });
    addTearDown(transport.close);
    final api = ApiClient(client: transport, baseUrl: 'http://localhost:9000');

    await api.search(special, page: 2);
    expect(sent.queryParameters, {
      'query': special,
      'offset': '10',
      'count': '10',
    });
    await api.searchTabs(special, page: 3);
    expect(sent.queryParameters['query'], special);
    await api.searchTabs(special, page: 3, tabType: 8);
    expect(sent.path, '/api/v1/search');
    expect(sent.queryParameters, {
      'query': special,
      'tab_type': '8',
      'offset': '20',
      'count': '10',
    });
    expect(sent.fragment, isEmpty);

    await api.searchTabs(special, page: 3, tabType: 11, offset: 17);
    expect(sent.path, '/api/v1/search');
    expect(sent.queryParameters, {
      'query': special,
      'tab_type': '11',
      'offset': '17',
      'count': '10',
    });

    // Detail and directory are addressed through the v1 routes that replaced
    // the removed Web bridge; the id travels in the path, so the query carries
    // nothing and the encoded id must survive intact.
    await api.detail(special);
    expect(sent.path, contains('/api/v1/books/'));
    expect(sent.pathSegments.last, 'detail');
    expect(sent.pathSegments[3], special);
    expect(sent.queryParameters, isEmpty);
    expect(sent.fragment, isEmpty);

    for (final action in [api.directory, api.directoryChapters]) {
      await action(special, tab: special);
      expect(sent.pathSegments[3], special);
      expect(sent.pathSegments.last, 'directory');
      expect(sent.fragment, isEmpty);
    }

    // Novel content goes to the chapter route.
    await api.content(special, tab: '小说', toneId: special, mode: special);
    expect(sent.pathSegments[3], special);
    expect(sent.queryParameters['tone_id'], special);
    await api.contentText(special, tab: '小说');
    expect(sent.pathSegments[3], special);
    expect(sent.fragment, isEmpty);

    // Each tab is a distinct route, not a query parameter.
    await api.content(special, tab: '漫画');
    expect(sent.path, contains('/api/v1/manga/'));
    await api.content(special, tab: '短剧', mode: special);
    expect(sent.path, contains('/api/v1/videos/'));
    expect(sent.queryParameters['mode'], special);
    // 用途参数是本地契约:不给 purpose 时不出现,给出时只追加一个。
    expect(sent.queryParameters.containsKey('_playback_purpose'), isFalse);
    await api.content(
      special,
      tab: '短剧',
      mode: special,
      purpose: PlaybackPurpose.prefetch,
    );
    expect(sent.path, contains('/api/v1/videos/'));
    expect(sent.queryParameters['mode'], special);
    expect(sent.queryParameters['_playback_purpose'], 'prefetch');
    // gate key 仍是原始 URL:同 URL 的 foreground/prefetch 合并为一次在飞请求。
    // 传输 URI 带第一发起者的用途;joiner 不重发,只共享该航班,日志记自己
    // 请求的用途(queue=shared)。
    var videoHits = 0;
    Uri? firstVideoRequest;
    final flightStarted = Completer<void>();
    final releaseFlight = Completer<void>();
    final gatedTransport = MockClient((request) async {
      videoHits++;
      firstVideoRequest = request.url;
      flightStarted.complete();
      await releaseFlight.future;
      return http.Response('{"code":200,"data":{}}', 200);
    });
    addTearDown(gatedTransport.close);
    final gatedApi = ApiClient(
      client: gatedTransport,
      baseUrl: 'http://localhost:9000',
    );
    AppLog.instance.clear();
    final foreground = gatedApi.content(
      special,
      tab: '短剧',
      mode: 'stream',
      purpose: PlaybackPurpose.foreground,
    );
    // 等第一发起者真正握手后再发 joiner,合并才由 gate key 决定而非时序。
    await flightStarted.future;
    final prefetch = gatedApi.content(
      special,
      tab: '短剧',
      mode: 'stream',
      purpose: PlaybackPurpose.prefetch,
    );
    releaseFlight.complete();
    await Future.wait([foreground, prefetch]);
    await pumpEventQueue();
    expect(videoHits, 1);
    expect(
      firstVideoRequest!.queryParameters['_playback_purpose'],
      'foreground',
    );
    final apiLogs = AppLog.instance.entries
        .where((entry) => entry.tag == 'api')
        .map((entry) => entry.message)
        .toList();
    final prefetchLogs = apiLogs
        .where((message) => message.contains('purpose=prefetch'))
        .toList();
    expect(prefetchLogs, hasLength(1));
    expect(prefetchLogs.single, contains('queue=shared'));
    final foregroundLogs = apiLogs
        .where((message) => message.contains('purpose=foreground'))
        .toList();
    expect(foregroundLogs, hasLength(1));
    expect(foregroundLogs.single, isNot(contains('queue=shared')));
    await api.homepageRecommend(tabType: 8, offset: 2, sessionId: special);
    expect(sent.queryParameters, {
      'tab_type': '8',
      'offset': '2',
      'session_id': special,
    });
    await api.homepagePage(tabType: 8, offset: 2, sessionId: special);
    expect(sent.queryParameters['session_id'], special);
    expect(sent.fragment, isEmpty);
  });

  test('resource URLs resolve network paths and backend paths correctly', () {
    final transport = MockClient((_) async => http.Response('', 200));
    addTearDown(transport.close);
    final api = ApiClient(client: transport, baseUrl: 'http://localhost:9000');

    expect(api.absoluteUrl('  '), isEmpty);
    expect(
      api.absoluteUrl('/src/video.mp4'),
      'http://localhost:9000/src/video.mp4',
    );
    expect(
      api.absoluteUrl('src/video.mp4'),
      'http://localhost:9000/src/video.mp4',
    );
    expect(
      api.absoluteUrl('//cdn.example/video.mp4'),
      'http://cdn.example/video.mp4',
    );
    const signed = 'https://cdn.example/video.mp4?sign=a%2Fb+xyz';
    expect(api.absoluteUrl(' $signed '), signed);
  });

  test(
    'both supported envelopes preserve UTF-8 data through parsing',
    () async {
      for (final code in [0, 200]) {
        final transport = MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'code': code,
                'data': {
                  'search_tabs': [
                    {
                      'title': '小说',
                      'data': [
                        {'book_id': '1', 'book_name': '中文书名'},
                      ],
                    },
                  ],
                },
              }),
            ),
            200,
          ),
        );
        addTearDown(transport.close);
        final tabs = await ApiClient(client: transport).searchTabs('中文');
        expect(tabs.single.items.single.title, '中文书名');
      }
    },
  );

  test('unsuccessful envelopes surface as API errors', () async {
    for (final body in [
      {'code': 500, 'message': '失败'},
      {'success': false, 'error': '失败'},
    ]) {
      final transport = MockClient(
        (_) async => http.Response.bytes(utf8.encode(jsonEncode(body)), 200),
      );
      addTearDown(transport.close);
      await expectLater(
        ApiClient(client: transport).detail('1'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', '失败')),
      );
    }
  });

  test(
    'remote full pilot signs, decrypts locally, and appends the suffix',
    () async {
      final remoteRequests = <http.Request>[];
      final remote = MockClient((request) async {
        remoteRequests.add(request);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final key = request.headers['X-FQ-Signature'];
        final timestamp = request.headers['X-FQ-Timestamp']!;
        final nonce = request.headers['X-FQ-Nonce']!;
        final bodyHash = sha256.convert(request.bodyBytes).toString();
        final canonical =
            'POST\n/api/v1/chapters/full\n$timestamp\n$nonce\n$bodyHash';
        final expected = Hmac(
          sha256,
          utf8.encode(_testInstallSigningKey),
        ).convert(utf8.encode(canonical)).toString();
        expect(request.headers['Authorization'], 'Bearer $_testInstallToken');
        expect(key, 'v1=$expected');
        expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(nonce), isTrue);

        final encrypted = _encryptForClient(
          body['client_public_key'] as String,
          '<p>第一段</p><p>第二段</p>',
        );
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 0,
              'data': {
                'item_infos': {
                  'chapter-1': {
                    'title': '第一章',
                    'key': encrypted.key,
                    'content': encrypted.content,
                  },
                },
              },
              'relay': {'protocol': 1, 'content_suffix': '\n\n（完）'},
            }),
          ),
          200,
        );
      });
      final local = MockClient((request) async {
        fail('local core was called: ${request.url}');
      });
      addTearDown(remote.close);
      addTearDown(local.close);
      final api = ApiClient(
        client: local,
        remoteClient: remote,
        sourceRouter: SourceRouter(
          config: const SourceRouterConfig(
            remoteBaseUrl: 'http://127.0.0.1:18921',
            fullPilotBookIds: {'book-1'},
            installToken: _testInstallToken,
            installSigningKey: _testInstallSigningKey,
          ),
        ),
      );

      final content = await api.remoteFullChapterContent('book-1', 'chapter-1');

      expect(content.legacyText, '第一段\n第二段\n（完）');
      final request = remoteRequests.single;
      expect(
        request.url.toString(),
        'http://127.0.0.1:18921/api/v1/chapters/full',
      );
      expect(request.url.query, isEmpty);
      final sent = jsonDecode(request.body) as Map<String, dynamic>;
      expect(sent.keys.toSet(), {'book_id', 'item_ids', 'client_public_key'});
      expect(sent['book_id'], 'book-1');
      expect(sent['item_ids'], ['chapter-1']);
    },
  );

  test('remote full failures never call the local body path', () async {
    final local = MockClient((request) async {
      fail('local core was called: ${request.url}');
    });
    addTearDown(local.close);

    for (final response in [
      http.Response(
        '{"success":false,"error":"upstream failed","error_code":"upstream_error"}',
        502,
      ),
      http.Response(
        '{"code":0,"data":{"item_infos":{}},"relay":{"protocol":2}}',
        200,
      ),
      http.Response(
        '{"code":0,"data":{"item_infos":{}},"relay":{"protocol":1}}',
        200,
      ),
    ]) {
      final remote = MockClient((_) async => response);
      addTearDown(remote.close);
      final api = ApiClient(
        client: local,
        remoteClient: remote,
        sourceRouter: SourceRouter(
          config: const SourceRouterConfig(
            remoteBaseUrl: 'http://127.0.0.1:18921',
            fullPilotBookIds: {'book-1'},
          ),
        ),
      );
      await expectLater(
        api.remoteFullChapterContent('book-1', 'chapter-1'),
        throwsA(isA<Exception>()),
      );
    }
  });

  test(
    'remote full rejects a non-zero envelope with valid ciphertext',
    () async {
      final local = MockClient((request) async {
        fail('local core was called: ${request.url}');
      });
      final remote = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final encrypted = _encryptForClient(
          body['client_public_key'] as String,
          '<p>不应显示</p>',
        );
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 200,
              'data': {
                'item_infos': {
                  'chapter-1': {
                    'title': '第一章',
                    'key': encrypted.key,
                    'content': encrypted.content,
                  },
                },
              },
              'relay': {'protocol': 1},
            }),
          ),
          200,
        );
      });
      addTearDown(remote.close);
      addTearDown(local.close);
      final api = ApiClient(
        client: local,
        remoteClient: remote,
        sourceRouter: SourceRouter(
          config: const SourceRouterConfig(
            remoteBaseUrl: 'http://127.0.0.1:18921',
            fullPilotBookIds: {'book-1'},
          ),
        ),
      );

      await expectLater(
        api.remoteFullChapterContent('book-1', 'chapter-1'),
        throwsA(isA<ApiException>()),
      );
    },
  );

  test('a non-loopback remote requires install auth before sending', () async {
    var called = false;
    final remote = MockClient((_) async {
      called = true;
      return http.Response('{}', 200);
    });
    addTearDown(remote.close);
    final api = ApiClient(
      remoteClient: remote,
      sourceRouter: SourceRouter(
        config: const SourceRouterConfig(
          remoteBaseUrl: 'https://source.example.invalid',
          fullPilotBookIds: {'book-1'},
        ),
      ),
    );

    await expectLater(
      api.remoteFullChapterContent('book-1', 'chapter-1'),
      throwsA(isA<ApiException>()),
    );
    expect(called, isFalse);
  });

  test(
    'remote manga pilot signs the exact endpoint and keeps page order',
    () async {
      final remoteRequests = <http.Request>[];
      final remote = MockClient((request) async {
        remoteRequests.add(request);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body.keys.toSet(), {'item_id'});
        expect(request.url.path, '/api/v1/manga/chapter');
        expect(request.url.query, isEmpty);
        final timestamp = request.headers['X-FQ-Timestamp']!;
        final nonce = request.headers['X-FQ-Nonce']!;
        final bodyHash = sha256.convert(request.bodyBytes).toString();
        final canonical =
            'POST\n/api/v1/manga/chapter\n$timestamp\n$nonce\n$bodyHash';
        final expected = Hmac(
          sha256,
          utf8.encode(_testInstallSigningKey),
        ).convert(utf8.encode(canonical)).toString();
        expect(request.headers['Authorization'], 'Bearer $_testInstallToken');
        expect(request.headers['X-FQ-Signature'], 'v1=$expected');
        return _json(
          _mangaEnvelope(
            itemId: 'chapter-1',
            picUrls: const [
              'https://cdn.example/a.jpg?sign=a%2Fb&x=1',
              'https://cdn.example/b.png',
              'https://cdn.example/a.jpg?sign=a%2Fb&x=1',
            ],
          ),
        );
      });
      var localCalls = 0;
      final local = MockClient((_) async {
        localCalls++;
        return _json({});
      });
      addTearDown(remote.close);
      addTearDown(local.close);
      final api = ApiClient(
        client: local,
        remoteClient: remote,
        sourceRouter: SourceRouter(
          config: const SourceRouterConfig(
            remoteBaseUrl: 'http://127.0.0.1:18922',
            mangaPilotBookIds: {'book-1'},
            installToken: _testInstallToken,
            installSigningKey: _testInstallSigningKey,
          ),
        ),
      );

      final images = await api.remoteComicImages('book-1', 'chapter-1');

      expect(images.map((image) => image.url), [
        'https://cdn.example/a.jpg?sign=a%2Fb&x=1',
        'https://cdn.example/b.png',
        'https://cdn.example/a.jpg?sign=a%2Fb&x=1',
      ]);
      expect(
        images.every((image) => image.encryptKeyHex == _mangaImageKeyHex),
        isTrue,
      );
      expect(remoteRequests, hasLength(1));
      expect(localCalls, 0);
    },
  );

  test('remote manga failures never call the local comic path', () async {
    final invalid = <Object>[
      {
        'code': 200,
        'data': _mangaData(picUrls: const ['https://cdn.example/a.jpg']),
        'relay': {'protocol': 1},
      },
      {
        'code': 0,
        'data': _mangaData(picUrls: const ['https://cdn.example/a.jpg']),
        'relay': {'protocol': 2},
      },
      {
        'code': 0,
        'data': _mangaData(
          itemId: 'chapter-2',
          picUrls: const ['https://cdn.example/a.jpg'],
        ),
        'relay': {'protocol': 1},
      },
      {
        'code': 0,
        'data': _mangaData(
          key: List.filled(63, 'a').join(),
          picUrls: const ['https://cdn.example/a.jpg'],
        ),
        'relay': {'protocol': 1},
      },
      {
        'code': 0,
        'data': _mangaData(
          key: List.filled(64, 'z').join(),
          picUrls: const ['https://cdn.example/a.jpg'],
        ),
        'relay': {'protocol': 1},
      },
      {
        'code': 0,
        'data': _mangaData(picUrls: const []),
        'relay': {'protocol': 1},
      },
      {
        'code': 0,
        'data': _mangaData(
          picUrls: List.generate(65, (_) => 'https://cdn.example/a.jpg'),
        ),
        'relay': {'protocol': 1},
      },
      for (final url in [
        '/src/a.jpg',
        'https://cdn.example/src/a.jpg',
        'https://user@cdn.example/a.jpg',
        'file:///tmp/a.jpg',
        ' https://cdn.example/a.jpg',
      ])
        {
          'code': 0,
          'data': _mangaData(picUrls: [url]),
          'relay': {'protocol': 1},
        },
      {
        'code': 0,
        'data': {'item_id': 'chapter-1', 'encrypt_key': _mangaImageKeyHex},
        'relay': {'protocol': 1},
      },
      http.Response('{}', 502),
    ];

    for (var index = 0; index < invalid.length; index++) {
      final payload = invalid[index];
      final remote = MockClient(
        (_) async => payload is http.Response ? payload : _json(payload),
      );
      var localCalls = 0;
      final local = MockClient((_) async {
        localCalls++;
        return _json({});
      });
      addTearDown(remote.close);
      addTearDown(local.close);
      final api = ApiClient(
        client: local,
        remoteClient: remote,
        sourceRouter: SourceRouter(
          config: const SourceRouterConfig(
            remoteBaseUrl: 'http://127.0.0.1:18922',
            mangaPilotBookIds: {'book-1'},
          ),
        ),
      );
      await expectLater(
        api.remoteComicImages('book-1', 'chapter-1'),
        throwsA(isA<ApiException>()),
        reason: 'invalid case $index',
      );
      expect(localCalls, 0);
    }
  });

  test('remote source policy uses a signed bodyless GET', () async {
    final expiresAt = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300;
    final remoteRequests = <http.Request>[];
    final remote = MockClient((request) async {
      remoteRequests.add(request);
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'schema_version': 1,
            'expires_at': expiresAt,
            'scopes': {
              'novel_full': {
                'backend': 'remote',
                'book_ids': ['book-1'],
              },
              'manga_chapter': {'backend': 'local'},
            },
          }),
        ),
        200,
      );
    });
    final local = MockClient((request) async {
      fail('local core was called: ${request.url}');
    });
    addTearDown(remote.close);
    addTearDown(local.close);
    final api = ApiClient(
      client: local,
      remoteClient: remote,
      sourceRouter: SourceRouter(
        config: const SourceRouterConfig(
          remoteBaseUrl: 'https://source.example.invalid',
          installToken: _testInstallToken,
          installSigningKey: _testInstallSigningKey,
        ),
      ),
    );

    final policy = await api.fetchRemoteSourcePolicy();

    expect(policy.expiresAt, expiresAt);
    expect(
      policy.runtimeConfig.backendFor(SourceRouteScope.novelFull),
      SourceBackend.remote,
    );
    expect(
      policy.runtimeConfig.allowsBook(SourceRouteScope.novelFull, 'book-1'),
      isTrue,
    );
    final request = remoteRequests.single;
    expect(request.method, 'GET');
    expect(request.url.path, '/api/v1/client-policy');
    expect(request.bodyBytes, isEmpty);
    expect(request.url.query, isEmpty);
    final timestamp = request.headers['X-FQ-Timestamp']!;
    final nonce = request.headers['X-FQ-Nonce']!;
    final bodyHash = sha256.convert(request.bodyBytes).toString();
    final canonical =
        'GET\n/api/v1/client-policy\n$timestamp\n$nonce\n$bodyHash';
    final expected = Hmac(
      sha256,
      utf8.encode(_testInstallSigningKey),
    ).convert(utf8.encode(canonical)).toString();
    expect(request.headers['Authorization'], 'Bearer $_testInstallToken');
    expect(request.headers['X-FQ-Signature'], 'v1=$expected');
  });

  for (final stallsBody in [false, true]) {
    test(
      'timeout aborts stalled ${stallsBody ? 'body' : 'headers'} only',
      () async {
        final transport = _AbortAwareClient(stallsBody: stallsBody);
        addTearDown(transport.close);
        final api = ApiClient(
          client: transport,
          timeout: const Duration(milliseconds: 20),
        );

        await expectLater(
          api.detail('stalled'),
          throwsA(isA<TimeoutException>()),
        );
        await transport.aborted.future.timeout(const Duration(seconds: 1));
        expect(await api.search('healthy'), {'code': 200});
      },
    );
  }
}

const _mangaImageKeyHex =
    '404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f';

Map<String, dynamic> _mangaData({
  String itemId = 'chapter-1',
  String key = _mangaImageKeyHex,
  required List<String> picUrls,
}) => {
  'item_id': itemId,
  'encrypt_key': key,
  'pic_infos': [
    for (final url in picUrls) {'pic_url': url},
  ],
};

Map<String, dynamic> _mangaEnvelope({
  String itemId = 'chapter-1',
  List<String> picUrls = const ['https://cdn.example/a.jpg'],
}) => {
  'code': 0,
  'data': _mangaData(itemId: itemId, picUrls: picUrls),
  'relay': {'protocol': 1},
};

http.Response _json(Object? body, {int status = 200}) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status);

class _AbortAwareClient extends http.BaseClient {
  _AbortAwareClient({required this.stallsBody});

  final bool stallsBody;
  final aborted = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (!request.url.path.endsWith('/detail')) {
      return Future.value(
        http.StreamedResponse(Stream.value(utf8.encode('{"code":200}')), 200),
      );
    }
    final pending = Completer<http.StreamedResponse>();
    final body = StreamController<List<int>>();
    if (stallsBody) pending.complete(http.StreamedResponse(body.stream, 200));
    (request as http.AbortableRequest).abortTrigger!.then((_) {
      aborted.complete();
      final error = http.RequestAbortedException(request.url);
      if (stallsBody) {
        body.addError(error);
        body.close().ignore();
      } else {
        pending.completeError(error);
        body.close().ignore();
      }
    });
    return pending.future;
  }
}

const _cmPrimeHex =
    'ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74'
    '020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f14'
    '374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406'
    'b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a1'
    '63bf0598da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356'
    '208552bb9ed529077096966d670c354e4abc9804f1746c08ca237327ffffffff'
    'ffffffff';

final BigInt _cmPrime = BigInt.parse(_cmPrimeHex, radix: 16);

({String key, String content}) _encryptForClient(
  String clientPublicKeyBase64,
  String plaintext,
) {
  final clientKey = _bytesToBigInt(base64.decode(clientPublicKeyBase64));
  final serverPrivate =
      _bytesToBigInt(List<int>.generate(32, (index) => index + 1)) %
      (_cmPrime - BigInt.one);
  final serverPublic = BigInt.two.modPow(serverPrivate, _cmPrime);
  final serverKeyBytes = _bigIntToBytes(serverPublic);
  final shared = clientKey.modPow(serverPrivate, _cmPrime);
  final sharedBytes = _bigIntToBytes(shared);
  if (sharedBytes.length < 32) {
    throw StateError('test shared secret is too short');
  }
  final aesKey = Uint8List.fromList(sharedBytes.sublist(0, 32));
  final iv = Uint8List.fromList(List<int>.generate(16, (index) => index));
  final padded = _padPkcs7(Uint8List.fromList(utf8.encode(plaintext)));
  final ciphertext = _encryptCbc(padded, aesKey, iv);
  final blob = Uint8List(iv.length + ciphertext.length)
    ..setRange(0, iv.length, iv)
    ..setRange(iv.length, iv.length + ciphertext.length, ciphertext);
  return (key: base64.encode(serverKeyBytes), content: base64.encode(blob));
}

BigInt _bytesToBigInt(List<int> bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

Uint8List _bigIntToBytes(BigInt value) {
  if (value == BigInt.zero) return Uint8List(0);
  final length = (value.bitLength + 7) >> 3;
  final bytes = Uint8List(length);
  var remaining = value;
  for (var i = length - 1; i >= 0; i--) {
    bytes[i] = (remaining & BigInt.from(0xff)).toInt();
    remaining >>= 8;
  }
  return bytes;
}

Uint8List _padPkcs7(Uint8List input) {
  final paddingLength = 16 - input.length % 16;
  final padded = Uint8List(input.length + paddingLength);
  padded.setRange(0, input.length, input);
  padded.fillRange(input.length, padded.length, paddingLength);
  return padded;
}

Uint8List _encryptCbc(Uint8List plaintext, Uint8List key, Uint8List iv) {
  final cipher = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(key), iv));
  final ciphertext = Uint8List(plaintext.length);
  for (var offset = 0; offset < plaintext.length; offset += 16) {
    cipher.processBlock(plaintext, offset, ciphertext, offset);
  }
  return ciphertext;
}
