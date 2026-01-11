---
title: "Supabase Session Pooler対応：pgxへの移行とSQL固定化による安定化"
emoji: "🐘"
type: "tech"
topics: ["go", "postgresql", "supabase", "pgx", "session-pooler"]
published: true
---

## はじめに

SupabaseのSession Pooler（ポート6543）を使用しているAWS Lambda環境で、間欠的に発生するPostgreSQL接続エラーを解決するために行った対応をまとめます。

### 背景：なぜSession Poolerを使う必要があったか

Supabaseでは、直接接続（direct connection、ポート5432）とSession Pooler（ポート6543）の2つの接続方法があります。

- **直接接続（ポート5432）**: IPv6のみ対応（無料プラン）
- **Session Pooler（ポート6543）**: IPv4対応（無料プラン）

AWS Lambda環境ではIPv6接続がサポートされていないため、**Session Pooler（ポート6543）を使用する必要がありました**。直接接続を使用するにはIPv4が必要ですが、SupabaseではIPv4は有料オプションのため、コスト削減のためにSession Poolerを利用しました。

### 発生していたエラー

Session Poolerを使用する中で、以下のような間欠的なエラーが発生していました：

- `pq: bind message supplies 1 parameters, but prepared statement "" requires 3`
- `pq: bind message supplies 19 parameters, but prepared statement "" requires 1`

これらのエラーは、Session Poolerがprepared statementをキャッシュする際に、動的に生成されるSQLクエリのパラメータ数が異なることで発生していました。

## 解決アプローチ

以下の4つの対応を実施しました：

1. **Session Pooler設定の確認**
2. **SQLクエリの固定化**（重要・必須）- Session Pooler互換性の基礎
3. **prefer_simple_protocol=trueの設定**（試行したが効果なし）
4. **pgxへの移行**（最終的な解決策）- これによりエラーが解消され、レスポンスも改善

**重要なポイント：** 
- `prefer_simple_protocol`だけでは解決しませんでした
- **SQLクエリの固定化**がSession Pooler互換性の基礎となりました
- **最終的にはpgxへの移行でエラーが解消**され、レスポンスもスムーズになりました
- SQL固定化とpgx移行の組み合わせが効果的でした

## 1. Session Pooler設定

### Session Poolerとは

Supabase Session Pooler（ポート6543）は、接続プーリングを提供するプロキシサーバーです。Transaction poolingモードでは、prepared statementがクライアント間で共有されるため、**SQL構造を固定する必要があります**。

### 接続URLの形式

```go
// Session Pooler（ポート6543）- 無料プランでIPv4対応
postgresql://postgres.xxx:xxx@aws-1-ap-northeast-1.pooler.supabase.com:6543/postgres?sslmode=require

// 直接接続（ポート5432）- IPv4は有料、IPv6のみ無料
postgresql://postgres:xxx@db.xxx.supabase.co:5432/postgres?sslmode=require
```

**注意：** AWS Lambda環境ではIPv6がサポートされていないため、Session Pooler（ポート6543）を使用する必要があります。直接接続を使用する場合は、IPv4が必要ですが、Supabaseでは有料オプションです。

## 2. SQLクエリの固定化（最重要）

### 問題のあるコード（動的SQL）

動的にWHERE句を組み立てるコードは、Session Poolerと互換性がありません。

```go
// ❌ 問題のあるコード
whereClause := "1=1"
args := []interface{}{}
argIndex := 1

if params.PrefID != "" {
    whereClause += fmt.Sprintf(" AND pref_id = $%d", argIndex)
    args = append(args, params.PrefID)
    argIndex++
}

if params.AreaID != "" {
    whereClause += fmt.Sprintf(" AND area_id = $%d", argIndex)
    args = append(args, params.AreaID)
    argIndex++
}

query := fmt.Sprintf("SELECT * FROM shops WHERE %s LIMIT $%d OFFSET $%d", whereClause, argIndex, argIndex+1)
```

このコードは、パラメータの組み合わせによってSQLの構造が変わり、パラメータ数も変わります。Session Poolerがprepared statementをキャッシュする際に、異なるSQL構造のクエリが混在してエラーが発生します。

### 修正後のコード（固定SQL）

**すべてのパラメータを固定で含め、NULLチェックを使用**します。

```go
// ✅ 修正後のコード
query := `
    SELECT s.id, s.name, s.instagram, s.pref_id, s.city_id, s.address
    FROM shops s
    WHERE
        ($1::text IS NULL OR s.pref_id = $1)
        AND ($2::text IS NULL OR s.city_id = $2)
        AND ($3::text IS NULL OR s.name ILIKE $3)
        AND ($4::boolean IS NULL OR s.is_closed = $4)
        AND ($5::text IS NULL OR EXISTS (
            SELECT 1 FROM shop_area_relations sar 
            WHERE sar.shop_id = s.id AND sar.area_id = $5
        ))
    ORDER BY s.created_at DESC
    LIMIT $6 OFFSET $7
    /* shop_search */
`

// パラメータは常に同じ順序で固定
var prefID interface{}
if params.PrefID != "" {
    prefID = params.PrefID
}
// NULLの場合はnilを渡す

var cityID interface{}
if params.CityID != "" {
    cityID = params.CityID
}

var queryParam interface{}
if params.Query != "" {
    queryParam = "%" + params.Query + "%"
}

var isClosed interface{}
if params.IsClosed != nil {
    isClosed = *params.IsClosed
}

var areaID interface{}
if params.AreaID != "" {
    areaID = params.AreaID
}

rows, err := r.pool.Query(ctx, query, prefID, cityID, queryParam, isClosed, areaID, limit, offset)
```

**重要なポイント：**
- SQL構造は常に同じ（パラメータ数も固定）
- オプショナルなパラメータは`($1::text IS NULL OR ...)`パターンを使用
- パラメータの順序を固定（コメントで明示）
- クエリにSQLコメントを追加（`/* shop_search */`）して識別性を向上

### 配列パラメータの扱い

配列パラメータも同様に固定化します。

```go
query := `
    SELECT s.id, s.name
    FROM shops s
    LEFT JOIN shop_style_relations ssr ON s.id = ssr.shop_id 
        AND ($1::text[] IS NULL OR ssr.style_id = ANY($1::text[]))
    LEFT JOIN shop_feature_relations sfr ON s.id = sfr.shop_id 
        AND ($2::text[] IS NULL OR sfr.feature_id = ANY($2::text[]))
    WHERE
        ($3::text IS NULL OR s.pref_id = $3)
    GROUP BY s.id, s.name
    HAVING
        ($1::text[] IS NULL OR bool_or(ssr.style_id IS NOT NULL))
        AND ($2::text[] IS NULL OR bool_or(sfr.feature_id IS NOT NULL))
    LIMIT $4 OFFSET $5
    /* shop_search */
`

var styleIDs interface{}
if len(params.StyleIDs) > 0 {
    styleIDs = params.StyleIDs
}

var featureIDs interface{}
if len(params.FeatureIDs) > 0 {
    featureIDs = params.FeatureIDs
}

var prefID interface{}
if params.PrefID != "" {
    prefID = params.PrefID
}

rows, err := r.pool.Query(ctx, query, styleIDs, featureIDs, prefID, limit, offset)
```

### UNNESTを使用したバッチ更新

`Reorder`メソッドなどで使用する配列のバッチ更新も、UNNESTを使用して固定化します。

```go
query := `
    UPDATE areas
    SET display_order = (
        SELECT new_order
        FROM UNNEST($1::text[], $2::int[]) AS t(id, new_order)
        WHERE areas.id = t.id
    ),
    updated_at = $3
    WHERE id = ANY($1::text[])
`

displayOrders := make([]int, len(ids))
for i := range ids {
    displayOrders[i] = i + 1
}

_, err = tx.Exec(ctx, query, ids, displayOrders, time.Now())
```

## 3. prefer_simple_protocol=trueの設定（試行錯誤）

### lib/pqでの試行（解決しなかった）

最初に、`lib/pq`ドライバーで接続URLに`prefer_simple_protocol=true`を追加する方法を試しました。

```go
// lib/pqの場合（試行したが、エラーが解消されなかった）
databaseURL := "postgresql://user:pass@host:6543/db?sslmode=require"
finalURL, _ := url.Parse(databaseURL)
query := finalURL.Query()
query.Set("prefer_simple_protocol", "true")
finalURL.RawQuery = query.Encode()
databaseURL = finalURL.String()
```

**しかし、この方法ではエラーが解消されませんでした。** Session Poolerが`prefer_simple_protocol`パラメータを無視する、または正しく処理しない可能性があります。

### pgxでの設定

`pgx`では接続URLパラメータではなく、**設定オブジェクトで指定**します。

```go
// pgxの場合（新実装）
poolConfig, err := pgxpool.ParseConfig(databaseURL)
if err != nil {
    return nil, fmt.Errorf("failed to parse connection string: %w", err)
}

// Set prefer_simple_protocol for Session Pooler compatibility
poolConfig.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
logger.Info("Using simple protocol mode for Session Pooler compatibility")

// Set connection pool settings
poolConfig.MaxConns = int32(maxOpenConns)
poolConfig.MinConns = int32(maxIdleConns)
poolConfig.MaxConnLifetime = 5 * time.Minute
poolConfig.MaxConnIdleTime = 30 * time.Second

pool, err := pgxpool.NewWithConfig(context.Background(), poolConfig)
```

**重要：** `prefer_simple_protocol`（または`QueryExecModeSimpleProtocol`）だけでは**不十分**でした。最終的な解決には、**SQL構造の固定化とpgxへの移行の組み合わせ**が必要でした。

## 4. pgxへの移行

### なぜpgxに移行したのか

最初は`lib/pq`で`prefer_simple_protocol=true`を試しましたが、エラーが解消されませんでした。その後、SQL固定化と併せて`pgx`への移行を実施したところ、**最終的にエラーが解消され、レスポンスもスムーズになりました**。

1. **Session Poolerとの互換性（最終的な解決）**
   - `pgx`は、prepared statementの扱いが`lib/pq`よりも柔軟
   - `QueryExecModeSimpleProtocol`でsimple protocolを明示的に指定可能
   - SQL固定化と組み合わせることで、エラーが完全に解消された

2. **パフォーマンス向上**
   - `pgx`は、`lib/pq`よりも高速
   - ネイティブな型マッピングにより、変換オーバーヘッドが少ない
   - **移行後、レスポンスがスムーズになった**

3. **型安全性**
   - 配列型を直接扱える（`pq.Array`が不要）
   - エラーハンドリングが改善されている

**重要：** SQL固定化とpgx移行の**組み合わせ**が効果的でした。SQL固定化だけでは不十分で、pgxへの移行により最終的にエラーが解消されました。

### 移行のポイント

#### 依存関係の変更

```go
// go.mod
- github.com/lib/pq v1.10.9
- github.com/jmoiron/sqlx v1.4.0
+ github.com/jackc/pgx/v5 v5.7.1
```

#### 接続の変更

```go
// 旧実装（sqlx）
import (
    "github.com/jmoiron/sqlx"
    _ "github.com/lib/pq"
)

db, err := sqlx.Connect("postgres", databaseURL)

// 新実装（pgx）
import (
    "github.com/jackc/pgx/v5/pgxpool"
)

pool, err := pgxpool.NewWithConfig(ctx, poolConfig)
```

#### クエリ実行の変更

```go
// 旧実装（sqlx）
type Postgres struct {
    db *sqlx.DB
}

func (r *Postgres) GetByID(ctx context.Context, id string) (*domain.Shop, error) {
    var shop domain.Shop
    err := r.db.GetContext(ctx, &shop, "SELECT * FROM shops WHERE id = $1", id)
    if err != nil {
        if err == sql.ErrNoRows {
            return nil, ErrShopNotFound
        }
        return nil, err
    }
    return &shop, nil
}

// 新実装（pgx）
type Postgres struct {
    pool *pgxpool.Pool
}

func (r *Postgres) GetByID(ctx context.Context, id string) (*domain.Shop, error) {
    var shop domain.Shop
    query := `SELECT id, name, ... FROM shops WHERE id = $1 /* shop_get_by_id */`
    err := r.pool.QueryRow(ctx, query, id).Scan(
        &shop.ID, &shop.Name, ...
    )
    if err != nil {
        if errors.Is(err, pgx.ErrNoRows) {
            return nil, ErrShopNotFound
        }
        return nil, err
    }
    return &shop, nil
}
```

#### リスト取得の変更

```go
// 旧実装（sqlx）
func (r *Postgres) List(ctx context.Context) ([]*domain.Shop, error) {
    var shops []*domain.Shop
    err := r.db.SelectContext(ctx, &shops, "SELECT * FROM shops ORDER BY created_at DESC")
    return shops, err
}

// 新実装（pgx）
func (r *Postgres) List(ctx context.Context) ([]*domain.Shop, error) {
    query := `SELECT id, name, ... FROM shops ORDER BY created_at DESC /* shop_list */`
    rows, err := r.pool.Query(ctx, query)
    if err != nil {
        return nil, err
    }
    defer rows.Close()

    var shops []*domain.Shop
    for rows.Next() {
        var shop domain.Shop
        err := rows.Scan(&shop.ID, &shop.Name, ...)
        if err != nil {
            return nil, err
        }
        shops = append(shops, &shop)
    }
    if err := rows.Err(); err != nil {
        return nil, err
    }
    return shops, nil
}
```

#### トランザクションの変更

```go
// 旧実装（sqlx）
func (r *Postgres) Update(ctx context.Context, shop *domain.Shop) error {
    tx, err := r.db.BeginTxx(ctx, nil)
    if err != nil {
        return err
    }
    defer tx.Rollback()

    _, err = tx.ExecContext(ctx, "UPDATE shops SET name = $1 WHERE id = $2", shop.Name, shop.ID)
    if err != nil {
        return err
    }

    return tx.Commit()
}

// 新実装（pgx）
func (r *Postgres) Update(ctx context.Context, shop *domain.Shop) error {
    tx, err := r.pool.Begin(ctx)
    if err != nil {
        return err
    }
    defer tx.Rollback(ctx)

    _, err = tx.Exec(ctx, "UPDATE shops SET name = $1 WHERE id = $2", shop.Name, shop.ID)
    if err != nil {
        return err
    }

    return tx.Commit(ctx)
}
```

#### 配列パラメータの変更

```go
// 旧実装（lib/pq）
import "github.com/lib/pq"

_, err := tx.ExecContext(ctx, "UPDATE areas SET ... WHERE id = ANY($1)", pq.Array(ids))

// 新実装（pgx）
// pq.Arrayは不要。直接配列を渡せる
_, err := tx.Exec(ctx, "UPDATE areas SET ... WHERE id = ANY($1::text[])", ids)
```

#### エラーハンドリングの変更

```go
// 旧実装
import "database/sql"

if err == sql.ErrNoRows {
    return nil, ErrNotFound
}

// 新実装
import "github.com/jackc/pgx/v5"

if errors.Is(err, pgx.ErrNoRows) {
    return nil, ErrNotFound
}
```

## 実装例：完全なリポジトリファイル

```go
package shop

import (
    "context"
    "errors"
    "vt-server/internal/domain"
    
    "github.com/jackc/pgx/v5"
    "github.com/jackc/pgx/v5/pgxpool"
)

type Postgres struct {
    pool *pgxpool.Pool
}

func NewPostgres(pool *pgxpool.Pool) *Postgres {
    return &Postgres{pool: pool}
}

func (r *Postgres) Search(ctx context.Context, params *domain.ShopSearchParams) ([]*domain.Shop, error) {
    // Fixed SQL structure with fixed parameter count for Session Pooler compatibility
    query := `
        SELECT s.id, s.name, s.instagram, s.pref_id, s.city_id, s.address
        FROM shops s
        WHERE
            ($1::text IS NULL OR s.pref_id = $1)
            AND ($2::text IS NULL OR s.city_id = $2)
            AND ($3::text IS NULL OR s.name ILIKE $3)
        ORDER BY s.created_at DESC
        LIMIT $4 OFFSET $5
        /* shop_search */
    `

    var prefID interface{}
    if params.PrefID != "" {
        prefID = params.PrefID
    }

    var cityID interface{}
    if params.CityID != "" {
        cityID = params.CityID
    }

    var queryParam interface{}
    if params.Query != "" {
        queryParam = "%" + params.Query + "%"
    }

    limit := params.Limit
    if limit <= 0 {
        limit = 20
    }
    offset := params.Offset

    rows, err := r.pool.Query(ctx, query, prefID, cityID, queryParam, limit, offset)
    if err != nil {
        return nil, err
    }
    defer rows.Close()

    var shops []*domain.Shop
    for rows.Next() {
        var shop domain.Shop
        err := rows.Scan(
            &shop.ID, &shop.Name, &shop.Instagram,
            &shop.PrefID, &shop.CityID, &shop.Address,
        )
        if err != nil {
            return nil, err
        }
        shops = append(shops, &shop)
    }
    if err := rows.Err(); err != nil {
        return nil, err
    }
    return shops, nil
}
```

## まとめ

Session Poolerを使用する際のベストプラクティス：

1. **SQL構造を固定する（必須・基礎）**
   - 動的SQLを避け、すべてのパラメータを固定で含める
   - `($1::type IS NULL OR ...)`パターンでオプショナルパラメータを扱う
   - SQLコメントを追加して識別性を向上
   - **Session Pooler互換性の基礎となります**

2. **pgxを使用する（推奨・最終的な解決策）**
   - SQL固定化と組み合わせることで、エラーが解消される
   - Session Poolerとの互換性が良い
   - パフォーマンスと型安全性が向上
   - **移行後、レスポンスがスムーズになった**
   - `QueryExecModeSimpleProtocol`を設定

3. **prefer_simple_protocolを設定する（補助的）**
   - `pgx`では`QueryExecModeSimpleProtocol`を使用
   - `lib/pq`の`prefer_simple_protocol=true`は効果がなかった
   - ただし、これだけでは不十分

4. **エラーハンドリングを適切に行う**
   - `pgx.ErrNoRows`を使用
   - `errors.Is`でエラーを比較

### 最終的な結果

- SQL固定化とpgx移行の**組み合わせ**により、エラーが解消されました
- **最終的にはpgxへの移行で解決**し、レスポンスもスムーズになりました
- 間欠的なエラーが発生しなくなり、安定した動作を実現できました

## 参考リンク

- [pgx - PostgreSQL driver and toolkit for Go](https://github.com/jackc/pgx)
- [Supabase Connection Pooling](https://supabase.com/docs/guides/platform/connection-pooling)
- [pgxpool - Connection pool for pgx](https://pkg.go.dev/github.com/jackc/pgx/v5/pgxpool)

