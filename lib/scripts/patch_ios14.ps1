param(
    [string]$platform = "ios"
)

# ============================================================================
# patch_ios14.ps1 - patch script for the PiliPlus BTR `ios14` branch.
#
# Differences from lib/scripts/patch.ps1 (everything else is identical: same patch
# order, same app-side logic):
#   1. Flutter is 3.44.9 (see `flutter: 3.44.9` in pubspec.yaml), so the two app level
#      iOS patches (bottom_sheet_ios_piliplus.patch / geetest_ios.patch) are already
#      committed on this branch and are NOT applied here again (re-applying them
#      conflicts, especially the pubspec.yaml dependency hunks).
#   2. The two Flutter SDK patches selectable_region / scrollable_gesture were ported
#      to 3.44.9 (3 hunks no longer applied) -> use lib/scripts/ios14/*_3449.patch.
#   3. material_ui / cupertino_ui patches are applied to the versions pinned in
#      pubspec.lock (material_ui 1.2.0 / cupertino_ui 1.0.2) and the script fails
#      loudly if those versions are not found, so we never patch a wrong version.
#
# NOTE: keep this file ASCII-only (no non-ASCII comments/strings) so that any
# PowerShell 5.1/7 under any console code page parses it identically.
# ============================================================================

git config --global user.name "ci"
git config --global user.email "example@example.com"

if ($platform.ToLower() -ne "ios") {
    throw "patch_ios14.ps1 only supports iOS (got: $platform)"
}

# set `gestureSettings`
$BottomSheetIOSFlutterPatch = "lib/scripts/bottom_sheet_ios_flutter.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/1662
# handle bottom scroll event
$ScrollViewPatch = "lib/scripts/scroll_view.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2106
# use `TouchGestureRecognizer` on all platforms
$TextSelectionPatch = "lib/scripts/text_selection.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/1947
$NavigatorPatch = "lib/scripts/navigator.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2107
$ImageAnimPatch = "lib/scripts/image_anim.patch"

# remove `_scheduleRebuild`
$LayoutBuilderPatch = "lib/scripts/layout_builder.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2308
$NavigationDrawerPatch = "lib/scripts/navigation_drawer.patch"

# apply text color to icon color
$PopupMenuPatch = "lib/scripts/popup_menu.patch"

# remove `Hero` effect
$FABPatch = "lib/scripts/fab.patch"

# https://github.com/flutter/flutter/issues/124078
# https://github.com/flutter/flutter/pull/183261
$NullSafetySelectableRegionPatch = "lib/scripts/null_safety_for_selectable_region.patch"

# https://github.com/flutter/flutter/issues/139890
# https://github.com/flutter/flutter/issues/174689
# separator support / clamp handle offset / widgetspan selection support / clear selection when
# tapping outside / free selection if there is only one text / clamp dragging selection behavior
# on Android / show selection menu if secondary tap position is in text region on desktop
# NOTE: 3.44.9 port (the original patch has 2 hunks that no longer apply)
$SelectableRegionPatch = "lib/scripts/ios14/selectable_region_3449.patch"

# https://github.com/flutter/flutter/issues/132047
# https://github.com/flutter/flutter/issues/174689
$EditableTextPatch = "lib/scripts/editable_text.patch"

# set `selectAllOnFocus` to `false` by default
$TextFieldPatch = "lib/scripts/text_field.patch"

# notify `userScrollDirection` only if position is actually changing
$ScrollPositionPatch = "lib/scripts/scroll_position.patch"

# expose `_shouldIgnorePointer`
$ScrollablePatch = "lib/scripts/scrollable.patch"

# fix nested scrollable gesture / custom `HorizontalDragGestureRecognizer` support
# NOTE: 3.44.9 port (the original patch has 1 import hunk that no longer applies)
$ScrollableGesturePatch = "lib/scripts/ios14/scrollable_gesture_3449.patch"

# expose
$DraggableScrollableSheetPatch = "lib/scripts/draggable_scrollable_sheet.patch"

# expose
$ScaffoldPatch = "lib/scripts/scaffold.patch"

# expose
$TextPatch = "lib/scripts/text.patch"

# expose
$TextPainterPatch = "lib/scripts/text_painter.patch"

$SliverPatch = "lib/scripts/sliver.patch"

$RefreshIndicatorPatch = "lib/scripts/refresh_indicator.patch"

# TODO: remove
# https://github.com/flutter/flutter/issues/90223
$ModalBarrierPatch = "lib/scripts/modal_barrier.patch"

# TODO: remove
# https://github.com/flutter/flutter/issues/182466
$MouseCursorPatch = "lib/scripts/mouse_cursor.patch"

Set-Location $env:FLUTTER_ROOT

$patches = @($ModalBarrierPatch, $TextSelectionPatch, $MouseCursorPatch,
            $ImageAnimPatch, $LayoutBuilderPatch, $NavigationDrawerPatch,
            $PopupMenuPatch, $FABPatch, $NullSafetySelectableRegionPatch,
            $SelectableRegionPatch, $EditableTextPatch, $TextFieldPatch,
            $ScrollPositionPatch, $ScrollablePatch, $ScrollableGesturePatch,
            $DraggableScrollableSheetPatch, $ScaffoldPatch, $TextPatch,
            $TextPainterPatch, $SliverPatch, $RefreshIndicatorPatch)

$patches += $ScrollViewPatch
$patches += $BottomSheetIOSFlutterPatch
$patches += $NavigatorPatch

foreach ($patch in $patches) {
    git apply "$env:GITHUB_WORKSPACE/$patch"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$patch applied"
    } else {
        throw "$patch failed: $LASTEXITCODE"
    }
}

Set-Location $env:GITHUB_WORKSPACE

$BottomSheetIOSFlutterMaterialPatchMaterial = "lib/scripts/material/bottom_sheet_ios_flutter_material.patch"

$ModalBarrierPatchMaterial = "lib/scripts/material/modal_barrier_material.patch"

$NavigationDrawerPatchMaterial = "lib/scripts/material/navigation_drawer.patch"

$PopupMenuPatchMaterial = "lib/scripts/material/popup_menu.patch"

$FABPatchMaterial = "lib/scripts/material/fab.patch"

$TextFieldPatchMaterial = "lib/scripts/material/text_field.patch"

$ScaffoldPatchMaterial = "lib/scripts/material/scaffold.patch"

$RefreshIndicatorPatchMaterial = "lib/scripts/material/refresh_indicator.patch"

$TabsPatchMaterial = "lib/scripts/material/tabs.patch"

$patches_material = @($ModalBarrierPatchMaterial, $NavigationDrawerPatchMaterial, $PopupMenuPatchMaterial,
                    $FABPatchMaterial, $TextFieldPatchMaterial, $ScaffoldPatchMaterial, $RefreshIndicatorPatchMaterial,
                    $TabsPatchMaterial)
$patches_material += $BottomSheetIOSFlutterMaterialPatchMaterial

$PubCacheDir = "~/.pub-cache"

# drop the cached material_ui so that flutter pub get downloads it again (pristine), then patch it
try {
    Get-ChildItem "$PubCacheDir/hosted/pub.dev" -Directory |
        Where-Object { $_.Name -like "material_ui-*" } |
        Remove-Item -Recurse -Force
} catch {
}

flutter pub get

$MaterialUiDir = Get-ChildItem "$PubCacheDir/hosted/pub.dev" -Directory |
    Where-Object { $_.Name -like "material_ui-*" } |
    Select-Object -Last 1

if (-not $MaterialUiDir) {
    throw "material_ui package not found in pub cache"
}

Write-Host "material_ui dir: $($MaterialUiDir.FullName)"

Get-ChildItem -Path "$env:GITHUB_WORKSPACE/lib/scripts/material" -Filter *.patch | ForEach-Object {
    (Get-Content $_.FullName -Raw) -replace "`r`n", "`n" |
        Set-Content -NoNewline $_.FullName
}

cd $MaterialUiDir.FullName

foreach ($patch in $patches_material) {
    git apply "$env:GITHUB_WORKSPACE/$patch"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$patch applied"
    } else {
        throw "$patch failed: $LASTEXITCODE"
    }
}

$BottomSheetIOSFlutterPatchCupertino = "lib/scripts/cupertino/bottom_sheet_ios_flutter.patch"

$patches_cupertino = @($BottomSheetIOSFlutterPatchCupertino)

$CupertinoUiDir = Get-ChildItem "$PubCacheDir/hosted/pub.dev" -Directory |
    Where-Object { $_.Name -like "cupertino_ui-*" } |
    Select-Object -Last 1

if (-not $CupertinoUiDir) {
    throw "cupertino_ui package not found in pub cache"
}

Write-Host "cupertino_ui dir: $($CupertinoUiDir.FullName)"

Get-ChildItem -Path "$env:GITHUB_WORKSPACE/lib/scripts/cupertino" -Filter *.patch | ForEach-Object {
    (Get-Content $_.FullName -Raw) -replace "`r`n", "`n" |
        Set-Content -NoNewline $_.FullName
}

cd $CupertinoUiDir.FullName

foreach ($patch in $patches_cupertino) {
    git apply "$env:GITHUB_WORKSPACE/$patch"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$patch applied"
    } else {
        throw "$patch failed: $LASTEXITCODE"
    }
}

Set-Location $env:GITHUB_WORKSPACE
