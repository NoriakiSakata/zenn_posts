---
title: "Riverpod 3.0とFreezed 3.0への移行で行った作業まとめ"
emoji: "🔄"
type: "tech"
topics: ["flutter", "dart", "riverpod", "freezed"]
published: true
publication_name: "vintagetracker"
---

## はじめに

FlutterプロジェクトでRiverpod 2.x → 3.x、Freezed 2.x → 3.xへのバージョンアップを行いました。この記事では、移行時に実施した主な変更点と対応方法をまとめます。

## バージョン情報

- **Riverpod**: 2.x → 3.1.0
- **Freezed**: 2.x → 3.2.3
- **hooks_riverpod**: 3.1.0
- **riverpod_annotation**: 2.3.5

## 主な変更点

### 1. Riverpod 3.0への移行

#### 1.1 StateNotifier → Notifier/AsyncNotifierへの移行

Riverpod 3.0では、`StateNotifier`が非推奨となり、`Notifier`と`AsyncNotifier`に置き換えられました。

**Before (Riverpod 2.x)**
```dart
class LoadingController extends StateNotifier<bool> {
  LoadingController() : super(false);

  void show() {
    state = true;
  }

  void dismiss() {
    state = false;
  }
}

final loadingProvider = StateNotifierProvider<LoadingController, bool>(
  (ref) => LoadingController(),
);
```

**After (Riverpod 3.x)**
```dart
class LoadingController extends Notifier<bool> {
  @override
  bool build() => false;

  void show() {
    state = true;
  }

  void dismiss() {
    state = false;
  }
}

final loadingProvider = NotifierProvider<LoadingController, bool>(() {
  return LoadingController();
});
```

#### 1.2 AsyncNotifierの使用

非同期処理を行う場合は`AsyncNotifier`を使用します。

```dart
class BuyItemController extends AsyncNotifier<BuyItemState> {
  final _buyItemService = BuyItemService();

  @override
  Future<BuyItemState> build() async {
    final buyItemList = await _buyItemService.fetchBuyItems();
    return BuyItemState(buyItemList: buyItemList);
  }

  Future<void> fetchBuyItems() async {
    state = const AsyncValue.loading();
    try {
      final buyItemList = await _buyItemService.fetchBuyItems();
      state = AsyncValue.data(BuyItemState(buyItemList: buyItemList));
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }
}

final buyItemControllerProvider =
    AsyncNotifierProvider<BuyItemController, BuyItemState>(() {
  return BuyItemController();
});
```

#### 1.3 FamilyNotifierの扱い

`FamilyNotifier`を使用する場合、ファクトリー関数のシグネチャが変更されました。

**Before**
```dart
final shopEditProvider = StateNotifierProvider.family<
    ShopEditController, ShopEditState, String>(
  (ref, shopId) => ShopEditController(shopId: shopId),
);
```

**After**
```dart
final shopEditProvider = NotifierProvider.family<
    ShopEditController, ShopEditState, String>(
  (shopId) {
    final controller = ShopEditController();
    Future.microtask(() => controller.init(shopId));
    return controller;
  },
);
```

#### 1.4 StateProviderの扱い

Riverpod 3.0では、`StateProvider`が`riverpod`パッケージから直接エクスポートされなくなりました。`hooks_riverpod`から提供されていますが、より明示的な方法として`NotifierProvider`を使用することもできます。

**Before**
```dart
final cityListFilterPrefIdProvider = StateProvider<String?>((ref) => null);
```

**After (Option 1: hooks_riverpodから使用)**
```dart
import 'package:hooks_riverpod/hooks_riverpod.dart';

final cityListFilterPrefIdProvider = StateProvider<String?>((ref) => null);
```

**After (Option 2: NotifierProviderを使用)**
```dart
class CityListFilterPrefIdController extends Notifier<String?> {
  @override
  String? build() => null;

  void setValue(String? value) {
    state = value;
  }
}

final cityListFilterPrefIdProvider = 
    NotifierProvider<CityListFilterPrefIdController, String?>(() {
  return CityListFilterPrefIdController();
});
```

#### 1.5 sealed classの追加

Riverpod 3.0では、状態クラスに`sealed class`を使用することが推奨されます（Freezed 3.0の要件でもあります）。

```dart
@freezed
sealed class LoadingState with _$LoadingState {
  const factory LoadingState({
    @Default(false) bool isLoading,
  }) = _LoadingState;
}
```

### 2. Freezed 3.0への移行

#### 2.1 sealed classの必須化

Freezed 3.0では、`@freezed`アノテーションを使用するクラスは`sealed class`である必要があります。

**Before (Freezed 2.x)**
```dart
@freezed
class ShopModel with _$ShopModel {
  const factory ShopModel({
    @Default('') String id,
    @Default('') String name,
  }) = _ShopModel;

  factory ShopModel.fromJson(Map<String, dynamic> json) =>
      _$ShopModelFromJson(json);
}
```

**After (Freezed 3.x)**
```dart
@freezed
sealed class ShopModel with _$ShopModel {
  const factory ShopModel({
    @Default('') String id,
    @Default('') String name,
  }) = _ShopModel;

  factory ShopModel.fromJson(Map<String, dynamic> json) =>
      _$ShopModelFromJson(json);
}
```

#### 2.2 一括修正の実施

プロジェクト内の全ての`@freezed`クラス（約38クラス）を`sealed class`に変更しました。

```bash
# 修正が必要なファイルを検索
grep -r "@freezed" lib/models --include="*.dart" -A 2

# 各ファイルで class → sealed class に変更
```

## 移行手順

1. **依存関係の更新**
   ```yaml
   dependencies:
     hooks_riverpod: ^3.1.0
     riverpod: ^3.1.0
     freezed: ^3.2.3
     freezed_annotation: ^3.1.0
   ```

2. **コード生成の実行**
   ```bash
   flutter pub get
   flutter pub run build_runner build --delete-conflicting-outputs
   ```

3. **エラーの修正**
   - `StateNotifier` → `Notifier`/`AsyncNotifier`への置き換え
   - `@freezed`クラスを`sealed class`に変更
   - その他の非推奨APIの修正

4. **テストの実行**
   ```bash
   flutter analyze
   flutter test
   ```

## 注意点

1. **build_runnerの実行**
   - Freezed 3.0では、`sealed class`を使用するため、コード生成を必ず実行する必要があります
   - エラーが発生した場合は、生成ファイルを削除してから再生成してください

2. **StateProviderの扱い**
   - `StateProvider`は`hooks_riverpod`から提供されていますが、より明示的な`NotifierProvider`の使用も検討してください

3. **FamilyNotifierの初期化**
   - `build()`メソッドは引数を受け取れないため、初期化処理は外部で行う必要があります
   - `Future.microtask()`を使用して初期化を遅延実行する方法が有効です

## まとめ

Riverpod 3.0とFreezed 3.0への移行は、主に以下の変更が必要でした：

- `StateNotifier` → `Notifier`/`AsyncNotifier`への置き換え
- 全ての`@freezed`クラスを`sealed class`に変更
- `withOpacity` → `withValues`への置き換え
- `super parameter`の使用
- その他の非推奨APIの修正

これらの変更により、より型安全で保守性の高いコードになりました。移行作業は大変でしたが、新しいAPIの恩恵を受けることができました。

## 参考リンク

- [Riverpod 3.0 Migration Guide](https://riverpod.dev/docs/migration/from_state_notifier)
- [Freezed 3.0 Documentation](https://pub.dev/packages/freezed)
- [Flutter 3.0 Breaking Changes](https://docs.flutter.dev/release/breaking-changes)

