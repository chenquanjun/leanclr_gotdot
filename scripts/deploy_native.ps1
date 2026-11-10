# 把 out/bin 下编译好的原生库部署到 Godot 工程（res://bin），供编辑器与导出加载。
# 约定：所有编译产物只写 out/，工程内只保留部署结果；本脚本是唯一部署入口。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\deploy_native.ps1 [-Platform windows|linux|android] [-Abi x86_64|arm64-v8a|armeabi-v7a] [-Configuration Debug|Release|Both]
[CmdletBinding()]
param(
    [ValidateSet('windows', 'linux', 'android')]
    [string]$Platform = 'windows',
    [ValidateSet('x86_64', 'arm64-v8a', 'armeabi-v7a')]
    [string]$Abi = 'x86_64',
    [ValidateSet('Debug', 'Release', 'Both')]
    [string]$Configuration = 'Both'
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'repo.ps1')
$root = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path (Get-OutRoot) 'bin'
$projectBin = Join-Path (Join-Path $root 'godot_project') 'bin'
$configs = if ($Configuration -eq 'Both') { @('Debug', 'Release') } else { @($Configuration) }

function Copy-One([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "缺少编译产物：$Source（先运行对应 build 脚本）"
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    Write-Host "  deploy $Source -> $Destination"
}

foreach ($config in $configs) {
    $release = $config -eq 'Release'
    $suffix = if ($release) { '.release' } else { '' }
    switch ($Platform) {
        'windows' {
            $name = "leanclr_godot$suffix.dll"
            Copy-One (Join-Path (Join-Path $sourceRoot 'windows') $name) (Join-Path $projectBin $name)
        }
        'linux' {
            $name = "leanclr_godot$suffix.so"
            Copy-One (Join-Path (Join-Path $sourceRoot 'linux') $name) (Join-Path $projectBin $name)
        }
        'android' {
            $name = "libleanclr_godot$suffix.so"
            Copy-One (Join-Path (Join-Path (Join-Path $sourceRoot 'android') $Abi) $name) (Join-Path (Join-Path (Join-Path $projectBin 'android') $Abi) $name)
        }
    }
}

Write-Host "部署完成：$Platform$(if ($Platform -eq 'android') { " $Abi" }) -> godot_project\bin"
