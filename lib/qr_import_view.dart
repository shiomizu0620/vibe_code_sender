import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'encoder.dart';
import 'main.dart' show SenderPage;
import 'supabase_service.dart';

/// QRから取り出した文字列をどう送るかの判定結果。
///
/// 「QR（光・カメラ）→ 振動の楽譜」のブリッジでは、新しい符号化は作らず
/// 既存パイプライン（X1 / id方式）の入口に振り分けるだけ。判定はここに集約し、
/// カメラ非依存で単体テストできるよう純粋ロジックに切り出している
/// （[classifyScannedText] 参照）。
sealed class QrScanResult {
  const QrScanResult();
}

/// QRの中身がURLとして扱えない（明らかな非URL・空など）。送信しない。
class QrRejected extends QrScanResult {
  const QrRejected(this.reason);

  /// ユーザー向けの理由（そのまま画面表示してよい短文）。
  final String reason;
}

/// 短URL → X1（URL直接・自己完結）で送る。Supabase登録は不要。
class QrX1 extends QrScanResult {
  const QrX1(this.url);

  /// X1で符号化して送るURL（[encodeUrl] が通ることを確認済み）。
  final String url;
}

/// 長い／X1非対応のURL → id方式（Supabaseに登録して発行したidを送る）。
class QrIdMode extends QrScanResult {
  const QrIdMode(this.url);

  /// Supabaseに登録する元URL。
  final String url;
}

/// QRから読み取った生文字列を検証し、送信モードを決める純粋ロジック。
///
/// 振り分け方針（CLAUDE.md / 既存パイプライン準拠）:
///   1. URLらしくない文字列は弾く（[QrRejected]）。
///   2. X1で符号化できる（短く・小文字URL）なら X1（[QrX1]）。
///   3. X1で送れない（長すぎ／大文字など未対応文字）なら id方式（[QrIdMode]）。
///
/// 「短い/長い」を文字数の閾値で決めず、**実際に [encodeUrl] が通るか**で判定する。
/// X1のフレーム長・文字テーブル（[encodeUrl] の制約）が唯一の正であり、ここに
/// 別の閾値を持つと二重管理になるため。
QrScanResult classifyScannedText(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    return const QrRejected('QRコードが空でした');
  }
  if (!_looksLikeUrl(text)) {
    return const QrRejected('URLのQRコードではありません');
  }
  // X1で符号化できればそのまま自己完結で送れる（短URL）。できなければ id方式へ。
  try {
    encodeUrl(text);
    return QrX1(text);
  } on FormatException {
    // 大文字・未対応記号などX1テーブル外。id方式なら任意文字列を登録できる。
    return QrIdMode(text);
  } on ArgumentError {
    // 本体長が x1MaxLength 超過（長URL）。id方式へ。
    return QrIdMode(text);
  }
}

/// 文字列がURLとして妥当そうかの最小判定。
///
/// `http(s)://` 付きはスキーム＋ホストで判定。スキーム無しは「ドメインらしさ」
/// （空白を含まず、ドット区切りのホストで始まる）で判定する。これにより
/// `github.com/a` のようなスキーム省略URL（X1の既定 https 扱い）は許容しつつ、
/// 普通の文章や単語は弾く。
bool _looksLikeUrl(String text) {
  if (text.contains(RegExp(r'\s'))) return false;
  final lower = text.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    final uri = Uri.tryParse(text);
    return uri != null && uri.host.isNotEmpty;
  }
  // スキーム無し: `ドメイン.tld` で始まり、任意でパス/クエリ/ポート等が続く形のみ。
  // 末尾 $ まで検証しないと `example.com@@@` のような文字列が先頭一致で通り、
  // 非URLを reject できなくなる（部分一致禁止）。
  return RegExp(
    r'^[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z0-9\-]+)*\.[a-z]{2,}([/:?#][^\s]*)?$',
  ).hasMatch(lower);
}

/// QR読み取り画面。カメラ or 画像からQR（URL内包）を読み、取り出したURLを
/// 既存のencoder（X1 / id方式）に流して楽譜（[SenderPage]）へ繋ぐブリッジ。
class QrImportPage extends StatefulWidget {
  const QrImportPage({super.key, SupabaseService? service, ImagePicker? picker})
    : _service = service,
      _picker = picker;

  final SupabaseService? _service;
  final ImagePicker? _picker;

  @override
  State<QrImportPage> createState() => _QrImportPageState();
}

class _QrImportPageState extends State<QrImportPage> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    // 1枚目を読めたら十分。連続検出は使わない。
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  late final SupabaseService _service = widget._service ?? SupabaseService();
  late final ImagePicker _picker = widget._picker ?? ImagePicker();

  /// 演奏画面へ遷移中・登録中はカメラの連続検出を無視するためのロック。
  bool _handling = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// カメラがQRを検出したときのコールバック。最初の有効値だけ処理する。
  void _onDetect(BarcodeCapture capture) {
    if (_handling) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.isNotEmpty) {
        _dispatch(value);
        return;
      }
    }
  }

  /// 画像ファイル（ギャラリー）からQRを読み込む。
  ///
  /// `pickImage` / `analyzeImage` は await を挟むため、開始時点でロックを取る。
  /// そうしないと選択・解析中にカメラ側の [_onDetect] が走り、復帰後に二重処理
  /// （registerUrl の重複・二重遷移）になりうる。プラグイン呼び出しは
  /// PlatformException / MobileScannerException を投げうるので捕捉して通知に倒す。
  Future<void> _pickFromImage() async {
    if (_handling) return;
    setState(() => _handling = true);
    try {
      final XFile? file = await _picker.pickImage(source: ImageSource.gallery);
      if (!mounted) return;
      if (file == null) {
        // キャンセル。ロックを解いて元の状態へ。
        _stopHandling();
        return;
      }
      final BarcodeCapture? result = await _controller.analyzeImage(file.path);
      if (!mounted) return;
      final value = result?.barcodes
          .map((b) => b.rawValue)
          .firstWhere((v) => v != null && v.isNotEmpty, orElse: () => null);
      if (value == null) {
        _showMessage('画像からQRコードを読み取れませんでした');
        _stopHandling();
        return;
      }
      await _dispatch(value);
    } catch (e, st) {
      // 画像選択/解析の失敗（権限拒否・非対応形式・プラグイン内部エラー等）が
      // 上位へ伝播して操作が中断しないよう、ここで握ってユーザー通知に倒す。
      debugPrint('QR: 画像読み取りに失敗: $e\n$st');
      _showMessage('画像の読み取りに失敗しました');
      _stopHandling();
    }
  }

  /// 読み取れた文字列を検証し、モードを振り分けて演奏画面へ。
  ///
  /// ロックは呼び出し元（[_onDetect] は未取得・[_pickFromImage] は取得済み）に
  /// 関わらずここで確実に立てる。reject 時は解除し、遷移時は復帰後に解除する。
  Future<void> _dispatch(String raw) async {
    if (!_handling) setState(() => _handling = true);
    final result = classifyScannedText(raw);
    switch (result) {
      case QrRejected(:final reason):
        _showMessage(reason);
        _stopHandling();
      case QrX1(:final url):
        // 短URLはX1で自己完結（id を渡さない＝URL直接専用で開く）。
        await _openSender(SenderPage(url: url));
      case QrIdMode(:final url):
        await _openIdMode(url);
    }
  }

  /// 処理ロックを解除する（マウント済みのときのみ）。
  void _stopHandling() {
    if (!mounted) return;
    setState(() => _handling = false);
  }

  /// 長URLをSupabaseに登録してidを発行し、id方式で演奏画面へ。
  Future<void> _openIdMode(String url) async {
    _showMessage('長いURLのため登録しています…');
    try {
      final id = await _service.registerUrl(url);
      if (!mounted) return;
      await _openSender(SenderPage(id: id, url: url));
    } catch (e, st) {
      debugPrint('QR: URL登録に失敗: $e\n$st');
      if (!mounted) return;
      _showMessage('登録に失敗しました。通信状況を確認してください。');
      _stopHandling();
    }
  }

  /// 演奏画面へ遷移し、戻ってきたら再びスキャン可能にする。
  Future<void> _openSender(Widget page) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
    _stopHandling();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: theme.colorScheme.inversePrimary,
        title: const Text('VibeCode — QR読み取り'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                  onDetectError: (error, _) => debugPrint('QR: 検出エラー: $error'),
                ),
                _ScanOverlay(busy: _handling),
              ],
            ),
          ),
          _QrGuidePanel(busy: _handling, onPickImage: _pickFromImage),
        ],
      ),
    );
  }
}

/// 読み取り枠（四隅ブラケット）と処理中オーバーレイ。カメラ映像の上に重ねる。
///
/// カメラ非依存に切り出してあるので、プレビュー（[QrImportPreview]）でも
/// そのまま再利用できる。
class _ScanOverlay extends StatelessWidget {
  const _ScanOverlay({required this.busy});

  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // 「ここに合わせる」を伝える四隅ブラケット。
        const IgnorePointer(
          child: CustomPaint(
            size: Size(240, 240),
            painter: _ScanFramePainter(color: Colors.white),
          ),
        ),
        if (busy)
          const ColoredBox(
            color: Colors.black54,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 12),
                  Text('読み取り中…', style: TextStyle(color: Colors.white)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 下部パネル: 読み取り後の振り分けルールを明示し、画像読み取りへ導く。
class _QrGuidePanel extends StatelessWidget {
  const _QrGuidePanel({required this.busy, required this.onPickImage});

  /// 処理中（カメラ/画像の解析・遷移中）。画像読み取りボタンを無効化する。
  final bool busy;
  final VoidCallback onPickImage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.qr_code_scanner, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'URLのQRコードをかざすと楽譜になります',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: busy ? null : onPickImage,
            icon: const Icon(Icons.image),
            label: const Text('画像から読み取る'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ],
      ),
    );
  }
}

/// QR読み取り画面の**カメラ非依存プレビュー**（カメラ映像の代わりに暗色背景）。
///
/// 実機なしで見た目を確認するための導線。実際の [_ScanOverlay] / [_QrGuidePanel]
/// をそのまま使うので、本番画面と同じ枠・チップ・パネルが描画される。
class QrImportPreview extends StatelessWidget {
  const QrImportPreview({super.key, this.busy = false});

  /// 処理中オーバーレイ（読み取り中…）を表示するか。
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: theme.colorScheme.inversePrimary,
        title: const Text('VibeCode — QR読み取り（プレビュー）'),
      ),
      body: Column(
        children: [
          Expanded(
            child: ColoredBox(
              color: const Color(0xFF202124), // カメラ映像の代わりの暗色背景
              child: _ScanOverlay(busy: busy),
            ),
          ),
          _QrGuidePanel(busy: busy, onPickImage: () {}),
        ],
      ),
    );
  }
}

/// 読み取り枠の四隅ブラケットを描く CustomPainter。
///
/// プレーンな矩形より「ここに合わせる」が伝わり、カメラ映像の上でも視認しやすい。
class _ScanFramePainter extends CustomPainter {
  const _ScanFramePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    const arm = 28.0; // 各ブラケットの腕の長さ
    final w = size.width;
    final h = size.height;
    canvas
      ..drawPath(
        Path()
          ..moveTo(0, arm)
          ..lineTo(0, 0)
          ..lineTo(arm, 0),
        paint,
      ) // 左上
      ..drawPath(
        Path()
          ..moveTo(w - arm, 0)
          ..lineTo(w, 0)
          ..lineTo(w, arm),
        paint,
      ) // 右上
      ..drawPath(
        Path()
          ..moveTo(0, h - arm)
          ..lineTo(0, h)
          ..lineTo(arm, h),
        paint,
      ) // 左下
      ..drawPath(
        Path()
          ..moveTo(w - arm, h)
          ..lineTo(w, h)
          ..lineTo(w, h - arm),
        paint,
      ); // 右下
  }

  @override
  bool shouldRepaint(_ScanFramePainter oldDelegate) =>
      oldDelegate.color != color;
}
