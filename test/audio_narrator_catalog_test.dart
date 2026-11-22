import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';

import 'support/controlled_player.dart';

/// 「同一部作品有多个真人讲书版本」时，声音面板必须能看到并切到其他主播。
///
/// 背景：`/tones` 是**按当前书**返回的。切到某个主播的 abook 之后，响应里的
/// `audio_tones` 只剩它自己一条 —— 面板于是只有「当前选择的」这一行，其他主播
/// 点不到。修复是记住来源书的完整目录，必要时再向关联原著要一份。
const _novelBook = 'novel-1';
const _narratorA = 'abook-a';
const _narratorB = 'abook-b';
const _novelChapter = 'n1';

AudioExtras _novelExtras() => const AudioExtras(
  tones: AudioToneSet(
    narratorTones: [
      AudioTone(id: _narratorA, title: '主播：甲'),
      AudioTone(id: _narratorB, title: '主播：乙'),
    ],
  ),
);

/// 某个主播版本自己的 `/tones`：`genre_type = 1`，`audio_tones` 只有它自己。
AudioExtras _recordingExtras(String id) => AudioExtras(
  tones: AudioToneSet(
    genreType: 1,
    narratorTones: [AudioTone(id: id, title: id == _narratorA ? '主播：甲' : '主播：乙')],
    relatedNovel: const RelatedWork(
      kind: 'book',
      id: _novelBook,
      title: '原著小说',
    ),
  ),
);

void main() {
  testWidgets('从原著切进某个主播后，面板仍列出全部主播版本', (tester) async {
    final session = _Session(
      bookId: _novelBook,
      adoptPreferredTone: true,
      extras: (bookId) async =>
          bookId == _novelBook ? _novelExtras() : _recordingExtras(bookId),
    );
    await _mount(tester, session);

    // 起播即主播甲的版本（本地定制），不是原著章节。
    expect(session.requests, ['a1:0']);

    await _showVoices(tester);
    expect(find.byKey(const ValueKey('voice_option_$_narratorA')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('voice_option_$_narratorB')),
      findsOneWidget,
      reason: '切到主播甲之后，主播乙也必须还在面板里',
    );

    // 点另一个主播：换到它那本书的目录与章节。
    await tester.tap(find.byKey(const ValueKey('voice_option_$_narratorB')));
    await tester.pumpAndSettle();
    await _flush(tester);
    await tester.pumpAndSettle();
    expect(session.directories, [_narratorA, _narratorB]);
    expect(session.requests.last, 'b1:0');
  });

  testWidgets('直接进有声书时，向关联原著补齐其他主播版本', (tester) async {
    final session = _Session(
      bookId: _narratorA,
      extras: (bookId) async =>
          bookId == _novelBook ? _novelExtras() : _recordingExtras(bookId),
    );
    await _mount(tester, session);
    await _flush(tester);

    await _showVoices(tester);
    expect(find.byKey(const ValueKey('voice_option_$_narratorA')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('voice_option_$_narratorB')),
      findsOneWidget,
      reason: '有声书自己的 /tones 只报自己，其他主播要从关联原著取',
    );
    expect(session.extrasRequests, contains(_novelBook));

    await tester.tap(find.byKey(const ValueKey('voice_option_$_narratorB')));
    await tester.pumpAndSettle();
    await _flush(tester);
    await tester.pumpAndSettle();
    expect(session.requests.last, 'b1:0');
  });

  testWidgets('只有单个主播版本时不额外请求关联原著', (tester) async {
    final session = _Session(
      bookId: _narratorA,
      extras: (bookId) async => AudioExtras(
        tones: AudioToneSet(
          genreType: 1,
          narratorTones: const [AudioTone(id: _narratorA, title: '主播：甲')],
          relatedNovel: const RelatedWork(
            kind: 'book',
            id: _novelBook,
            title: '原著小说',
          ),
        ),
      ),
    );
    await _mount(tester, session);
    await _flush(tester);
    await _showVoices(tester);
    await _flush(tester);

    // 只有一条可切换的版本：补一次原著就够，不能反复请求。
    expect(
      session.extrasRequests.where((id) => id == _novelBook).length,
      lessThanOrEqualTo(1),
    );
    expect(find.byKey(const ValueKey('voice_option_$_narratorA')), findsOneWidget);
  });
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _showVoices(WidgetTester tester) async {
  final picker = find.byKey(const ValueKey('audio-voice'));
  await tester.ensureVisible(picker);
  await tester.tap(picker);
  await tester.pumpAndSettle();
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
  _Session({
    required this.bookId,
    required this.extras,
    this.adoptPreferredTone = false,
  });

  final String bookId;
  final AudioExtrasLoader extras;
  final bool adoptPreferredTone;
  final players = <ControlledNativePlayer>[];
  final directories = <String>[];
  final requests = <String>[];
  final extrasRequests = <String>[];

  List<Chapter> _chaptersFor(String id) {
    if (id == _novelBook) {
      return [Chapter(itemId: _novelChapter, title: '第1章 开端', volumeName: '')];
    }
    final prefix = id == _narratorA ? 'a' : 'b';
    return [
      Chapter(itemId: '${prefix}1', title: '第1集 开端', volumeName: ''),
      Chapter(itemId: '${prefix}2', title: '第2集 继续', volumeName: ''),
    ];
  }

  Widget app() => MaterialApp(
    home: AudioPage(
      bookId: bookId,
      title: '测试有声书',
      chapters: _chaptersFor(bookId),
      historyStore: ControlledReaderStore(),
      voicesLoader: () async => const [],
      extrasLoader: (id) {
        extrasRequests.add(id);
        return extras(id);
      },
      directoryLoader: (id) {
        directories.add(id);
        return Future.value(_chaptersFor(id));
      },
      sourceLoader: (itemId, {toneId}) async {
        requests.add('$itemId:$toneId');
        return AudioSource(
          itemId: itemId,
          url: 'https://example.invalid/$itemId-$toneId.mp3',
          toneId: toneId ?? '0',
        );
      },
      playerFactory: () {
        final player = ControlledNativePlayer();
        players.add(player);
        return player;
      },
      adoptPreferredTone: adoptPreferredTone,
    ),
  );
}
