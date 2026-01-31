---
title: "PostgreSQLのN+1クエリ問題を解決して検索処理を高速化した話"
emoji: "⚡"
type: "tech"
topics: ["postgresql", "go", "performance", "optimization", "n-plus-one"]
published: true
---

## はじめに

ショップ検索APIのパフォーマンスが悪く、レスポンスタイムが数秒かかることがありました。調査の結果、**N+1クエリ問題**が原因であることが判明しました。この記事では、その問題と解決方法を紹介します。

## 問題の発生

ショップ検索API（`/api/v1/app/shops/search`）を呼び出すと、**レスポンスタイムが3〜5秒**かかることがありました。特に、検索結果が10件以上返される場合に顕著でした。

```bash
# 検索結果が20件の場合
$ time curl "https://api.example.com/shops/search?limit=20"
# 実行時間: 3.5秒
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

### 問題のあったコード

最初の実装では、各ショップに対して個別にリレーションをロードしていました：

```go
func (r *Postgres) Search(ctx context.Context, params *domain.ShopSearchParams) ([]*domain.Shop, error) {
    // メインクエリでショップを取得
    shops, err := r.queryShops(ctx, params)
    if err != nil {
        return nil, err
    }

    // 各ショップに対して個別にリレーションをロード ← 問題！
    for _, shop := range shops {
        shop.StyleIDs, _ = r.loadRelationIDs(ctx, shop.ID, "shop_style_relations", "style_id")
        shop.FeatureIDs, _ = r.loadRelationIDs(ctx, shop.ID, "shop_feature_relations", "feature_id")
        shop.EraIDs, _ = r.loadRelationIDs(ctx, shop.ID, "shop_era_relations", "era_id")
        shop.SourcingCountryIDs, _ = r.loadRelationIDs(ctx, shop.ID, "shop_sourcing_country_relations", "country_id")
        shop.GenderIDs, _ = r.loadRelationIDs(ctx, shop.ID, "shop_gender_relations", "gender_id")
        shop.StoreTypeIDs, _ = r.loadRelationIDs(ctx, shop.ID, "shop_store_type_relations", "store_type_id")
        shop.AreaIDs, _ = r.loadRelationIDs(ctx, shop.ID, "shop_area_relations", "area_id")
    }

    return shops, nil
}

func (r *Postgres) loadRelationIDs(ctx context.Context, shopID, tableName, idColumn string) ([]string, error) {
    query := fmt.Sprintf("SELECT %s FROM %s WHERE shop_id = $1", idColumn, tableName)
    rows, err := r.pool.Query(ctx, query, shopID)
    // ...
}
```

### N+1クエリ問題とは

この実装では、以下のようなクエリが実行されます：

1. **メインクエリ**: ショップ一覧を取得（1クエリ）
2. **各ショップに対して7つのリレーションクエリ**: スタイル、特徴、時代、仕入国、性別、店舗タイプ、エリア

**例：検索結果が20件の場合**
- メインクエリ: 1回
- リレーションクエリ: 20件 × 7種類 = **140回**

**合計: 141クエリ！**

これが**N+1クエリ問題**です。

## 解決方法：バッチロード

### 修正後のコード

全てのショップに対して、各リレーションを一度のクエリで取得するように変更しました：

```go
func (r *Postgres) Search(ctx context.Context, params *domain.ShopSearchParams) ([]*domain.Shop, error) {
    // メインクエリでショップを取得
    shops, err := r.queryShops(ctx, params)
    if err != nil {
        return nil, err
    }

    // 全ショップのリレーションをバッチでロード ← 改善！
    if err := r.loadAllRelationsBatch(ctx, shops); err != nil {
        return nil, err
    }

    return shops, nil
}

// loadAllRelationsBatch loads all relationship IDs for multiple shops in batch
func (r *Postgres) loadAllRelationsBatch(ctx context.Context, shops []*domain.Shop) error {
    if len(shops) == 0 {
        return nil
    }

    // ショップIDのリストを作成
    shopIDs := make([]string, len(shops))
    for i, shop := range shops {
        shopIDs[i] = shop.ID
    }

    // 各リレーションをバッチで取得
    styleMap, err := r.loadStyleIDsBatch(ctx, shopIDs)
    if err != nil {
        return fmt.Errorf("failed to load style IDs: %w", err)
    }

    featureMap, err := r.loadFeatureIDsBatch(ctx, shopIDs)
    if err != nil {
        return fmt.Errorf("failed to load feature IDs: %w", err)
    }

    // ... 他のリレーションも同様

    // 各ショップにリレーションIDを割り当て
    for _, shop := range shops {
        shop.StyleIDs = styleMap[shop.ID]
        shop.FeatureIDs = featureMap[shop.ID]
        // ... 他のリレーションも同様
    }

    return nil
}

// loadStyleIDsBatch loads style IDs for multiple shops in a single query
func (r *Postgres) loadStyleIDsBatch(ctx context.Context, shopIDs []string) (map[string][]string, error) {
    if len(shopIDs) == 0 {
        return make(map[string][]string), nil
    }

    query := `SELECT shop_id, style_id FROM shop_style_relations WHERE shop_id = ANY($1::text[])`
    rows, err := r.pool.Query(ctx, query, shopIDs)
    if err != nil {
        return nil, err
    }
    defer rows.Close()

    result := make(map[string][]string)
    for rows.Next() {
        var shopID, styleID string
        if err := rows.Scan(&shopID, &styleID); err != nil {
            return nil, err
        }
        result[shopID] = append(result[shopID], styleID)
    }

    return result, nil
}
```

### クエリ数の比較

**修正前（検索結果20件の場合）:**
- メインクエリ: 1回
- リレーションクエリ: 20件 × 7種類 = 140回
- **合計: 141クエリ**

**修正後（検索結果20件の場合）:**
- メインクエリ: 1回
- リレーションクエリ: 7回（各リレーションを1回ずつ）
- **合計: 8クエリ**

**約17.6倍の改善！**

## パフォーマンスの改善

### レスポンスタイムの比較

| 検索結果件数 | 修正前 | 修正後 | 改善率 |
|------------|--------|--------|--------|
| 10件 | 1.5秒 | 0.2秒 | **7.5倍** |
| 20件 | 3.5秒 | 0.3秒 | **11.7倍** |
| 50件 | 8.0秒 | 0.5秒 | **16.0倍** |

検索結果が多くなるほど、改善効果が大きくなります。

### データベース負荷の軽減

- **クエリ数の削減**: 141クエリ → 8クエリ（20件の場合）
- **ネットワーク往復の削減**: データベースへの接続回数が大幅に減少
- **コネクションプールの効率化**: 接続の再利用が効率的に

## 実装のポイント

### 1. ANY句を使用したバッチクエリ

PostgreSQLの`ANY`句を使用して、複数のIDを一度に検索します：

```sql
SELECT shop_id, style_id 
FROM shop_style_relations 
WHERE shop_id = ANY($1::text[])
```

### 2. マップを使用した結果の割り当て

バッチクエリの結果を`map[string][]string`に格納し、各ショップに割り当てます：

```go
result := make(map[string][]string)
for rows.Next() {
    var shopID, styleID string
    rows.Scan(&shopID, &styleID)
    result[shopID] = append(result[shopID], styleID)
}

// 各ショップに割り当て
for _, shop := range shops {
    shop.StyleIDs = result[shop.ID]
}
```

### 3. 空のスライスの初期化

リレーションが存在しないショップに対しては、空のスライスを返すようにします：

```go
for _, shop := range shops {
    shop.StyleIDs = styleMap[shop.ID]
    if shop.StyleIDs == nil {
        shop.StyleIDs = []string{}  // nilではなく空スライス
    }
}
```

## AWS Lambda環境での注意点

当初、バッチクエリを並列実行（goroutine）で実装していましたが、**AWS Lambda + RDS Proxy環境では並列実行が問題を引き起こす**ことがありました。

```go
// 並列実行（問題があった実装）
var wg sync.WaitGroup
wg.Add(7)
go func() { defer wg.Done(); styleMap, _ = r.loadStyleIDsBatch(ctx, shopIDs) }()
go func() { defer wg.Done(); featureMap, _ = r.loadFeatureIDsBatch(ctx, shopIDs) }()
// ...
wg.Wait()
```

そのため、**順次実行**に変更しました：

```go
// 順次実行（現在の実装）
styleMap, err := r.loadStyleIDsBatch(ctx, shopIDs)
if err != nil {
    return err
}
featureMap, err := r.loadFeatureIDsBatch(ctx, shopIDs)
if err != nil {
    return err
}
// ...
```

順次実行でも、クエリ数が大幅に削減されるため、十分なパフォーマンス改善が得られます。

## まとめ

- **N+1クエリ問題**は、検索結果が多くなるほど深刻になる
- **バッチロード**を使用することで、クエリ数を大幅に削減できる
- PostgreSQLの`ANY`句を使用して、複数のIDを一度に検索する
- AWS Lambda環境では、並列実行よりも順次実行の方が安全な場合がある
- この最適化により、**レスポンスタイムが10倍以上改善**した

## 参考

- [N+1 Query Problem](https://stackoverflow.com/questions/97197/what-is-the-n1-selects-problem-in-orm-object-relational-mapping)
- [PostgreSQL ANY Clause](https://www.postgresql.org/docs/current/functions-comparisons.html#FUNCTIONS-COMPARISONS-ANY-SOME)
- [Go Database Performance](https://go.dev/doc/database/querying)
