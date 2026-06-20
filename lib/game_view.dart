import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'constants.dart';
import 'game_logic.dart';
import 'vibrator_service.dart';

// ── color palette ─────────────────────────────────────────────────────
const _bg = Color(0xFF0B0D16);
const _bg2 = Color(0xFF11141F);
const _neonCyan = Color(0xFF36E3E3);
const _neonAmber = Color(0xFFFFB454);
const _neonGold = Color(0xFFFFD700);
const _lineColor = Color(0xFF313A55);
const _mutedColor = Color(0xFF838AA6);

// ── timing ────────────────────────────────────────────────────────────
// Travel time = preamble duration: preamble IS the visual countdown.
// Note spawns at center when displayMs == note.hitTimeMs,
// reaches ring when displayMs == note.hitTimeMs + _travelMs.
const int _travelMs = (preambleOnMs + preambleOffMs) * preambleRepeat; // 1800
const double _exitMs = 500;
const int _demoId = 42;
const int _effectDurationMs = 600; // judgment popup lifetime (ms)

// ── Judgment popup data ───────────────────────────────────────────────
class _JudgmentEffect {
  _JudgmentEffect({
    required this.judgement,
    required this.angle,
    required this.startMs,
  });

  final Judgement judgement;
  final double angle; // note angle on ring (radians)
  final int startMs; // displayMs when triggered
}

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
  final List<_JudgmentEffect> _effects = [];
  int _combo = 0;

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
      // _displayMs is intentionally NOT reset here so the waveform stays at
      // the end position until the user presses play again. Ticker.start()
      // always resets elapsed to zero, so _displayMs will be overwritten.
      setState(() => _started = false);
    }
  }

  void _onTick(Duration elapsed) {
    final ms = elapsed.inMilliseconds;
    _effects.removeWhere((e) => ms - e.startMs > _effectDurationMs);
    setState(() => _displayMs = ms);
    final gameMs = _displayMs - _travelMs;
    if (gameMs >= 0) _gc.tick(gameMs);
  }

  void _start() {
    _gc.reset(); // ensure clean slate for replay
    _gc.start();
    _ticker.start();
    setState(() {
      _started = true;
      _combo = 0;
      _effects.clear();
    });
  }

  void _stop() {
    _ticker.stop();
    _gc.reset();
    setState(() {
      _started = false;
      _displayMs = 0;
      _combo = 0;
      _effects.clear();
    });
  }

  // Any touch on the game area = input down.
  // GameController judges against the current cursor note and fires vibration.
  void _onTapDown(TapDownDetails _) {
    if (!_started || _gc.state != GameState.playing) return;
    final gameMs = _displayMs - _travelMs;
    if (gameMs < 0) return; // ignore taps during visual countdown
    final cursor = _gc.cursor;
    if (cursor >= _gc.notes.length) return;
    final j = _gc.onInputDown(gameMs);
    if (j == null) return;
    _effects.add(
      _JudgmentEffect(
        judgement: j,
        angle: _gc.notes[cursor].angle,
        startMs: _displayMs,
      ),
    );
    if (j != Judgement.miss) {
      _combo++;
    } else {
      _combo = 0;
    }
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
                        effects: List.unmodifiable(_effects),
                        displayMs: _displayMs.toDouble(),
                        travelMs: _travelMs.toDouble(),
                      ),
                    ),
                  ),
                  // Combo HUD — shown from first hit, cleared on miss or restart
                  if (_combo >= 1)
                    Positioned(
                      top: 20,
                      left: 0,
                      right: 0,
                      child: IgnorePointer(
                        child: Center(child: _buildComboDisplay()),
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

  Widget _buildComboDisplay() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$_combo',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 52,
            fontWeight: FontWeight.bold,
            letterSpacing: -2,
            shadows: [Shadow(color: _neonCyan, blurRadius: 16)],
          ),
        ),
        const Text(
          'COMBO',
          style: TextStyle(
            color: _neonCyan,
            fontSize: 10,
            letterSpacing: 5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
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

// ── Game painter: ring + flying notes + judgment effects ──────────────
class _GamePainter extends CustomPainter {
  _GamePainter({
    required this.notes,
    required this.results,
    required this.effects,
    required this.displayMs,
    required this.travelMs,
  });

  final List<Note> notes;
  final Map<int, Judgement> results;
  final List<_JudgmentEffect> effects;
  final double displayMs;
  final double travelMs;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final ringR = min(size.width, size.height) * 0.38;
    _drawRing(canvas, center, ringR);
    _drawNoteGuides(canvas, center, ringR);
    _drawNotes(canvas, center, ringR);
    _drawJudgmentEffects(canvas, center, ringR);
  }

  // Continuous ring with 8 blurry glow blobs at each possible note position.
  // The ring line itself is unbroken; only the glow intensity varies per slot.
  void _drawRing(Canvas canvas, Offset center, double r) {
    final rect = Rect.fromCircle(center: center, radius: r);
    final slotProgress = _computeSlotProgress();
    // arcHalf = half slot width (22.5°); heavy blur blends edges into the
    // continuous ring so there is no dotted / segmented appearance.
    const arcHalf = pi / 8;

    // Ambient full-circle base glow
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 24
        ..color = _neonCyan.withAlpha(10)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );

    // 8 blurry blobs — always faintly mark each position, flare on approach
    for (var k = 0; k < 8; k++) {
      final ca = 2 * pi * k / 8;
      final p = slotProgress[k];
      canvas.drawArc(
        rect,
        ca - arcHalf,
        arcHalf * 2,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 28
          ..color = _neonCyan.withAlpha((22 + p * 110).toInt())
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
    }

    // Crisp continuous ring line drawn last so it stays sharp on top
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = _neonCyan.withAlpha(65),
    );

    // Inner guide ring
    canvas.drawCircle(
      center,
      r * 0.82,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _lineColor,
    );
  }

  // Returns a list of 8 values in [0,1]: max ringProgress of any in-flight
  // note targeting each slot (0 = idle, 1 = just reached ring).
  List<double> _computeSlotProgress() {
    final progress = List<double>.filled(8, 0.0);
    if (travelMs <= 0) return progress;
    for (var i = 0; i < notes.length; i++) {
      final j = results[i];
      if (j != null && j != Judgement.miss) continue;
      final spawnMs = notes[i].hitTimeMs.toDouble();
      if (displayMs < spawnMs) continue;
      final rp = (displayMs - spawnMs) / travelMs;
      if (rp <= 0 || rp >= 1.0) continue;
      // angle = 2π·pos/8  →  slot = round(angle·4/π) % 8
      final slot = ((notes[i].angle * 4 / pi).round() % 8 + 8) % 8;
      if (rp > progress[slot]) progress[slot] = rp;
    }
    return progress;
  }

  // Semi-transparent ring markers showing where in-flight notes will land.
  // Drawn before notes so the flying note renders on top of its own guide.
  void _drawNoteGuides(Canvas canvas, Offset center, double ringR) {
    if (travelMs <= 0) return;
    for (var i = 0; i < notes.length; i++) {
      final note = notes[i];
      final j = results[i];
      if (j != null && j != Judgement.miss) continue;

      final spawnMs = note.hitTimeMs.toDouble();
      if (displayMs < spawnMs) continue;
      final ringProgress = (displayMs - spawnMs) / travelMs;
      if (ringProgress >= 1.0) continue; // already at / past ring

      // Base 15 % opacity, rises to 55 % as the note nears the ring
      final alpha = ((0.15 + ringProgress * 0.40) * 255).toInt();
      final guidePos = Offset(
        center.dx + cos(note.angle) * ringR,
        center.dy + sin(note.angle) * ringR,
      );

      if (note.type == NoteType.tap) {
        canvas.drawCircle(
          guidePos,
          18,
          Paint()
            ..color = _neonAmber.withAlpha(alpha)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5,
        );
      } else {
        canvas.drawPath(
          _diamondPath(guidePos, 24, 14),
          Paint()
            ..color = _neonCyan.withAlpha(alpha)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5,
        );
      }
    }
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
        _drawStarNote(canvas, center, pos, ringProgress, opacity);
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

  // Long / hold note: glowing slide trail (gradient beam from center) + diamond
  void _drawStarNote(
    Canvas canvas,
    Offset center,
    Offset pos,
    double ringProgress,
    double opacity,
  ) {
    final t = ringProgress.clamp(0.0, 1.0);
    if (t > 0.02) {
      // Outer glow beam — wide, blurry, fades from center to note
      canvas.drawLine(
        center,
        pos,
        Paint()
          ..strokeWidth = 22
          ..strokeCap = StrokeCap.round
          ..shader = ui.Gradient.linear(center, pos, [
            _neonCyan.withAlpha(0),
            _neonCyan.withAlpha((opacity * 55).toInt()),
          ])
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
      // Inner bright beam
      canvas.drawLine(
        center,
        pos,
        Paint()
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round
          ..shader = ui.Gradient.linear(center, pos, [
            _neonCyan.withAlpha(0),
            _neonCyan.withAlpha((opacity * 200).toInt()),
          ]),
      );
    }

    // Glow halo
    canvas.drawCircle(
      pos,
      36,
      Paint()
        ..color = _neonCyan.withAlpha((opacity * 60).toInt())
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );

    // Diamond fill + rim
    final dPath = _diamondPath(pos, 22, 13);
    canvas.drawPath(
      dPath,
      Paint()..color = _neonCyan.withAlpha((opacity * 255).toInt()),
    );
    canvas.drawPath(
      dPath,
      Paint()
        ..color = Colors.white.withAlpha((opacity * 180).toInt())
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  Path _diamondPath(Offset c, double halfH, double halfW) => Path()
    ..moveTo(c.dx, c.dy - halfH)
    ..lineTo(c.dx + halfW, c.dy)
    ..lineTo(c.dx, c.dy + halfH)
    ..lineTo(c.dx - halfW, c.dy)
    ..close();

  // PERFECT / GOOD / MISS text floating up from ring hit point
  void _drawJudgmentEffects(Canvas canvas, Offset center, double ringR) {
    for (final effect in effects) {
      final age = displayMs - effect.startMs;
      if (age < 0 || age > _effectDurationMs) continue;
      final t = age / _effectDurationMs;
      final opacity = (1.0 - t).clamp(0.0, 1.0);
      final rise = t * 48.0; // floats upward on screen

      final ringPos = Offset(
        center.dx + cos(effect.angle) * ringR,
        center.dy + sin(effect.angle) * ringR,
      );
      final textPos = Offset(ringPos.dx, ringPos.dy - rise);

      String label;
      Color labelColor;
      if (effect.judgement == Judgement.perfect) {
        label = 'PERFECT';
        labelColor = _neonGold;
      } else if (effect.judgement == Judgement.good) {
        label = 'GOOD';
        labelColor = _neonCyan;
      } else {
        label = 'MISS';
        labelColor = _mutedColor;
      }

      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: labelColor.withAlpha((opacity * 255).toInt()),
            fontSize: 13,
            fontWeight: FontWeight.bold,
            letterSpacing: 2.5,
            shadows: [
              Shadow(
                color: labelColor.withAlpha((opacity * 160).toInt()),
                blurRadius: 8,
              ),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      tp.layout();
      tp.paint(canvas, textPos - Offset(tp.width / 2, tp.height / 2));
    }
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
    final rect = Rect.fromLTWH(
      x + 1,
      containerH - blockH,
      max(0.0, w - 2),
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
      gameMs != old.gameMs || results.length != old.results.length;
}
