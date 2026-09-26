import 'package:PiliPlus/utils/bili_colors.dart';
import 'package:flex_seed_scheme/flex_seed_scheme.dart';
import 'package:material_ui/material_ui.dart'
    show ThemeData, Color, ColorScheme, Brightness, Colors;

extension ThemeDataExt on ThemeData {
  bool get isLight => brightness.isLight;

  bool get isDark => brightness.isDark;
}

extension ColorSchemeExt on ColorScheme {
  Color get vipColor =>
      brightness.isLight ? BiliColors.pinkLight : BiliColors.pinkDark;

  Color get blue =>
      brightness.isLight ? BiliColors.blueLight : BiliColors.blueDark;

  Color get btnColor =>
      brightness.isLight ? BiliColors.pinkLight : const Color(0xFF8F0030);

  Color get freeColor =>
      brightness.isLight ? const Color(0xFFFF7F24) : const Color(0xFFD66011);

  bool get isLight => brightness.isLight;

  bool get isDark => brightness.isDark;
}

extension ColorExtension on Color {
  Color darken([double amount = .5]) {
    assert(amount >= 0 && amount <= 1, 'Amount must be between 0 and 1');
    return Color.lerp(this, Colors.black, amount)!;
  }

  /// `flex_seed_scheme 4.0.1`（Flutter 3.44.9 分支用）返回的是 Flutter SDK 自带
  /// material 的 `ColorScheme`，而本项目的 UI 已经切到解耦出的 `material_ui` 包，
  /// 两者是**不同**的类 → 这里逐字段把生成结果搬进 `material_ui` 的 `ColorScheme`。
  /// （3.47.4 分支用的 flex_seed_scheme 5.x 自带 material_ui 支持，不需要这层搬运。）
  ColorScheme asColorSchemeSeed([
    FlexSchemeVariant variant = .material,
    Brightness brightness = .light,
  ]) {
    final seed = SeedColorScheme.fromSeeds(
      primaryKey: this,
      variant: variant,
      brightness: brightness,
      useExpressiveOnContainerColors: false,
    );
    return ColorScheme(
      brightness: seed.brightness,
      primary: seed.primary,
      onPrimary: seed.onPrimary,
      primaryContainer: seed.primaryContainer,
      onPrimaryContainer: seed.onPrimaryContainer,
      primaryFixed: seed.primaryFixed,
      primaryFixedDim: seed.primaryFixedDim,
      onPrimaryFixed: seed.onPrimaryFixed,
      onPrimaryFixedVariant: seed.onPrimaryFixedVariant,
      secondary: seed.secondary,
      onSecondary: seed.onSecondary,
      secondaryContainer: seed.secondaryContainer,
      onSecondaryContainer: seed.onSecondaryContainer,
      secondaryFixed: seed.secondaryFixed,
      secondaryFixedDim: seed.secondaryFixedDim,
      onSecondaryFixed: seed.onSecondaryFixed,
      onSecondaryFixedVariant: seed.onSecondaryFixedVariant,
      tertiary: seed.tertiary,
      onTertiary: seed.onTertiary,
      tertiaryContainer: seed.tertiaryContainer,
      onTertiaryContainer: seed.onTertiaryContainer,
      tertiaryFixed: seed.tertiaryFixed,
      tertiaryFixedDim: seed.tertiaryFixedDim,
      onTertiaryFixed: seed.onTertiaryFixed,
      onTertiaryFixedVariant: seed.onTertiaryFixedVariant,
      error: seed.error,
      onError: seed.onError,
      errorContainer: seed.errorContainer,
      onErrorContainer: seed.onErrorContainer,
      surface: seed.surface,
      onSurface: seed.onSurface,
      surfaceDim: seed.surfaceDim,
      surfaceBright: seed.surfaceBright,
      surfaceContainerLowest: seed.surfaceContainerLowest,
      surfaceContainerLow: seed.surfaceContainerLow,
      surfaceContainer: seed.surfaceContainer,
      surfaceContainerHigh: seed.surfaceContainerHigh,
      surfaceContainerHighest: seed.surfaceContainerHighest,
      onSurfaceVariant: seed.onSurfaceVariant,
      inverseSurface: seed.inverseSurface,
      onInverseSurface: seed.onInverseSurface,
      inversePrimary: seed.inversePrimary,
      outline: seed.outline,
      outlineVariant: seed.outlineVariant,
      shadow: seed.shadow,
      scrim: seed.scrim,
      surfaceTint: seed.surfaceTint,
    );
  }
}

extension BrightnessExt on Brightness {
  Brightness get reverse => isLight ? Brightness.dark : Brightness.light;

  bool get isLight => this == Brightness.light;

  bool get isDark => this == Brightness.dark;
}
