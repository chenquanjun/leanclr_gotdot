#!/usr/bin/env bash
# Linux x86_64 构建：CMake 产物写 out/build/linux，编译结果落 out/bin/linux，再部署到 godot_project/bin。
# 用法：bash scripts/build_native_linux.sh
# 说明：生成的是编辑器/调试运行用的模板（GODOTCPP_TARGET=template_debug），与 Windows build_native.bat 对齐。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$root/out/build/linux/debug"
bin_dir="$root/out/bin/linux"

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

mkdir -p "$build_dir" "$bin_dir" "$root/out/logs"
cmake -S "$root" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGODOTCPP_TARGET=template_debug
cmake --build "$build_dir" --target leanclr_godot --parallel

cp "$build_dir/leanclr_godot.so" "$bin_dir/leanclr_godot.so"

if command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -File "$root/scripts/deploy_native.ps1" -Platform linux -Configuration Debug
else
    mkdir -p "$root/godot_project/bin"
    cp "$bin_dir/leanclr_godot.so" "$root/godot_project/bin/leanclr_godot.so"
    echo "  deploy $bin_dir/leanclr_godot.so -> godot_project/bin/leanclr_godot.so"
fi

echo "Build completed: out/build/linux/debug -> godot_project/bin/leanclr_godot.so"
