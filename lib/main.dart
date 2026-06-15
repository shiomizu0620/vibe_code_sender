import 'package:flutter/material.dart';

import 'constants.dart';
import 'encoder.dart';
import 'pattern_builder.dart';
import 'score_view.dart';
import 'vibrator_service.dart';

void main() {
  runApp(const VibeCodeApp());
}

class VibeCodeApp extends StatelessWidget {
  const VibeCodeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VibeCode Sender',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const SenderPage(),
    );
  }
}

class SenderPage extends StatefulWidget {
  const SenderPage({super.key});

  @override
  State<SenderPage> createState() => _SenderPageState();
}

enum _Phase { idle, preamble, playing, auto, done }

class _SenderPageState extends State<SenderPage> {
  final VibratorService _vibrator = VibratorService();

  bool? _hasVibrator;

  // デモ用 id。F7 で入力欄に差し替える。
  static const int _demoId = 42;
  late List<Pulse> _pulses;
  int _cursor = 0;
  _Phase _phase = _Phase.idle;

  @override
  void initState() {
    super.initState();
    _pulses = encode(_demoId);
    _checkVibrator();
  }

  Future<void> _checkVibrator() async {
    final available = await _vibrator.hasVibrator();
    if (!mounted) return;
    setState(() => _hasVibrator = available);
  }

  Future<void> _startPlaying() async {
    setState(() => _phase = _Phase.preamble);
    _vibrator.play(buildPreamble()); // fire-and-forget（プリアンブルは待機不要）
    await Future.delayed(
      const Duration(
        milliseconds: (preambleOnMs + preambleOffMs) * preambleRepeat,
      ),
    );
    if (!mounted || _phase != _Phase.preamble) return;
    setState(() => _phase = _Phase.playing);
  }

  /// 自動演奏（F6）。プリアンブル込みのフル信号を機械精度で一括再生する。
  ///
  /// 振動本体は [buildSignal]（プリアンブル + 全 [_pulses]）を [VibratorService.play]
  /// に一度渡すだけで完結する。以降の待機は楽譜カーソルを実再生に追従させる
  /// ための視覚演出であり、振動のタイミングには影響しない。
  Future<void> _playAuto() async {
    setState(() {
      _cursor = 0;
      _phase = _Phase.auto;
    });

    // フル信号の再生開始。完了待ちはしない（カーソルは下の delay で駆動）が、
    // 例外で done に進むと不整合になるので、即 catchError を付けて未処理エラーを
    // 防ぎつつ失敗を記録する（再生中のリセット/アンマウントで早期 return しても
    // この Future にハンドラが付いているため未処理にならない）。
    var playbackFailed = false;
    final playback = _vibrator.play(buildSignal(_pulses)).catchError((
      Object _,
    ) {
      playbackFailed = true;
    });

    // プリアンブル送出ぶんを待ってからカーソルを進め始める。
    const preambleMs = (preambleOnMs + preambleOffMs) * preambleRepeat;
    await Future.delayed(const Duration(milliseconds: preambleMs));
    for (var i = 0; i < _pulses.length; i++) {
      final onMs = _pulses[i] == Pulse.long ? longMs : shortMs;
      await Future.delayed(Duration(milliseconds: onMs));
      if (!mounted || _phase != _Phase.auto) return;
      setState(() => _cursor = i + 1);
      if (i < _pulses.length - 1) {
        await Future.delayed(const Duration(milliseconds: gapMs));
      }
    }

    // 再生の最終結果を確定させてから状態遷移する（catchError 済みなので throw しない）。
    await playback;
    if (!mounted || _phase != _Phase.auto) return;
    setState(() => _phase = playbackFailed ? _Phase.idle : _Phase.done);
  }

  void _playShort() {
    _vibrator.play(<int>[0, shortMs]);
    _advance();
  }

  void _playLong() {
    _vibrator.play(<int>[0, longMs]);
    _advance();
  }

  void _advance() {
    if (_cursor >= _pulses.length) return;
    final next = _cursor + 1;
    setState(() {
      _cursor = next;
      if (next >= _pulses.length) _phase = _Phase.done;
    });
  }

  void _reset() => setState(() {
    _cursor = 0;
    _phase = _Phase.idle;
  });

  @override
  Widget build(BuildContext context) {
    final hasVibrator = _hasVibrator;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('VibeCode Sender'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (hasVibrator == false)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text(
                    'この端末は振動に対応していません。\n'
                    '（エミュレータ／シミュレータでは物理的な振動は出ません）',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.redAccent),
                  ),
                ),
              Text(
                'id: $_demoId',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              ScoreView(pulses: _pulses, cursor: _cursor),
              const SizedBox(height: 8),
              _StatusLine(
                phase: _phase,
                cursor: _cursor,
                total: _pulses.length,
              ),
              const SizedBox(height: 32),
              _buildButtons(context),
              const SizedBox(height: 16),
              TextButton(onPressed: _reset, child: const Text('リセット')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildButtons(BuildContext context) {
    return switch (_phase) {
      _Phase.idle => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ElevatedButton.icon(
            onPressed: _startPlaying,
            icon: const Icon(Icons.play_arrow),
            label: const Text('演奏開始'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _playAuto,
            icon: const Icon(Icons.smart_toy),
            label: const Text('自動演奏'),
          ),
        ],
      ),
      _Phase.preamble => ElevatedButton.icon(
        onPressed: null,
        icon: const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: const Text('プリアンブル送出中...'),
      ),
      _Phase.playing => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ElevatedButton(onPressed: _playShort, child: const Text('● 短')),
          const SizedBox(width: 16),
          ElevatedButton(onPressed: _playLong, child: const Text('━ 長')),
        ],
      ),
      _Phase.auto => ElevatedButton.icon(
        onPressed: null,
        icon: const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: const Text('自動演奏中...'),
      ),
      _Phase.done => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ElevatedButton(onPressed: null, child: const Text('● 短')),
          const SizedBox(width: 16),
          ElevatedButton(onPressed: null, child: const Text('━ 長')),
        ],
      ),
    };
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.phase,
    required this.cursor,
    required this.total,
  });

  final _Phase phase;
  final int cursor;
  final int total;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: switch (phase) {
        _Phase.idle => const Text(
          'プリアンブルを送出してから演奏を始めます',
          key: ValueKey('idle'),
        ),
        _Phase.preamble => const SizedBox(key: ValueKey('preamble')),
        _Phase.playing => Text(
          '$cursor / $total 打',
          key: const ValueKey('playing'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        _Phase.auto => Text(
          '自動演奏中  $cursor / $total 打',
          key: const ValueKey('auto'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        _Phase.done => Text(
          '演奏完了！',
          key: const ValueKey('done'),
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
      },
    );
  }
}
