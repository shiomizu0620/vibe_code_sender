import 'dart:math';

import 'package:flutter/foundation.dart';

import 'constants.dart';
import 'encoder.dart';
import 'pattern_builder.dart';
import 'vibrator_service.dart';

/// 判定窓（ミリ秒）。hitTime との差の絶対値で判定する。
///
/// 値は調整しやすいよう定数化（issue: Perfect±40ms / Good±90ms）。
const int perfectWindowMs = 100;
const int goodWindowMs = 200;

/// 打ち方の種類。tap=短押し（150ms）、hold=長押し（450ms/プリアンブル700ms）。
enum NoteType { tap, hold }

/// 入力タイミングの判定結果。
enum Judgement { perfect, good, miss }

/// 演奏モード。
/// - [hybrid]: 人間の実入力が振動を出す（体験の主役）。
/// - [auto]: 譜面どおりに自動で振動（デモ保険・受信チューニング基準）。
enum GameMode { hybrid, auto }

/// ゲームの進行状態。
enum GameState { idle, playing, paused, finished }

/// 譜面上の1音。UI描画と判定の両方が参照する不変データ。
@immutable
class Note {
  const Note({
    required this.type,
    required this.bit,
    required this.hitTimeMs,
    required this.durationMs,
    required this.angle,
    required this.isPreamble,
  });

  /// 打ち方（tap/hold）。
  final NoteType type;

  /// この音が表すデータビット（0/1）。プリアンブルは null。
  /// モードマーカーは 0（short）。
  final int? bit;

  /// 信号開始からの「叩くべき時刻」（ms）。ON の開始時刻。
  final int hitTimeMs;

  /// ON の長さ（ms）。short=150 / long=450 / preamble=700。
  final int durationMs;

  /// UI 配置用の角度（ラジアン）。譜面順に円周上へ等間隔配置。
  final double angle;

  /// プリアンブル音か。
  final bool isPreamble;

  /// hold（長押し）の場合に離すべき時刻（ms）。
  int get releaseTimeMs => hitTimeMs + durationMs;

  @override
  String toString() =>
      'Note(${type.name}, bit:$bit, hit:$hitTimeMs, dur:$durationMs, '
      'preamble:$isPreamble)';
}

/// id から譜面（[Note] 列）を生成する。
///
/// 構成（PROTOCOL.md v1.0 idモード）:
///   プリアンブル[700ms ON,200ms OFF]×2 → モードマーカー1bit(short) → id 8bit(MSB first)
/// 各音の ON の後には必ず OFF（休符）を入れる。プリアンブルは 200ms、データは [gapMs]。
///
/// 振動の正確さ最優先のため、プリアンブルは見た目は「長2連」でも実時間は
/// PROTOCOL 準拠の [preambleOnMs]=700ms で出す（データの long=450ms とは別物）。
List<Note> buildChart(int id) {
  // 各音を (durationMs, restMs, bit, isPreamble) で並べる。
  final symbols = <_Symbol>[
    for (var i = 0; i < preambleRepeat; i++)
      const _Symbol(
        durationMs: preambleOnMs,
        restMs: preambleOffMs,
        bit: null,
        isPreamble: true,
      ),
    for (final pulse in encode(id))
      _Symbol(
        durationMs: pulse == Pulse.long ? longMs : shortMs,
        restMs: gapMs,
        bit: pulse == Pulse.long ? 1 : 0,
        isPreamble: false,
      ),
  ];

  final notes = <Note>[];
  var cursorMs = 0;
  for (var i = 0; i < symbols.length; i++) {
    final s = symbols[i];
    notes.add(
      Note(
        type: s.durationMs >= longMs ? NoteType.hold : NoteType.tap,
        bit: s.bit,
        hitTimeMs: cursorMs,
        durationMs: s.durationMs,
        angle: 2 * pi * i / symbols.length,
        isPreamble: s.isPreamble,
      ),
    );
    cursorMs += s.durationMs + s.restMs;
  }
  return notes;
}

/// 入力時刻と目標時刻の差から判定する純粋関数。
///
/// 差の絶対値が [perfectWindowMs] 以内なら Perfect、[goodWindowMs] 以内なら Good、
/// それを超えたら Miss。境界値は「以内」（<=）で含む。
Judgement judgeHit(int expectedMs, int actualMs) {
  final diff = (actualMs - expectedMs).abs();
  if (diff <= perfectWindowMs) return Judgement.perfect;
  if (diff <= goodWindowMs) return Judgement.good;
  return Judgement.miss;
}

class _Symbol {
  const _Symbol({
    required this.durationMs,
    required this.restMs,
    required this.bit,
    required this.isPreamble,
  });
  final int durationMs;
  final int restMs;
  final int? bit;
  final bool isPreamble;
}

/// 演奏ゲームの心臓部。譜面・実時間クロック・判定・振動制御を担う。
///
/// **UI（描画）から独立**: クロックは外部の実時間 ticker から [tick] で
/// 経過 msを受け取るだけで、描画フレーム数には依存しない。振動は固定長を
/// [VibratorService.play] に渡して実時間タイマで一発出す。
class GameController extends ChangeNotifier {
  GameController({
    required VibratorService vibrator,
    this.mode = GameMode.hybrid,
  }) : _vibrator = vibrator;

  final VibratorService _vibrator;

  /// 演奏モード（hybrid/auto）。[setMode] で切替。
  GameMode mode;

  List<Note> _notes = const [];
  GameState _state = GameState.idle;
  int _elapsedMs = 0;
  int _cursor = 0; // 次に判定/自動発火する音のindex
  final Map<int, Judgement> _results = {};

  List<Note> get notes => List.unmodifiable(_notes);
  GameState get state => _state;
  int get elapsedMs => _elapsedMs;
  int get cursor => _cursor;
  Map<int, Judgement> get results => Map.unmodifiable(_results);

  /// 譜面全体の終了時刻（最後の音が離れる時刻）。
  int get chartEndMs => _notes.isEmpty ? 0 : _notes.last.releaseTimeMs;

  /// id を読み込んで譜面を作り、idle に戻す。
  void load(int id) {
    _notes = buildChart(id);
    reset();
  }

  void setMode(GameMode value) {
    mode = value;
    notifyListeners();
  }

  void start() {
    if (_notes.isEmpty) return;
    _state = GameState.playing;
    notifyListeners();
  }

  void pause() {
    if (_state == GameState.playing) {
      _state = GameState.paused;
      notifyListeners();
    }
  }

  void reset() {
    _state = GameState.idle;
    _elapsedMs = 0;
    _cursor = 0;
    _results.clear();
    notifyListeners();
  }

  /// 外部の実時間クロック（Ticker 等）から経過msを受け取る。
  ///
  /// auto モードでは、経過が音の hitTime に達するたびに固定長振動を発火する。
  /// 描画フレームではなく実時間に基づくため、フレーム落ちの影響を受けない。
  void tick(int elapsedMs) {
    if (_state != GameState.playing) return;
    _elapsedMs = elapsedMs;

    if (mode == GameMode.auto) {
      while (_cursor < _notes.length &&
          _notes[_cursor].hitTimeMs <= elapsedMs) {
        _fire(_notes[_cursor]);
        _results[_cursor] = Judgement.perfect; // 機械発火は常に正確
        _cursor++;
      }
    }

    if (elapsedMs >= chartEndMs) {
      _state = GameState.finished;
    }
    notifyListeners();
  }

  /// ハイブリッド: 入力 down。現在の対象音を hitTime と比べて判定し、振動する。
  /// 判定結果を返す（対象音が無ければ null）。
  Judgement? onInputDown(int atMs) {
    if (_state != GameState.playing || mode != GameMode.hybrid) return null;
    if (_cursor >= _notes.length) return null;
    final note = _notes[_cursor];
    final judgement = judgeHit(note.hitTimeMs, atMs);
    _results[_cursor] = judgement;
    if (judgement != Judgement.miss) {
      _fire(note);
    }
    _cursor++;
    if (_cursor >= _notes.length) _state = GameState.finished;
    notifyListeners();
    return judgement;
  }

  /// 固定長の振動を実時間タイマで一発出す（描画と独立）。
  void _fire(Note note) {
    _vibrator.play(<int>[0, note.durationMs]);
  }
}
