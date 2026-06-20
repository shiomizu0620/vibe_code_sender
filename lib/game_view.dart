import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'constants.dart';
import 'game_logic.dart';
import 'supabase_service.dart';
import 'vibrator_service.dart';

// ── color palette (ProSeka) ────────────────────────────────────────────
const _bg = Color(0xFF08001A);
const _neonCyan = Color(0xFF36E3E3);
const _neonAmber = Color(0xFFFFB454);
const _neonGold = Color(0xFFFFD700);
const _neonPurple = Color(0xFFAA6EFF);
const _lineColor = Color(0xFF281545);
const _mutedColor = Color(0xFF7A6E9A);

// ── timing ────────────────────────────────────────────────────────────
const int _travelMs = (preambleOnMs + preambleOffMs) * preambleRepeat; // 1800
const double _exitMs = 500;
const int _demoId = 42; // fallback when Supabase is unavailable
const int _effectDurationMs = 600;

// ── Judgment popup data ───────────────────────────────────────────────
class _JudgmentEffect {
  _JudgmentEffect({
    required this.judgement,
    required this.angle,
    required this.startMs,
  });

  final Judgement judgement;
  final double angle;
  final int startMs;
}

// ── GameView ──────────────────────────────────────────────────────────
class GameView extends StatefulWidget {
  const GameView({super.key, this.onNavigateBack, SupabaseService? service})
    : _service = service;

  /// Called when the user taps the back button to return to the 演奏 tab.
  final VoidCallback? onNavigateBack;

  final SupabaseService? _service;

  @override
  State<GameView> createState() => _GameViewState();
}

class _GameViewState extends State<GameView>
    with SingleTickerProviderStateMixin {
  late final SupabaseService _service;
  late final VibratorService _vibrator;
  late final GameController _gc;
  late final Ticker _ticker;
  int _displayMs = 0;
  bool _started = false;
  final List<_JudgmentEffect> _effects = [];
  int _combo = 0;
  // noteIndex → _displayMs when tapped; drives the hold-drain animation
  final Map<int, int> _holdStartMs = {};
  List<UrlEntry> _urls = const [];
  UrlEntry? _selectedEntry;
  bool _loadingUrls = false;
  String? _urlError;
  PageController? _pageController;

  @override
  void initState() {
    super.initState();
    _service = widget._service ?? SupabaseService();
    _vibrator = VibratorService();
    _gc = GameController(vibrator: _vibrator);
    _gc.load(_demoId); // placeholder until URL is selected
    _ticker = createTicker(_onTick);
    _gc.addListener(_onControllerChange);
    _fetchUrls();
  }

  Future<void> _fetchUrls() async {
    setState(() {
      _loadingUrls = true;
      _urlError = null;
    });
    try {
      final entries = await _service.fetchUrls();
      _pageController?.dispose();
      final ctrl = PageController(viewportFraction: 0.78);
      setState(() {
        _urls = entries;
        _loadingUrls = false;
        _pageController = ctrl;
        if (_selectedEntry == null && entries.isNotEmpty) {
          _selectedEntry = entries.first;
          _gc.load(_selectedEntry!.id);
        }
      });
    } catch (e) {
      setState(() {
        _loadingUrls = false;
        _urlError = '読込失敗';
      });
    }
  }

  @override
  void dispose() {
    _gc.removeListener(_onControllerChange);
    _ticker.dispose();
    _gc.dispose();
    _pageController?.dispose();
    super.dispose();
  }

  void _onControllerChange() {
    // Ticker shutdown is handled in _onTick after the last note exits the screen.
    setState(() {});
  }

  void _onTick(Duration elapsed) {
    final ms = elapsed.inMilliseconds;
    _effects.removeWhere((e) => ms - e.startMs > _effectDurationMs);
    _holdStartMs.removeWhere(
      (idx, tapMs) => ms - tapMs > _gc.notes[idx].durationMs,
    );
    setState(() => _displayMs = ms);
    final gameMs = _displayMs - _travelMs;
    if (gameMs >= 0) _gc.tick(gameMs);

    // Stop only after the last note has fully exited past the judgment line.
    if (_gc.state == GameState.finished && _started) {
      final notes = _gc.notes;
      final lastExitMs = notes.isEmpty
          ? 0
          : notes.last.hitTimeMs + _travelMs + _exitMs.toInt();
      if (ms >= lastExitMs) {
        _ticker.stop();
        setState(() {
          _started = false;
          _holdStartMs.clear();
        });
      }
    }
  }

  void _start() {
    _gc.reset();
    _gc.start();
    _ticker.start();
    setState(() {
      _started = true;
      _combo = 0;
      _effects.clear();
      _holdStartMs.clear();
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
      _holdStartMs.clear();
    });
  }

  void _onTapDown(TapDownDetails _) {
    if (!_started || _gc.state != GameState.playing) return;
    final gameMs = _displayMs - _travelMs;
    if (gameMs < 0) return;
    final cursor = _gc.cursor;
    if (cursor >= _gc.notes.length) return;
    final j = _gc.onInputDown(gameMs);
    if (j == null) return;
    final tappedNote = _gc.notes[cursor];
    _effects.add(
      _JudgmentEffect(
        judgement: j,
        angle: tappedNote.angle,
        startMs: _displayMs,
      ),
    );
    // Hold notes that weren't missed: record tap time for drain animation.
    if (tappedNote.type == NoteType.hold && j != Judgement.miss) {
      _holdStartMs[cursor] = _displayMs;
    }
    if (j != Judgement.miss) {
      _combo++;
    } else {
      _combo = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _onTapDown,
          child: Stack(
            children: [
              Positioned.fill(child: CustomPaint(painter: _BgPainter())),
              Positioned.fill(
                child: CustomPaint(
                  painter: _GamePainter(
                    notes: _started ? _gc.notes : const [],
                    results: _gc.results,
                    effects: List.unmodifiable(_effects),
                    holdStartMs: Map.unmodifiable(_holdStartMs),
                    displayMs: _displayMs.toDouble(),
                    travelMs: _travelMs.toDouble(),
                  ),
                ),
              ),
              // Combo HUD — top-center
              if (_combo >= 1)
                Positioned(
                  top: 4,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(child: _buildComboDisplay()),
                  ),
                ),
              // Title — top-right (only when not playing, so it doesn't distract)
              if (!_started)
                const Positioned(
                  top: 8,
                  right: 12,
                  child: IgnorePointer(
                    child: Text(
                      'V I B E C O D E',
                      style: TextStyle(
                        color: _neonPurple,
                        fontSize: 9,
                        letterSpacing: 4,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              // Back button — top-left, only when not playing
              if (!_started && widget.onNavigateBack != null)
                Positioned(top: 4, left: 4, child: _buildBackButton()),
              // URL selector — fills space between header and play button
              if (!_started)
                Positioned(
                  top: 30,
                  left: 16,
                  right: 16,
                  bottom: 50,
                  child: _buildUrlSelector(),
                ),
              if (!_started)
                Positioned(
                  bottom: 10,
                  left: 0,
                  right: 0,
                  child: Center(child: _buildPlayButton()),
                )
              else
                Positioned(top: 8, right: 8, child: _buildPlayButton()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUrlSelector() {
    if (_loadingUrls) {
      return const Center(
        child: CircularProgressIndicator(color: _neonCyan, strokeWidth: 2),
      );
    }
    if (_urlError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _urlError!,
              style: const TextStyle(color: _mutedColor, fontSize: 12),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _fetchUrls,
              child: const Text(
                '再試行',
                style: TextStyle(color: _neonCyan, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }
    if (_urls.isEmpty) {
      return const Center(
        child: Text(
          'URLが登録されていません\n演奏タブから登録してください',
          textAlign: TextAlign.center,
          style: TextStyle(color: _mutedColor, fontSize: 12),
        ),
      );
    }

    final ctrl = _pageController!;
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final cardH = (constraints.maxHeight - 8).clamp(60.0, 150.0);
              return Center(
                child: SizedBox(
                  height: cardH,
                  child: NotificationListener<ScrollEndNotification>(
                    onNotification: (_) {
                      final i = ctrl.page?.round();
                      if (i != null && i >= 0 && i < _urls.length) {
                        final entry = _urls[i];
                        if (entry.id != _selectedEntry?.id) {
                          setState(() {
                            _selectedEntry = entry;
                            _gc.load(entry.id);
                          });
                        }
                      }
                      return false;
                    },
                    child: PageView.builder(
                      controller: ctrl,
                      itemCount: _urls.length,
                      itemBuilder: (context, i) {
                        final selected = _selectedEntry?.id == _urls[i].id;
                        return _buildUrlCard(_urls[i], selected);
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildUrlCard(UrlEntry entry, bool selected) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      margin: EdgeInsets.symmetric(horizontal: 8, vertical: selected ? 2 : 10),
      decoration: BoxDecoration(
        color: selected
            ? _neonPurple.withAlpha(22)
            : Colors.black.withAlpha(90),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected ? _neonPurple : _lineColor,
          width: selected ? 2 : 1,
        ),
        boxShadow: selected
            ? [BoxShadow(color: _neonPurple.withAlpha(65), blurRadius: 14)]
            : null,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: (selected ? _neonPurple : _mutedColor).withAlpha(28),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: (selected ? _neonPurple : _mutedColor).withAlpha(90),
              ),
            ),
            child: Text(
              'id : ${entry.id.toString().padLeft(3, '0')}',
              style: TextStyle(
                color: selected ? _neonPurple : _mutedColor,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            entry.url,
            style: TextStyle(
              color: selected
                  ? Colors.white.withAlpha(215)
                  : Colors.white.withAlpha(90),
              fontSize: 12,
              letterSpacing: 0.2,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildBackButton() {
    return GestureDetector(
      onTap: widget.onNavigateBack,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: _neonPurple.withAlpha(120)),
          borderRadius: BorderRadius.circular(4),
          color: _neonPurple.withAlpha(20),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chevron_left, color: _neonPurple, size: 14),
            Text(
              '演奏',
              style: TextStyle(
                color: _neonPurple,
                fontSize: 10,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComboDisplay() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '$_combo',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 34,
            fontWeight: FontWeight.bold,
            letterSpacing: -1,
            shadows: [Shadow(color: _neonCyan, blurRadius: 12)],
          ),
        ),
        const SizedBox(width: 4),
        const Padding(
          padding: EdgeInsets.only(bottom: 4),
          child: Text(
            'COMBO',
            style: TextStyle(
              color: _neonCyan,
              fontSize: 8,
              letterSpacing: 4,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPlayButton() {
    if (_started) {
      return OutlinedButton.icon(
        onPressed: _stop,
        icon: const Icon(Icons.stop, color: _neonCyan, size: 14),
        label: const Text(
          '停止',
          style: TextStyle(color: _neonCyan, fontSize: 11),
        ),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: _neonCyan),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }
    return ElevatedButton.icon(
      onPressed: _selectedEntry == null ? null : _start,
      icon: const Icon(Icons.play_arrow, size: 16),
      label: const Text('演奏開始', style: TextStyle(fontSize: 13)),
      style: ElevatedButton.styleFrom(
        backgroundColor: _neonPurple.withAlpha(50),
        foregroundColor: _neonPurple,
        side: const BorderSide(color: _neonPurple),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

// ── Background painter (ProSeka deep purple) ──────────────────────────
class _BgPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), [
          const Color(0xFF130025),
          const Color(0xFF04000E),
        ]),
    );
    // Purple bloom at top (notes spawn from here)
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.8),
          radius: 1.0,
          colors: [_neonPurple.withAlpha(30), Colors.transparent],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ── Game painter: 6 perspective lanes, notes fall top → bottom ────────
class _GamePainter extends CustomPainter {
  _GamePainter({
    required this.notes,
    required this.results,
    required this.effects,
    required this.holdStartMs,
    required this.displayMs,
    required this.travelMs,
  });

  final List<Note> notes;
  final Map<int, Judgement> results;
  final List<_JudgmentEffect> effects;
  final Map<int, int> holdStartMs;
  final double displayMs;
  final double travelMs;

  static const _nLanes = 6;
  // Judgment line at 80% down; bottom 20% = tap pad area.
  static const _judgeRatio = 0.80;
  // Track width at spawn (top) as fraction of screen width → creates perspective.
  static const _topWidthRatio = 0.25;

  int _toLane(double angle) =>
      ((angle * 4 / pi).round() % _nLanes + _nLanes) % _nLanes;

  // Center X of a lane at the given approach progress (0 = top, 1 = judgment line).
  double _perspX(int lane, double progress, double screenW) {
    final topW = screenW * _topWidthRatio;
    final w = topW + (screenW - topW) * progress;
    final left = (screenW - w) / 2;
    return left + (lane + 0.5) * (w / _nLanes);
  }

  // Width of one lane at the given progress.
  double _perspLaneW(double progress, double screenW) {
    final topW = screenW * _topWidthRatio;
    return (topW + (screenW - topW) * progress) / _nLanes;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final judgeY = size.height * _judgeRatio;
    final slotProgress = _computeSlotProgress(size.width);

    _drawLaneBg(canvas, size, judgeY);
    _drawJudgeLine(canvas, size, judgeY, slotProgress);
    _drawNotes(canvas, size, judgeY);
    _drawJudgmentEffects(canvas, judgeY, size.width);
  }

  // ── Lane background: converging perspective lines + fade ──────────────
  void _drawLaneBg(Canvas canvas, Size size, double judgeY) {
    final topW = size.width * _topWidthRatio;
    final topLeft = (size.width - topW) / 2;

    // Alternating lane fills (trapezoids)
    for (var k = 0; k < _nLanes; k++) {
      if (!k.isOdd) continue;
      final topX0 = topLeft + k * (topW / _nLanes);
      final topX1 = topLeft + (k + 1) * (topW / _nLanes);
      final botX0 = k * (size.width / _nLanes);
      final botX1 = (k + 1) * (size.width / _nLanes);
      final path = Path()
        ..moveTo(topX0, 0)
        ..lineTo(topX1, 0)
        ..lineTo(botX1, judgeY)
        ..lineTo(botX0, judgeY)
        ..close();
      canvas.drawPath(path, Paint()..color = Colors.white.withAlpha(7));
    }

    // Converging lane separator lines (perspective)
    for (var k = 0; k <= _nLanes; k++) {
      final topX = topLeft + k * (topW / _nLanes);
      final botX = k * (size.width / _nLanes);
      canvas.drawLine(
        Offset(topX, 0),
        Offset(botX, judgeY),
        Paint()
          ..color = _lineColor
          ..strokeWidth = 0.8,
      );
    }

    // Outer border lines (slightly brighter)
    canvas.drawLine(
      Offset(topLeft, 0),
      Offset(0, judgeY),
      Paint()
        ..color = _neonPurple.withAlpha(40)
        ..strokeWidth = 1.2,
    );
    canvas.drawLine(
      Offset(topLeft + topW, 0),
      Offset(size.width, judgeY),
      Paint()
        ..color = _neonPurple.withAlpha(40)
        ..strokeWidth = 1.2,
    );

    // Top darkness fade (depth / vanishing effect)
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, judgeY * 0.45),
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(0, judgeY * 0.45), [
          Colors.black.withAlpha(100),
          Colors.transparent,
        ]),
    );
  }

  // ── Judgment line + 6 perspective tap pads ────────────────────────────
  void _drawJudgeLine(
    Canvas canvas,
    Size size,
    double judgeY,
    List<double> slotProgress,
  ) {
    // Glow
    canvas.drawLine(
      Offset(0, judgeY),
      Offset(size.width, judgeY),
      Paint()
        ..color = Colors.white.withAlpha(45)
        ..strokeWidth = 12
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    // Crisp line
    canvas.drawLine(
      Offset(0, judgeY),
      Offset(size.width, judgeY),
      Paint()
        ..color = Colors.white.withAlpha(210)
        ..strokeWidth = 2,
    );

    // Tap pads below judgment line — aligned with lane perspective at progress=1
    final padH = size.height - judgeY - 6;
    for (var k = 0; k < _nLanes; k++) {
      // At judgment line, lanes are full-width. _perspX(k, 1.0) gives center.
      final laneX = _perspX(k, 1.0, size.width);
      final laneW = _perspLaneW(1.0, size.width);
      final p = slotProgress[k];
      final padW = laneW * 0.78;
      final padRect = Rect.fromLTWH(laneX - padW / 2, judgeY + 4, padW, padH);
      final padRR = RRect.fromRectAndRadius(
        padRect,
        Radius.circular(padW * 0.12),
      );

      if (p > 0) {
        canvas.drawRRect(
          padRR,
          Paint()
            ..color = _neonCyan.withAlpha((p * 95).toInt())
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
        );
      }
      canvas.drawRRect(
        padRR,
        Paint()..color = _neonCyan.withAlpha((18 + p * 85).toInt()),
      );
      canvas.drawRRect(
        padRR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = _neonCyan.withAlpha((75 + p * 180).toInt().clamp(0, 255)),
      );
    }
  }

  // ── Notes falling top → bottom with perspective scaling ───────────────
  void _drawNotes(Canvas canvas, Size size, double judgeY) {
    if (travelMs <= 0) return;

    for (var i = 0; i < notes.length; i++) {
      final note = notes[i];

      // Hold note that was tapped: drain animation (shrinks toward tail).
      final tapMs = holdStartMs[i];
      if (tapMs != null) {
        final holdProgress = ((displayMs - tapMs) / note.durationMs).clamp(
          0.0,
          1.0,
        );
        if (holdProgress >= 1.0) continue; // fully drained
        final lane = _toLane(note.angle);
        final headLaneW = _perspLaneW(1.0, size.width);
        final remainingFrac =
            (1.0 - holdProgress) * (note.durationMs / travelMs);
        _drawHoldNote(
          canvas,
          lane,
          headLaneW,
          judgeY,
          remainingFrac,
          judgeY,
          1.0,
          size.width,
        );
        continue;
      }

      final j = results[i];
      if (j != null && j != Judgement.miss) continue;

      final spawnMs = note.hitTimeMs.toDouble();
      if (displayMs < spawnMs) continue;

      final progress = (displayMs - spawnMs) / travelMs;
      if (progress > 1.0 + _exitMs / travelMs) continue;

      final opacity = progress >= 1.0
          ? (1.0 - (progress - 1.0) * travelMs / _exitMs).clamp(0.0, 1.0)
          : 1.0;

      final lane = _toLane(note.angle);
      final noteY = judgeY * progress;
      // Clamp progress to [0,1] for position/size (exit goes below judgeY)
      final p = progress.clamp(0.0, 1.0);
      final laneX = _perspX(lane, p, size.width);
      final laneW = _perspLaneW(p, size.width);

      if (note.type == NoteType.tap) {
        _drawTapNote(canvas, laneX, laneW, noteY, opacity);
      } else {
        final barLenFraction = note.durationMs / travelMs;
        _drawHoldNote(
          canvas,
          lane,
          laneW,
          noteY,
          barLenFraction,
          judgeY,
          opacity,
          size.width,
        );
      }
    }
  }

  // Short/tap note: wide flat bar, sized by perspective laneW
  void _drawTapNote(
    Canvas canvas,
    double laneX,
    double laneW,
    double noteY,
    double opacity,
  ) {
    const noteH = 10.0;
    final noteW = laneW * 0.86;
    final rect = Rect.fromLTWH(
      laneX - noteW / 2,
      noteY - noteH / 2,
      noteW,
      noteH,
    );
    final rr = RRect.fromRectAndRadius(rect, const Radius.circular(5));

    canvas.drawRRect(
      rr,
      Paint()
        ..color = _neonAmber.withAlpha((opacity * 65).toInt())
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawRRect(
      rr,
      Paint()..color = _neonAmber.withAlpha((opacity * 255).toInt()),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withAlpha((opacity * 200).toInt()),
    );
  }

  // Long/hold note: perspective trapezoid (wide at head, narrow at tail)
  void _drawHoldNote(
    Canvas canvas,
    int lane,
    double headLaneW,
    double headY,
    double barLenFraction,
    double judgeY,
    double opacity,
    double screenW,
  ) {
    // tail progress = head progress - barLenFraction (clamped to 0 so tail doesn't go above screen)
    final headProgress = (headY / judgeY).clamp(0.0, 1.0);
    final tailProgress = (headProgress - barLenFraction).clamp(0.0, 1.0);
    final tailY = judgeY * tailProgress;

    final headW = headLaneW * 0.72;
    final tailLaneW = _perspLaneW(tailProgress, screenW);
    final tailW = tailLaneW * 0.72;
    final headLaneX = _perspX(lane, headProgress, screenW);
    final tailLaneX = _perspX(lane, tailProgress, screenW);

    // Draw as a trapezoid path (wider at bottom/head, narrower at top/tail)
    final path = Path()
      ..moveTo(tailLaneX - tailW / 2, tailY)
      ..lineTo(tailLaneX + tailW / 2, tailY)
      ..lineTo(headLaneX + headW / 2, headY)
      ..lineTo(headLaneX - headW / 2, headY)
      ..close();

    // Glow
    canvas.drawPath(
      path,
      Paint()
        ..color = _neonCyan.withAlpha((opacity * 75).toInt())
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
    // Gradient fill: purple (tail/top) → cyan (head/bottom)
    canvas.drawPath(
      path,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(headLaneX, tailY),
          Offset(headLaneX, headY),
          [
            _neonPurple.withAlpha((opacity * 185).toInt()),
            _neonCyan.withAlpha((opacity * 225).toInt()),
          ],
        ),
    );
    // Rim
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withAlpha((opacity * 160).toInt()),
    );

    // Bright head cap
    final capRect = Rect.fromLTWH(headLaneX - headW / 2, headY - 5, headW, 10);
    canvas.drawRRect(
      RRect.fromRectAndRadius(capRect, const Radius.circular(4)),
      Paint()..color = _neonCyan.withAlpha((opacity * 255).toInt()),
    );
  }

  // ── Per-lane max approach progress (drives tap pad glow) ──────────────
  List<double> _computeSlotProgress(double screenW) {
    final progress = List<double>.filled(_nLanes, 0.0);
    if (travelMs <= 0) return progress;
    for (var i = 0; i < notes.length; i++) {
      final j = results[i];
      if (j != null && j != Judgement.miss) continue;
      final spawnMs = notes[i].hitTimeMs.toDouble();
      if (displayMs < spawnMs) continue;
      final rp = (displayMs - spawnMs) / travelMs;
      if (rp <= 0 || rp >= 1.0) continue;
      final lane = _toLane(notes[i].angle);
      if (rp > progress[lane]) progress[lane] = rp;
    }
    return progress;
  }

  // ── PERFECT / GOOD / MISS text at judgment line, floats upward ────────
  void _drawJudgmentEffects(Canvas canvas, double judgeY, double screenW) {
    for (final effect in effects) {
      final age = displayMs - effect.startMs;
      if (age < 0 || age > _effectDurationMs) continue;
      final t = age / _effectDurationMs;
      final opacity = (1.0 - t).clamp(0.0, 1.0);
      final rise = t * 36.0;

      final lane = _toLane(effect.angle);
      final laneX = _perspX(lane, 1.0, screenW);
      final textY = judgeY - rise - 6;

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
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
            shadows: [
              Shadow(
                color: labelColor.withAlpha((opacity * 150).toInt()),
                blurRadius: 6,
              ),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      tp.layout();
      tp.paint(canvas, Offset(laneX - tp.width / 2, textY - tp.height));
    }
  }

  @override
  bool shouldRepaint(covariant _GamePainter old) =>
      displayMs != old.displayMs || results.length != old.results.length;
}
