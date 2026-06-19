import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';

/// `urls` テーブルの1行を表すモデル。
class UrlEntry {
  const UrlEntry({required this.id, required this.url, this.createdAt});

  /// id（8bit・0〜255）。振動で送られる本体。
  final int id;

  /// 逆引き先の URL。
  final String url;

  /// 登録日時（一覧の並び替え用）。
  final DateTime? createdAt;

  factory UrlEntry.fromMap(Map<String, dynamic> map) {
    final created = map['created_at'];
    return UrlEntry(
      id: map['id'] as int,
      url: map['url'] as String,
      createdAt: created == null ? null : DateTime.parse(created as String),
    );
  }
}

/// Supabase の `urls` テーブルへのアクセス（URL登録 / id発行 / 一覧取得）。
///
/// PROTOCOL.md v1.0 より id は 8bit（0〜255）固定。発行は**ランダム**で行い、
/// 主キー衝突（既存id）したら別の値で再試行する。アプリに渡してよいのは
/// anon key のみで、service_role key は絶対に持ち込まない（CLAUDE.md セキュリティ方針）。
class SupabaseService {
  SupabaseService({SupabaseClient? client, Random? random})
    : _client = client ?? Supabase.instance.client,
      _random = random ?? Random();

  final SupabaseClient _client;
  final Random _random;

  static const String _table = 'urls';

  /// id の上限（8bit）。
  static const int _idMax = 255;

  /// ランダム発行の再試行上限（埋まりすぎ検出用）。
  static const int _maxRetries = 32;

  /// 登録済み URL を新しい順で取得する。
  Future<List<UrlEntry>> fetchUrls() async {
    final rows = await _client
        .from(_table)
        .select()
        .order('created_at', ascending: false);
    return rows.map(UrlEntry.fromMap).toList();
  }

  /// [url] を登録し、発行された id（0〜255）を返す。
  ///
  /// id は 0〜255 のランダム。主キー衝突したら別の値で再試行する。
  /// 256件近く埋まっていて空きが見つからない場合は [StateError] を投げる。
  Future<int> registerUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(url, 'url', 'URL が空です');
    }
    for (var attempt = 0; attempt < _maxRetries; attempt++) {
      final id = _random.nextInt(_idMax + 1); // 0..255
      try {
        await _client.from(_table).insert({'id': id, 'url': trimmed});
        return id;
      } on PostgrestException catch (e) {
        // 23505 = unique_violation（id 重複）。重複なら別idで再試行、他はそのまま投げる。
        if (e.code == '23505') continue;
        rethrow;
      }
    }
    throw StateError('空き id が見つかりませんでした（0〜255 がほぼ埋まっています）');
  }
}
