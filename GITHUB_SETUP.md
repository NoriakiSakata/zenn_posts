# GitHub連携の設定手順

## 1. GitHubリポジトリの作成

1. GitHubで新しいリポジトリを作成します
2. リポジトリ名は任意（例: `zenn-posts`）

## 2. ZennとGitHubの連携

1. [Zennのダッシュボード](https://zenn.dev/dashboard)にアクセス
2. 「設定」→「GitHub連携」からリポジトリを選択して連携
3. 連携後、既存の記事がGitHubリポジトリに自動的にプッシュされます

## 3. ローカルリポジトリの設定

### 既存のGitHubリポジトリをクローンする場合

```bash
git clone <あなたのGitHubリポジトリのURL>
cd zenn_posts
npm install
```

### 現在のディレクトリをGitHubリポジトリとして設定する場合

```bash
# Gitリポジトリを初期化
git init

# リモートリポジトリを追加（GitHubで作成したリポジトリのURLに置き換えてください）
git remote add origin <あなたのGitHubリポジトリのURL>

# 既存の記事をプル（Zennと連携済みの場合）
git pull origin main --allow-unrelated-histories
# または
git pull origin master --allow-unrelated-histories

# 初回コミット
git add .
git commit -m "Initial commit: Zenn CLI setup"
git push -u origin main
# または
git push -u origin master
```

## 4. 既存記事のダウンロード

ZennとGitHubを連携後、以下のコマンドで既存の記事を取得できます：

```bash
git pull origin main
# または
git pull origin master
```

記事は `articles/` ディレクトリにMarkdown形式で保存されます。

## 5. 記事の編集と公開

```bash
# プレビュー（ローカルで確認）
npm run preview

# 新しい記事を作成
npm run new:article

# 新しい本を作成
npm run new:book

# 編集後、GitHubにプッシュ
git add .
git commit -m "記事を更新"
git push
```

Zennと連携したリポジトリにプッシュすると、Zenn上の記事が自動的に更新されます。

