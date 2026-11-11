#!/usr/bin/env bash
# macOS 构建：CMake 产物写 out/build/macos/debug，dylib 落 out/bin/macos，再部署到 godot_project/bin。
# 用法：bash scripts/build_native_macos.sh
# 说明：默认按宿主架构编译（GitHub 的 macos-latest 是 arm64）；
#      需要通用包时传 LEANCLR_MACOS_ARCHS="arm64;x86_64"（构建时间约翻倍）。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$root/out/build/macos/debug"
bin_dir="$root/out/bin/macos"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "macOS 构建需要 Darwin 宿主（当前 $(uname -s)）" >&2
    exit 1
fi

if [[ -e "$root/.git" ]]; then
    git -C "$root" submodule update --init --recursive
fi
bash "$root/scripts/apply_patches.sh"

for f in native/thirdparty/leanclr/src/runtime/CMakeLists.txt native/thirdparty/godot-cpp/CMakeLists.txt; do
    if [[ ! -f "$root/$f" ]]; then
        echo "缺少依赖：$root/$f（执行 git submodule update --init --recursive）" >&2
        exit 1
    fi
done

archs="${LEANCLR_MACOS_ARCHS:-$(uname -m)}"
echo "macOS archs: $archs"

mkdir -p "$build_dir" "$bin_dir" "$root/out/logs"
cmake -S "$root" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGODOTCPP_TARGET=template_debug \
    -DCMAKE_OSX_ARCHITECTURES="$archs"
cmake --build "$build_dir" --target leanclr_godot --parallel

cp "$build_dir/leanclr_godot.dylib" "$bin_dir/leanclr_godot.dylib"

mkdir -p "$root/godot_project/bin"
cp "$bin_dir/leanclr_godot.dylib" "$root/godot_project/bin/leanclr_godot.dylib"

echo "Build completed: out/build/macos/debug -> godot_project/bin/leanclr_godot.dylib"
