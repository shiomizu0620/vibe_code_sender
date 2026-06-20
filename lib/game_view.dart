import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'constants.dart';
import 'game_logic.dart';
import 'vibrator_service.dart';

// ── color palette (matched to receiver oscilloscope) ──────────────────
const _bg = Color(0xFF0B0D16);
const _bg2 = Color(0xFF11141F);
const _neonCyan = Color(0xFF36E3E3);
const _neonAmber = Color(0xFFFFB454);
const _lineColor = Color(0xFF313A55);
const _mutedColor = Color(0xFF838AA6);

// ── timing ────────────────────────────────────────────────────────────
// Travel time = preamble duration: preamble IS the visual countdown.
// Note spawns at center when displayMs == note.hitTimeMs,
// reaches ring when displayMs == note.hitTimeMs + _travelMs.
const int _travelMs = (preambleOnMs + preambleOffMs) * preambleRepeat; // 1800
const double _exitMs = 500;
const int _demoId = 42;

// ── GameView ──────────────────────────────────────────────────────────
class GameView extends StatefulWidget {
  const GameView({super.key, this.id = _demoId});

  /// id to encode and animate. Swap for A-G's game controller injection later.
  final int id;

  @override
  State<GameView> createState() => _GameViewState();
}

class _GameViewState extends State<GameView>
    with SingleTickerProviderStateMixin {
  late final VibratorService _vibrator;
  late final GameController _gc;
  late final Ticker _ticker;
  int _displayMs = 0;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _vibrator = VibratorService();
    _gc = GameController(vibrator: _vibrator);
    _gc.load(widget.id);
    _ticker = createTicker(_onTick);
    _gc.addListener(_onControllerChange);
  }

  @override
  void dispose() {
    _gc.removeListener(_onControllerChange);
    _ticker.dispose();
    _gc.dispose();
    super.dispose();
  }

  void _onControllerChange() {
    if (_gc.state == GameState.finished && _started) {
      _ticker.stop();
      setState(() => _started = false);
    }
  }

  void _onTick(Duration elapsed) {
    setState(() => _displayMs = elapsed.inMilliseconds);
    final gameMs = _displayMs - _travelMs;
    if (gameMs >= 0) _gc.tick(gameMs);
  }

  void _start() {
    _gc.start();
    _ticker.start();
    setState(() => _started = true);
  }

  void _stop() {
    _ticker.stop();
    _gc.reset();
    setState(() {
      _started = false;
      _displayMs = 0;
    });
  }

  // Any touch on the game area = input down.
  // GameController judges against the current cursor note and fires vibration.
  void _onTapDown(TapDownDetails _) {
    if (!_started || _gc.state != GameState.playing) return;
    final gameMs = _displayMs - _travelMs;
    if (gameMs < 0) return; // ignore taps during visual countdown
    _gc.onInputDown(gameMs);
  }

  @override
  Widget build(BuildContext context) {
    final gameMs = max(0, _displayMs - _travelMs).toDouble();
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg2,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          'V I B E C O D E',
          style: TextStyle(
            color: _neonCyan,
            letterSpacing: 6,
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: _onTapDown,
              child: Stack(
                children: [
                  Positioned.fill(child: CustomPaint(painter: _BgPainter())),
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _GamePainter(
                        notes: _gc.notes,
                        results: _gc.results,
                        displayMs: _displayMs.toDouble(),
                        travelMs: _travelMs.toDouble(),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 24,
                    left: 0,
                    right: 0,
                    child: Center(child: _buildPlayButton()),
                  ),
                ],
              ),
            ),
          ),
          _WaveformBar(
            notes: _gc.notes,
            results: _gc.results,
            gameMs: gameMs,
            totalMs: (_gc.chartEndMs + _exitMs).clamp(1.0, double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayButton() {
    if (_started) {
      return OutlinedButton.icon(
        onPressed: _stop,
        icon: const Icon(Icons.stop, color: _neonCyan),
        label: const Text('停止', style: TextStyle(color: _neonCyan)),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: _neonCyan),
        ),
      );
    }
    return ElevatedButton.icon(
      onPressed: _start,
      icon: const Icon(Icons.play_arrow),
      label: const Text('演奏開始'),
      style: ElevatedButton.styleFrom(
        backgroundColor: _neonCyan.withAlpha(40),
        foregroundColor: _neonCyan,
        side: const BorderSide(color: _neonCyan),
      ),
    );
  }
}

// ── Background painter (static) ───────────────────────────────────────
class _BgPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0.9, -0.9),
          radius: 1.4,
          colors: [const Color(0xFF36E3E3).withAlpha(20), Colors.transparent],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ── Game painter: ring + flying notes ─────────────────────────────────
class _GamePainter extends CustomPainter {
  _GamePainter({
    required this.notes,
    required this.results,
    required this.displayMs,
    required this.travelMs,
  });
  final List<Note> notes;
  final Map<int, Judgement> results;
  final double displayMs;
  final double travelMs;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final ringR = min(size.width, size.height) * 0.38;
    _drawRing(canvas, center, ringR);
    _drawNotes(canvas, center, ringR);
  }

  void _drawRing(Canvas canvas, Offset center, double r) {
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 28
        ..color = _neonCyan.withAlpha(25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..color = _neonCyan.withAlpha(80)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = _neonCyan,
    );
    canvas.drawCircle(
      center,
      r * 0.82,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _lineColor,
    );
  }

  void _drawNotes(Canvas canvas, Offset center, double ringR) {
    if (travelMs <= 0) return;
    for (var i = 0; i < notes.length; i++) {
      final note = notes[i];

      // Perfect/good hits disappear; misses pass through.
      final j = results[i];
      if (j != null && j != Judgement.miss) continue;

      // displayMs == note.hitTimeMs → spawns at center
      // displayMs == note.hitTimeMs + travelMs → hits ring
      final spawnMs = note.hitTimeMs.toDouble();
      if (displayMs < spawnMs || displayMs > spawnMs + travelMs + _exitMs) {
        continue;
      }

      final ringProgress = (displayMs - spawnMs) / travelMs;
      final opacity = ringProgress >= 1.0
          ? (1.0 - (ringProgress - 1.0) * travelMs / _exitMs).clamp(0.0, 1.0)
          : 1.0;
      final dist = ringR * ringProgress.clamp(0.0, 1.6);
      final pos = Offset(
        center.dx + cos(note.angle) * dist,
        center.dy + sin(note.angle) * dist,
      );

      if (note.type == NoteType.tap) {
        _drawCircleNote(canvas, pos, opacity);
      } else {
        _drawStarNote(canvas, pos, note.angle, ringProgress, opacity);
      }
    }
  }

  // Short / tap note: amber filled circle with glow
  void _drawCircleNote(Canvas canvas, Offset pos, double opacity) {
    canvas.drawCircle(
      pos,
      28,
      Paint()
        ..color = _neonAmber.withAlpha((opacity * 60).toInt())
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    canvas.drawCircle(
      pos,
      16,
      Paint()..color = _neonAmber.withAlpha((opacity * 255).toInt()),
    );
  }

  // Long / hold note: cyan diamond + trailing tail
  void _drawStarNote(
    Canvas canvas,
    Offset pos,
    double angle,
    double ringProgress,
    double opacity,
  ) {
    if (ringProgress > 0.05) {
      final trailLen = min(ringProgress, 1.0) * 72;
      final trailEnd = Offset(
        pos.dx - cos(angle) * trailLen,
        pos.dy - sin(angle) * trailLen,
      );
      canvas.drawLine(
        trailEnd,
        pos,
        Paint()
          ..color = _neonCyan.withAlpha((opacity * 160).toInt())
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.drawCircle(
      pos,
      32,
      Paint()
        ..color = _neonCyan.withAlpha((opacity * 50).toInt())
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    final path = Path()
      ..moveTo(pos.dx, pos.dy - 20)
      ..lineTo(pos.dx + 11, pos.dy)
      ..lineTo(pos.dx, pos.dy + 20)
      ..lineTo(pos.dx - 11, pos.dy)
      ..close();
    canvas.drawPath(
      path,
      Paint()..color = _neonCyan.withAlpha((opacity * 255).toInt()),
    );
  }

  @override
  bool shouldRepaint(covariant _GamePainter old) =>
      displayMs != old.displayMs || results.length != old.results.length;
}

// ── Bottom waveform guide ─────────────────────────────────────────────
class _WaveformBar extends StatelessWidget {
  const _WaveformBar({
    required this.notes,
    required this.results,
    required this.gameMs,
    required this.totalMs,
  });
  final List<Note> notes;
  final Map<int, Judgement> results;
  final double gameMs;
  final double totalMs;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72,
      color: _bg2,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'WAVE  GUIDE',
            style: TextStyle(
              color: _mutedColor,
              fontSize: 9,
              letterSpacing: 3,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: CustomPaint(
              painter: _WaveformPainter(
                notes: notes,
                results: results,
                gameMs: gameMs,
                totalMs: totalMs,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.notes,
    required this.results,
    required this.gameMs,
    required this.totalMs,
  });
  final List<Note> notes;
  final Map<int, Judgement> results;
  final double gameMs;
  final double totalMs;

  @override
  void paint(Canvas canvas, Size size) {
    final pxPerMs = size.width / totalMs;
    final h = size.height;

    for (var i = 0; i < notes.length; i++) {
      final note = notes[i];
      final x = note.hitTimeMs * pxPerMs;
      final w = (note.durationMs * pxPerMs).clamp(1.0, double.infinity);
      final bh = note.type == NoteType.hold ? h : h * 0.55;
      final color = note.type == NoteType.hold ? _neonCyan : _neonAmber;

      final j = results[i];
      final isHit = j != null && j != Judgement.miss;
      final isActive =
          !isHit &&
          gameMs >= note.hitTimeMs &&
          gameMs < note.hitTimeMs + note.durationMs;
      final isPast =
          isHit || (!isActive && gameMs >= note.hitTimeMs + note.durationMs);

      _block(canvas, x, w, h, bh, color, isPast: isPast, isActive: isActive);
    }

    // Playhead
    final headX = (gameMs / totalMs * size.width).clamp(0.0, size.width);
    canvas.drawLine(
      Offset(headX, 0),
      Offset(headX, h),
      Paint()
        ..color = Colors.white.withAlpha(200)
        ..strokeWidth = 1.5,
    );
  }

  void _block(
    Canvas canvas,
    double x,
    double w,
    double containerH,
    double blockH,
    Color color, {
    required bool isPast,
    required bool isActive,
  }) {
    final rect = Rect.fromLTWH(x + 1, containerH - blockH, w - 2, blockH);
    if (!isPast && !isActive) {
      canvas.drawRect(
        rect,
        Paint()
          ..color = color.withAlpha(50)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      return;
    }
    if (isActive) {
      canvas.drawRect(
        rect.inflate(2),
        Paint()
          ..color = color.withAlpha(60)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
    }
    canvas.drawRect(rect, Paint()..color = color.withAlpha(isPast ? 120 : 220));
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) =>
      gameMs != old.gameMs || results.length != old.results.length;
}
