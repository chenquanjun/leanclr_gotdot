#!/usr/bin/env bash
# Linux 交叉编译 Android 版 leanclr_godot（CI 用；Windows 对应 scripts/build_android_native.ps1）。
# 用法：bash scripts/build_android_linux.sh [x86_64|arm64-v8a|armeabi-v7a] [Debug|Release|Both]
# 依赖：ANDROID_HOME / ANDROID_SDK_ROOT 指向 SDK，ANDROID_NDK_HOME 或 $SDK/ndk/<ver> 提供 NDK。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
abi="${1:-x86_64}"
config_arg="${2:-Both}"

case "$abi" in
    x86_64|arm64-v8a|armeabi-v7a) ;;
    *) echo "不支持的 ABI：$abi" >&2; exit 1 ;;
esac
case "$config_arg" in
    Debug|Release|Both) ;;
    *) echo "不支持的配置：$config_arg" >&2; exit 1 ;;
esac

sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$sdk" || ! -d "$sdk" ]]; then
    echo "找不到 Android SDK：设置 ANDROID_HOME 或 ANDROID_SDK_ROOT" >&2
    exit 1
fi
ndk="${ANDROID_NDK_HOME:-}"
if [[ -z "$ndk" || ! -d "$ndk" ]]; then
    ndk="$(ls -d "$sdk"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
fi
toolchain="$ndk/build/cmake/android.toolchain.cmake"
if [[ ! -f "$toolchain" ]]; then
    echo "找不到 NDK toolchain：$toolchain" >&2
    exit 1
fi

echo "SDK   : $sdk"
echo "NDK   : $ndk"
echo "ABI   : $abi"

if [[ -e "$root/.git" ]]; then
    git -C "$root" submodule update --init --recursive
fi
bash "$root/scripts/apply_patches.sh"

# Debug 对应 .gdextension 的 libleanclr_godot.so，Release 对应 libleanclr_godot.release.so。
configs=(Debug Release)
if [[ "$config_arg" != "Both" ]]; then
    configs=("$config_arg")
fi

for config in "${configs[@]}"; do
    label="$(printf '%s' "$config" | tr '[:upper:]' '[:lower:]')"
    if [[ "$config" == "Debug" ]]; then
        template="template_debug"
    else
        template="template_release"
    fi
    build_dir="$root/out/build/android/$abi/$label"
    log="$root/out/logs/android_native_${abi}_${label}.log"
    mkdir -p "$build_dir" "$root/out/bin/android/$abi" "$root/out/logs"

    echo "[$abi][$config] configure ($template)"
    cmake -S "$root" -B "$build_dir" \
        -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
        -DANDROID_ABI="$abi" \
        -DANDROID_PLATFORM=android-24 \
        -DANDROID_STL=c++_shared \
        -DCMAKE_C_FLAGS="-include unistd.h" \
        -DCMAKE_BUILD_TYPE="$config" \
        -DGODOTCPP_TARGET="$template" 2>&1 | tee "$log"

    echo "[$abi][$config] build leanclr_godot"
    cmake --build "$build_dir" --target leanclr_godot --parallel 2>&1 | tee -a "$log"

    if [[ ! -f "$build_dir/leanclr_godot.so" ]]; then
        echo "[$abi][$config] 未生成 $build_dir/leanclr_godot.so" >&2
        exit 1
    fi
    if [[ "$config" == "Debug" ]]; then
        name="libleanclr_godot.so"
    else
        name="libleanclr_godot.release.so"
    fi
    cp "$build_dir/leanclr_godot.so" "$root/out/bin/android/$abi/$name"

    if command -v pwsh >/dev/null 2>&1; then
        pwsh -NoProfile -File "$root/scripts/deploy_native.ps1" -Platform android -Abi "$abi" -Configuration "$config"
    else
        mkdir -p "$root/godot_project/bin/android/$abi"
        cp "$root/out/bin/android/$abi/$name" "$root/godot_project/bin/android/$abi/$name"
        echo "  deploy -> godot_project/bin/android/$abi/$name"
    fi
done

echo "Android 原生库构建完成：$abi（产物 out/bin/android/$abi）"
