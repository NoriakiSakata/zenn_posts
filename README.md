# Zenn CLI

このリポジトリは、Zennの記事をローカルで管理するためのリポジトリです。

* [📘 How to use](https://zenn.dev/zenn/articles/zenn-cli-guide)

## セットアップ

### 必要な環境

- Node.js がインストールされていること

### インストール

```bash
npm install
```

## 使い方

### プレビュー

```bash
npm run preview
```

### 新しい記事を作成

```bash
npm run new:article
```

### 新しい本を作成

```bash
npm run new:book
```

## GitHub連携

既存記事のダウンロードとGitHub連携の詳細な手順は、[GITHUB_SETUP.md](./GITHUB_SETUP.md) を参照してください。

### 簡単な手順

1. GitHubでリポジトリを作成
2. [Zennのダッシュボード](https://zenn.dev/dashboard)でGitHubリポジトリと連携
3. 既存の記事がGitHubに自動的にプッシュされます
4. ローカルで `git pull` を実行して記事をダウンロード