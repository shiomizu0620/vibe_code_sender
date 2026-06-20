import 'package:device_preview/device_preview.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'constants.dart';
import 'encoder.dart';
import 'game_view.dart';
import 'pattern_builder.dart';
import 'score_view.dart';
import 'supabase_service.dart';
import 'vibrator_service.dart';

/// Supabase 接続情報。anon key のみ。コミットせず `--dart-define-from-file`
/// 等で外から渡す（CLAUDE.md セキュリティ方針: service_role key は持ち込まない）。
const String _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const String _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var ready = false;
  // Web では supabase_flutter が passkey(Web認証)用の第三者JSを要求し、未読込だと
  // 初期化が失敗してタブごと落ちる。Web はテスト用途（device_preview で X1 UI 確認）
  // なので Supabase 初期化をスキップし、_ConfigNeededPage のテスト導線へ誘導する。
  if (!kIsWeb && _supabaseUrl.isNotEmpty && _supabaseAnonKey.isNotEmpty) {
    try {
      // 我々が扱うのは anon key（JWT）。publishableKey は新形式キー用のため、
      // anon key に対応する anonKey 引数を使う（将来 anon key 廃止時に見直し）。
      // ignore: deprecated_member_use
      await Supabase.initialize(url: _supabaseUrl, anonKey: _supabaseAnonKey);
      ready = true;
    } catch (e, st) {
      // 起動時の外部初期化は失敗し得る（ネットワーク不通・鍵不正など）。
      // ここで握りつぶさずに throw すると runApp 前なのでアプリが起動しない。
      // 未設定扱いにしてフォールバック画面で起動を継続する。
      debugPrint('Supabase 初期化に失敗しました: $e\n$st');
    }
  }
  runApp(
    DevicePreview(
      // テスト用。Web のデバッグ時のみ端末プレビューを有効化し、
      // 実機/リリースビルドには影響させない（kReleaseMode で除外）。
      enabled: kIsWeb && !kReleaseMode,
      builder: (context) => VibeCodeApp(configured: ready),
    ),
  );
}

class VibeCodeApp extends StatelessWidget {
  const VibeCodeApp({super.key, required this.configured});

  /// Supabase の接続情報が渡されているか。
  final bool configured;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VibeCode Sender',
      // device_preview 連携（無効時は no-op として透過する）。
      locale: DevicePreview.locale(context),
      builder: DevicePreview.appBuilder,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: configured ? const _RootShell() : const _ConfigNeededPage(),
    );
  }
}

class _RootShell extends StatefulWidget {
  const _RootShell();

  @override
  State<_RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<_RootShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: const [UrlListPage(), X1DirectPage(), GameView()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.vibration), label: '演奏'),
          NavigationDestination(icon: Icon(Icons.link), label: 'URL直接'),
          NavigationDestination(icon: Icon(Icons.sports_esports), label: 'ゲーム'),
        ],
      ),
    );
  }
}

/// X1（URL直接符号化）専用画面。登録不要で任意の短URLをそのまま演奏する。
///
/// id方式（Supabase逆引き）と異なり DB を介さないため、ここで打った URL を
/// [SenderPage]（X1専用＝idなし）へ渡して演奏する。
class X1DirectPage extends StatefulWidget {
  const X1DirectPage({super.key});

  @override
  State<X1DirectPage> createState() => _X1DirectPageState();
}

class _X1DirectPageState extends State<X1DirectPage> {
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _open() {
    final url = _controller.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'URL を入力してください');
      return;
    }
    // 演奏画面へ渡す前に符号化可否を検証（未対応文字・長さ超過をここで弾く）。
    try {
      encodeUrl(url);
    } on FormatException {
      setState(() => _error = 'X1で送れない文字が含まれます（小文字URLのみ対応）');
      return;
    } on ArgumentError catch (e) {
      // 本体が空 / 長すぎ など。エンコーダのメッセージをそのまま表示。
      setState(() => _error = 'X1で送れません: ${e.message}');
      return;
    }
    setState(() => _error = null);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        // id を渡さない＝X1専用で開く（モード切替トグルは出さない）。
        builder: (_) => SenderPage(url: url),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('VibeCode — URL直接 (X1)'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '登録不要で短URLをそのまま振動で送ります（X1モード）。\n'
                  '小文字のみ・本体は最大 $x1MaxLength 文字。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _controller,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: '送る URL（小文字）',
                    hintText: 'github.com',
                    border: const OutlineInputBorder(),
                    errorText: _error,
                  ),
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  onSubmitted: (_) => _open(),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _open,
                  icon: const Icon(Icons.vibration),
                  label: const Text('演奏画面を開く'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Supabase が未設定、または初期化に失敗したときの案内画面。
///
/// デバッグビルドでは Supabase を介さず SenderPage（X1 トグル）を直接開ける
/// テスト導線を表示する（Web + device_preview での UI 確認用）。
class _ConfigNeededPage extends StatefulWidget {
  const _ConfigNeededPage();

  @override
  State<_ConfigNeededPage> createState() => _ConfigNeededPageState();
}

class _ConfigNeededPageState extends State<_ConfigNeededPage> {
  final TextEditingController _testUrlController = TextEditingController(
    text: 'github.com',
  );

  @override
  void dispose() {
    _testUrlController.dispose();
    super.dispose();
  }

  void _openTestSender() {
    final raw = _testUrlController.text.trim();
    final url = raw.isEmpty ? 'github.com' : raw;
    // SenderPage は initState で encodeUrl(url) を呼ぶため、不正URLのまま渡すと
    // ビルドがクラッシュする。X1DirectPage と同様にここで事前検証して弾く。
    try {
      encodeUrl(url);
    } on FormatException {
      _showTestError('X1で送れない文字が含まれます（小文字URLのみ対応）');
      return;
    } on ArgumentError catch (e) {
      _showTestError('X1で送れません: ${e.message}');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        // X1（URL直接）専用で開く（id なし）。
        builder: (_) => SenderPage(url: url),
      ),
    );
  }

  void _showTestError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('VibeCode Sender')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Supabase に接続できません。\n'
                  '--dart-define-from-file=env.json で\n'
                  'SUPABASE_URL / SUPABASE_ANON_KEY を渡し、\n'
                  'ネットワークと鍵を確認してください。',
                  textAlign: TextAlign.center,
                ),
                if (kDebugMode) ...[
                  const SizedBox(height: 32),
                  const Divider(),
                  const SizedBox(height: 16),
                  Text(
                    'テスト用（Supabase不要・X1確認）',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _testUrlController,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'テストURL（小文字）',
                      hintText: 'github.com',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _openTestSender(),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _openTestSender,
                    icon: const Icon(Icons.vibration),
                    label: const Text('演奏画面を開く（X1テスト）'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// F9: URL一覧 + 登録画面。登録すると id が発行され、選ぶと演奏画面へ。
class UrlListPage extends StatefulWidget {
  const UrlListPage({super.key, SupabaseService? service}) : _service = service;

  final SupabaseService? _service;

  @override
  State<UrlListPage> createState() => _UrlListPageState();
}

class _UrlListPageState extends State<UrlListPage> {
  late final SupabaseService _service = widget._service ?? SupabaseService();
  final TextEditingController _urlController = TextEditingController();

  late Future<List<UrlEntry>> _future;
  bool _registering = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _refresh() {
    setState(() {
      _future = _service.fetchUrls().catchError((Object e, StackTrace st) {
        // 詳細はログへ。画面には FutureBuilder 側で定型文を出す。
        debugPrint('URL一覧の取得に失敗: $e\n$st');
        Error.throwWithStackTrace(e, st);
      });
    });
  }

  Future<void> _register() async {
    final url = _urlController.text.trim();
    if (url.isEmpty || _registering) return;
    setState(() => _registering = true);
    try {
      final id = await _service.registerUrl(url);
      if (!mounted) return;
      _urlController.clear();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('登録しました → id: $id')));
      _refresh();
    } catch (e, st) {
      debugPrint('URL登録に失敗: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('登録に失敗しました。通信状況を確認して再度お試しください。')),
      );
    } finally {
      if (mounted) setState(() => _registering = false);
    }
  }

  void _openPlayer(UrlEntry entry) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SenderPage(id: entry.id, url: entry.url),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('VibeCode — URL一覧'),
        actions: [
          IconButton(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: '再読み込み',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '登録する URL',
                      hintText: 'https://example.com',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _register(),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _registering ? null : _register,
                  child: _registering
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('登録'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<UrlEntry>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('読み込みに失敗しました。通信状況を確認してください。'),
                    ),
                  );
                }
                final entries = snapshot.data ?? const [];
                if (entries.isEmpty) {
                  return const Center(child: Text('まだURLがありません。上から登録してください。'));
                }
                return ListView.separated(
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final entry = entries[i];
                    return ListTile(
                      leading: CircleAvatar(child: Text('${entry.id}')),
                      title: Text(
                        entry.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openPlayer(entry),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

enum _Phase { idle, preamble, playing, auto, done }

/// 送信モード。[id]=従来のidモード（marker=0）/ [urlDirect]=X1モード（marker=1）。
enum _SendMode { id, urlDirect }

/// 演奏画面。選択した URL の [id] を楽譜化し、手動（F5）/ 自動（F6）で演奏する。
///
/// id は URL一覧での選択で確定するため、ここでは編集せず表示のみ（F7 の
/// id入力欄は一覧選択に置き換わった）。
class SenderPage extends StatefulWidget {
  const SenderPage({super.key, this.id, this.url})
    : assert(id != null || url != null, 'id か url のどちらかは必須');

  /// 演奏対象の id（0〜255）。X1専用（URL直接タブ）で開く場合は null。
  /// null のときは id方式トグル・id表示を出さず、X1（URL直接）固定で演奏する。
  final int? id;

  /// 逆引き元の URL（表示用・X1の符号化対象）。
  final String? url;

  /// id を持たない＝X1（URL直接）専用で開かれたか。
  bool get isUrlOnly => id == null;

  @override
  State<SenderPage> createState() => _SenderPageState();
}

class _SenderPageState extends State<SenderPage> {
  final VibratorService _vibrator = VibratorService();

  bool? _hasVibrator;

  // X1専用（id なし）で開かれたら urlDirect 固定。それ以外は従来どおり id 方式から。
  late _SendMode _mode = widget.isUrlOnly ? _SendMode.urlDirect : _SendMode.id;
  late List<Pulse> _pulses = widget.isUrlOnly
      ? encodeUrl(widget.url!)
      : encode(widget.id!);
  int _cursor = 0;
  _Phase _phase = _Phase.idle;
  bool _vibrating = false; // 振動中は連打を無視する
  final Set<int> _mistakes = {};

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
    // 振動開始とほぼ同時刻から計時し、カーソルは「絶対経過時間」で進める。
    // 1打ずつ delay を積み上げると微小誤差が蓄積し、打数の多い X1 では実振動と
    // カーソルがずれる。毎ステップ Stopwatch に再同期して蓄積ドリフトを防ぐ。
    final clock = Stopwatch()..start();

    const preambleMs = (preambleOnMs + preambleOffMs) * preambleRepeat;
    // 各打が「鳴り終わる」絶対時刻を積算し、その時刻にカーソルを i+1 へ進める。
    var elapsedTargetMs = preambleMs;
    for (var i = 0; i < _pulses.length; i++) {
      final onMs = _pulses[i] == Pulse.long ? longMs : shortMs;
      elapsedTargetMs += onMs;
      final waitMs = elapsedTargetMs - clock.elapsedMilliseconds;
      if (waitMs > 0) {
        await Future.delayed(Duration(milliseconds: waitMs));
      }
      if (!mounted || _phase != _Phase.auto) return;
      setState(() => _cursor = i + 1);
      elapsedTargetMs += gapMs; // 次の打の前に gap を挟む
    }

    await playback;
    if (!mounted || _phase != _Phase.auto) return;
    setState(() => _phase = playbackFailed ? _Phase.idle : _Phase.done);
  }

  void _playShort() {
    if (_vibrating) return;
    if (_pulses[_cursor] != Pulse.short) _mistakes.add(_cursor);
    _lockFor(shortMs);
    _vibrator.play(<int>[0, shortMs]);
    _advance();
  }

  void _playLong() {
    if (_vibrating) return;
    if (_pulses[_cursor] != Pulse.long) _mistakes.add(_cursor);
    _lockFor(longMs);
    _vibrator.play(<int>[0, longMs]);
    _advance();
  }

  void _lockFor(int ms) {
    setState(() => _vibrating = true);
    // gapMs を足して最低限の間隔を強制 → 連続振動が繋がってlongに誤判定されるのを防ぐ
    Future.delayed(Duration(milliseconds: ms + gapMs), () {
      if (!mounted) return;
      setState(() => _vibrating = false);
    });
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
    _vibrating = false;
    _mistakes.clear();
  });

  /// 送信モードを切り替え、対応する [_pulses] を再計算して演奏状態をリセットする。
  ///
  /// URL直接（X1）は [widget.url] を [encodeUrl] で符号化する。符号化できない場合
  /// （未対応文字・長さ超過）はモードを変えずに SnackBar で通知する。
  void _setMode(_SendMode mode) {
    if (mode == _mode) return;
    List<Pulse> next;
    if (mode == _SendMode.urlDirect) {
      final url = widget.url;
      if (url == null) return; // URL不明ならX1不可（ボタン側でも無効化済み）
      try {
        next = encodeUrl(url);
      } on FormatException catch (e) {
        _showModeError('このURLはX1で送れません: ${e.message}');
        return;
      } on ArgumentError catch (e) {
        _showModeError('このURLはX1で送れません: ${e.message}');
        return;
      }
    } else {
      final id = widget.id;
      if (id == null) return; // X1専用で開いた場合は id 方式へ切替不可
      next = encode(id);
    }
    setState(() {
      _mode = mode;
      _pulses = next;
      _cursor = 0;
      _phase = _Phase.idle;
      _vibrating = false;
      _mistakes.clear();
    });
  }

  void _showModeError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final hasVibrator = _hasVibrator;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('VibeCode Sender'),
      ),
      // 楽譜は X1（URL直接）で打数が増えると縦に長くなる。収まる時は中央寄せ、
      // あふれる時はスクロールできるようにして overflow を防ぐ。
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - 48,
              ),
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
              if (widget.url != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    widget.url!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (!widget.isUrlOnly) ...[
                Text(
                  'id: ${widget.id}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                _buildModeSelector(context),
              ] else
                Text(
                  'URL直接モード (X1)',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              const SizedBox(height: 16),
              ScoreView(pulses: _pulses, cursor: _cursor, mistakes: _mistakes),
              const SizedBox(height: 8),
              _StatusLine(
                phase: _phase,
                cursor: _cursor,
                total: _pulses.length,
                mistakeCount: _mistakes.length,
              ),
              const SizedBox(height: 32),
              _buildButtons(context),
              const SizedBox(height: 16),
                  TextButton(onPressed: _reset, child: const Text('リセット')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 送信モード切替（id方式 ↔ URL直接/X1）の最小トグル。
  ///
  /// URL不明（[widget.url] が null）や再生中（preamble/auto）は切替不可。
  Widget _buildModeSelector(BuildContext context) {
    final canSwitch =
        widget.url != null &&
        _phase != _Phase.preamble &&
        _phase != _Phase.auto;
    return SegmentedButton<_SendMode>(
      segments: const [
        ButtonSegment<_SendMode>(
          value: _SendMode.id,
          label: Text('id方式'),
          icon: Icon(Icons.tag),
        ),
        ButtonSegment<_SendMode>(
          value: _SendMode.urlDirect,
          label: Text('URL直接'),
          icon: Icon(Icons.link),
        ),
      ],
      selected: {_mode},
      onSelectionChanged: canSwitch
          ? (selection) => _setMode(selection.first)
          : null,
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
          ElevatedButton(
            onPressed: _vibrating ? null : _playShort,
            child: const Text('● 短'),
          ),
          const SizedBox(width: 16),
          ElevatedButton(
            onPressed: _vibrating ? null : _playLong,
            child: const Text('━ 長'),
          ),
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
    this.mistakeCount = 0,
  });

  final _Phase phase;
  final int cursor;
  final int total;
  final int mistakeCount;

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
          mistakeCount == 0 ? '演奏完了！' : '演奏完了！ ミス $mistakeCount打',
          key: const ValueKey('done'),
          style: TextStyle(
            color: mistakeCount == 0
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.error,
            fontWeight: FontWeight.bold,
          ),
        ),
      },
    );
  }
}
