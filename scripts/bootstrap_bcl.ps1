# 从 leanclr submodule 的 mono-4.5 目录准备完整 BCL（godot_project/bin/bcl）。
# 规则（见 docs/01）：顶层全部 dll + Facades/netstandard.dll 复制到 BCL 根目录，保持扁平。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\bootstrap_bcl.ps1 [-Force]
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $root 'native') 'thirdparty') 'leanclr') 'src') (Join-Path 'libraries' 'mono-4.5')
$dest = Join-Path (Join-Path (Join-Path $root 'godot_project') 'bin') 'bcl'

if (-not (Test-Path -LiteralPath $src)) {
    throw "缺少 BCL 源目录：$src（先执行 scripts\ensure_deps.ps1）"
}
$existing = @(Get-ChildItem -LiteralPath $dest -Filter '*.dll' -File -ErrorAction SilentlyContinue)
if ($existing.Count -ge 154 -and -not $Force) {
    Write-Host "  BCL 已就绪：$($existing.Count) 个 dll"
    exit 0
}

New-Item -ItemType Directory -Path $dest -Force | Out-Null
$topLevel = @(Get-ChildItem -LiteralPath $src -Filter '*.dll' -File)
foreach ($file in $topLevel) {
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $dest $file.Name) -Force
}
$netstandard = Join-Path (Join-Path $src 'Facades') 'netstandard.dll'
if (-not (Test-Path -LiteralPath $netstandard)) {
    throw "缺少 Facades/netstandard.dll：$netstandard"
}
Copy-Item -LiteralPath $netstandard -Destination (Join-Path $dest 'netstandard.dll') -Force

$count = @(Get-ChildItem -LiteralPath $dest -Filter '*.dll' -File).Count
Write-Host "  BCL 已复制：$count 个 dll -> godot_project/bin/bcl"
