import 'package:device_preview/device_preview.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'constants.dart';
import 'encoder.dart';
import 'game_view.dart';
import 'pattern_builder.dart';
import 'qr_import_view.dart';
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

  void _onTabChanged(int i) {
    setState(() => _tab = i);
    if (i == 3) {
      // ゲームタブ（index 3）のみ横向き。
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          const UrlListPage(),
          const X1DirectPage(),
          // QRタブはカメラを使う。IndexedStack は全タブを常駐させるため、
          // 画面外でカメラを起動しないよう、アクティブな時だけマウントする
          // （離れると破棄＝カメラ停止）。
          _tab == 2 ? const QrImportPage() : const SizedBox.shrink(),
          GameView(onNavigateBack: () => _onTabChanged(0)),
        ],
      ),
      // ゲームタブ（index 3）ではナビバーを隠す（F13: 全画面ゲーム）。
      bottomNavigationBar: _tab == 3
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: _onTabChanged,
              destinations: const [
                NavigationDestination(icon: Icon(Icons.vibration), label: '演奏'),
                NavigationDestination(icon: Icon(Icons.link), label: 'URL入力'),
                NavigationDestination(
                  icon: Icon(Icons.qr_code_scanner),
                  label: 'QR',
                ),
                NavigationDestination(
                  icon: Icon(Icons.sports_esports),
                  label: 'ゲーム',
                ),
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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 現在の入力URLを X1 で符号化した場合のプレビュー（送信可否・スキーム・本体長）。
  ///
  /// 入力のたびに [encodeUrl] を試し、可否と理由を [_X1Preview] にまとめる。
  /// 文字数カウンタ用の本体長は [encodeUrl] と同じスキーム除去ルールで数える。
  /// 入力が空のときは null（プレビュー非表示）。
  _X1Preview? _preview() {
    final url = _controller.text.trim();
    if (url.isEmpty) return null;
    final scheme = url.startsWith('http://') ? 'http' : 'https';
    final body = url.startsWith('https://')
        ? url.substring('https://'.length)
        : url.startsWith('http://')
        ? url.substring('http://'.length)
        : url;
    try {
      encodeUrl(url);
      return _X1Preview(canSend: true, scheme: scheme, bodyLen: body.length);
    } on FormatException {
      return _X1Preview(
        canSend: false,
        scheme: scheme,
        bodyLen: body.length,
        message: '送れない文字が含まれます（小文字のURLのみ対応）',
      );
    } on ArgumentError {
      // エンコーダ内部のメッセージ（"X1"/"本体" 等の用語を含む）はそのまま見せず、
      // 長さ超過か否かで一般向けの理由に置き換える。
      return _X1Preview(
        canSend: false,
        scheme: scheme,
        bodyLen: body.length,
        message: body.length > x1MaxLength
            ? 'URLが長すぎます（最大 $x1MaxLength 文字）'
            : '送れないURLです',
      );
    }
  }

  void _open() {
    if (!(_preview()?.canSend ?? false)) return; // ボタン無効化済みだが二重防御。
    final url = _controller.text.trim();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        // id を渡さない＝X1専用で開く（モード切替トグルは出さない）。
        builder: (_) => SenderPage(url: url),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = _preview();
    final canSend = preview?.canSend ?? false;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: theme.colorScheme.inversePrimary,
        title: const Text('VibeCode — 登録なしで送信'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Card(
              elevation: 0,
              color: theme.colorScheme.surfaceContainerHighest,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ヘッダ: どのモードで送るかを明示。
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: theme.colorScheme.primaryContainer,
                          foregroundColor: theme.colorScheme.onPrimaryContainer,
                          child: const Icon(Icons.link),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '登録なしで送信',
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _controller,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _open(),
                      decoration: InputDecoration(
                        labelText: '送る URL（小文字）',
                        hintText: 'github.com',
                        prefixIcon: const Icon(Icons.public),
                        filled: true,
                        fillColor: theme.colorScheme.surface,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _X1StatusPanel(preview: preview),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: canSend ? _open : null,
                      icon: const Icon(Icons.vibration),
                      label: const Text('演奏画面を開く'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// X1入力の符号化プレビュー結果（送信可否・スキーム・本体文字数）。
class _X1Preview {
  const _X1Preview({
    required this.canSend,
    required this.scheme,
    required this.bodyLen,
    this.message,
  });

  /// X1で送信できるか（[encodeUrl] が通ったか）。
  final bool canSend;

  /// 判定したスキーム表示（'https' / 'http'）。
  final String scheme;

  /// 本体（スキーム除去後）の文字数。[x1MaxLength] との対比に使う。
  final int bodyLen;

  /// 送れない理由（[canSend] が false のとき）。
  final String? message;
}

/// 入力URLの X1 送信可否・スキーム・本体文字数を視覚化する小パネル。
class _X1StatusPanel extends StatelessWidget {
  const _X1StatusPanel({required this.preview});

  final _X1Preview? preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = preview;
    if (p == null) {
      return Text(
        '小文字のみ・最大 $x1MaxLength 文字まで',
        style: theme.textTheme.bodySmall,
      );
    }
    final color = p.canSend
        ? theme.colorScheme.primary
        : theme.colorScheme.error;
    final overLength = p.bodyLen > x1MaxLength;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              p.canSend ? Icons.check_circle : Icons.error,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                p.canSend ? 'このURLはそのまま送れます' : (p.message ?? '送れません'),
                style: theme.textTheme.bodyMedium?.copyWith(color: color),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _MiniChip(
              icon: p.scheme == 'https' ? Icons.lock : Icons.lock_open,
              label: p.scheme,
            ),
            _MiniChip(
              icon: Icons.straighten,
              label: '長さ ${p.bodyLen} / $x1MaxLength 文字',
              warning: overLength,
            ),
          ],
        ),
      ],
    );
  }
}

/// 角丸の小さな情報チップ（スキーム・文字数などのメタ表示用）。
class _MiniChip extends StatelessWidget {
  const _MiniChip({
    required this.icon,
    required this.label,
    this.warning = false,
  });

  final IconData icon;
  final String label;

  /// 注意表示（文字数超過など）。true で配色を error に寄せる。
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = warning
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 4),
          Text(label, style: theme.textTheme.labelMedium?.copyWith(color: fg)),
        ],
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
      _showTestError('送れない文字が含まれます（小文字のURLのみ対応）');
      return;
    } on ArgumentError {
      _showTestError('登録なしで送れないURLです');
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
                    'テスト用（Supabase不要・登録なしで送信）',
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
                    label: const Text('演奏画面を開く（テスト）'),
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

  @override
  void dispose() {
    // 自動演奏中に戻る/画面遷移しても振動が鳴り続けないよう、離脱時に打ち切る。
    _vibrator.cancel();
    super.dispose();
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

  void _reset() {
    // 自動演奏は端末側で長いパターンを再生し続けるため、状態リセットだけでは
    // 振動が止まらない。実際の振動を打ち切ってから UI を初期化する。
    _vibrator.cancel();
    setState(() {
      _cursor = 0;
      _phase = _Phase.idle;
      _vibrating = false;
      _mistakes.clear();
    });
  }

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
      } on FormatException {
        _showModeError('このURLは登録なしで送れません（登録ありに切り替えてください）');
        return;
      } on ArgumentError {
        _showModeError('このURLは登録なしで送れません（登録ありに切り替えてください）');
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
                      '番号: ${widget.id}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    _buildModeSelector(context),
                  ] else
                    Text(
                      '登録なしで送信',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  const SizedBox(height: 16),
                  ScoreView(
                    pulses: _pulses,
                    cursor: _cursor,
                    mistakes: _mistakes,
                  ),
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
          label: Text('登録あり'),
          icon: Icon(Icons.tag),
        ),
        ButtonSegment<_SendMode>(
          value: _SendMode.urlDirect,
          label: Text('登録なし'),
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
        label: const Text('はじめの合図を送信中...'),
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
        _Phase.idle => const Text('はじめの合図を送ってから演奏を始めます', key: ValueKey('idle')),
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
