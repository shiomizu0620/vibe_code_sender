import 'package:flutter/material.dart';

import 'pattern_builder.dart';

/// id → Pulse 列を記号で表示し、演奏位置をハイライトするウィジェット。
///
/// [cursor] は「次に打つ」インデックス（0 = 未開始, pulses.length = 完了）。
/// [mistakes] は誤打したインデックスの集合。該当チップを赤で表示する。
///
/// X1（URL直接）は打数が多く縦に長くなるため、スクロール可能な親の中に置かれた
/// 場合は現在位置（[cursor]）が常に見えるよう自動スクロールする。
class ScoreView extends StatefulWidget {
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
  State<ScoreView> createState() => _ScoreViewState();
}

class _ScoreViewState extends State<ScoreView> {
  // 現在位置のチップに付け、cursor 変化時に ensureVisible で追従させる。
  final GlobalKey _currentKey = GlobalKey();

  @override
  void didUpdateWidget(ScoreView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cursor != widget.cursor) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _currentKey.currentContext;
        if (ctx == null) return; // 完了時など現在位置が無い場合は何もしない。
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5, // ビューポート中央に寄せる。
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pulses.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: WrapAlignment.center,
      children: [
        for (var i = 0; i < widget.pulses.length; i++)
          _PulseChip(
            key: i == widget.cursor ? _currentKey : null,
            pulse: widget.pulses[i],
            index: i,
            cursor: widget.cursor,
            isMistake: widget.mistakes.contains(i),
          ),
      ],
    );
  }
}

class _PulseChip extends StatelessWidget {
  const _PulseChip({
    super.key,
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
    final scheme = Theme.of(context).colorScheme;
    final isCurrent = index == cursor;
    final isDone = index < cursor;
    final isMistakeDone = isDone && isMistake;
    final isLong = pulse == Pulse.long;

    // 状態で色を変える: ミス=エラー / 現在=ブランド色 / 完了=淡いブランド色 /
    // これから=薄いグレー。テキスト記号(●/━)をやめ、短=ドット・長=バーの
    // 実譜面風マークにして安っぽさを消す。
    final markColor = isMistakeDone
        ? scheme.error
        : isCurrent
        ? scheme.primary
        : isDone
        ? scheme.primary.withValues(alpha: 0.6)
        : scheme.onSurface.withValues(alpha: 0.18);

    // 現在位置はわずかに拡大＋グロー。短/長で幅は変えるがセルは固定幅にして
    // Wrap が行ごとにガタつかないようにする（自動演奏で顕著なため）。
    final mark = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      // 長は「細長」のイメージ。短(ドット)より薄く・横長にする。
      width: isLong ? 30 : 16,
      height: isLong ? 8 : 16,
      decoration: BoxDecoration(
        color: markColor,
        borderRadius: BorderRadius.circular(isLong ? 4 : 8),
        boxShadow: isCurrent
            ? [
                BoxShadow(
                  color: markColor.withValues(alpha: 0.5),
                  blurRadius: 10,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
    );

    return AnimatedScale(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      scale: isCurrent ? 1.25 : 1.0,
      child: SizedBox(width: 44, height: 34, child: Center(child: mark)),
    );
  }
}
