#!/usr/bin/env bash
# iOS 交叉编译：产出静态库 libleanclr_godot.a（arm64 真机），供 Godot 4.5 导出时链接进 Xcode 工程。
# 用法：bash scripts/build_native_ios.sh [Debug|Release]
#
# 边界：
#   - 只做「编译 + 归档 + 符号检查」，不产出 .ipa、不做签名、不跑设备/模拟器测试。
#   - iOS 导出需要 macOS 宿主 + Xcode + Apple 开发者签名，这几步不在本脚本里伪造。
#   - 仅支持 iphoneos/arm64；模拟器（iphonesimulator）与 x86_64 未配置。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="${1:-Debug}"

case "$config" in
    Debug|Release) ;;
    *) echo "不支持的配置：$config（Debug|Release）" >&2; exit 1 ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "iOS 构建需要 macOS 宿主（当前 $(uname -s)）" >&2
    exit 1
fi
if ! command -v xcrun >/dev/null 2>&1; then
    echo "缺少 xcrun：安装 Xcode 或 Xcode Command Line Tools" >&2
    exit 1
fi

if [[ "$config" == "Debug" ]]; then
    template="template_debug"
else
    template="template_release"
fi
label="$(printf '%s' "$config" | tr '[:upper:]' '[:lower:]')"
build_dir="$root/out/build/ios/$label"
out_dir="$root/out/bin/ios"
name="libleanclr_godot.ios.$label.a"

if [[ -e "$root/.git" ]]; then
    git -C "$root" submodule update --init --recursive
fi
bash "$root/scripts/apply_patches.sh"

sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
if [[ ! -d "$sdk" ]]; then
    echo "找不到 iphoneos SDK：$sdk" >&2
    exit 1
fi
echo "iOS SDK : $sdk"
echo "config  : $config ($template)"

mkdir -p "$build_dir" "$out_dir" "$root/out/logs"

# godot-cpp 的 cmake/macos.cmake 会用 $ENV{SDKROOT} 覆盖 CMAKE_OSX_SYSROOT，
# 这里显式指向 iphoneos，避免 runner 上残留的 SDKROOT 把目标拉回 macOS。
export SDKROOT="$sdk"

cmake -S "$root" -B "$build_dir" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
    -DCMAKE_BUILD_TYPE="$config" \
    -DGODOTCPP_TARGET="$template"
cmake --build "$build_dir" --target leanclr_godot --parallel

archive="$build_dir/libleanclr_godot.a"
if [[ ! -f "$archive" ]]; then
    echo "未生成静态库：$archive" >&2
    exit 1
fi

# Godot 的 iOS 导出只链接 .gdextension 里列出的静态库，不会替我们链接 godot-cpp / leanclr，
# 所以这里把三个静态库合并成一个自包含的 .a（与 godot-cpp 示例用 xcframework 打包同理）。
godotcpp_lib=""
for cand in "$build_dir"/bin/libgodot-cpp*.a "$build_dir"/libgodot-cpp*.a; do
    if [[ -f "$cand" ]]; then
        godotcpp_lib="$cand"
        break
    fi
done
leanclr_lib="$build_dir/leanclr_runtime/libleanclr.a"
for dep in "$godotcpp_lib" "$leanclr_lib"; do
    if [[ -z "$dep" || ! -f "$dep" ]]; then
        echo "缺少静态依赖库（godot-cpp / leanclr）：'$dep'" >&2
        exit 1
    fi
done
echo "merge   : $archive + $godotcpp_lib + $leanclr_lib"

mkdir -p "$out_dir"
libtool -static -o "$out_dir/$name" "$archive" "$godotcpp_lib" "$leanclr_lib"

mkdir -p "$root/godot_project/bin/ios"
cp "$out_dir/$name" "$root/godot_project/bin/ios/$name"

echo "iOS 静态库：out/bin/ios/$name -> godot_project/bin/ios/$name"
