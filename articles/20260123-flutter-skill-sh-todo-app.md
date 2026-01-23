---
title: "Flutterの初期設計、VercelのSkills.shに任せてみた🤖"
emoji: "🚀"
type: "tech"
topics: ["flutter", "riverpod", "freezed", "gorouter", "skills"]
published: true
---

## はじめに

[Skills.sh](https://skills.sh/)のFlutter Skillを使って、TODOアプリを0から開発してみました。この記事では、開発の流れ、採用したアーキテクチャ、パッケージの特徴、テストの実装について紹介します。

Skills.shは、プロンプトファイルを使ってClaude Codeに特定のベストプラクティスやアーキテクチャを教え込むことができるツールです。Flutter Skillでは、Riverpod + Freezed + go_routerの構成が推奨されています。

## Skills.shのセットアップ

Skills.shは、npxコマンドで簡単にプロジェクトに追加できます。

```bash
npx skills add https://github.com/alinaqi/claude-bootstrap --skill flutter
```

このコマンドを実行すると、`.claude/skills/flutter/`ディレクトリにFlutter Skillのプロンプトファイルが追加されます。Claude Codeは自動的にこのSkillを認識し、`/flutter`コマンドで利用できるようになります。

## 実際に使用したプロンプト

今回のTODOアプリ開発では、以下のようなシンプルなプロンプトで開発を開始しました：

```
flutter createコマンドで新規アプリを作成

要件
todoアプリ
- 登録ができる
- 削除ができる
- 更新ができる
```

このたった5行のプロンプトから、Claude CodeとFlutter Skillが以下のような作業を自動的に行ってくれました：

1. `flutter create`でプロジェクト作成
2. 必要なパッケージの追加（Riverpod、Freezed、go_router等）
3. プロジェクト構造の作成（core、data、presentationレイヤー）
4. Todoモデルの実装（Freezed使用）
5. Riverpodプロバイダーの実装
6. 4つの画面の実装（一覧、追加、編集、詳細）
7. go_routerによるルーティング設定
8. Material 3テーマの設定
9. ユニットテスト・ウィジェットテストの実装（44テスト）

## 開発環境

- Flutter 3.38.7 (Dart 3.10.7)
- FVM (Flutter Version Management)
- Skills.sh Flutter Skill

## プロジェクト作成から実装まで

### 1. Flutter Skillの起動

```bash
/flutter
```

Claude Codeで`/flutter`コマンドを実行すると、Flutter Skillが読み込まれます。このSkillには以下の内容が含まれています：

- 推奨プロジェクト構造
- Riverpodの使い方（Provider、Notifier、AsyncValue）
- Freezedのデータモデル定義方法
- go_routerのルーティング設定
- テストの書き方（mocktail使用）
- アンチパターンの警告

### 2. プロジェクトのセットアップ

```bash
# プロジェクト作成
flutter create try_skills_sh_flutter_todo_app

# 必要なパッケージの追加
flutter pub add flutter_riverpod riverpod_annotation freezed_annotation json_annotation go_router uuid intl
flutter pub add --dev build_runner freezed json_serializable riverpod_generator riverpod_lint mocktail
```

Skills.shが自動的に`pubspec.yaml`を更新し、必要な依存関係を追加してくれます。

### 3. コード生成

Freezed + Riverpod Generatorを使用するため、build_runnerでコード生成を実行します：

```bash
dart run build_runner build --delete-conflicting-outputs
```

## アーキテクチャ

Skills.shが推奨するクリーンアーキテクチャ風のディレクトリ構造になりました。

```
lib/
├── core/
│   ├── router/            # go_router設定
│   │   └── app_router.dart
│   └── theme/             # テーマ設定
│       └── app_theme.dart
├── data/
│   └── models/            # Freezedデータモデル
│       └── todo.dart
├── presentation/
│   ├── features/
│   │   └── todo/
│   │       ├── providers/        # Riverpodプロバイダー
│   │       │   └── todo_provider.dart
│   │       ├── widgets/          # 機能固有のウィジェット
│   │       │   └── todo_card.dart
│   │       ├── todo_list_screen.dart
│   │       ├── add_todo_screen.dart
│   │       ├── edit_todo_screen.dart
│   │       └── todo_detail_screen.dart
│   └── common/            # 共通ウィジェット
├── app.dart               # アプリエントリーポイント
└── main.dart
```

### レイヤー分離

- **core/**: アプリ全体で使用される設定（ルーティング、テーマ）
- **data/**: データモデル、リポジトリ実装
- **presentation/**: UI層（画面、ウィジェット、プロバイダー）

この構成により、責任が明確に分離され、テストしやすいコードになります。

## 採用パッケージと特徴

### 1. Riverpod (状態管理)

Riverpodは、Providerパターンベースの状態管理ライブラリです。今回はRiverpod Generatorが使用されていました。

**Notifierパターンの実装例:**

```dart
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';
import '../../../../data/models/todo.dart';

part 'todo_provider.g.dart';

@riverpod
class Todos extends _$Todos {
  @override
  List<Todo> build() {
    return [];
  }

  void addTodo(String title, String description) {
    final newTodo = Todo(
      id: const Uuid().v4(),
      title: title,
      description: description,
      createdAt: DateTime.now(),
    );
    state = [...state, newTodo];
  }

  void toggleTodo(String id) {
    state = [
      for (final todo in state)
        if (todo.id == id)
          todo.copyWith(
            isCompleted: !todo.isCompleted,
            updatedAt: DateTime.now(),
          )
        else
          todo,
    ];
  }

  void deleteTodo(String id) {
    state = state.where((todo) => todo.id != id).toList();
  }
}
```

**特徴:**
- `@riverpod`アノテーションで自動的にプロバイダーを生成
- 型安全で補完が効く
- `ref.watch()`で依存関係を明示的に宣言
- 自動的にメモ化とキャッシュを提供

**UIでの使用:**

```dart
class TodoListScreen extends ConsumerWidget {
  const TodoListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final todos = ref.watch(todosProvider);

    return Scaffold(
      body: ListView.builder(
        itemCount: todos.length,
        itemBuilder: (context, index) {
          final todo = todos[index];
          return TodoCard(
            todo: todo,
            onToggle: () => ref.read(todosProvider.notifier).toggleTodo(todo.id),
            onDelete: () => ref.read(todosProvider.notifier).deleteTodo(todo.id),
          );
        },
      ),
    );
  }
}
```

### 2. Freezed (イミュータブルモデル)

Freezedは、イミュータブルなデータクラスとUnion型を生成するコード生成ライブラリです。

**データモデルの定義:**

```dart
import 'package:freezed_annotation/freezed_annotation.dart';

part 'todo.freezed.dart';
part 'todo.g.dart';

@freezed
abstract class Todo with _$Todo {
  const Todo._();

  const factory Todo({
    required String id,
    required String title,
    required String description,
    @Default(false) bool isCompleted,
    required DateTime createdAt,
    DateTime? updatedAt,
  }) = _Todo;

  factory Todo.fromJson(Map<String, dynamic> json) => _$TodoFromJson(json);
}
```

**特徴:**
- `copyWith`メソッドの自動生成
- `==`と`hashCode`の自動実装
- `toJson/fromJson`の自動生成
- デフォルト値のサポート (`@Default`)
- Union型のサポート（状態パターンに便利）

**使用例:**

```dart
// イミュータブルな更新
final updatedTodo = todo.copyWith(
  title: '新しいタイトル',
  isCompleted: true,
  updatedAt: DateTime.now(),
);

// JSON変換
final json = todo.toJson();
final todoFromJson = Todo.fromJson(json);
```

### 3. go_router (ルーティング)

go_routerは、宣言的ルーティングを提供するナビゲーションライブラリです。

**ルーター設定:**

```dart
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const TodoListScreen(),
        routes: [
          GoRoute(
            path: 'add',
            builder: (context, state) => const AddTodoScreen(),
          ),
          GoRoute(
            path: 'detail/:id',
            builder: (context, state) {
              final id = state.pathParameters['id']!;
              return TodoDetailScreen(todoId: id);
            },
          ),
          GoRoute(
            path: 'edit/:id',
            builder: (context, state) {
              final id = state.pathParameters['id']!;
              return EditTodoScreen(todoId: id);
            },
          ),
        ],
      ),
    ],
  );
});
```

**特徴:**
- パスパラメータのサポート (`/detail/:id`)
- ネストしたルート定義
- ディープリンクのサポート
- リダイレクト機能（認証チェックなどに便利）
- 型安全なナビゲーション

**ナビゲーション:**

```dart
// パスベースのナビゲーション
context.push('/detail/$todoId');
context.go('/');

// スタックへのプッシュ
context.push('/add');

// 戻る
context.pop();
```

### 4. その他のパッケージ

- **uuid**: ユニークIDの生成
- **intl**: 日付フォーマット（作成日時・更新日時の表示）

## 実装した機能

### 1. TODO一覧画面

- TODOリストの表示
- チェックボックスで完了/未完了の切り替え
- 削除ボタン
- 詳細画面への遷移
- FABから追加画面へ

### 2. TODO追加画面

- タイトル入力（必須バリデーション）
- 説明入力（任意）
- フォームバリデーション

### 3. TODO詳細画面

- タイトル、説明、完了状態の表示
- 作成日時・更新日時の表示
- 編集・削除ボタン

### 4. TODO編集画面

- 既存データの読み込み
- タイトル・説明の編集

## テストについて

Skills.shのガイドに従い、ユニットテストとウィジェットテストを実装されました。

### テスト構成

```
test/
├── unit/                      # ユニットテスト (18 tests)
│   ├── todo_model_test.dart   # Todoモデル (7 tests)
│   └── todos_notifier_test.dart # TodosNotifier (11 tests)
└── widget/                    # ウィジェットテスト (26 tests)
    ├── todo_list_screen_test.dart # 一覧画面 (7 tests)
    ├── todo_card_test.dart        # Todoカード (12 tests)
    └── add_todo_screen_test.dart  # 追加画面 (7 tests)
```

合計: **44個のテスト**

### ユニットテストの例

**Todoモデルのテスト:**

```dart
test('copyWith creates new instance with updated fields', () {
  final todo = Todo(
    id: '1',
    title: 'Test Todo',
    description: 'Test Description',
    createdAt: DateTime.now(),
  );

  final updatedTodo = todo.copyWith(
    title: 'Updated Title',
    isCompleted: true,
  );

  expect(updatedTodo.id, todo.id);
  expect(updatedTodo.title, 'Updated Title');
  expect(updatedTodo.description, todo.description);
  expect(updatedTodo.isCompleted, true);
});
```

**TodosNotifierのテスト:**

```dart
test('addTodo adds a new todo to the list', () {
  final container = ProviderContainer();
  final notifier = container.read(todosProvider.notifier);

  notifier.addTodo('Test Todo', 'Test Description');

  final todos = container.read(todosProvider);
  expect(todos.length, 1);
  expect(todos[0].title, 'Test Todo');
  expect(todos[0].description, 'Test Description');
  expect(todos[0].isCompleted, false);

  container.dispose();
});
```

### ウィジェットテストの例

**TodoCardのテスト:**

```dart
testWidgets('calls onToggle when checkbox is tapped', (tester) async {
  var toggleCalled = false;

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TodoCard(
          todo: testTodo,
          onTap: () {},
          onToggle: () => toggleCalled = true,
          onDelete: () {},
        ),
      ),
    ),
  );

  await tester.tap(find.byType(Checkbox));
  await tester.pump();

  expect(toggleCalled, true);
});
```

**TODO一覧画面のテスト:**

```dart
testWidgets('displays empty state when no todos', (tester) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: TodoListScreen(),
      ),
    ),
  );

  expect(find.text('TODOがありません'), findsOneWidget);
  expect(find.text('右下のボタンから追加できます'), findsOneWidget);
  expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
});
```

### テスト実行結果

```bash
$ fvm flutter test --reporter compact
00:02 +44: All tests passed!
```

すべてのテストが成功し、主要な機能が正しく動作することを確認できました。

### テストのメリット

1. **リファクタリングの安全性**: コードを変更しても既存機能が壊れていないことを確認できる
2. **ドキュメントとしての役割**: テストコードが使い方の例になる
3. **バグの早期発見**: 開発中に問題を発見できる
4. **設計の改善**: テストしやすいコードは、疎結合で保守しやすい

## Skills.shを使った感想

### 良かった点

1. **ベストプラクティスが明確**
   - Riverpod、Freezed、go_routerの使い方が具体的に示されている
   - アンチパターンの警告もあり、間違った実装を避けられる

2. **プロジェクト構造が統一される**
   - レイヤー分離が明確
   - チーム開発でも一貫性を保ちやすい

3. **開発速度の向上**
   - Claude Codeが適切なコードを提案してくれる
   - テストコードも自動生成してくれる

4. **最新バージョンへの対応**
   - Flutter 3.38.7（Dart 3.10.7）を使用
   - Riverpod 3.x、Freezed 3.xに対応

### 注意点

1. **Dart SDKのバージョン**
   - 古いFlutterバージョンだとriverpod_generatorが動かない
   - Flutterバージョンは最新版を使用することを推奨

2. **コード生成の理解**
   - build_runnerの使い方を理解する必要がある
   - Freezed、Riverpod Generatorの仕組みを知っておくと良い

3. **学習コスト**
   - Riverpod、Freezed、go_routerそれぞれの学習が必要
   - ただし、一度覚えれば非常に生産的

## まとめ

Skills.shのFlutter Skillを使ってTODOアプリを0から開発しました。結果として、以下のような高品質なプロジェクトが完成しました：

- ✅ クリーンなアーキテクチャ
- ✅ 型安全な状態管理（Riverpod）
- ✅ イミュータブルなデータモデル（Freezed）
- ✅ 宣言的ルーティング（go_router）
- ✅ 包括的なテスト（44テスト）

**これからFlutterを新規開発する場合、Skills.shは非常に良い選択肢だと思います！**

特に以下のようなケースで効果を発揮するかも？：

- 新規プロジェクトの立ち上げ
- チームでベストプラクティスを統一したい
- Riverpod + Freezedの構成を学びたい
- テスト駆動開発を実践したい
- メンテナンスしやすいコードを書きたい

Claude Codeと組み合わせることで、設計からテストまで一貫した品質のコードを素早く生成できます。Flutter開発の新しいスタンダードになる可能性を感じました。

## 参考リンク

- [Skills.sh](https://skills.sh/)
- [Riverpod公式ドキュメント](https://riverpod.dev/)
- [Freezed](https://pub.dev/packages/freezed)
- [go_router](https://pub.dev/packages/go_router)

## リポジトリ

今回作成したTODOアプリのコードは以下で公開しています：

https://github.com/NoriakiSakata/try_skills_sh_flutter_todo_app

実際の実装を見ることができるので、ぜひ参考にしてみてください！
