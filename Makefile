.PHONY: help preview install new-article new-book fetch-articles

help: ## 利用可能なコマンドを表示
	@echo "利用可能なコマンド:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

install: ## 依存関係をインストール
	npm install

preview: ## プレビューサーバーを起動
	npx zenn preview

new-article: ## 新しい記事を作成
	npx zenn new:article

new-book: ## 新しい本を作成
	npx zenn new:book

fetch-articles: ## 既存記事を取得（使用例: make fetch-articles USERNAME=your_username）
	@if [ -z "$(USERNAME)" ]; then \
		echo "エラー: USERNAMEを指定してください"; \
		echo "使用例: make fetch-articles USERNAME=enjoy_nori"; \
		exit 1; \
	fi
	@if [ -z "$(COOKIE)" ]; then \
		npm run fetch:articles $(USERNAME); \
	else \
		ZENN_COOKIE="$(COOKIE)" npm run fetch:articles $(USERNAME); \
	fi

