import 'package:vibration/vibration.dart';

/// 振動ハードウェアへのアクセスを一手に引き受けるサービス。
///
/// `vibration` パッケージへの依存をこのクラスに閉じ込め、上位層
/// （UI・encoder・pattern_builder）はプラットフォーム差を意識しない。
/// コードは Android / iOS 共通で、プラットフォーム分岐は持たない。
class VibratorService {
  VibratorService({this.amplitude = 255}) {
    if (amplitude < 1 || amplitude > 255) {
      throw ArgumentError.value(
        amplitude,
        'amplitude',
        '振幅は 1〜255 の範囲で指定してください',
      );
    }
  }

  /// ONパルスの振動の強さ（振幅）。1〜255。255 が最大。
  ///
  /// 端末が振幅制御（[Vibration.hasAmplitudeControl]）に対応している場合のみ
  /// 反映される。既定振幅は中程度で弱く感じるため、最大の 255 を既定値にする。
  /// プロトコル定数ではない（受信側と共有不要）ため [constants] には置かない。
  final int amplitude;

  /// 端末が振動モーターを備えているか。
  Future<bool> hasVibrator() => Vibration.hasVibrator();

  /// カスタム振動（duration / pattern 指定）に対応しているか。
  ///
  /// iOS では CoreHaptics 対応機（iPhone 8 以降）で true になる。
  Future<bool> hasCustomVibrationsSupport() =>
      Vibration.hasCustomVibrationsSupport();

  /// 生のパターン配列 `[待ち, 振動, 待ち, 振動, ...]`（ミリ秒）を再生する。
  ///
  /// 振動非対応の端末では何もしない。振幅制御対応機では各ONパルスを
  /// [amplitude] の強さで振動させる（非対応機は端末の既定振幅で再生）。
  Future<void> play(List<int> pattern) async {
    if (!await Vibration.hasVibrator()) return;
    if (await Vibration.hasAmplitudeControl()) {
      // pattern は [待ち, 振動, ...]。偶数index=待ちは振幅0、奇数index=振動は最大に。
      final intensities = <int>[
        for (var i = 0; i < pattern.length; i++) i.isOdd ? amplitude : 0,
      ];
      await Vibration.vibrate(pattern: pattern, intensities: intensities);
      return;
    }
    await Vibration.vibrate(pattern: pattern);
  }
}
