import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/audio_playback_choice.dart';
import '../home/home_design.dart';
import '../home/home_sheet.dart';

/// 更多面板里的「跳过片头 / 跳过片尾」两行。
///
/// 官方 `du`/`dq` 是「跳过片头 / 跳过片尾」，`e8`/`e9`/`e_` 是设置成功的提示，
/// 说明这是**按书**保存的偏好。默认 0 秒（不跳）。
///
/// 秒数改成滑块选：固定档位（0/10/15/20/30）不够用 —— 每本书的片头长短都不
/// 一样，所以 5 秒一档、0~300 秒任意选，0 即关闭；原来的档位保留成快捷按钮。
class AudioSkipPointsRows extends StatelessWidget {
  final AudioSkipPoints points;
  final ValueChanged<AudioSkipPoints> onChanged;

  const AudioSkipPointsRows({
    super.key,
    required this.points,
    required this.onChanged,
  });

  /// 滑块上限与步进（秒）。
  ///
  /// 1 秒一档：片头/片尾长度是逐个作品不同的，5 秒一档经常差那么两三秒。
  /// 滑块旁边还有 −1s / +1s 的微调按钮（300 档滑到精确值太考验手指）。
  static const int maxSeconds = 300;
  static const int stepSeconds = 1;

  /// 上游原本只有这几档，保留成快捷按钮；精确秒数用滑块自己拖。
  static const List<int> quickOptions = <int>[0, 10, 15, 20, 30, 60];

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _row(
          context: context,
          palette: palette,
          key: const Key('audio_skip_intro'),
          sliderKey: const Key('audio_skip_intro_slider'),
          icon: LucideIcons.skip_forward,
          title: '跳过片头',
          unitLabel: '开章跳',
          seconds: points.introSeconds,
          onPicked: (value) => onChanged(
            AudioSkipPoints(
              introSeconds: value,
              outroSeconds: points.outroSeconds,
            ),
          ),
        ),
        _row(
          context: context,
          palette: palette,
          key: const Key('audio_skip_outro'),
          sliderKey: const Key('audio_skip_outro_slider'),
          icon: LucideIcons.skip_back,
          title: '跳过片尾',
          unitLabel: '结尾跳',
          seconds: points.outroSeconds,
          onPicked: (value) => onChanged(
            AudioSkipPoints(
              introSeconds: points.introSeconds,
              outroSeconds: value,
            ),
          ),
        ),
      ],
    );
  }

  Widget _row({
    required BuildContext context,
    required HomePalette palette,
    required Key key,
    required Key sliderKey,
    required IconData icon,
    required String title,
    required String unitLabel,
    required int seconds,
    required ValueChanged<int> onPicked,
  }) {
    return ListTile(
      key: key,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: palette.ink.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 20, color: palette.ink),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 15,
          color: palette.ink,
        ),
      ),
      subtitle: Text(
        seconds == 0 ? '不跳过' : '$unitLabel $seconds 秒',
        style: TextStyle(fontSize: 12.5, color: palette.muted),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            seconds == 0 ? '关闭' : '$seconds 秒',
            style: TextStyle(fontSize: 13, color: palette.muted),
          ),
          const SizedBox(width: 2),
          Icon(LucideIcons.chevron_right, size: 14, color: palette.muted),
        ],
      ),
      onTap: () => _pick(
        context,
        sliderKey: sliderKey,
        title: title,
        current: seconds,
        onPicked: onPicked,
      ),
    );
  }

  /// 把任意秒数对齐到滑块的一档（[stepSeconds]），并夹在 0~[maxSeconds] 之间。
  static int snap(int seconds) {
    final stepped = (seconds / stepSeconds).round() * stepSeconds;
    return stepped.clamp(0, maxSeconds);
  }

  Future<void> _pick(
    BuildContext context, {
    required Key sliderKey,
    required String title,
    required int current,
    required ValueChanged<int> onPicked,
  }) async {
    var draft = snap(current);
    await showHomeSheet<void>(
      context: context,
      title: title,
      children: [
        StatefulBuilder(
          builder: (context, setSheetState) {
            final palette = HomePalette.of(context);
            final muted = TextStyle(fontSize: 12, color: palette.muted);
            void commit(int value) {
              final next = snap(value);
              setSheetState(() => draft = next);
              onPicked(next);
            }

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text('当前', style: muted),
                    const Spacer(),
                    IconButton(
                      key: const Key('audio_skip_minus'),
                      tooltip: '减 1 秒',
                      visualDensity: VisualDensity.compact,
                      onPressed: draft <= 0 ? null : () => commit(draft - 1),
                      icon: const Icon(LucideIcons.minus, size: 18),
                    ),
                    Text(
                      draft == 0 ? '不跳过' : '$draft 秒',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: palette.accentText,
                      ),
                    ),
                    IconButton(
                      key: const Key('audio_skip_plus'),
                      tooltip: '加 1 秒',
                      visualDensity: VisualDensity.compact,
                      onPressed: draft >= maxSeconds
                          ? null
                          : () => commit(draft + 1),
                      icon: const Icon(LucideIcons.plus, size: 18),
                    ),
                  ],
                ),
                Slider(
                  key: sliderKey,
                  value: draft.toDouble(),
                  min: 0,
                  max: maxSeconds.toDouble(),
                  divisions: maxSeconds ~/ stepSeconds,
                  label: draft == 0 ? '不跳过' : '$draft 秒',
                  onChanged: (value) {
                    final next = snap(value.round());
                    if (next == draft) return;
                    setSheetState(() => draft = next);
                  },
                  // 拖动过程只在本地刷新读数，松手才落库：每格写一次
                  // SharedPreferences 会带着听书页整页重建，手感发涩。
                  onChangeEnd: (value) => commit(value.round()),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('不跳过', style: muted),
                      Text('$maxSeconds 秒', style: muted),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final value in quickOptions)
                      ChoiceChip(
                        label: Text(value == 0 ? '关闭' : '$value 秒'),
                        selected: draft == value,
                        onSelected: (_) => commit(value),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Center(
                  child: TextButton(
                    key: const Key('audio_skip_done'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('完成'),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
