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
  // スキーム無し: 先頭が `ドメイン.tld`（英数とハイフン、最後にドット＋2文字以上）。
  return RegExp(
    r'^[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z0-9\-]+)*\.[a-z]{2,}',
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
        _handleScanned(value);
        return;
      }
    }
  }

  /// 画像ファイル（ギャラリー）からQRを読み込む。
  Future<void> _pickFromImage() async {
    if (_handling) return;
    final XFile? file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null || !mounted) return;
    final BarcodeCapture? result = await _controller.analyzeImage(file.path);
    if (!mounted) return;
    final value = result?.barcodes
        .map((b) => b.rawValue)
        .firstWhere((v) => v != null && v.isNotEmpty, orElse: () => null);
    if (value == null) {
      _showMessage('画像からQRコードを読み取れませんでした');
      return;
    }
    _handleScanned(value);
  }

  /// 読み取れた文字列を検証し、モードを振り分けて演奏画面へ。
  Future<void> _handleScanned(String raw) async {
    setState(() => _handling = true);
    final result = classifyScannedText(raw);
    switch (result) {
      case QrRejected(:final reason):
        _showMessage(reason);
        setState(() => _handling = false);
      case QrX1(:final url):
        // 短URLはX1で自己完結（id を渡さない＝URL直接専用で開く）。
        await _openSender(SenderPage(url: url));
      case QrIdMode(:final url):
        await _openIdMode(url);
    }
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
      setState(() => _handling = false);
    }
  }

  /// 演奏画面へ遷移し、戻ってきたら再びスキャン可能にする。
  Future<void> _openSender(Widget page) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
    if (!mounted) return;
    setState(() => _handling = false);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
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
                // 読み取り枠のガイド。
                IgnorePointer(
                  child: Container(
                    width: 220,
                    height: 220,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white70, width: 2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                if (_handling)
                  const ColoredBox(
                    color: Colors.black45,
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'URLのQRコードをカメラにかざすと楽譜になります。\n'
                  '短いURLはX1（直接）、長いURLは登録してid方式で送ります。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _handling ? null : _pickFromImage,
                  icon: const Icon(Icons.image),
                  label: const Text('画像から読み取る'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
