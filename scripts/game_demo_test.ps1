# 可玩热更 demo 的自动化验证：构建 v1/v2 -> CLI 与 MCP 双通道运行测试场景 -> 断言判定。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\game_demo_test.ps1 [-Channel cli|mcp|both] [-SkipBuild]
[CmdletBinding()]
param(
    [ValidateSet('cli', 'mcp', 'both')]
    [string]$Channel = 'both',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'repo.ps1')
$root = Split-Path -Parent $PSScriptRoot
$demoDir = Join-Path $root 'demo_csharp'
$projectDir = Join-Path $root 'godot_project'
$outRoot = Get-OutRoot
$logDir = Join-Path $outRoot 'logs'
$tmpDir = Join-Path $projectDir 'game_demo_tmp'
$assembliesDir = Join-Path $projectDir 'bin\assemblies'
$godot = Resolve-GodotExe
$mcpServer = Join-Path $root '.tools\godot-mcp\build\index.js'
$scene = 'res://game_demo_test.tscn'
$cliLog = Join-Path $logDir 'godot_game_demo_test.log'
$mcpLog = Join-Path $logDir 'godot_game_demo_test_mcp.log'
$mcpRawLog = Join-Path $logDir 'godot_mcp_game_demo_raw.log'

$required = @(
    @{ Name = 'v1 版本标识'; Pattern = 'demo v1 build tag = v1' },
    @{ Name = 'v1 速度基线'; Pattern = 'demo v1 speed 180 = true' },
    @{ Name = 'v1 计分基线'; Pattern = 'demo v1 points 10 = true' },
    @{ Name = 'v1 时长基线'; Pattern = 'demo v1 round 30 = true' },
    @{ Name = 'v1 判定半径基线'; Pattern = 'demo v1 radius 16 = true' },
    @{ Name = 'v1 位移=180*0.5'; Pattern = 'demo v1 move 0\.5s at 180 = true' },
    @{ Name = 'v1 吃目标 +10'; Pattern = 'demo v1 pickup \+10 = true' },
    @{ Name = 'v1 超时失败'; Pattern = 'demo v1 timeout state over = true' },
    @{ Name = 'v1 超时归零'; Pattern = 'demo v1 timeout zero = true' },
    @{ Name = 'v1 重开复位'; Pattern = 'demo v1 restart resets = true' },
    @{ Name = '热更前进度'; Pattern = 'demo score before reload = 20' },
    @{ Name = '热更前命中数'; Pattern = 'demo hits before reload = 2' },
    @{ Name = '热更返回成功'; Pattern = 'demo reload returned = true' },
    @{ Name = '热更模式'; Pattern = 'demo reload mode = assembly' },
    @{ Name = '代次 +1'; Pattern = 'demo generation delta = 1' },
    @{ Name = '加载集合不变'; Pattern = 'demo assemblies unchanged = true' },
    @{ Name = '旧句柄失效返回值'; Pattern = 'demo old handle is null = true' },
    @{ Name = '旧句柄 stale 报错'; Pattern = "demo old handle error = stale type identity: handle \d+ belongs to unloaded assembly 'LeanClrGameDemo'" },
    @{ Name = 'v2 速度生效'; Pattern = 'demo v2 speed 320 = true' },
    @{ Name = 'v2 计分生效'; Pattern = 'demo v2 points 25 = true' },
    @{ Name = 'v2 时长生效'; Pattern = 'demo v2 round 20 = true' },
    @{ Name = 'v2 判定半径生效'; Pattern = 'demo v2 radius 22 = true' },
    @{ Name = '静态分数迁移'; Pattern = 'demo static score kept = 20' },
    @{ Name = '静态命中数迁移'; Pattern = 'demo static hits kept = 2' },
    @{ Name = 'v2 位移=320*0.5'; Pattern = 'demo v2 move 0\.5s at 320 = true' },
    @{ Name = 'v2 计时生效'; Pattern = 'demo v2 time after step = true' },
    @{ Name = 'v2 吃目标 +25'; Pattern = 'demo v2 pickup \+25 = true' },
    @{ Name = '节点对象创建'; Pattern = 'demo node created = true' },
    @{ Name = '节点解析 Player'; Pattern = 'demo node resolved player = true' },
    @{ Name = '节点解析 Target'; Pattern = 'demo node resolved target = true' },
    @{ Name = '节点初始位置同步'; Pattern = 'demo node initial position = true' },
    @{ Name = '节点热更返回'; Pattern = 'demo node reload returned = true' },
    @{ Name = '节点热更模式'; Pattern = 'demo node reload mode = assembly' },
    @{ Name = '节点代次 +1'; Pattern = 'demo node reload generation delta = 1' },
    @{ Name = '节点自动重绑'; Pattern = 'demo node bound generation = true' },
    @{ Name = '节点无待重绑'; Pattern = 'demo node pending rebind = false' },
    @{ Name = '节点回到 v1 速度'; Pattern = 'demo node back to v1 speed = true' },
    @{ Name = '重绑后继续驱动节点'; Pattern = 'demo node position after rebind = true' },
    @{ Name = '完成标记'; Pattern = '=== game demo hot reload test done ===' }
)
$forbidden = @(
    @{ Name = '脚本错误'; Pattern = 'SCRIPT ERROR' },
    @{ Name = 'LeanCLR 失败'; Pattern = 'LeanCLR[^\r\n]*failed' },
    @{ Name = 'Godot 错误'; Pattern = '(?m)^ERROR:' }
)

function Write-Stage([string]$Text) {
    Write-Host "[$Text]" -ForegroundColor Cyan
}

function Assert-Command([string]$Name, [string]$Hint) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "缺少命令 $Name：$Hint"
    }
    return $command.Source
}

function Build-Demo([string]$Variant, [string]$Label) {
    Write-Host "  编译 $Label (DemoVariant=$Variant)"
    $log = Join-Path $logDir ("build_LeanClrGameDemo_" + $Variant + '.log')
    & dotnet build (Join-Path $demoDir 'LeanClrGameDemo.csproj') -c Release -nologo -v:minimal -p:DemoVariant=$Variant *> $log
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath $log | Write-Host
        throw "dotnet build LeanClrGameDemo ($Variant) 失败，exit=$LASTEXITCODE，日志：$log"
    }
}

function Install-Dll([string]$Source, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "缺少文件：$Source"
    }
    Copy-Item -LiteralPath $Source -Destination $Target -Force
}

function Test-Regression([string]$LogPath, [string]$Label) {
    if (-not (Test-Path -LiteralPath $LogPath)) {
        return [pscustomobject]@{ Label = $Label; Passed = $false; Log = $LogPath; Missing = @('日志文件不存在'); Forbidden = @() }
    }
    $content = Get-Content -LiteralPath $LogPath -Raw
    $missing = @()
    foreach ($item in $required) {
        if ($content -notmatch $item.Pattern) {
            $missing += $item.Name
        }
    }
    $hits = @()
    foreach ($item in $forbidden) {
        if ($content -match $item.Pattern) {
            $hits += $item.Name
        }
    }
    return [pscustomobject]@{
        Label     = $Label
        Passed    = ($missing.Count -eq 0 -and $hits.Count -eq 0)
        Log       = $LogPath
        Missing   = $missing
        Forbidden = $hits
    }
}

function Print-Result($Result) {
    $total = $required.Count
    if ($Result.Passed) {
        Write-Host ("  {0}: PASS ({1}/{1} 断言)" -f $Result.Label, $total) -ForegroundColor Green
    } else {
        Write-Host ("  {0}: FAIL" -f $Result.Label) -ForegroundColor Red
        foreach ($name in $Result.Missing) {
            Write-Host "    缺少断言: $name" -ForegroundColor Red
        }
        foreach ($name in $Result.Forbidden) {
            Write-Host "    命中禁止项: $name" -ForegroundColor Red
        }
    }
    Write-Host "  日志: $($Result.Log)"
}

$watch = [System.Diagnostics.Stopwatch]::StartNew()
Write-Stage '可玩热更 demo 验证'

$dotnet = Assert-Command 'dotnet' '安装 .NET SDK 后重试'
if (-not (Test-Path -LiteralPath $godot)) {
    throw "缺少 Godot：$godot（见 docs/01）"
}
if ($Channel -ne 'cli' -and -not (Test-Path -LiteralPath $mcpServer)) {
    throw "缺少 godot-mcp：$mcpServer（见 docs/04 §8；或用 -Channel cli 跳过 MCP）"
}
$running = Get-Process -Name 'Godot_v4.5-stable_win64_console' -ErrorAction SilentlyContinue
if ($running) {
    throw '检测到运行中的 Godot 进程，请先关闭游戏窗口再重试'
}
foreach ($dir in @($logDir, $tmpDir, (Join-Path $tmpDir 'hot'), (Join-Path $tmpDir 'build'), $assembliesDir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

if (-not $SkipBuild) {
    Write-Stage '1/3 编译 v1/v2 程序集'
    Build-Demo 'v1' '基线（v1）'
    Install-Dll (Join-Path $tmpDir 'build\v1\LeanClrGameDemo.dll') (Join-Path $tmpDir 'LeanClrGameDemo.base.dll')
    Build-Demo 'v2' '热更版（v2）'
    Install-Dll (Join-Path $tmpDir 'build\v2\LeanClrGameDemo.dll') (Join-Path $tmpDir 'hot\LeanClrGameDemo.dll')
} else {
    Write-Stage '1/3 跳过编译（-SkipBuild）'
}
# 测试场景自身也会在开始时还原基线，这里先确保 bin/assemblies 是 v1。
Install-Dll (Join-Path $tmpDir 'LeanClrGameDemo.base.dll') (Join-Path $assembliesDir 'LeanClrGameDemo.dll')

$results = @()
if ($Channel -ne 'mcp') {
    Write-Stage '2/3 CLI 验证'
    & $godot --headless --path $projectDir --quit-after 300 --log-file $cliLog $scene | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Godot CLI 运行失败，exit=$LASTEXITCODE，日志：$cliLog"
    }
    $results += Test-Regression $cliLog 'CLI'
}

if ($Channel -ne 'cli') {
    Write-Stage '3/3 MCP 验证'
    $node = Assert-Command 'node' '安装 Node.js >= 18 后重试'
    & $node (Join-Path $PSScriptRoot 'mcp_run_scene.mjs') `
        --project $projectDir `
        --scene $scene `
        --log $mcpLog `
        --raw-log $mcpRawLog `
        --godot $godot `
        --quit-after 300 `
        --timeout 120
    if ($LASTEXITCODE -ne 0) {
        throw "MCP 通道运行失败，exit=$LASTEXITCODE，日志：$mcpLog"
    }
    $results += Test-Regression $mcpLog 'MCP'
}

Write-Stage '结果'
foreach ($result in $results) {
    Print-Result $result
}
$failCount = @($results | Where-Object { -not $_.Passed }).Count
$allPassed = ($results.Count -gt 0 -and $failCount -eq 0)
$watch.Stop()
if ($allPassed) {
    Write-Host ("PASS  用时 {0:N1}s" -f $watch.Elapsed.TotalSeconds) -ForegroundColor Green
    exit 0
}
Write-Host ("FAIL  用时 {0:N1}s" -f $watch.Elapsed.TotalSeconds) -ForegroundColor Red
exit 1
