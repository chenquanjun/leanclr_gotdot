# 确保 native/thirdparty 的 git submodule 就位，并应用 patches/ 下的本地补丁。
# 所有构建脚本在编译前调用本脚本，本地与 CI 走同一套依赖逻辑。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\ensure_deps.ps1 [-SkipSubmoduleUpdate]
[CmdletBinding()]
param(
    [switch]$SkipSubmoduleUpdate
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sep = [IO.Path]::DirectorySeparatorChar

if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
    Write-Host '  未检测到 .git（源码归档），跳过 submodule 初始化'
} elseif (-not $SkipSubmoduleUpdate) {
    Write-Host '  git submodule update --init --recursive'
    # PowerShell 5.1 会把 git 的 stderr 当错误记录，这里临时降级后按退出码判断。
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    git -C $root submodule update --init --recursive 2>&1 | ForEach-Object { Write-Host "  $_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) {
        throw 'git submodule update 失败：检查网络与 .gitmodules 中的 URL'
    }
}

# 固定版本校验：submodule HEAD 必须等于入库 gitlink，防止误更新到别的 commit 后提交。
if (Test-Path -LiteralPath (Join-Path $root '.git')) {
    & (Join-Path $PSScriptRoot 'verify_submodules.ps1')
}

$required = @(
    'native/thirdparty/leanclr/src/runtime/CMakeLists.txt',
    'native/thirdparty/godot-cpp/CMakeLists.txt'
)
foreach ($rel in $required) {
    $path = Join-Path $root ($rel -replace '/', $sep)
    if (-not (Test-Path -LiteralPath $path)) {
        throw "缺少依赖：$path（执行 git submodule update --init --recursive）"
    }
}

& (Join-Path $PSScriptRoot 'apply_patches.ps1')
