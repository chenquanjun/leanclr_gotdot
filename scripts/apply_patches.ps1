# 把 patches/ 下的补丁应用到对应的 git submodule 工作区（幂等）。
# 约定：补丁文件名前缀决定目标目录（leanclr-* -> native/thirdparty/leanclr，godot-cpp-* -> native/thirdparty/godot-cpp）。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\apply_patches.ps1 [-Check]
[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$patchDir = Join-Path $root 'patches'
$sep = [IO.Path]::DirectorySeparatorChar

$targets = @(
    @{ Prefix = 'leanclr'; Dir = 'native/thirdparty/leanclr' },
    @{ Prefix = 'godot-cpp'; Dir = 'native/thirdparty/godot-cpp' }
)

# PowerShell 5.1 会把原生命令的 stderr 当成错误记录；这里统一降级为 Continue 并只取退出码。
function Invoke-Git {
    param([string]$Repo, [string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    git -C $Repo @GitArgs 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return $code
}

function Resolve-PatchTarget([string]$PatchName) {
    foreach ($target in $targets) {
        if ($PatchName -like ($target.Prefix + '-*')) {
            return $target.Dir
        }
    }
    throw "无法判断补丁目标：$PatchName（约定前缀 leanclr- / godot-cpp-）"
}

if (-not (Test-Path -LiteralPath $patchDir)) {
    throw "缺少补丁目录：$patchDir"
}
$patches = @(Get-ChildItem -LiteralPath $patchDir -Filter '*.patch' | Sort-Object Name)
if ($patches.Count -eq 0) {
    throw "补丁目录为空：$patchDir"
}

foreach ($patch in $patches) {
    $rel = Resolve-PatchTarget $patch.Name
    $repo = Join-Path $root ($rel -replace '/', $sep)
    if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
        throw "子模块未初始化：$repo（先执行 git submodule update --init --recursive）"
    }
    # git apply 需要正斜杠路径；Windows 下反斜杠会被当成转义。
    $patchPath = $patch.FullName -replace '\\', '/'

    # 反向可应用 == 已在本工作区应用过，跳过，保证脚本可重复执行。
    if ((Invoke-Git $repo @('apply', '--check', '--reverse', $patchPath)) -eq 0) {
        Write-Host "  已应用: $($patch.Name) -> $rel"
        continue
    }

    if ((Invoke-Git $repo @('apply', '--check', $patchPath)) -ne 0) {
        throw "补丁与上游冲突：$($patch.Name) -> $rel；请基于新上游重建补丁（git -C $rel apply --3way patches/$($patch.Name) 可辅助定位）"
    }
    if ($Check) {
        Write-Host "  待应用: $($patch.Name) -> $rel"
        continue
    }

    if ((Invoke-Git $repo @('apply', $patchPath)) -ne 0) {
        throw "应用补丁失败：$($patch.Name) -> $rel"
    }
    Write-Host "  已应用: $($patch.Name) -> $rel"
}

Write-Host "  补丁状态检查完成（$($patches.Count) 个）"
