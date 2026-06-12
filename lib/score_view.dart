import 'package:flutter/material.dart';

import 'pattern_builder.dart';

/// id → Pulse 列を記号で表示し、演奏位置をハイライトするウィジェット。
///
/// [cursor] は「次に打つ」インデックス（0 = 未開始, pulses.length = 完了）。
class ScoreView extends StatelessWidget {
  const ScoreView({super.key, required this.pulses, required this.cursor});

  final List<Pulse> pulses;
  final int cursor;

  @override
  Widget build(BuildContext context) {
    if (pulses.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: WrapAlignment.center,
      children: [
        for (var i = 0; i < pulses.length; i++)
          _PulseChip(pulse: pulses[i], index: i, cursor: cursor),
      ],
    );
  }
}

class _PulseChip extends StatelessWidget {
  const _PulseChip({
    required this.pulse,
    required this.index,
    required this.cursor,
  });

  final Pulse pulse;
  final int index;
  final int cursor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCurrent = index == cursor;
    final isDone = index < cursor;

    final symbol = pulse == Pulse.short ? '●' : '━';
    final color = isDone
        ? theme.colorScheme.onSurface.withValues(alpha: 0.3)
        : isCurrent
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isCurrent
            ? theme.colorScheme.primaryContainer
            : Colors.transparent,
        border: Border.all(
          color: isCurrent ? theme.colorScheme.primary : Colors.transparent,
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
