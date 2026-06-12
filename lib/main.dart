import 'package:flutter/material.dart';

import 'constants.dart';
import 'encoder.dart';
import 'pattern_builder.dart';
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

/// マイルストーン1のテスト用画面。
///
/// 短/長の振動を任意の並びで出力できることを確認するための最小UI。
class SenderPage extends StatefulWidget {
  const SenderPage({super.key});

  @override
  State<SenderPage> createState() => _SenderPageState();
}

class _SenderPageState extends State<SenderPage> {
  final VibratorService _vibrator = VibratorService();

  /// 端末が振動可能か。null は確認中。
  bool? _hasVibrator;

  @override
  void initState() {
    super.initState();
    _checkVibrator();
  }

  Future<void> _checkVibrator() async {
    final available = await _vibrator.hasVibrator();
    if (!mounted) return;
    setState(() => _hasVibrator = available);
  }

  /// 「短」を1発（初期待機0 + 短い振動）。
  void _playShort() => _vibrator.play(<int>[0, shortMs]);

  /// 「長」を1発（初期待機0 + 長い振動）。
  void _playLong() => _vibrator.play(<int>[0, longMs]);

  /// サンプル列を再生。encoder → pattern_builder → vibrator の層を通す。
  void _playSample() => _vibrator.play(buildPattern(encode(42)));

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
              ElevatedButton(onPressed: _playShort, child: const Text('短 を1発')),
              const SizedBox(height: 12),
              ElevatedButton(onPressed: _playLong, child: const Text('長 を1発')),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _playSample,
                child: const Text('サンプル列（短・長・短・短）'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
