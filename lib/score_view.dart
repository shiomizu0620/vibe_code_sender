import 'package:flutter/material.dart';

import 'pattern_builder.dart';

/// id → Pulse 列を記号で表示し、演奏位置をハイライトするウィジェット。
///
/// [cursor] は「次に打つ」インデックス（0 = 未開始, pulses.length = 完了）。
/// [mistakes] は誤打したインデックスの集合。該当チップを赤で表示する。
class ScoreView extends StatelessWidget {
  const ScoreView({
    super.key,
    required this.pulses,
    required this.cursor,
    this.mistakes = const {},
  });

  final List<Pulse> pulses;
  final int cursor;
  final Set<int> mistakes;

  @override
  Widget build(BuildContext context) {
    if (pulses.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: WrapAlignment.center,
      children: [
        for (var i = 0; i < pulses.length; i++)
          _PulseChip(
            pulse: pulses[i],
            index: i,
            cursor: cursor,
            isMistake: mistakes.contains(i),
          ),
      ],
    );
  }
}

class _PulseChip extends StatelessWidget {
  const _PulseChip({
    required this.pulse,
    required this.index,
    required this.cursor,
    required this.isMistake,
  });

  final Pulse pulse;
  final int index;
  final int cursor;
  final bool isMistake;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCurrent = index == cursor;
    final isDone = index < cursor;

    final symbol = pulse == Pulse.short ? '●' : '━';
    final color = isDone
        ? isMistake
              ? theme.colorScheme.error
              : theme.colorScheme.onSurface.withValues(alpha: 0.3)
        : isCurrent
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface;

    final isMistakeDone = isDone && isMistake;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      // 固定サイズ＋中央寄せにする。現在位置の太字化や記号(●/━)の幅差で
      // チップ幅が変わると Wrap が行ごとにガタつく（自動演奏で顕著）ため、
      // サイズを固定してレイアウトを安定させる。
      width: 48,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isCurrent
            ? theme.colorScheme.primaryContainer
            : isMistakeDone
            ? theme.colorScheme.errorContainer
            : Colors.transparent,
        border: Border.all(
          color: isCurrent
              ? theme.colorScheme.primary
              : isMistakeDone
              ? theme.colorScheme.error
              : Colors.transparent,
          width: 2,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        symbol,
        style: TextStyle(
          fontSize: 32,
          color: color,
          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }
}
