import 'pattern_builder.dart';

/// id(0..255) を [Pulse] 列に変換する（モードマーカー + 8bit MSB first）。
///
/// フレーム構成（PROTOCOL.md v1.0 idモード）:
///   [モードマーカー 0=short] + [id 8bit MSB first] → 計9打
///
/// id が 0〜255 の範囲外の場合は [RangeError] を投げる。
List<Pulse> encode(int id) {
  if (id < 0 || id > 255) {
    throw RangeError.range(id, 0, 255, 'id');
  }
  return [
    Pulse.short, // モードマーカー 0 = idモード
    for (var i = 7; i >= 0; i--)
      (id >> i) & 1 == 1 ? Pulse.long : Pulse.short,
  ];
}
