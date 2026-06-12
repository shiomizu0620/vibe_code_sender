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

class _SenderPageState extends State<SenderPage> {
  final VibratorService _vibrator = VibratorService();

  bool? _hasVibrator;

  // デモ用 id。F7 で入力欄に差し替える。
  static const int _demoId = 42;
  late List<Pulse> _pulses;
  int _cursor = 0;

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

  void _playShort() {
    _vibrator.play(<int>[0, shortMs]);
    _advance();
  }

  void _playLong() {
    _vibrator.play(<int>[0, longMs]);
    _advance();
  }

  void _advance() {
    if (_cursor < _pulses.length) {
      setState(() => _cursor++);
    }
  }

  void _reset() => setState(() => _cursor = 0);

  bool get _isDone => _cursor >= _pulses.length;

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
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _isDone
                    ? Text(
                        '演奏完了！',
                        key: const ValueKey('done'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      )
                    : Text(
                        '$_cursor / ${_pulses.length} 打',
                        key: const ValueKey('progress'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
              ),
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: _isDone ? null : _playShort,
                    child: const Text('● 短'),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton(
                    onPressed: _isDone ? null : _playLong,
                    child: const Text('━ 長'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextButton(onPressed: _reset, child: const Text('リセット')),
            ],
          ),
        ),
      ),
    );
  }
}
