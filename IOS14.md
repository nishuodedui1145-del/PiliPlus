# ios14 分支 — 用 Flutter 3.44.9 编译「能装 iOS 14」的 BTR 版

## 为什么要有这个分支

`btr` 分支用 Flutter **3.47.4**，它的引擎（`Flutter.xcframework`）自己带着 `LC_BUILD_VERSION.minos = 15.0`，
所以不管 Xcode 工程里 `IPHONEOS_DEPLOYMENT_TARGET` 写多少，打出来的包最低也只能装 iOS 15。
Flutter 3.44.9 是最后一个引擎下限仍为 iOS 13 的稳定版（Flutter 3.45 起抬到 iOS 15），因此这里降到 **3.44.9（Dart 3.12.2）**。

## 相对 `btr` 的改动

| 位置 | 改动 |
| --- | --- |
| `pubspec.yaml` | `environment.sdk: ">=3.12.0"`、`flutter: 3.44.9`；`material_ui: 1.2.0`、`cupertino_ui: 1.0.2`、`flex_seed_scheme: 4.0.1`（3.44.9 上能解的最高版本组合） |
| `.fvmrc` | `3.44.9` |
| `lib/scripts/ios14/selectable_region_3449.patch` | `selectable_region.patch` 的 3.44.9 移植版（原版有 2 个 hunk 打不上：`rendering/paragraph.dart` 的 `_getSelectionGeometry` 手柄位置、选择高亮合并绘制） |
| `lib/scripts/ios14/scrollable_gesture_3449.patch` | `scrollable_gesture.patch` 的 3.44.9 移植版（原版 `widgets/page_view.dart` 的 import hunk 打不上） |
| `lib/scripts/patch_ios14.ps1` | iOS 打补丁脚本：patch 顺序与 `patch.ps1` 一致，只是换成上面两个移植补丁；两个 App 级 iOS 补丁（`bottom_sheet_ios_piliplus.patch`、`geetest_ios.patch`）已直接提交在本分支，不再重复应用 |
| `lib/scripts/check_ios14_minos.sh` | 逐个 Mach-O 检查 `LC_BUILD_VERSION.minos` / `LC_VERSION_MIN_IPHONEOS`（`vtool`，回退 `otool -l`），任何一个 > 14.0 就直接失败 |
| `.github/workflows/ios14.yml` | GitHub Actions：`macos-26` + flutter-action 读 `pubspec.yaml` 的 `flutter:` 版本 → 3.44.9；构建后先跑 minos 检查再打包 |
| `lib/utils/extension/theme_ext.dart` | `asColorSchemeSeed` 改成逐字段把 FlexSeedScheme 生成的 `ColorScheme` 搬进 `material_ui` 的 `ColorScheme`（`flex_seed_scheme 4.0.1` 生成的是 Flutter 自带 material 的类型，和 `material_ui` 不是一个类） |
| 6 处 `Future.pause(...)` → `Future.delayed(...)` | 3.44.9（Dart 3.12）还没有 `Future.pause`（3.13 才有）：`common_publish_page.dart`、`episode_panel/view.dart`、`superchat_card.dart`（这里原来是 `future: Future.pause`，改成 `() => Future.delayed(Duration.zero)`，参数类型是 `Future<void> Function()?`）、`reply_utils.dart`、`request_utils.dart` ×2 |

## 怎么构建

GitHub Actions 里手动触发（workflow 名 **Build for iOS 14 (BTR)**，ref 选 `ios14`）：

```bash
gh workflow run "Build for iOS 14 (BTR)" --ref ios14 -R nishuodedui1145-del/PiliPlus
```

产物：`PiliPlus-BTR-ios14_<版本>.ipa`（artifact 名 `iOS14-release`，未签名，需要自签/AltStore 之类装）。
带 `tag` 输入时同时发 Release。

### 已验证的构建（2026-09-27）

| 项 | 值 |
|---|---|
| run | 36255867438（`macos-26` / Xcode 26.6 / Flutter stable-3.44.9-arm64） |
| 结果 | ✅ success |
| 产物 | `PiliPlus-BTR-ios14_2.1.4+5419.ipa`（24.2 MB） |
| `Runner` 主二进制 | iOS 14.0 |
| `Frameworks/Flutter.framework/Flutter` | **iOS 13.0**（同一位置在 3.47.4 上是 15.0 → 这就是降版本的目的） |
| `Frameworks/App.framework/App` | iOS 13.0 |
| 其余 27 个 Mach-O | 11.0 ~ 14.0，全部 ≤ 14.0 |
| `Info.plist MinimumOSVersion` | 14.0 |

## 本地怎么复现

macOS 上（本机 Windows 编不了 iOS）：

```bash
git checkout ios14
flutter --version          # 需要 3.44.9
lib/scripts/build.ps1      # 写入 pili_release.json + 版本号
lib/scripts/patch_ios14.ps1 iOS   # 对 FLUTTER_ROOT 打补丁（含两个移植补丁）
flutter build ios --release --no-codesign --dart-define-from-file=pili_release.json --no-pub
bash lib/scripts/check_ios14_minos.sh build/ios/iphoneos/Runner.app 14.0
```

## 注意

- 这个分支只保证 iOS：`pubspec.yaml` 的依赖版本是按 3.44.9 钉的，`btr` 上的 Android/Windows 构建配置不保证还能用。
- 两个移植补丁的 hunk 行号是按「3.44.9 + 该补丁之前的所有补丁」这个状态写的；如果以后改动 `patch_ios14.ps1` 里 patch 的顺序，需要重新核对行号。
- `lib/scripts/ios14/*_3449.patch` 里的 `@@` 行号只能靠 `git apply` 默认的严格匹配；验证方式：在干净的 3.44.9 树上按 `patch_ios14.ps1` 的顺序全量应用，确认 0 个 `.rej`。
