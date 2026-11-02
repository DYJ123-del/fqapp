import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/audio_playback_choice.dart';
import 'package:fqapp/widgets/audio/audio_skip_points_rows.dart';

/// 跳过片头 / 片尾改成滑块后，秒数不再受固定档位限制：
/// 上游原有的 0/10/15/20/30 只是快捷按钮，滑块 5 秒一档拖到 0~300 任意值。
void main() {
  group('AudioSkipPointsRows.snap', () {
    test('对齐到 5 秒一档', () {
      expect(AudioSkipPointsRows.snap(0), 0);
      expect(AudioSkipPointsRows.snap(13), 15);
      expect(AudioSkipPointsRows.snap(12), 10);
      expect(AudioSkipPointsRows.snap(147), 145);
    });

    test('夹在 0~300 之间', () {
      expect(AudioSkipPointsRows.snap(-20), 0);
      expect(AudioSkipPointsRows.snap(9999), AudioSkipPointsRows.maxSeconds);
    });
  });

  Widget mount(AudioSkipPoints points, ValueChanged<AudioSkipPoints> onChanged) {
    return MaterialApp(
      home: Scaffold(
        body: AudioSkipPointsRows(points: points, onChanged: onChanged),
      ),
    );
  }

  testWidgets('点「跳过片头」弹出滑块，默认值就是已存秒数', (tester) async {
    AudioSkipPoints? emitted;
    await tester.pumpWidget(mount(
      const AudioSkipPoints(introSeconds: 25, outroSeconds: 40),
      (value) => emitted = value,
    ));

    await tester.tap(find.byKey(const Key('audio_skip_intro')));
    await tester.pumpAndSettle();

    final slider = tester.widget<Slider>(
      find.byKey(const Key('audio_skip_intro_slider')),
    );
    expect(slider.min, 0);
    expect(slider.max, AudioSkipPointsRows.maxSeconds.toDouble());
    expect(slider.divisions, AudioSkipPointsRows.maxSeconds ~/
        AudioSkipPointsRows.stepSeconds);
    expect(slider.value, 25);
    // 打开面板本身不写库，避免没动过就产生一次写入。
    expect(emitted, isNull);
  });

  testWidgets('拖动滑块落库：片头变、片尾保持', (tester) async {
    final emitted = <AudioSkipPoints>[];
    await tester.pumpWidget(mount(
      const AudioSkipPoints(introSeconds: 0, outroSeconds: 40),
      emitted.add,
    ));

    await tester.tap(find.byKey(const Key('audio_skip_intro')));
    await tester.pumpAndSettle();

    final sliderKey = find.byKey(const Key('audio_skip_intro_slider'));
    final rect = tester.getRect(sliderKey);
    // 点在轨道中点：约 150 秒，允许滑块内边距带来的偏差。
    await tester.tapAt(Offset(rect.center.dx, rect.center.dy));
    await tester.pumpAndSettle();

    expect(emitted, isNotEmpty);
    final last = emitted.last;
    expect(last.introSeconds, greaterThan(100));
    expect(last.introSeconds, lessThan(200));
    expect(last.introSeconds % AudioSkipPointsRows.stepSeconds, 0);
    expect(last.outroSeconds, 40);
  });

  testWidgets('快捷档位仍可选，且只改自己那一项', (tester) async {
    AudioSkipPoints? emitted;
    await tester.pumpWidget(mount(
      const AudioSkipPoints(introSeconds: 0, outroSeconds: 40),
      (value) => emitted = value,
    ));

    await tester.tap(find.byKey(const Key('audio_skip_outro')));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, '15 秒'));
    await tester.pumpAndSettle();

    expect(emitted, isNotNull);
    expect(emitted!.outroSeconds, 15);
    expect(emitted!.introSeconds, 0);
  });

  testWidgets('选「关闭」回到不跳过', (tester) async {
    AudioSkipPoints? emitted;
    await tester.pumpWidget(mount(
      const AudioSkipPoints(introSeconds: 30, outroSeconds: 0),
      (value) => emitted = value,
    ));

    await tester.tap(find.byKey(const Key('audio_skip_intro')));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, '关闭'));
    await tester.pumpAndSettle();

    expect(emitted, isNotNull);
    expect(emitted!.introSeconds, 0);
    expect(emitted!.isActive, isFalse);
  });
}
