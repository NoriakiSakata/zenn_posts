---
title: "PostgreSQLの複雑なJOINクエリで重複が発生した原因と解決"
emoji: "🐘"
type: "tech"
topics: ["postgresql", "sql", "join", "performance", "optimization"]
published: true
---

## はじめに

ショップ検索APIを実装中、同じショップが複数回返される問題に遭遇しました。この記事では、その原因と解決方法を紹介します。

## 問題の発生

ショップ検索API（`/api/v1/app/shops/search`）を呼び出すと、**同じショップが5回重複して返される**問題が発生していました。

```json
{
  "shops": [
    {"id": "shop1", "name": "FUJI STORE"},
    {"id": "shop1", "name": "FUJI STORE"},  // ← 重複
    {"id": "shop1", "name": "FUJI STORE"},  // ← 重複
    {"id": "shop1", "name": "FUJI STORE"},  // ← 重複
    {"id": "shop1", "name": "FUJI STORE"},  // ← 重複
    {"id": "shop2", "name": "OTHER SHOP"}
  ]
}
```

## 原因の調査

### データベース構造

ショップは複数の属性（スタイル、特徴、時代、性別など）と多対多の関係を持っています：

```sql
-- ショップテーブル
CREATE TABLE shops (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    -- ...
);

-- リレーションテーブル（例：スタイル）
CREATE TABLE shop_style_relations (
    shop_id TEXT REFERENCES shops(id),
    style_id TEXT,
    PRIMARY KEY (shop_id, style_id)
);
```

### 問題のあったクエリ

最初の実装では、複数のリレーションテーブルを`LEFT JOIN`で結合していました：

```sql
SELECT s.id, s.name, s.instagram, -- ...
FROM shops s
LEFT JOIN shop_style_relations ssr ON s.id = ssr.shop_id
LEFT JOIN shop_feature_relations sfr ON s.id = sfr.shop_id
LEFT JOIN shop_era_relations ser ON s.id = ser.shop_id
-- ... 他のリレーション
WHERE
    ($1::text[] IS NULL OR ssr.style_id = ANY($1::text[]))
    AND ($2::text[] IS NULL OR sfr.feature_id = ANY($2::text[]))
    -- ...
GROUP BY s.id, s.name, s.instagram, -- ... 全てのカラムを列挙
ORDER BY s.created_at DESC
LIMIT $18 OFFSET $19
```

### なぜ重複が発生したのか

1つのショップが複数のスタイルや特徴を持っている場合、`LEFT JOIN`により**行が増幅**されます。

例：ショップAが「スタイル1」と「スタイル2」を持ち、「特徴1」と「特徴2」を持つ場合：

```
shops:        shop_style_relations:    shop_feature_relations:
id  name      shop_id  style_id        shop_id  feature_id
A   FUJI      A        style1          A        feature1
              A        style2          A        feature2
```

`LEFT JOIN`を実行すると：

```
shop_id  name   style_id  feature_id
A        FUJI   style1    feature1
A        FUJI   style1    feature2
A        FUJI   style2    feature1
A        FUJI   style2    feature2
```

**4行に増幅されます！** これが重複の原因でした。

## 解決方法

### 方法1: EXISTSサブクエリを使用（採用）

`LEFT JOIN`の代わりに`EXISTS`サブクエリを使用することで、行の増幅を防ぎます：

```sql
SELECT s.id, s.name, s.instagram, -- ...
FROM shops s
WHERE
    ($1::text[] IS NULL OR EXISTS (
        SELECT 1 FROM shop_style_relations ssr
        WHERE ssr.shop_id = s.id
        AND ssr.style_id = ANY($1::text[])
    ))
    AND ($2::text[] IS NULL OR EXISTS (
        SELECT 1 FROM shop_feature_relations sfr
        WHERE sfr.shop_id = s.id
        AND sfr.feature_id = ANY($2::text[])
    ))
    -- ... 他の条件
ORDER BY s.created_at DESC
LIMIT $18 OFFSET $19
```

**メリット:**
- 行が増幅されない（1ショップ = 1行）
- `GROUP BY`が不要
- パフォーマンスが向上する可能性がある（インデックスが効きやすい）

**デメリット:**
- クエリが長くなる
- 複数の`EXISTS`サブクエリが実行される

### 方法2: DISTINCT ONを使用

`DISTINCT ON`を使用して重複を排除する方法もあります：

```sql
SELECT DISTINCT ON (s.id) s.id, s.name, s.instagram, -- ...
FROM shops s
LEFT JOIN shop_style_relations ssr ON s.id = ssr.shop_id
LEFT JOIN shop_feature_relations sfr ON s.id = sfr.shop_id
-- ...
WHERE
    ($1::text[] IS NULL OR ssr.style_id = ANY($1::text[]))
    AND ($2::text[] IS NULL OR sfr.feature_id = ANY($2::text[]))
ORDER BY s.id, s.created_at DESC
LIMIT $18 OFFSET $19
```

**注意点:**
- `ORDER BY`の最初のカラムは`DISTINCT ON`で指定したカラムである必要がある
- パフォーマンスが劣る可能性がある（全ての行を生成してから重複を排除するため）

### 方法3: GROUP BY + HAVING（元の実装の改善）

元の`LEFT JOIN` + `GROUP BY`のアプローチを改善する方法：

```sql
SELECT s.id, s.name, s.instagram, -- ...
FROM shops s
LEFT JOIN shop_style_relations ssr ON s.id = ssr.shop_id
    AND ($1::text[] IS NULL OR ssr.style_id = ANY($1::text[]))
LEFT JOIN shop_feature_relations sfr ON s.id = sfr.shop_id
    AND ($2::text[] IS NULL OR sfr.feature_id = ANY($2::text[]))
-- ...
WHERE
    -- 基本条件
GROUP BY s.id, s.name, s.instagram, -- ... 全てのカラム
HAVING
    ($1::text[] IS NULL OR bool_or(ssr.style_id IS NOT NULL))
    AND ($2::text[] IS NULL OR bool_or(sfr.feature_id IS NOT NULL))
ORDER BY s.created_at DESC
LIMIT $18 OFFSET $19
```

**ポイント:**
- `JOIN`の条件にフィルタを追加（`AND`句）
- `HAVING`句で`bool_or()`を使用して、マッチしたリレーションが存在するか確認

## 実際の修正

今回のケースでは、**方法3（GROUP BY + HAVING）**を採用しました。理由は以下の通りです：

1. **既存のクエリ構造を大きく変更せずに済む**
2. **複数のリレーションを効率的に処理できる**
3. **パフォーマンスが良好**

### 修正前

```sql
SELECT s.id, s.name, s.instagram, -- ...
FROM shops s
LEFT JOIN shop_style_relations ssr ON s.id = ssr.shop_id
LEFT JOIN shop_feature_relations sfr ON s.id = sfr.shop_id
-- ...
WHERE
    ($1::text[] IS NULL OR ssr.style_id = ANY($1::text[]))
    AND ($2::text[] IS NULL OR sfr.feature_id = ANY($2::text[]))
GROUP BY s.id, s.name, s.instagram, -- ... 全てのカラム
ORDER BY s.created_at DESC
LIMIT $18 OFFSET $19
```

### 修正後

```sql
SELECT s.id, s.name, s.instagram, -- ...
FROM shops s
LEFT JOIN shop_style_relations ssr ON s.id = ssr.shop_id
    AND ($1::text[] IS NULL OR ssr.style_id = ANY($1::text[]))
LEFT JOIN shop_feature_relations sfr ON s.id = sfr.shop_id
    AND ($2::text[] IS NULL OR sfr.feature_id = ANY($2::text[]))
-- ...
WHERE
    -- 基本条件（pref_id, city_id, is_closed など）
GROUP BY s.id, s.name, s.instagram, -- ... 全てのカラム
HAVING
    ($1::text[] IS NULL OR bool_or(ssr.style_id IS NOT NULL))
    AND ($2::text[] IS NULL OR bool_or(sfr.feature_id IS NOT NULL))
ORDER BY s.created_at DESC
LIMIT $18 OFFSET $19
```

**重要な変更点:**
1. `JOIN`の条件にフィルタを追加（`AND`句で条件を指定）
2. `WHERE`句からリレーションの条件を削除
3. `HAVING`句で`bool_or()`を使用して、マッチしたリレーションが存在するか確認

## パフォーマンスの比較

### 実行計画の確認

`EXPLAIN ANALYZE`を使用して、クエリの実行計画を確認しました：

**修正前（WHERE句でフィルタ）:**
```
Hash Join  (cost=... rows=...)
  -> Seq Scan on shops s
  -> Hash
      -> Hash Join  (cost=... rows=...)
          -> Seq Scan on shop_style_relations
          -> Seq Scan on shop_feature_relations
  -> Group
```

**修正後（HAVING句でフィルタ）:**
```
Hash Join  (cost=... rows=...)
  -> Seq Scan on shops s
  -> Hash
      -> Index Scan using shop_style_relations_shop_id_idx
      -> Index Scan using shop_feature_relations_shop_id_idx
  -> Group
  -> Filter: (HAVING句の条件)
```

`HAVING`句を使用することで、インデックスを効率的に使用できるようになりました。

## インデックスの最適化

パフォーマンスを向上させるため、以下のインデックスを追加しました：

```sql
-- リレーションテーブルにインデックスを追加
CREATE INDEX idx_shop_style_relations_shop_id 
ON shop_style_relations(shop_id);

CREATE INDEX idx_shop_style_relations_style_id 
ON shop_style_relations(style_id);

-- 複合インデックス（shop_id + style_id）も有効
CREATE INDEX idx_shop_style_relations_shop_style 
ON shop_style_relations(shop_id, style_id);
```

## まとめ

- **複数の多対多リレーションを`LEFT JOIN`で結合すると、行が増幅される**
- **`JOIN`の条件にフィルタを追加し、`HAVING`句で`bool_or()`を使用することで、重複を防げる**
- **適切なインデックスを追加することで、パフォーマンスが向上する**
- **`EXISTS`サブクエリも有効な選択肢だが、複数のリレーションがある場合は`GROUP BY + HAVING`の方が効率的な場合がある**

## 参考

- [PostgreSQL EXISTS vs JOIN](https://www.postgresql.org/docs/current/functions-subquery.html#FUNCTIONS-SUBQUERY-EXISTS)
- [PostgreSQL Performance Tips](https://www.postgresql.org/docs/current/performance-tips.html)
- [PostgreSQL GROUP BY and HAVING](https://www.postgresql.org/docs/current/tutorial-agg.html)
