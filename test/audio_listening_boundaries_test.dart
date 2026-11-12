import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/services/audio_playback_choice.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/desktop_platform.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/native_player.dart';
import 'package:fqapp/services/platform_channel.dart';
import 'package:fqapp/widgets/audio/audio_control_rows.dart';

import 'support/controlled_player.dart';

/// 本 fork 关闭了章末倒计时（`kAdvanceCountdownEnabled = false`）：章末直接
/// 连播，没有「可取消的倒计时窗口」。上游这三组用例测的就是那个窗口，关闭
/// 状态下跳过；将来若把倒计时打开，它们会自动回归。
bool get _noCountdownSkip => !kAdvanceCountdownEnabled;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    ListeningSession.instance.clear();
  });

  for (final autoAdvance in [false, true]) {
    testWidgets(
      'completion leaves the listening session paused with autoAdvance=$autoAdvance',
      (tester) async {
        final player = _NativeEndingPlayer();
        await _mount(
          tester,
          player: player,
          startIndex: autoAdvance ? 1 : 0,
          autoAdvance: autoAdvance,
        );
        expect(ListeningSession.instance.playing, isTrue);
        player.endPlayback();
        await _flush(tester);
        expect(player.isPlaying, isFalse);
        expect(ListeningSession.instance.playing, isFalse);
        // autoAdvance=true 时从末章起播：官方 `v7` 对末章给的是书末提示，
        // 其余情况才是「本章已播完」。
        expect(
          find.text(autoAdvance ? '已播完最新章节，去听听其它内容吧' : '本章已播完'),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets(
    'automatic next does not publish playback while its source waits',
    (tester) async {
      final player = _NativeEndingPlayer();
      final next = Completer<AudioSource>();
      addTearDown(() {
        if (!next.isCompleted) next.complete(_source('2'));
      });
      await _mount(tester, player: player, nextSource: next.future);
      expect(
        ListeningSession.instance.matches('boundary-book', '1'),
        isTrue,
        reason:
            '${player.calls}; '
            '${ListeningSession.instance.bookId}/'
            '${ListeningSession.instance.chapterId}/'
            '${ListeningSession.instance.playing}',
      );
      player.endPlayback();
      await _flush(tester);
      // 连播倒计时窗口内仍是本章：会话不发布、播放器也还没释放。
      expect(ListeningSession.instance.playing, isFalse);
      await tester.pump(const Duration(seconds: 3));
      await _flush(tester);
      expect(player.disposed, isTrue);
      expect(ListeningSession.instance.playing, isFalse);
      next.complete(_source('2'));
      await _flush(tester);
      expect(ListeningSession.instance.matches('boundary-book', '2'), isTrue);
    },
  );

  testWidgets('stopping near the end does not synthesize completion', (
    tester,
  ) async {
    final player = _NativeEndingPlayer();
    await _mount(tester, player: player);
    player.emitDuration(const Duration(seconds: 554));
    player.emitPosition(const Duration(seconds: 553));
    player.isPlaying = false;
    player.playingEvents.add(false);
    await _flush(tester);
    await tester.pump(const Duration(seconds: 5));
    await _flush(tester);
    expect(player.disposed, isFalse);
    expect(find.byKey(const Key('audio_advance_banner')), findsNothing);
    expect(find.text('播放出错，请稍后重试'), findsNothing);
    expect(ListeningSession.instance.chapterId, '1');
    expect(ListeningSession.instance.playing, isFalse);
    expect(ListeningSession.instance.completed, isFalse);
  });

  for (final completed in [false, true]) {
    testWidgets(
      'native error at chapter end rolls on to the next chapter (completed=$completed)',
      (tester) async {
        final player = _NativeEndingPlayer();
        final requests = <String>[];
        await _mount(tester, player: player, sourceRequests: requests);
        player.emitDuration(const Duration(seconds: 554));
        player.emitPosition(const Duration(seconds: 553));
        if (completed) player.endPlayback();
        await _flush(tester);
        // completed=true 时旧播放器已经释放（连播会重建），错误流已 close，
        // 真实场景也不会在 STATE_ENDED 之后再报错——只有没播完的那支造错误。
        if (!completed) {
          player.errors.add(
            const NativePlaybackException('Playback failed', errorCode: 2001),
          );
          await _flush(tester);
        }
        await tester.pump(const Duration(seconds: 5));
        await _flush(tester);
        // 本 fork 的定制：章末几秒内的失败按「本章播完」处理，不弹错误，直接
        // 续播下一集（见 lib/services/audio_playback_advance.dart）。
        expect(find.text('播放出错，请稍后重试'), findsNothing);
        expect(requests, contains('2'));
        expect(ListeningSession.instance.chapterId, '2');
      },
    );
  }

  for (final action in ['pause', 'noisy', 'replay']) {
    testWidgets('$action cancels a pending chapter advance', (tester) async {
      final player = _NativeEndingPlayer();
      await _mount(tester, player: player);
      player.endPlayback();
      await _flush(tester);
      expect(find.byKey(const Key('audio_advance_banner')), findsOneWidget);
      switch (action) {
        case 'pause':
          await PlatformChannels.notify(
            'fqapp/native_player',
            'onNotificationAction',
            'pause',
          );
        case 'noisy':
          await PlatformChannels.notify(
            'fqapp/native_player',
            'onAudioBecomingNoisy',
          );
        case 'replay':
          await tester.tap(find.byTooltip('播放'));
      }
      await _flush(tester);
      expect(find.byKey(const Key('audio_advance_banner')), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await _flush(tester);
      expect(player.disposed, isFalse);
      expect(player.isPlaying, action == 'replay');
      expect(ListeningSession.instance.bookId, 'boundary-book');
      expect(ListeningSession.instance.chapterId, '1');
      expect(ListeningSession.instance.playing, action == 'replay');
    }, skip: _noCountdownSkip);
  }

  for (final action in ['seek', 'back15', 'forward15']) {
    testWidgets('$action cancels a pending chapter advance', (tester) async {
      final player = _NativeEndingPlayer();
      final requests = <String>[];
      await _mount(tester, player: player, sourceRequests: requests);
      player.emitDuration(const Duration(minutes: 1));
      player.endPlayback();
      await _flush(tester);
      expect(find.byKey(const Key('audio_advance_banner')), findsOneWidget);
      final row = tester.widget<AudioTimeSeekRow>(
        find.byType(AudioTimeSeekRow),
      );
      switch (action) {
        case 'seek':
          row.onChangeEnd!(30000);
        case 'back15':
          row.onBack15!();
        case 'forward15':
          row.onForward15!();
      }
      await _flush(tester);
      expect(find.byKey(const Key('audio_advance_banner')), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await _flush(tester);
      expect(player.disposed, isFalse);
      expect(requests, ['1']);
      expect(ListeningSession.instance.chapterId, '1');
    }, skip: _noCountdownSkip);
  }

  testWidgets('seek preview cancels chapter advance before release', (
    tester,
  ) async {
    final player = _NativeEndingPlayer();
    final requests = <String>[];
    await _mount(tester, player: player, sourceRequests: requests);
    player.emitDuration(const Duration(minutes: 1));
    player.endPlayback();
    await _flush(tester);
    final row = tester.widget<AudioTimeSeekRow>(find.byType(AudioTimeSeekRow));
    row.onChanged!(30000);
    await _flush(tester);
    expect(find.byKey(const Key('audio_advance_banner')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await _flush(tester);
    row.onChangeEnd!(30000);
    await _flush(tester);
    expect(player.disposed, isFalse);
    expect(requests, ['1']);
    expect(ListeningSession.instance.chapterId, '1');
  }, skip: _noCountdownSkip);

  for (final background in [false, true]) {
    testWidgets('chapter advance respects background playback=$background', (
      tester,
    ) async {
      await AudioPreferences.instance.setBackgroundPlayback(background);
      final player = _NativeEndingPlayer();
      final requests = <String>[];
      await _mount(tester, player: player, sourceRequests: requests);
      // 先退到后台再播完：本 fork 没有倒计时窗口，章末立刻连播，所以「后台
      // 播放关闭时不该继续」必须在连播入口就判掉（上游是在倒计时里取消）。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await _flush(tester);
      player.endPlayback();
      await _flush(tester);
      await tester.pump(const Duration(seconds: 5));
      await _flush(tester);
      expect(requests, background ? ['1', '2'] : ['1']);
      expect(ListeningSession.instance.chapterId, background ? '2' : '1');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flush(tester);
      expect(find.byKey(const Key('audio_advance_banner')), findsNothing);
    });
  }

  testWidgets('Linux lock and suspend preserve the pending playback resume', (
    tester,
  ) async {
    final session = DesktopSystemSession.instance;
    addTearDown(() {
      session.accept({'type': 'locked', 'value': false});
      session.accept({'type': 'suspend', 'value': false});
    });
    final player = _NativeEndingPlayer();
    final requests = <String>[];
    await _mount(
      tester,
      player: player,
      sourceRequests: requests,
      surfaceSize: const Size(1000, 800),
    );
    await AudioPreferences.instance.setBackgroundPlayback(false);
    expect(player.isPlaying, isTrue);
    session.accept({'type': 'locked', 'value': true});
    await _flush(tester);
    expect(player.isPlaying, isFalse);
    session.accept({'type': 'suspend', 'value': true});
    await _flush(tester);
    expect(player.isPlaying, isFalse);
    session.accept({'type': 'suspend', 'value': false});
    await _flush(tester);
    expect(player.isPlaying, isFalse);
    session.accept({'type': 'locked', 'value': false});
    await _flush(tester);
    expect(player.isPlaying, isTrue);
    expect(player.disposed, isFalse);
    expect(requests, ['1']);
  }, variant: TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('closing right after the chapter advance releases the player', (
    tester,
  ) async {
    final player = _NativeEndingPlayer();
    await _mount(tester, player: player);
    player.endPlayback();
    await _flush(tester);
    // 本 fork 无倒计时：章末立刻开下一章，界面上不再有 `audio_advance_banner`。
    expect(find.byKey(const Key('audio_advance_banner')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    expect(player.disposed, isTrue);
  });

  testWidgets('next source failure retries then reports the attempt count', (
    tester,
  ) async {
    final player = _NativeEndingPlayer();
    final next = Completer<AudioSource>();
    final requests = <String>[];
    await _mount(
      tester,
      player: player,
      nextSource: next.future,
      sourceRequests: requests,
    );
    player.endPlayback();
    await _flush(tester);
    next.completeError(StateError('next chapter source unavailable'));
    await _flush(tester);
    // 自动连播失败：丢缓存换地址重试 3 次（间隔 1.5s），用尽才把失败文案
    // 留在界面上，并带上重试次数（见 lib/services/audio_playback_advance.dart）。
    await tester.pump(const Duration(seconds: 6));
    await _flush(tester);
    expect(find.textContaining('已自动重试'), findsOneWidget);
    expect(ListeningSession.instance.playing, isFalse);
    expect(requests.where((id) => id == '2').length, greaterThan(1));
  });

  testWidgets('听完本章 prevents automatic next at the sleep boundary', (
    tester,
  ) async {
    final player = _NativeEndingPlayer();
    await _mount(tester, player: player);
    await tester.tap(find.byKey(const Key('audio_sleep')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('听完本章'));
    await tester.pumpAndSettle();
    player.endPlayback();
    await _flush(tester);
    await tester.pump(const Duration(seconds: 5));
    await _flush(tester);
    expect(player.disposed, isFalse);
    expect(player.isPlaying, isFalse);
    expect(find.byKey(const Key('audio_advance_banner')), findsNothing);
    expect(ListeningSession.instance.bookId, 'boundary-book');
    expect(ListeningSession.instance.chapterId, '1');
    expect(ListeningSession.instance.playing, isFalse);
  });

  testWidgets('15 分钟后 stops playback at the deadline', (tester) async {
    final player = _NativeEndingPlayer();
    await _mount(tester, player: player);
    await tester.tap(find.byKey(const Key('audio_sleep')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15 分钟后'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 14, seconds: 59));
    player.endPlayback();
    await _flush(tester);
    await tester.pump(const Duration(seconds: 5));
    await _flush(tester);
    // 本 fork 没有倒计时窗口：章末会立刻连播下一集，睡眠定时在 1 秒后到点
    // 再把它停住。断言的是「到点即停」，不再要求仍停在第一章。
    expect(ListeningSession.instance.playing, isFalse);
    expect(player.isPlaying, isFalse);
    expect(find.byKey(const Key('audio_advance_banner')), findsNothing);
  });
}

Future<void> _mount(
  WidgetTester tester, {
  required ControlledNativePlayer player,
  int startIndex = 0,
  bool autoAdvance = true,
  Future<AudioSource>? nextSource,
  List<String>? sourceRequests,
  Size surfaceSize = const Size(430, 932),
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  var created = 0;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    MaterialApp(
      home: AudioPage(
        bookId: 'boundary-book',
        title: '播放边界',
        chapters: [
          Chapter(itemId: '1', title: '第一章', volumeName: ''),
          Chapter(itemId: '2', title: '第二章', volumeName: ''),
        ],
        startIndex: startIndex,
        historyStore: ControlledReaderStore(
          entry: {
            'id': 'boundary-book',
            'kind': 'audio',
            'chapterId': '${startIndex + 1}',
            'autoAdvance': autoAdvance,
          },
        ),
        playerFactory: () => created++ == 0 ? player : ControlledNativePlayer(),
        voicesLoader: () async => const [AudioVoice(id: '0', label: '默认音色')],
        sourceLoader: (itemId, {toneId}) {
          sourceRequests?.add(itemId);
          return itemId == '2' && nextSource != null
              ? nextSource
              : Future.value(_source(itemId));
        },
      ),
    ),
  );
  await _flush(tester);
}

AudioSource _source(String itemId) => AudioSource(
  itemId: itemId,
  url: 'https://cdn.example/$itemId.m4a',
  toneId: '0',
);

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

class _NativeEndingPlayer extends ControlledNativePlayer {
  void endPlayback() {
    // Media3 can report isPlaying=false before STATE_ENDED. Its subsequent
    // pause acknowledgement does not produce another onIsPlayingChanged.
    isPlaying = false;
    playingEvents.add(false);
    emitCompleted();
  }

  @override
  Future<void> pause() async {
    if (disposed) return;
    calls.add('pause');
    playbackRequested = false;
    playWhenReadyEvents.add(false);
    if (isPlaying) {
      isPlaying = false;
      playingEvents.add(false);
    }
  }
}
