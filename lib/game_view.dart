import 'dart:math';

import 'package:flutter/material.dart';

import 'constants.dart';
import 'encoder.dart';
import 'pattern_builder.dart';

// ── color palette (matched to receiver oscilloscope) ──────────────────
const _bg = Color(0xFF0B0D16);
const _bg2 = Color(0xFF11141F);
const _neonCyan = Color(0xFF36E3E3);
const _neonAmber = Color(0xFFFFB454);
const _lineColor = Color(0xFF313A55);
const _mutedColor = Color(0xFF838AA6);

// ── timing ────────────────────────────────────────────────────────────
// Preamble duration doubles as note travel time: preamble = visual countdown.
const int _preambleMs = (preambleOnMs + preambleOffMs) * preambleRepeat;
const double _exitMs = 500; // ms a note stays visible past the ring
const int _demoId = 42;

// ── note spec ─────────────────────────────────────────────────────────
class _NoteSpec {
  const _NoteSpec({
    required this.type,
    required this.angle,
    required this.hitMs,
  });
  final Pulse type;
  final double angle; // direction note travels from center (radians)
  final double hitMs; // elapsed ms when note should reach the ring
}

// ── GameView ──────────────────────────────────────────────────────────
class GameView extends StatefulWidget {
  const GameView({super.key, this.pulses});

  /// Pulse list to animate. Defaults to encode(_demoId) until A-G injects real notes.
  final List<Pulse>? pulses;

  @override
  State<GameView> createState() => _GameViewState();
}

class _GameViewState extends State<GameView>
    with SingleTickerProviderStateMixin {
  late final List<Pulse> _pulses;
  late final List<_NoteSpec> _notes;
  late final AnimationController _clock;
  late final double _totalMs;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _pulses = widget.pulses ?? encode(_demoId);
    _notes = _buildSpecs(_pulses);
    _totalMs = _calcTotalMs(_pulses);
    _clock =
        AnimationController(
          vsync: this,
          duration: Duration(milliseconds: _totalMs.toInt()),
        )..addStatusListener((s) {
          if (s == AnimationStatus.completed) {
            setState(() => _playing = false);
          }
        });
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  List<_NoteSpec> _buildSpecs(List<Pulse> pulses) {
    final specs = <_NoteSpec>[];
    double t = _preambleMs.toDouble();
    for (var i = 0; i < pulses.length; i++) {
      // Even angular distribution starting from top, clockwise
      final angle = -pi / 2 + (2 * pi * i / pulses.length);
      specs.add(_NoteSpec(type: pulses[i], angle: angle, hitMs: t));
      t += ((pulses[i] == Pulse.long ? longMs : shortMs) + gapMs).toDouble();
    }
    return specs;
  }

  double _calcTotalMs(List<Pulse> pulses) {
    double t = _preambleMs.toDouble();
    for (final p in pulses) {
      t += ((p == Pulse.long ? longMs : shortMs) + gapMs).toDouble();
    }
    return t + _exitMs;
  }

  void _start() {
    setState(() => _playing = true);
    _clock.forward(from: 0);
  }

  void _stop() {
    _clock.stop();
    _clock.reset();
    setState(() => _playing = false);
  }

  @override
  Widget build(BuildContext context) {
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
            child: Stack(
              children: [
                Positioned.fill(child: CustomPaint(painter: _BgPainter())),
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _clock,
                    builder: (context, _) => CustomPaint(
                      painter: _GamePainter(
                        notes: _notes,
                        elapsedMs: _clock.value * _totalMs,
                        travelMs: _preambleMs.toDouble(),
                      ),
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
          AnimatedBuilder(
            animation: _clock,
            builder: (context, _) => _WaveformBar(
              pulses: _pulses,
              elapsedMs: _clock.value * _totalMs,
              totalMs: _totalMs,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayButton() {
    if (_playing) {
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

// ── Background painter (static; shouldRepaint=false) ──────────────────
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
    required this.elapsedMs,
    required this.travelMs,
  });
  final List<_NoteSpec> notes;
  final double elapsedMs;
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
    for (final note in notes) {
      final spawnMs = note.hitMs - travelMs;
      final endMs = note.hitMs + _exitMs;
      if (elapsedMs < spawnMs || elapsedMs > endMs) continue;

      // ringProgress: 0=center, 1=ring, >1=past ring
      final ringProgress = (elapsedMs - spawnMs) / travelMs;
      final opacity = ringProgress >= 1.0
          ? (1.0 - (ringProgress - 1.0) * travelMs / _exitMs).clamp(0.0, 1.0)
          : 1.0;

      final dist = ringR * ringProgress.clamp(0.0, 1.6);
      final pos = Offset(
        center.dx + cos(note.angle) * dist,
        center.dy + sin(note.angle) * dist,
      );

      if (note.type == Pulse.short) {
        _drawCircleNote(canvas, pos, opacity);
      } else {
        _drawStarNote(canvas, pos, note.angle, ringProgress, opacity);
      }
    }
  }

  // Short note: amber filled circle with glow
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

  // Long note: cyan diamond + trailing tail
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
  bool shouldRepaint(covariant _GamePainter old) => elapsedMs != old.elapsedMs;
}

// ── Bottom waveform guide ─────────────────────────────────────────────
class _WaveformBar extends StatelessWidget {
  const _WaveformBar({
    required this.pulses,
    required this.elapsedMs,
    required this.totalMs,
  });
  final List<Pulse> pulses;
  final double elapsedMs;
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
                pulses: pulses,
                elapsedMs: elapsedMs,
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
    required this.pulses,
    required this.elapsedMs,
    required this.totalMs,
  });
  final List<Pulse> pulses;
  final double elapsedMs;
  final double totalMs;

  @override
  void paint(Canvas canvas, Size size) {
    final pxPerMs = size.width / totalMs;
    final h = size.height;

    // Preamble: two long cyan blocks
    for (var i = 0; i < preambleRepeat; i++) {
      final x = i * (preambleOnMs + preambleOffMs) * pxPerMs;
      final w = preambleOnMs * pxPerMs;
      final onMs = i * (preambleOnMs + preambleOffMs).toDouble();
      _block(
        canvas,
        x,
        w,
        h,
        h,
        _neonCyan,
        isPast: elapsedMs >= onMs + preambleOnMs,
        isActive: elapsedMs >= onMs && elapsedMs < onMs + preambleOnMs,
      );
    }

    // Data notes: short=amber half-height, long=cyan full-height
    double t = _preambleMs.toDouble();
    for (final p in pulses) {
      final pMs = (p == Pulse.long ? longMs : shortMs).toDouble();
      _block(
        canvas,
        t * pxPerMs,
        pMs * pxPerMs,
        h,
        p == Pulse.long ? h : h * 0.55,
        p == Pulse.long ? _neonCyan : _neonAmber,
        isPast: elapsedMs >= t + pMs,
        isActive: elapsedMs >= t && elapsedMs < t + pMs,
      );
      t += pMs + gapMs;
    }

    // Playhead
    final headX = (elapsedMs / totalMs * size.width).clamp(0.0, size.width);
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
    final rect = Rect.fromLTWH(
      x + 1,
      containerH - blockH,
      (w - 2).clamp(1.0, double.infinity),
      blockH,
    );
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
      elapsedMs != old.elapsedMs;
}
