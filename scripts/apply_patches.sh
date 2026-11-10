#!/usr/bin/env bash
# 把 patches/ 下的补丁应用到对应 submodule（幂等），供 Linux/macOS 与 CI 使用。
# 用法：bash scripts/apply_patches.sh [--check]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
patch_dir="$root/patches"
check=0
if [[ "${1:-}" == "--check" ]]; then
    check=1
fi

map_dir() {
    case "$1" in
        leanclr-*) echo "native/thirdparty/leanclr" ;;
        godot-cpp-*) echo "native/thirdparty/godot-cpp" ;;
        *) echo "无法判断补丁目标：$1" >&2; exit 1 ;;
    esac
}

shopt -s nullglob
patches=("$patch_dir"/*.patch)
if [[ ${#patches[@]} -eq 0 ]]; then
    echo "补丁目录为空：$patch_dir" >&2
    exit 1
fi

for patch in "${patches[@]}"; do
    name="$(basename "$patch")"
    rel="$(map_dir "$name")"
    repo="$root/$rel"
    if [[ ! -e "$repo/.git" ]]; then
        echo "子模块未初始化：$repo（先执行 git submodule update --init --recursive）" >&2
        exit 1
    fi
    if git -C "$repo" apply --check --reverse "$patch" >/dev/null 2>&1; then
        echo "  已应用: $name -> $rel"
        continue
    fi
    if ! git -C "$repo" apply --check "$patch" >/dev/null 2>&1; then
        echo "补丁与上游冲突：$name -> $rel（用 git -C $rel apply --3way $patch 定位）" >&2
        exit 1
    fi
    if [[ $check -eq 1 ]]; then
        echo "  待应用: $name -> $rel"
        continue
    fi
    git -C "$repo" apply "$patch"
    echo "  已应用: $name -> $rel"
done

echo "  补丁状态检查完成（${#patches[@]} 个）"
