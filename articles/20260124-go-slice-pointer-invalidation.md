---
title: "Goのスライスでポインタを取得する際の落とし穴：再割り当てとポインタの「ずれ」"
emoji: "🐹"
type: "tech"
topics: ["go", "slice", "pointer", "bug", "postgresql"]
published: true
---

## はじめに

Goでスライスに要素を追加しながら、その要素へのポインタを取得するコードを書いていたところ、予期しないバグに遭遇しました。この記事では、その問題と解決方法を紹介します。

## 問題の発生

YouTube動画一覧APIを実装中、動画に紐づくショップ情報を取得する処理で、以下のようなコードを書いていました：

```go
videos := make([]domain.YoutubeVideo, 0)
videoMap := make(map[string]*domain.YoutubeVideo)
for rows.Next() {
    var video domain.YoutubeVideo
    err := rows.Scan(
        &video.ID,
        &video.VideoID,
        &video.Title,
        // ... 他のフィールド
    )
    if err != nil {
        return nil, fmt.Errorf("failed to scan youtube video: %w", err)
    }
    video.Shops = make([]domain.Shop, 0)
    videos = append(videos, video)
    videoMap[video.ID] = &videos[len(videos)-1]  // ← 問題のコード
}
```

このコードでは、スライスに要素を追加した直後に、その要素へのポインタを`videoMap`に格納しています。

## 症状

APIレスポンスを確認すると、10件の動画が返されるはずなのに、**2件のみにショップ情報が含まれていました**。データベースには全10件の動画にショップが紐づいていることを確認済みでした。

```json
{
  "videos": [
    {
      "id": "video1",
      "shops": []  // ← 空！
    },
    {
      "id": "video2",
      "shops": []  // ← 空！
    },
    // ... 8件も空
    {
      "id": "video9",
      "shops": [{"name": "Shop A"}]  // ← 1件だけデータがある
    },
    {
      "id": "video10",
      "shops": [{"name": "Shop B"}, {"name": "Shop C"}]  // ← 1件だけデータがある
    }
  ]
}
```

## 原因：スライスの再割り当てとポインタの「ずれ」

Goのスライスは、**容量（capacity）を超えて要素を追加すると、新しい配列が割り当てられます**。スライスが参照する配列が変わるため、**そのポインタは `videos` の要素を指さなくなります**。

なお、Goではダングリングポインタ（解放済みメモリ）にはなりません。GCが生きている限り古い配列も保持されるため、**メモリ的に危険なわけではありません**。しかし、`videoMap` に格納したポインタはもはや `videos` が参照している配列を指しておらず、**アプリのロジックとしては壊れている**＝意味的に危険な状態です。

### スライスの内部構造

Goのスライスは以下の3つのフィールドで構成されています：

- `ptr`: 配列へのポインタ
- `len`: 長さ
- `cap`: 容量

```go
type slice struct {
    ptr *T      // 配列へのポインタ
    len int     // 長さ
    cap int     // 容量
}
```

### 問題の発生タイミング

```go
videos := make([]domain.YoutubeVideo, 0)  // len=0, cap=0
videoMap := make(map[string]*domain.YoutubeVideo)

// 1回目: cap=0なので、新しい配列が割り当てられる
videos = append(videos, video1)  // len=1, cap=1
videoMap["video1"] = &videos[0]  // ← このポインタは有効

// 2回目: cap=1なので、新しい配列が割り当てられる
videos = append(videos, video2)  // len=2, cap=2
// ↑ この時点で、videos[0]のアドレスが変わる！
videoMap["video2"] = &videos[1]  // ← このポインタは有効
// しかし、videoMap["video1"]のポインタは古い配列を指している！

// 3回目: cap=2なので、新しい配列が割り当てられる
videos = append(videos, video3)  // len=3, cap=4
// ↑ この時点で、videos[0]とvideos[1]のアドレスが変わる！
// videoMap["video1"]とvideoMap["video2"]は、もはやvideosが参照していない古い配列を指している！
```

容量が足りなくなると、Goランタイムは**より大きな配列を新しく割り当て**、既存の要素をコピーします。スライスが参照する配列が変わるため、取得済みのポインタは**`videos` の要素を指さなくなります**。

### 補足：「range + &変数」の罠との違い

Goでは、ループで「`range` + ループ変数のアドレス」も有名な罠です。

```go
for _, v := range videos {
    m[v.ID] = &v  // ← 別の有名な罠：v はループごとに上書きされる
}
```

**共通点**: どちらも「アドレスの誤解」が原因です。

**相違点**:
- **今回の問題**: `videos` の **backing array（実体の配列）** が再割り当てで変わり、`&videos[i]` で取ったポインタが古い配列を指すままになる。
- **range の罠**: **ループ変数 `v`** はループ全体で同一のアドレスを使い回される。`&v` は常に同じポインタになり、中身が最後の要素で上書きされる。

どちらも「スライス要素へのポインタを取る」文脈で出てきやすいので、一緒に押さえておくと理解が深まります。

## 解決方法

### 方法1: 事前に容量を確保し、全て追加後にポインタを取得（推奨）

```go
videos := make([]domain.YoutubeVideo, 0, limit)  // 事前に容量を確保
for rows.Next() {
    var video domain.YoutubeVideo
    err := rows.Scan(
        &video.ID,
        &video.VideoID,
        // ... 他のフィールド
    )
    if err != nil {
        return nil, fmt.Errorf("failed to scan youtube video: %w", err)
    }
    video.Shops = make([]domain.Shop, 0)
    videos = append(videos, video)
}

// 全て追加後にvideoMapを構築
videoMap := make(map[string]*domain.YoutubeVideo)
for i := range videos {
    videoMap[videos[i].ID] = &videos[i]
}
```

**メリット:**
- スライスの再割り当てを最小限に抑えられる
- 全ての要素が追加された後にポインタを取得するため、取得したポインタが `videos` の要素を正しく指す
- パフォーマンスも向上する（再割り当ての回数が減る）

**注意:** `make([]T, 0, limit)` の事前確保は、今回のケースでは安全ですが、**`limit` を超えて追加すると再発します**。仕様変更で件数が増えたときにも壊れる可能性があるため、**本当に安全なのは「全要素追加後にポインタを取る」設計そのものです**。容量確保はあくまで再割り当て抑制の副次効果として考えましょう。

### 方法2: インデックスを使用する

ポインタの代わりにインデックスを使用する方法もあります：

```go
videos := make([]domain.YoutubeVideo, 0)
videoMap := make(map[string]int)  // ポインタではなくインデックス
for rows.Next() {
    var video domain.YoutubeVideo
    // ... scan ...
    videos = append(videos, video)
    videoMap[video.ID] = len(videos) - 1
}

// 使用時
if idx, exists := videoMap[videoID]; exists {
    video := &videos[idx]
    // ...
}
```

### 方法3: ポインタのスライスを使用する

```go
videos := make([]*domain.YoutubeVideo, 0)
for rows.Next() {
    video := &domain.YoutubeVideo{}  // ポインタを直接作成
    err := rows.Scan(
        &video.ID,
        &video.VideoID,
        // ...
    )
    if err != nil {
        return nil, err
    }
    video.Shops = make([]domain.Shop, 0)
    videos = append(videos, video)
    videoMap[video.ID] = video  // ポインタは有効
}
```

## 実際の修正

今回のケースでは、**方法1**を採用しました：

```go
// 修正前
videos := make([]domain.YoutubeVideo, 0)
videoMap := make(map[string]*domain.YoutubeVideo)
for rows.Next() {
    // ...
    videos = append(videos, video)
    videoMap[video.ID] = &videos[len(videos)-1]  // ← 危険
}

// 修正後
videos := make([]domain.YoutubeVideo, 0, limit)  // 容量を事前確保
for rows.Next() {
    // ...
    videos = append(videos, video)
}

// 全て追加後にvideoMapを構築
videoMap := make(map[string]*domain.YoutubeVideo)
for i := range videos {
    videoMap[videos[i].ID] = &videos[i]  // ← 安全
}
```

修正後、**10件全ての動画にショップ情報が正しく含まれるようになりました**。

## デバッグのヒント

この問題をデバッグする際は、以下の点を確認すると良いでしょう：

1. **スライスの容量を確認**
   ```go
   fmt.Printf("len=%d, cap=%d\n", len(videos), cap(videos))
   ```

2. **ポインタのアドレスを確認**
   ```go
   fmt.Printf("videoMap[%s] = %p\n", videoID, videoMap[videoID])
   fmt.Printf("&videos[%d] = %p\n", idx, &videos[idx])
   ```

3. **スライスの再割り当てを検出**
   ```go
   oldCap := cap(videos)
   videos = append(videos, video)
   if cap(videos) != oldCap {
       fmt.Printf("Reallocated! old=%d, new=%d\n", oldCap, cap(videos))
   }
   ```

## まとめ

- Goのスライスは容量を超えると新しい配列が割り当てられる
- スライスに要素を追加しながら、その要素へのポインタを取得すると、再割り当て後に**取得済みのポインタが `videos` の要素を指さなくなる**可能性がある
- **解決方法**: 全ての要素を追加した後にポインタを取得する（最も安全）、または事前に容量を確保する
- この問題は、スライスの内部実装を理解していないと見つけにくいバグです

## 参考

- [Go Slices: usage and internals](https://go.dev/blog/slices-intro)
- [Effective Go - Slices](https://go.dev/doc/effective_go#slices)
