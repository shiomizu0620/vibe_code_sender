import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'constants.dart';
import 'encoder.dart';
import 'game_logic.dart';
import 'pattern_builder.dart';
import 'supabase_service.dart';
import 'vibrator_service.dart';

// ── color palette (Aurora Teal) ───────────────────────────────────────
const _bg = Color(0xFF091C1A);
const _neonCyan = Color(0xFF3DFFAA);
const _neonAmber = Color(0xFFFFB454);
const _neonGold = Color(0xFFFFD700);
const _neonPurple = Color(0xFFD070FF);
const _lineColor = Color(0xFF163530);
const _mutedColor = Color(0xFF5A8878);

// ── timing ────────────────────────────────────────────────────────────
// Fixed protocol timing offset. Notes always reach the judgment line at
// displayMs = hitTimeMs + _judgeOffsetMs, regardless of visual speed.
const int _judgeOffsetMs =
    (preambleOnMs + preambleOffMs) * preambleRepeat; // 1800
const double _exitMs = 500;
const int _demoId = 42; // fallback when Supabase is unavailable
const int _effectDurationMs = 750;

// ── URL selector mode ────────────────────────────────────────────────
enum _SelectorMode { list, direct }

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
  const GameView({
    super.key,
    this.onNavigateBack,
    this.initialPulses,
    SupabaseService? service,
  }) : _service = service;

  /// Called when the user taps the back button to return to the 演奏 tab。
  /// プッシュ遷移で開いた場合（[initialPulses] 指定時）はルートを pop する。
  final VoidCallback? onNavigateBack;

  /// 指定されると URL 選択をスキップし、この譜面を直接ゲームに読み込んで起動する。
  /// 演奏画面(SenderPage)の「ゲームで演奏」ボタンから現在の譜面を渡す用途。
  final List<Pulse>? initialPulses;

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
  Map<int, Judgement>? _lastResults; // snapshot for result screen
  int? _countdownRemaining; // 3/2/1/0="GO!" during countdown, null otherwise
  List<UrlEntry> _urls = const [];
  UrlEntry? _selectedEntry;
  bool _loadingUrls = false;
  String? _urlError;
  PageController? _pageController;
  _SelectorMode _selectorMode = _SelectorMode.list;
  final TextEditingController _directUrlCtrl = TextEditingController();
  String? _directUrlError;
  bool _directUrlReady = false;
  bool _listUseX1 = false; // false=ショート(id方式・9音) / true=ロング(X1・長譜面)
  bool _urlConfirmed = false; // Step2(形式選択)に進んだか
  double _noteSpeed = 4.0;
  bool _autoPlay = false; // true=自動演奏（触らなくても全ノーツPerfect）

  // Visual travel time in ms. Speed 4.0 = 1800ms (protocol default).
  int get _travelMs => (7200.0 / _noteSpeed).round();

  /// 演奏画面から譜面を直接渡されて起動したか（URL選択をスキップする）。
  bool get _isDirectLaunch => widget.initialPulses != null;

  @override
  void initState() {
    super.initState();
    _service = widget._service ?? SupabaseService();
    _vibrator = VibratorService();
    _gc = GameController(vibrator: _vibrator);
    _ticker = createTicker(_onTick);
    _gc.addListener(_onControllerChange);
    if (_isDirectLaunch) {
      // プッシュ遷移で開かれるためタブ切替の向き設定が効かない。ここで横向きにする。
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      _gc.loadPulses(widget.initialPulses!);
      _selectorMode = _SelectorMode.direct; // 選択UIは出さず直接演奏可能状態に
      _directUrlReady = true;
    } else {
      _gc.load(_demoId); // placeholder until URL is selected
      _fetchUrls();
    }
  }

  Future<void> _fetchUrls() async {
    setState(() {
      _loadingUrls = true;
      _urlError = null;
    });
    try {
      final entries = await _service.fetchUrls();
      if (!mounted) return;
      _pageController?.dispose();
      final ctrl = PageController(viewportFraction: 0.78);
      setState(() {
        _urls = entries;
        _loadingUrls = false;
        _pageController = ctrl;
        if (_selectedEntry == null && entries.isNotEmpty) {
          _selectedEntry = entries.first;
          _loadSelectedEntry(_selectedEntry!);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingUrls = false;
        _urlError = '読込失敗';
      });
    }
  }

  @override
  void dispose() {
    if (_isDirectLaunch) {
      // プッシュ遷移で横向きにしたので、戻る画面（縦）のために縦向きへ戻す。
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
    _gc.removeListener(_onControllerChange);
    _ticker.dispose();
    _gc.dispose();
    _pageController?.dispose();
    _directUrlCtrl.dispose();
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
    final gameMs = _displayMs - _judgeOffsetMs;
    if (gameMs >= 0) {
      final cursorBefore = _gc.cursor;
      _gc.tick(gameMs);
      for (var i = cursorBefore; i < _gc.cursor; i++) {
        final note = _gc.notes[i];
        final result = _gc.results[i];
        if (result == Judgement.miss) {
          _effects.add(
            _JudgmentEffect(
              judgement: Judgement.miss,
              angle: note.angle,
              startMs: ms,
            ),
          );
          _combo = 0;
        } else if (result == Judgement.perfect && !note.isPreamble) {
          _effects.add(
            _JudgmentEffect(
              judgement: Judgement.perfect,
              angle: note.angle,
              startMs: ms,
            ),
          );
          // 自動演奏の hold ノーツはドレイン演出のため発火時刻を記録する。
          if (_gc.mode == GameMode.auto && note.type == NoteType.hold) {
            _holdStartMs[i] = ms;
          }
          _combo++;
        }
      }
    }

    // Stop only after the last note has fully exited past the judgment line.
    if (_gc.state == GameState.finished && _started) {
      final notes = _gc.notes;
      final lastExitMs = notes.isEmpty
          ? 0
          : notes.last.hitTimeMs + _judgeOffsetMs + _exitMs.toInt();
      if (ms >= lastExitMs) {
        _ticker.stop();
        setState(() {
          _lastResults = Map.of(_gc.results);
          _started = false;
          _holdStartMs.clear();
        });
      }
    }
  }

  void _startPressed() {
    _gc.setMode(_autoPlay ? GameMode.auto : GameMode.hybrid);
    _gc.reset();
    _gc.start();
    _gc.skipPreamble();
    _ticker.start();
    // Fire preamble at judgeOffsetMs so it ends just before the first data
    // note reaches the judgment line (gap = preambleOffMs = 200ms ✓).
    // This delay is fixed regardless of visual note speed.
    Future.delayed(const Duration(milliseconds: _judgeOffsetMs), () {
      if (mounted && _countdownRemaining != null) {
        _vibrator.play(<int>[0, preambleOnMs]);
      }
    });
    Future.delayed(
      const Duration(
        milliseconds: _judgeOffsetMs + preambleOnMs + preambleOffMs,
      ),
      () {
        if (mounted && _countdownRemaining != null) {
          _vibrator.play(<int>[0, preambleOnMs]);
        }
      },
    );
    setState(() {
      _started = false; // interactive after countdown
      _combo = 0;
      _lastResults = null;
      _effects.clear();
      _holdStartMs.clear();
      _countdownRemaining = 3;
    });
    _tickCountdown();
  }

  Future<void> _tickCountdown() async {
    for (var i = 3; i >= 0; i--) {
      if (!mounted || _countdownRemaining == null) return;
      if (i < 3) setState(() => _countdownRemaining = i);
      if (i == 0) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted || _countdownRemaining == null) return;
        setState(() {
          _countdownRemaining = null;
          _started = true;
        });
        return;
      }
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  void _stop() {
    _ticker.stop();
    _gc.reset();
    setState(() {
      _started = false;
      _displayMs = 0;
      _combo = 0;
      _countdownRemaining = null;
      _lastResults = null;
      _effects.clear();
      _holdStartMs.clear();
    });
  }

  // Lane index (0-5) from tap X position (uses full-width spacing at judgeY).
  int _laneFromX(double x, double screenW) =>
      (x * _GamePainter._nLanes / screenW).floor().clamp(
        0,
        _GamePainter._nLanes - 1,
      );

  // Lane index (0-5) from a note's angle — same formula as _GamePainter._toLane.
  int _laneFromAngle(double angle) =>
      ((angle * 4 / pi).round() % _GamePainter._nLanes + _GamePainter._nLanes) %
      _GamePainter._nLanes;

  void _onPointerDown(Offset localPosition) {
    final screenH = context.size?.height ?? double.infinity;
    if (localPosition.dy < screenH * 0.80) return;
    if (!_started || _gc.state != GameState.playing) return;
    if (_gc.mode == GameMode.auto) return; // 自動演奏中は入力を無視
    final gameMs = _displayMs - _judgeOffsetMs;
    if (gameMs < 0) return;
    final cursor = _gc.cursor;
    if (cursor >= _gc.notes.length) return;

    // Wrong-lane tap → MISS effect at tapped position, no judgment advance.
    final screenW = context.size?.width ?? double.infinity;
    final tappedLane = _laneFromX(localPosition.dx, screenW);
    final noteLane = _laneFromAngle(_gc.notes[cursor].angle);
    if (tappedLane != noteLane) {
      setState(() {
        _effects.add(
          _JudgmentEffect(
            judgement: Judgement.miss,
            angle: tappedLane * pi / 4.0,
            startMs: _displayMs,
          ),
        );
      });
      return;
    }

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
    if (tappedNote.type == NoteType.hold && j != Judgement.miss) {
      _holdStartMs[cursor] = _displayMs;
    }
    if (j != Judgement.miss) {
      _combo++;
    } else {
      _combo = 0;
    }
  }

  void _onPointerUp() {}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      // 横向き＋ソフトキーボードで本文が潰れ、開始前UIの Column がオーバーフロー
      // するのを防ぐ。キーボードは画面に重ねる（入力欄は上寄せで隠れないようにする）。
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) => _onPointerDown(e.localPosition),
          onPointerUp: (_) => _onPointerUp(),
          child: Stack(
            children: [
              Positioned.fill(child: CustomPaint(painter: _BgPainter())),
              if (_started || _countdownRemaining != null)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _GamePainter(
                      notes: _gc.notes.toList(),
                      results: _gc.results,
                      effects: List.unmodifiable(_effects),
                      holdStartMs: Map.unmodifiable(_holdStartMs),
                      displayMs: _displayMs.toDouble(),
                      travelMs: _travelMs.toDouble(),
                    ),
                  ),
                ),
              // Countdown overlay
              if (_countdownRemaining != null)
                Positioned.fill(child: IgnorePointer(child: _buildCountdown())),
              // Score HUD — top-left during play
              if (_started)
                Positioned(
                  top: 6,
                  left: 10,
                  child: IgnorePointer(child: _buildScoreHud()),
                ),
              // AUTO badge — below score HUD during auto-play
              if (_started && _gc.mode == GameMode.auto)
                Positioned(
                  top: 28,
                  left: 10,
                  child: IgnorePointer(child: _buildAutoBadge()),
                ),
              // Combo HUD — top-center during play
              if (_started && _combo >= 1)
                Positioned(
                  top: 4,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(child: _buildComboDisplay()),
                  ),
                ),
              // Stop/cancel button — top-right during countdown or play
              if (_started || _countdownRemaining != null)
                Positioned(top: 8, right: 8, child: _buildPlayButton()),
              // Pre-game UI (hidden during countdown or result)
              if (!_started &&
                  _countdownRemaining == null &&
                  _lastResults == null)
                Positioned.fill(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 4, 12, 0),
                        child: Row(
                          children: [
                            if (widget.onNavigateBack != null)
                              _buildBackButton(),
                            const Spacer(),
                            const Text(
                              'V I B E C O D E',
                              style: TextStyle(
                                color: _neonPurple,
                                fontSize: 9,
                                letterSpacing: 4,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          // 演奏画面から直接起動した時は URL 選択を出さず、
                          // 読み込み済みの譜面でそのまま開始できる案内を出す。
                          child: _isDirectLaunch
                              ? _buildDirectReady()
                              : _buildUrlSelector(),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                        child: Center(child: _buildAutoToggle()),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                        child: _buildPlayButton(),
                      ),
                    ],
                  ),
                ),
              // Result overlay — after natural game end
              if (!_started && _lastResults != null)
                Positioned.fill(child: _buildResultOverlay()),
            ],
          ),
        ),
      ),
    );
  }

  /// 演奏画面から直接起動した時の準備画面。URL選択の代わりに、読み込み済みの
  /// 譜面でそのまま「演奏開始」を押せることを案内する。
  Widget _buildDirectReady() {
    final count = widget.initialPulses?.length ?? 0;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.sports_esports, color: _neonPurple, size: 52),
          const SizedBox(height: 16),
          const Text(
            'このURLをゲームで演奏',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$count ノーツ',
            style: const TextStyle(color: _mutedColor, fontSize: 12),
          ),
          const SizedBox(height: 28),
          _buildSpeedControl(),
        ],
      ),
    );
  }

  /// 停止/キャンセル。直接起動時は呼び出し元（演奏画面）へ pop して戻る。
  void _handleStop() {
    _stop();
    if (_isDirectLaunch) widget.onNavigateBack?.call();
  }

  Widget _buildUrlSelector() {
    return Column(
      children: [
        _buildSelectorToggle(),
        const SizedBox(height: 8),
        Expanded(
          child: _selectorMode == _SelectorMode.list
              ? _buildListContent()
              : _buildDirectContent(),
        ),
      ],
    );
  }

  Widget _buildSelectorToggle() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildModeTab('一覧', _SelectorMode.list),
        _buildModeTab('URL直接', _SelectorMode.direct),
      ],
    );
  }

  Widget _buildModeTab(String label, _SelectorMode mode) {
    final selected = _selectorMode == mode;
    final isLeft = mode == _SelectorMode.list;
    return GestureDetector(
      onTap: () => _switchSelectorMode(mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? _neonPurple.withAlpha(40) : Colors.transparent,
          border: Border.all(color: selected ? _neonPurple : _lineColor),
          borderRadius: BorderRadius.only(
            topLeft: isLeft ? const Radius.circular(6) : Radius.zero,
            bottomLeft: isLeft ? const Radius.circular(6) : Radius.zero,
            topRight: isLeft ? Radius.zero : const Radius.circular(6),
            bottomRight: isLeft ? Radius.zero : const Radius.circular(6),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? _neonPurple : _mutedColor,
            fontSize: 11,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }

  void _setNoteSpeed(double speed) {
    setState(() => _noteSpeed = speed.clamp(1.0, 10.0));
  }

  void _loadSelectedEntry(UrlEntry entry) {
    if (_listUseX1) {
      try {
        _gc.loadPulses(encodeUrl(entry.url));
        return;
      } catch (_) {}
    }
    _gc.load(entry.id);
  }

  void _setListEncoding({required bool useX1}) {
    if (_listUseX1 == useX1) return;
    setState(() => _listUseX1 = useX1);
    if (_selectedEntry != null) _loadSelectedEntry(_selectedEntry!);
  }

  bool get _canPlay => _selectorMode == _SelectorMode.list
      ? _selectedEntry != null
      : _directUrlReady;

  void _switchSelectorMode(_SelectorMode mode) {
    if (_selectorMode == mode) return;
    setState(() {
      _selectorMode = mode;
      _urlConfirmed = false;
      _directUrlError = null;
      if (mode == _SelectorMode.list && _selectedEntry != null) {
        _loadSelectedEntry(_selectedEntry!);
        _directUrlReady = false;
      }
    });
  }

  void _loadDirectUrl() {
    final url = _directUrlCtrl.text.trim();
    if (url.isEmpty) {
      setState(() => _directUrlError = 'URLを入力してください');
      return;
    }
    try {
      final pulses = encodeUrl(url);
      _gc.loadPulses(pulses);
      setState(() {
        _directUrlError = null;
        _directUrlReady = true;
      });
    } on FormatException {
      setState(() => _directUrlError = '送れない文字が含まれます（小文字のURLのみ対応）');
    } on ArgumentError {
      setState(() => _directUrlError = 'ロングでは送れないURLです');
    }
  }

  Widget _buildSpeedControl() {
    final canDec = _noteSpeed > 1.0;
    final canInc = _noteSpeed < 10.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'ノーツ速度',
          style: TextStyle(color: _mutedColor, fontSize: 10, letterSpacing: 1),
        ),
        const SizedBox(width: 10),
        _speedBtn(
          Icons.remove,
          canDec ? () => _setNoteSpeed(_noteSpeed - 0.5) : null,
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 36,
          child: Text(
            _noteSpeed == _noteSpeed.truncateToDouble()
                ? '${_noteSpeed.toInt()}.0'
                : _noteSpeed.toStringAsFixed(1),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ),
        const SizedBox(width: 6),
        _speedBtn(
          Icons.add,
          canInc ? () => _setNoteSpeed(_noteSpeed + 0.5) : null,
        ),
      ],
    );
  }

  /// 自動演奏のON/OFFトグル。開始前の画面で表示する。
  Widget _buildAutoToggle() {
    final on = _autoPlay;
    return GestureDetector(
      onTap: () => setState(() => _autoPlay = !_autoPlay),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: on ? _neonGold.withAlpha(28) : Colors.transparent,
          border: Border.all(color: on ? _neonGold : _lineColor),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              on ? Icons.smart_toy : Icons.smart_toy_outlined,
              size: 15,
              color: on ? _neonGold : _mutedColor,
            ),
            const SizedBox(width: 7),
            Text(
              on ? '自動演奏 ON' : '自動演奏 OFF',
              style: TextStyle(
                color: on ? _neonGold : _mutedColor,
                fontSize: 12,
                fontWeight: on ? FontWeight.w700 : FontWeight.normal,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 自動演奏中であることを示すバッジ（プレイ中のHUD）。
  Widget _buildAutoBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: _neonGold.withAlpha(28),
        border: Border.all(color: _neonGold.withAlpha(160)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.smart_toy, size: 11, color: _neonGold),
          SizedBox(width: 4),
          Text(
            'AUTO',
            style: TextStyle(
              color: _neonGold,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _speedBtn(IconData icon, VoidCallback? onTap) {
    final active = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: active ? _neonPurple : _lineColor),
          color: active ? _neonPurple.withAlpha(30) : Colors.transparent,
        ),
        child: Icon(icon, size: 14, color: active ? _neonPurple : _lineColor),
      ),
    );
  }

  Widget _buildListContent() {
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

    // Step2: URL確定済み → 形式選択
    if (_urlConfirmed && _selectedEntry != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 戻るリンク + URL表示
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => setState(() => _urlConfirmed = false),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.arrow_back_ios, color: _mutedColor, size: 11),
                      const SizedBox(width: 2),
                      Text(
                        '選び直す',
                        style: TextStyle(color: _mutedColor, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.link, color: _mutedColor, size: 11),
                const SizedBox(width: 3),
                Flexible(
                  child: Text(
                    _selectedEntry!.url,
                    style: const TextStyle(color: _mutedColor, fontSize: 10),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _buildEncodingToggle(),
          const SizedBox(height: 16),
          _buildSpeedControl(),
        ],
      );
    }

    // Step1: URLを選ぶ → カルーセル
    final ctrl = _pageController!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardH = constraints.maxHeight.clamp(60.0, 150.0);
        return Center(
          child: SizedBox(
            height: cardH,
            child: PageView.builder(
              controller: ctrl,
              itemCount: _urls.length,
              onPageChanged: (i) {
                final entry = _urls[i];
                if (entry.id != _selectedEntry?.id) {
                  setState(() {
                    _selectedEntry = entry;
                    _urlConfirmed = false;
                  });
                  _loadSelectedEntry(entry);
                }
              },
              itemBuilder: (context, i) {
                final selected = _selectedEntry?.id == _urls[i].id;
                return _buildUrlCard(_urls[i], selected);
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildEncodingToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Expanded(
            child: _buildEncTab('ショート', subtitle: '9打 · 固定長', useX1: false),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildEncTab('ロング', subtitle: '長譜面 · URL直接', useX1: true),
          ),
        ],
      ),
    );
  }

  Widget _buildEncTab(
    String label, {
    required String subtitle,
    required bool useX1,
  }) {
    final selected = _listUseX1 == useX1;
    return GestureDetector(
      onTap: () => _setListEncoding(useX1: useX1),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        decoration: BoxDecoration(
          color: selected
              ? _neonCyan.withAlpha(38)
              : Colors.black.withAlpha(60),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? _neonCyan : _lineColor,
            width: selected ? 2 : 1,
          ),
          boxShadow: selected
              ? [BoxShadow(color: _neonCyan.withAlpha(50), blurRadius: 14)]
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(
                color: selected ? _neonCyan : Colors.white.withAlpha(200),
                fontSize: 22,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                color: selected ? _neonCyan.withAlpha(190) : _mutedColor,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDirectContent() {
    // 横向きでキーボードを出しても入力欄が隠れないよう上寄せ。狭い領域でも
    // あふれないようスクロール可能にする。
    return SingleChildScrollView(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(90),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _directUrlReady ? _neonCyan : _lineColor,
            width: _directUrlReady ? 1.5 : 1,
          ),
          boxShadow: _directUrlReady
              ? [BoxShadow(color: _neonCyan.withAlpha(30), blurRadius: 14)]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _directUrlCtrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              decoration: InputDecoration(
                hintText: 'github.com',
                hintStyle: TextStyle(color: _mutedColor),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: _lineColor),
                  borderRadius: BorderRadius.circular(6),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: _neonCyan),
                  borderRadius: BorderRadius.circular(6),
                ),
                errorBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: Colors.redAccent),
                  borderRadius: BorderRadius.circular(6),
                ),
                focusedErrorBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: Colors.redAccent),
                  borderRadius: BorderRadius.circular(6),
                ),
                errorText: _directUrlError,
                errorStyle: const TextStyle(
                  color: Colors.redAccent,
                  fontSize: 10,
                ),
              ),
              onChanged: (_) {
                if (_directUrlError != null || _directUrlReady) {
                  setState(() {
                    _directUrlError = null;
                    _directUrlReady = false;
                  });
                }
              },
              onSubmitted: (_) => _loadDirectUrl(),
            ),
            if (_directUrlReady) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(
                    Icons.check_circle_outline,
                    color: _neonCyan,
                    size: 12,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      _directUrlCtrl.text.trim(),
                      style: TextStyle(
                        color: _neonCyan.withAlpha(200),
                        fontSize: 10,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: _loadDirectUrl,
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: _neonPurple.withAlpha(200)),
                foregroundColor: _neonPurple,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('読み込む', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUrlCard(UrlEntry entry, bool selected) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 80),
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

  // ── Score / rank helpers ─────────────────────────────────────────────

  int _calcScore() {
    final results = _lastResults ?? _gc.results;
    final notes = _gc.notes;
    var total = 0;
    var score = 0.0;
    for (var i = 0; i < notes.length; i++) {
      if (notes[i].isPreamble) continue;
      total++;
      final j = results[i];
      if (j == Judgement.perfect) {
        score += 1.0;
      } else if (j == Judgement.good) {
        score += 0.5;
      }
    }
    if (total == 0) return 0;
    return (score / total * 1000000).round();
  }

  String _rank(int score) {
    if (score >= 950000) return 'S';
    if (score >= 900000) return 'A';
    if (score >= 800000) return 'B';
    if (score >= 700000) return 'C';
    return 'F';
  }

  Color _rankColor(String rank) {
    switch (rank) {
      case 'S':
        return _neonGold;
      case 'A':
        return _neonCyan;
      case 'B':
        return _neonPurple;
      case 'C':
        return _neonAmber;
      default:
        return _mutedColor;
    }
  }

  // ── HUD: score during play ────────────────────────────────────────────

  Widget _buildScoreHud() {
    final score = _calcScore();
    return Text(
      score.toString().padLeft(7, '0'),
      style: const TextStyle(
        color: Colors.white,
        fontSize: 15,
        fontWeight: FontWeight.bold,
        letterSpacing: 2,
      ),
    );
  }

  // ── Result overlay ────────────────────────────────────────────────────

  Widget _buildResultOverlay() {
    final results = _lastResults!;
    final notes = _gc.notes;
    var perfects = 0, goods = 0, total = 0;
    for (var i = 0; i < notes.length; i++) {
      if (notes[i].isPreamble) continue;
      total++;
      if (results[i] == Judgement.perfect) {
        perfects++;
      } else if (results[i] == Judgement.good) {
        goods++;
      }
    }
    final misses = total - perfects - goods;
    final score = _calcScore();
    final rank = _rank(score);
    final rc = _rankColor(rank);

    return Container(
      color: _bg.withAlpha(215),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'R E S U L T',
              style: TextStyle(
                color: _mutedColor,
                fontSize: 10,
                letterSpacing: 6,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              rank,
              style: TextStyle(
                color: rc,
                fontSize: 80,
                fontWeight: FontWeight.w900,
                height: 1,
                shadows: [Shadow(color: rc.withAlpha(130), blurRadius: 24)],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              score.toString().padLeft(7, '0'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
                letterSpacing: 4,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildJudgeCount('PERFECT', perfects, _neonGold),
                const SizedBox(width: 28),
                _buildJudgeCount('GOOD', goods, _neonCyan),
                const SizedBox(width: 28),
                _buildJudgeCount('MISS', misses, _mutedColor),
              ],
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              // 直接起動時は同じ譜面で再演奏。通常時は選択画面へ戻す。
              onPressed: _isDirectLaunch ? _startPressed : _stop,
              icon: const Icon(Icons.replay, size: 16),
              label: const Text('もう一度', style: TextStyle(fontSize: 13)),
              style: ElevatedButton.styleFrom(
                backgroundColor: _neonPurple.withAlpha(200),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 10,
                ),
                elevation: 0,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildJudgeCount(String label, int count, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$count',
          style: TextStyle(
            color: color,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            color: color.withAlpha(180),
            fontSize: 8,
            letterSpacing: 2,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildCountdown() {
    final c = _countdownRemaining!;
    final isGo = c == 0;
    final text = isGo ? 'GO!' : '$c';
    final color = isGo ? _neonGold : _neonCyan;
    return Container(
      color: _bg.withAlpha(160),
      child: Center(
        child: Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 100,
            fontWeight: FontWeight.w900,
            height: 1,
            shadows: [Shadow(color: color.withAlpha(150), blurRadius: 32)],
          ),
        ),
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
            fontSize: 42,
            fontWeight: FontWeight.w900,
            letterSpacing: -2,
            height: 1.0,
            shadows: [
              Shadow(color: _neonCyan, blurRadius: 16),
              Shadow(color: _neonCyan, blurRadius: 32),
            ],
          ),
        ),
        const SizedBox(width: 5),
        const Padding(
          padding: EdgeInsets.only(bottom: 5),
          child: Text(
            'COMBO',
            style: TextStyle(
              color: _neonCyan,
              fontSize: 9,
              letterSpacing: 5,
              fontWeight: FontWeight.w700,
              shadows: [Shadow(color: _neonCyan, blurRadius: 8)],
            ),
          ),
        ),
      ],
    );
  }

  void _confirmUrl() => setState(() => _urlConfirmed = true);

  Widget _buildPlayButton() {
    if (_started || _countdownRemaining != null) {
      final label = _countdownRemaining != null ? 'キャンセル' : '停止';
      return OutlinedButton.icon(
        onPressed: _handleStop,
        icon: const Icon(Icons.stop, color: _neonCyan, size: 14),
        label: Text(
          label,
          style: const TextStyle(color: _neonCyan, fontSize: 11),
        ),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: _neonCyan),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }
    // Step1: URLを選ぶ（一覧モードで未確定）
    if (_selectorMode == _SelectorMode.list && !_urlConfirmed) {
      final ok = _selectedEntry != null;
      return ElevatedButton.icon(
        onPressed: ok ? _confirmUrl : null,
        icon: const Icon(Icons.check, size: 20),
        label: const Text(
          'URLを選択',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: ok
              ? _neonCyan.withAlpha(80)
              : Colors.white.withAlpha(10),
          foregroundColor: ok ? Colors.white : _mutedColor,
          side: BorderSide(color: ok ? _neonCyan : _lineColor, width: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
    // Step2 or direct URL: 演奏開始
    return ElevatedButton.icon(
      onPressed: _canPlay ? _startPressed : null,
      icon: const Icon(Icons.play_arrow, size: 20),
      label: const Text(
        '演奏開始',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: _canPlay
            ? _neonPurple.withAlpha(80)
            : Colors.white.withAlpha(10),
        foregroundColor: _canPlay ? Colors.white : _mutedColor,
        side: BorderSide(
          color: _canPlay ? _neonPurple : _lineColor,
          width: 1.5,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
      if (note.isPreamble) continue;

      // Tapped hold: expire once the full duration is consumed.
      final tapMs = holdStartMs[i];
      if (tapMs != null) {
        final holdProgress = ((displayMs - tapMs) / note.durationMs).clamp(
          0.0,
          1.0,
        );
        if (holdProgress >= 1.0) continue;
        // Fall through so natural progress drives the position.
      }

      final j = results[i];
      final isHit = j == Judgement.perfect || j == Judgement.good;

      final double spawnMs = note.hitTimeMs + _judgeOffsetMs - travelMs;
      if (displayMs < spawnMs) continue;

      final double progress = (displayMs - spawnMs) / travelMs;
      final double barLenFraction = note.durationMs / travelMs;

      // Hit notes always use natural constant-speed flow along the lane.
      // Missed notes use the _exitMs formula (fade while slowing to screen edge).
      final maxProgress = (tapMs != null || isHit)
          ? size.height / judgeY + barLenFraction
          : 1.0 + _exitMs / travelMs;
      if (progress > maxProgress) continue;

      // Tap notes: hide ghost until the note reaches the line.
      if (isHit && note.type == NoteType.tap && progress < 1.0) continue;

      final lane = _toLane(note.angle);
      // Hit notes: judgeY * progress (constant speed, follows lane perspective).
      // Missed notes: _exitMs-based formula after the line.
      final double noteY;
      if (!isHit && tapMs == null && progress > 1.0) {
        final exitFrac = ((progress - 1.0) * travelMs / _exitMs).clamp(
          0.0,
          1.0,
        );
        noteY = judgeY + (size.height - judgeY) * exitFrac;
      } else {
        noteY = judgeY * progress;
      }
      // Use unclamped progress for lane X/W on hit notes so they follow
      // the perspective projection past the judgment line.
      final double p = isHit && progress > 1.0
          ? progress
          : progress.clamp(0.0, 1.0);
      final laneX = _perspX(lane, p, size.width);
      final laneW = _perspLaneW(p, size.width);

      if (note.type == NoteType.tap) {
        final double opacity;
        if (isHit) {
          final exitFrac = ((progress - 1.0) * travelMs / _exitMs).clamp(
            0.0,
            1.0,
          );
          opacity = 0.45 * (1.0 - exitFrac);
        } else {
          opacity = progress >= 1.0
              ? (1.0 - (progress - 1.0) * travelMs / _exitMs).clamp(0.0, 1.0)
              : 1.0;
        }
        _drawTapNote(canvas, laneX, laneW, noteY, opacity);
      } else {
        if (isHit) {
          // Tapped hold: flows through judgeY at constant speed.
          // Above judgeY → bright; below judgeY → dim, fades as tail clears line.
          final holdExitFrac = ((progress - 1.0) / barLenFraction).clamp(
            0.0,
            1.0,
          );
          canvas.save();
          canvas.clipRect(Rect.fromLTRB(0, 0, size.width, judgeY));
          _drawHoldNote(
            canvas,
            lane,
            laneW,
            noteY,
            barLenFraction,
            judgeY,
            1.0,
            size.width,
          );
          canvas.restore();
          canvas.save();
          canvas.clipRect(Rect.fromLTRB(0, judgeY, size.width, size.height));
          _drawHoldNote(
            canvas,
            lane,
            laneW,
            noteY,
            barLenFraction,
            judgeY,
            0.30 * (1.0 - holdExitFrac),
            size.width,
          );
          canvas.restore();
        } else {
          // Non-tapped hold: clamp at judgeY, fade out if missed.
          final opacity = progress >= 1.0
              ? (1.0 - (progress - 1.0) * travelMs / _exitMs).clamp(0.0, 1.0)
              : 1.0;
          _drawHoldNote(
            canvas,
            lane,
            laneW,
            noteY.clamp(0.0, judgeY),
            barLenFraction,
            judgeY,
            opacity,
            size.width,
          );
        }
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
    // Use unclamped Y-progress for both head and tail so the bar continues
    // along the perspective lane extension past the judgment line.
    final rawHeadProgress = headY / judgeY;
    final tailProgress = (rawHeadProgress - barLenFraction).clamp(0.0, 1.0);
    final tailY = judgeY * tailProgress;

    final headLaneX = _perspX(lane, rawHeadProgress, screenW);
    final headActualW = _perspLaneW(rawHeadProgress, screenW) * 0.72;
    final tailLaneX = _perspX(lane, tailProgress, screenW);
    final tailLaneW = _perspLaneW(tailProgress, screenW);
    final tailW = tailLaneW * 0.72;
    final headW = headActualW;

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
      if (notes[i].isPreamble) continue;
      final j = results[i];
      if (j != null && j != Judgement.miss) continue;
      final spawnMs = notes[i].hitTimeMs + _judgeOffsetMs - travelMs;
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

      final lane = _toLane(effect.angle);
      final laneX = _perspX(lane, 1.0, screenW);
      final laneW = _perspLaneW(1.0, screenW);
      final isPerfect = effect.judgement == Judgement.perfect;
      final isGood = effect.judgement == Judgement.good;

      // ── Instant flash (PERFECT / GOOD only) ──────────────────────
      if (effect.judgement != Judgement.miss) {
        final flashT = (t * 6.0).clamp(0.0, 1.0);
        final flashA = (1.0 - flashT).clamp(0.0, 1.0);
        final flashColor = isPerfect ? _neonGold : _neonCyan;
        // Solid core glow
        canvas.drawCircle(
          Offset(laneX, judgeY),
          laneW * 0.9 * (1.0 - flashT * 0.4),
          Paint()
            ..color = flashColor.withAlpha((flashA * 160).toInt())
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
        );
        // Wide ambient glow
        canvas.drawCircle(
          Offset(laneX, judgeY),
          laneW * 2.5,
          Paint()
            ..color = flashColor.withAlpha((flashA * 55).toInt())
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22),
        );
      }

      // ── Ring bursts (PERFECT / GOOD) ──────────────────────────────
      if (effect.judgement != Judgement.miss) {
        final ringColor = isPerfect ? _neonGold : _neonCyan;
        // Primary ring
        final r1T = (t * 2.2).clamp(0.0, 1.0);
        final r1A = (1.0 - r1T).clamp(0.0, 1.0);
        canvas.drawCircle(
          Offset(laneX, judgeY),
          laneW * (0.4 + r1T * 2.0),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4.0 * (1.0 - r1T * 0.7)
            ..color = ringColor.withAlpha((r1A * 230).toInt())
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
        // Secondary outer ring
        final r2Color = isPerfect ? _neonGold : _neonCyan;
        final r2Alpha = isPerfect ? 150 : 70;
        final r2T = (t * 1.4).clamp(0.0, 1.0);
        final r2A = (1.0 - r2T).clamp(0.0, 1.0);
        canvas.drawCircle(
          Offset(laneX, judgeY),
          laneW * (0.8 + r2T * 3.2),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = isPerfect ? 2.0 : 1.0
            ..color = r2Color.withAlpha((r2A * r2Alpha).toInt()),
        );
      }

      // ── Star particles ────────────────────────────────────────────
      if (isPerfect || isGood) {
        // Inner dots: 8 for PERFECT, 4 for GOOD (subdued)
        final nDots = isPerfect ? 8 : 4;
        final dotSize = isPerfect ? 4.5 : 2.5;
        final dotAlpha = isPerfect ? 255 : 110;
        final dotColor = isPerfect ? _neonGold : _neonCyan;
        final pt = (t * 2.4).clamp(0.0, 1.0);
        final r = laneW * (0.5 + pt * 2.2);
        final pa = (1.0 - pt).clamp(0.0, 1.0);
        for (var k = 0; k < nDots; k++) {
          final a = k * 2 * pi / nDots - pi / 2;
          canvas.drawCircle(
            Offset(laneX + cos(a) * r, judgeY + sin(a) * r),
            dotSize * (1.0 - pt * 0.5),
            Paint()
              ..color = dotColor.withAlpha((pa * dotAlpha).toInt())
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
          );
        }
        // Outer diamond dots: PERFECT only
        if (isPerfect) {
          final pt2 = (t * 1.8).clamp(0.0, 1.0);
          final r2 = laneW * (1.0 + pt2 * 3.0);
          final pa2 = (1.0 - pt2).clamp(0.0, 1.0);
          for (var k = 0; k < 4; k++) {
            final a = k * 2 * pi / 4;
            canvas.drawCircle(
              Offset(laneX + cos(a) * r2, judgeY + sin(a) * r2),
              3.0 * (1.0 - pt2 * 0.6),
              Paint()
                ..color = Colors.white.withAlpha((pa2 * 220).toInt())
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
            );
          }
        }
      }

      // ── Judgment text ─────────────────────────────────────────────
      final String label;
      final Color labelColor;
      final double fontSize;
      if (isPerfect) {
        label = 'PERFECT';
        labelColor = _neonGold;
        fontSize = 22;
      } else if (isGood) {
        label = 'GOOD';
        labelColor = _neonCyan;
        fontSize = 19;
      } else {
        label = 'MISS';
        labelColor = const Color(0xFFFF6B6B);
        fontSize = 16;
      }

      // Scale pop: 1.5 → 1.0 over first 20%, hold, fade in last 35%
      final scale = 1.0 + 0.5 * (1.0 - (t / 0.20).clamp(0.0, 1.0));
      final opacity = t < 0.65
          ? 1.0
          : (1.0 - (t - 0.65) / 0.35).clamp(0.0, 1.0);
      final rise = t * 72.0;

      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: labelColor.withAlpha((opacity * 255).toInt()),
            fontSize: fontSize,
            fontWeight: FontWeight.w900,
            letterSpacing: 2.5,
            shadows: [
              Shadow(
                offset: const Offset(1.5, 1.5),
                color: Colors.black.withAlpha((opacity * 200).toInt()),
                blurRadius: 0,
              ),
              Shadow(
                offset: const Offset(-1.5, -1.5),
                color: Colors.black.withAlpha((opacity * 200).toInt()),
                blurRadius: 0,
              ),
              Shadow(
                color: labelColor.withAlpha((opacity * 240).toInt()),
                blurRadius: 18,
              ),
              Shadow(
                color: labelColor.withAlpha((opacity * 130).toInt()),
                blurRadius: 40,
              ),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      tp.layout();

      canvas.save();
      canvas.translate(laneX, judgeY - rise - 14);
      canvas.scale(scale);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _GamePainter old) =>
      displayMs != old.displayMs ||
      notes.length != old.notes.length ||
      results.length != old.results.length ||
      effects.length != old.effects.length ||
      holdStartMs.length != old.holdStartMs.length ||
      travelMs != old.travelMs;
}
