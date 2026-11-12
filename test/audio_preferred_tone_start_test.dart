import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';

import 'support/controlled_player.dart';

/// 「点听书进去就是真人讲书」的起播契约：
///
///  * 报名了的入口（详情页 / 阅读页 / 胶囊）必须在**起播之前**定音色 ——
///    用户明确不要「先按默认 TTS 播几秒再切」（1.0.133 的行为）。
///  * 没报名的入口保持上游的 p09 语义：装饰接口再慢也不得延迟首播，
///    更不能悄悄把书换掉。
void main() {
  const narratorExtras = AudioExtras(
    tones: AudioToneSet(
      narratorTones: [AudioTone(id: 'abook-9', title: '主播：林夕')],
    ),
  );

  List<Chapter> narratorChapters() => [
    Chapter(itemId: 'a1', title: '真人第一章', volumeName: '真人版'),
    Chapter(itemId: 'a2', title: '真人第二章', volumeName: '真人版'),
  ];

  testWidgets('报名入口：第一个播放器就是真人讲书那本书，没有默认 TTS 先播', (tester) async {
    final session = _Session(
      adoptPreferredTone: true,
      extras: (_) async => narratorExtras,
      directory: (bookId) async => bookId == 'abook-9'
          ? narratorChapters()
          : const <Chapter>[],
    );
    await _mount(tester, session);

    // 只起了一个播放器：说明音色/书在起播前就定好了，不存在「先播默认再切」。
    expect(session.players, hasLength(1));
    expect(session.players.single.isPlaying, isTrue);
    // 请求的是真人版本的章，原书章节一次都没请求过。
    expect(session.requests, ['a1:0']);
  });

  testWidgets('未报名入口：装饰接口慢也不推迟首播、不换书', (tester) async {
    final slowExtras = Completer<AudioExtras>();
    final session = _Session(
      extras: (_) => slowExtras.future,
      directory: (bookId) async =>
          bookId == 'abook-9' ? narratorChapters() : const <Chapter>[],
    );
    await _mount(tester, session);

    // /tones 还挂着，首播已经开始了（p09：慢响应不得延迟首播）。
    expect(session.players, hasLength(1));
    expect(session.players.single.isPlaying, isTrue);
    expect(session.requests, ['1:0']);

    // 迟到的音色表不能把没报名的入口切到别的书。
    slowExtras.complete(narratorExtras);
    await _flush(tester);
    expect(session.requests, ['1:0']);
    expect(session.players, hasLength(1));
  });

  testWidgets('报名入口但音色表超时：按默认音色起播，不卡住听书', (tester) async {
    final hungExtras = Completer<AudioExtras>();
    final session = _Session(
      adoptPreferredTone: true,
      extras: (_) => hungExtras.future,
      directory: (bookId) async =>
          bookId == 'abook-9' ? narratorChapters() : const <Chapter>[],
    );
    await _mount(tester, session);

    // 有界等待窗口内还没有播放器。
    expect(session.players, isEmpty);
    await tester.pump(const Duration(seconds: 3));
    await _flush(tester);
    // 超时后用默认音色照常起播。
    expect(session.players, hasLength(1));
    expect(session.requests, ['1:0']);

    // 让后台补选那条路（10s 超时 + 1.2s 观察窗）走完，别留 pending timer。
    await tester.pump(const Duration(seconds: 12));
    await _flush(tester);
  });
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _mount(WidgetTester tester, _Session session) async {
  await tester.binding.setSurfaceSize(const Size(430, 932));
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(session.app());
  await _flush(tester);
}

class _Session {
  final bool adoptPreferredTone;
  final AudioExtrasLoader extras;
  final Future<List<Chapter>> Function(String bookId)? directory;
  final List<Chapter> chapters;
  final players = <ControlledNativePlayer>[];
  final requests = <String>[];

  _Session({
    this.adoptPreferredTone = false,
    required this.extras,
    this.directory,
    List<Chapter>? chapters,
  }) : chapters =
           chapters ??
           [
             for (var index = 1; index <= 3; index++)
               Chapter(itemId: '$index', title: '第$index章', volumeName: '第一卷'),
           ];

  Widget app() => MaterialApp(
    home: AudioPage(
      bookId: 'book',
      title: '测试听书',
      chapters: chapters,
      historyStore: ControlledReaderStore(),
      sourceLoader: (id, {toneId}) {
        requests.add('$id:$toneId');
        return Future.value(
          AudioSource(
            itemId: id,
            url: 'https://example.invalid/$id-${toneId ?? '0'}.mp3',
            toneId: toneId ?? '0',
          ),
        );
      },
      voicesLoader: () async => const [],
      extrasLoader: extras,
      directoryLoader: directory,
      playerFactory: () {
        final player = ControlledNativePlayer();
        players.add(player);
        return player;
      },
      adoptPreferredTone: adoptPreferredTone,
    ),
  );
}
