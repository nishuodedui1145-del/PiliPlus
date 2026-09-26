#!/bin/bash
# ---------------------------------------------------------------------------
# check_ios14_minos.sh — 验证 iOS 构建产物真的能在 iOS 14 上装/跑
#
# 只看 Info.plist 的 MinimumOSVersion 不够：真正的下限是「每个 Mach-O 二进制自己的
# LC_BUILD_VERSION.minos / LC_VERSION_MIN_IPHONEOS」，尤其 Flutter 引擎预编译好的
# Flutter.xcframework 会带着它自己的下限（Flutter 3.45+ 的引擎下限是 iOS 15，这正是
# 需要降到 Flutter 3.44.9 的原因）。这里逐个二进制扫，任何一个 > 允许值就直接失败。
#
# 用法: check_ios14_minos.sh [path/to/Runner.app] [max-version]   (默认 14.0)
# ---------------------------------------------------------------------------
set -uo pipefail

APP="${1:-build/ios/iphoneos/Runner.app}"
MAX="${2:-14.0}"

if [ ! -d "$APP" ]; then
    echo "::error::app bundle not found: $APP"
    exit 2
fi

ver_gt() { # echo "yes" if $1 > $2 (dotted numbers)
    awk -v a="$1" -v b="$2" 'BEGIN{
        na=split(a,x,"."); nb=split(b,y,".");
        for(i=1;i<=3;i++){
            xi=(i<=na)?x[i]+0:0; yi=(i<=nb)?y[i]+0:0;
            if(xi>yi){print "yes"; exit}
            if(xi<yi){print "no"; exit}
        }
        print "no";
    }'
}

minos_of() {
    local f="$1"
    if command -v vtool >/dev/null 2>&1; then
        local m
        m=$(vtool -show-build "$f" 2>/dev/null | awk '/^[[:space:]]*minos[[:space:]]/{print $2; exit}')
        if [ -n "${m:-}" ]; then echo "$m"; return; fi
    fi
    otool -l "$f" 2>/dev/null | awk '
        /LC_VERSION_MIN_IPHONEOS/ { v=1; next }
        /LC_BUILD_VERSION/        { b=1; next }
        v && /^[[:space:]]*version[[:space:]]/ { print $2; exit }
        b && /^[[:space:]]*minos[[:space:]]/   { print $2; exit }'
}

is_macho() { file -b "$1" 2>/dev/null | grep -q "Mach-O"; }

echo "=================== iOS deployment target check ==================="
echo "bundle      : $APP"
echo "max allowed : iOS $MAX"
echo

fail=0

plist="$APP/Info.plist"
if [ -f "$plist" ]; then
    pmin=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$plist" 2>/dev/null | tr -d '\r' || true)
    printf '%-58s %s\n' "Info.plist MinimumOSVersion (Runner)" "${pmin:-<none>}"
    if [ -n "${pmin:-}" ] && [ "$(ver_gt "$pmin" "$MAX")" = "yes" ]; then
        echo "::error::Runner Info.plist MinimumOSVersion $pmin > $MAX"
        fail=1
    fi
fi

# 每个 Mach-O：主二进制 + Frameworks 里的引擎/插件库
count=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! is_macho "$f"; then continue; fi
    m=$(minos_of "$f")
    rel="${f#$APP/}"
    count=$((count + 1))
    if [ -z "${m:-}" ]; then
        printf '%-58s %s\n' "$rel" "<no minos>"
        continue
    fi
    if [ "$(ver_gt "$m" "$MAX")" = "yes" ]; then
        printf '%-58s %s   <== TOO NEW\n' "$rel" "iOS $m"
        echo "::error::$rel requires iOS $m (> $MAX)"
        fail=1
    else
        printf '%-58s %s\n' "$rel" "iOS $m"
    fi
done < <(find "$APP" -type f -perm -111 2>/dev/null)

echo
echo "checked $count Mach-O binaries"

# 引擎 framework 的 Info.plist（Flutter 3.45+ 这里会写 15.0）
for fw in "$APP"/Frameworks/*.framework; do
    [ -d "$fw" ] || continue
    fmin=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$fw/Info.plist" 2>/dev/null | tr -d '\r' || true)
    [ -n "${fmin:-}" ] || continue
    printf '%-58s %s\n' "Info.plist MinimumOSVersion ($(basename "$fw"))" "$fmin"
    if [ "$(ver_gt "$fmin" "$MAX")" = "yes" ]; then
        echo "::error::$(basename "$fw") Info.plist MinimumOSVersion $fmin > $MAX"
        fail=1
    fi
done

echo "=================================================================="
if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL — 产物里有要求高于 iOS $MAX 的二进制"
    exit 1
fi
echo "RESULT: OK — 所有二进制下限 <= iOS $MAX"
