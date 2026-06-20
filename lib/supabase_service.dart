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

  /// 登録済み URL を id の昇順（若い番号が先）で取得する。
  Future<List<UrlEntry>> fetchUrls() async {
    final rows = await _client
        .from(_table)
        .select()
        .order('id', ascending: true);
    return rows.map(UrlEntry.fromMap).toList();
  }

  /// [url] を登録し、発行された id（0〜255）を返す。
  ///
  /// 既存 id を取得し、空き候補（0〜255 − 既存）を**重複なしでシャッフル**して
  /// 順に挿入を試みる。ランダム順だが同じ id を二度引かないため、空きがある限り
  /// 確実に成功する。挿入直前に他クライアントが同じ id を取った場合（主キー衝突）
  /// は次の候補へ進む。空きが無い場合のみ [StateError] を投げる。
  Future<int> registerUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(url, 'url', 'URL が空です');
    }
    final taken = await _fetchTakenIds();
    final free = [
      for (var id = 0; id <= _idMax; id++)
        if (!taken.contains(id)) id,
    ]..shuffle(_random);
    if (free.isEmpty) {
      throw StateError('空き id がありません（0〜255 がすべて使用済み）');
    }
    for (final id in free) {
      try {
        await _client.from(_table).insert({'id': id, 'url': trimmed});
        return id;
      } on PostgrestException catch (e) {
        // 23505 = unique_violation。取得後に他クライアントが取った場合のみ。次の候補へ。
        if (e.code == '23505') continue;
        rethrow;
      }
    }
    // 走査中に空きが全て他クライアントに取られた（競合が続いた）場合のみ到達。
    throw StateError('空き id の確保に失敗しました（登録の競合が続きました）');
  }

  /// 使用済み id の集合を取得する。
  Future<Set<int>> _fetchTakenIds() async {
    final rows = await _client.from(_table).select('id');
    return {for (final row in rows) row['id'] as int};
  }
}
