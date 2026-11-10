# 一键热更回归：编译 v1 基线 / LeanClrExt / 热更版本 -> CLI 回归 -> MCP 回归。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\hotreload.ps1 [-Channel cli|mcp|both] [-SkipBuild]
[CmdletBinding()]
param(
    [ValidateSet('cli', 'mcp', 'both')]
    [string]$Channel = 'both',
    [string]$GodotExe = '',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'repo.ps1')
$root = Split-Path -Parent $PSScriptRoot
$demoDir = Join-Path $root 'demo_csharp'
$projectDir = Join-Path $root 'godot_project'
$outRoot = Get-OutRoot
$logDir = Join-Path $outRoot 'logs'
$tmpDir = Join-Path $projectDir 'hotreload_tmp'
$assembliesDir = Join-Path (Join-Path $projectDir 'bin') 'assemblies'
$godot = Resolve-GodotExe -Explicit $GodotExe
$mcpServer = Join-Path (Join-Path (Join-Path $root '.tools') 'godot-mcp') (Join-Path 'build' 'index.js')
$scene = 'res://hotreload_c_test.tscn'
$cliLog = Join-Path $logDir 'godot_hotreload_c.log'
$mcpLog = Join-Path $logDir 'godot_hotreload_c_mcp.log'
$mcpRawLog = Join-Path $logDir 'godot_mcp_hotreload_c_raw.log'

$required = @(
    @{ Name = '静态字段迁移'; Pattern = 'statics after reload: counter=123, tag=persist-me' },
    @{ Name = '旧句柄失效'; Pattern = "old handle error = stale type identity: handle \d+ belongs to unloaded assembly 'LeanClrGame' \(generation 0\)" },
    @{ Name = '新代码生效'; Pattern = 'new object build = v2' },
    @{ Name = '节点信号重绑'; Pattern = '\[hotreload\] node rebound: type=PlayerController, generation=1, signals=1' },
    @{ Name = '重绑后信号回调'; Pattern = 'OnHotSignal build=v2 text=post-reload' },
    @{ Name = '跨模块引用判定'; Pattern = "unsafe to unload: assembly 'LeanClrGame' is referenced by 'LeanClrExt'" },
    @{ Name = 'reject 不改代次'; Pattern = 'generation unchanged = true' },
    @{ Name = 'reject 模式'; Pattern = 'reject reload mode = rejected' },
    @{ Name = 'fallback 模式'; Pattern = 'fallback reload mode = fallback' },
    @{ Name = 'fallback 代次递增'; Pattern = 'generation after fallback = 2' },
    @{ Name = 'fallback 后信号回调'; Pattern = 'OnHotSignal build=v2 text=post-fallback' },
    @{ Name = '依赖链卸载顺序'; Pattern = 'dependents unload order: LeanClrExt2,LeanClrExt,LeanClrGame' },
    @{ Name = '依赖链热更模式'; Pattern = 'dependents reload mode = assembly\+dependents' },
    @{ Name = '依赖链代次 +1'; Pattern = 'dependents generation delta = 1' },
    @{ Name = '依赖链加载顺序恢复'; Pattern = 'dependents loaded order = LeanClrGame,LeanClrExt,LeanClrExt2' },
    @{ Name = '依赖链新代码生效'; Pattern = 'ExtUser2\.Use\(\) after dependents reload = ExtUser2->ExtUser->PlayerItem=42' },
    @{ Name = '缺文件回滚返回'; Pattern = 'aborted reload returned = false' },
    @{ Name = '缺文件回滚模式'; Pattern = 'aborted reload mode = aborted' },
    @{ Name = '缺文件回滚错误'; Pattern = "aborted reload error = hot reload aborted: missing assembly file 'LeanClrExt2'" },
    @{ Name = '回滚不改代次'; Pattern = 'aborted generation unchanged = true' },
    @{ Name = '回滚不改加载集合'; Pattern = 'aborted assemblies unchanged = true' },
    @{ Name = '循环引用卸载顺序'; Pattern = 'dependents unload order: LeanClrCycleB,LeanClrCycleA' },
    @{ Name = '循环引用热更模式'; Pattern = 'cycle reload mode = assembly\+dependents' },
    @{ Name = '循环引用加载顺序'; Pattern = 'cycle loaded order = .*LeanClrCycleA,LeanClrCycleB' },
    @{ Name = '循环引用后可调用'; Pattern = 'CycleA\.Ping = cycle-a:cycle-b' },
    @{ Name = '循环引用无错误'; Pattern = 'CycleA\.Ping error = \r?\n' },
    @{ Name = '参数类型变化返回'; Pattern = 'sig param type returned = false' },
    @{ Name = '参数类型变化模式'; Pattern = 'sig param type mode = signature-mismatch' },
    @{ Name = '参数类型变化错误'; Pattern = 'changed signature: PlayerController\.Add\(i4,i4\)->i4 -> PlayerController\.Add\(string,i4\)->i4' },
    @{ Name = '参数数量变化模式'; Pattern = 'sig param count mode = signature-mismatch' },
    @{ Name = '参数数量变化错误'; Pattern = 'removed method: PlayerController\.Add\(i4,i4\)->i4' },
    @{ Name = '返回值变化模式'; Pattern = 'sig return mode = signature-mismatch' },
    @{ Name = '返回值变化错误'; Pattern = 'changed signature: PlayerController\.SignatureProbe\(i4\)->i4' },
    @{ Name = '方法删除模式'; Pattern = 'sig removed mode = signature-mismatch' },
    @{ Name = '方法删除错误'; Pattern = 'removed method: PlayerController\.GetHotBuild\(\)->string' },
    @{ Name = '方法新增兼容'; Pattern = 'sig added returned = true' },
    @{ Name = '方法新增模式'; Pattern = 'sig added mode = assembly\+dependents' },
    @{ Name = '信号 0 参转发'; Pattern = 'PlayerController\.OnSignal' },
    @{ Name = '信号 1 参转发'; Pattern = 'signal arg=hello' },
    @{ Name = '信号 2 参转发'; Pattern = 'signal args2=hi,9' },
    @{ Name = '信号 3 参引用句柄转发'; Pattern = 'OnSignalMixed target=PlayerItem=5 text=sig3 value=42' },
    @{ Name = '信号 3 参 null 转发'; Pattern = 'OnSignalMixed target=null text=sig-null value=7' },
    @{ Name = 'Godot 实例信号映射'; Pattern = 'OnSignalObject target=PlayerController same=true text=sig-object' },
    @{ Name = 'Godot null 实例映射'; Pattern = 'OnSignalObject target=null same=false text=sig-null-object' },
    @{ Name = '显式绑定实例映射'; Pattern = 'OnSignalObject target=PlayerController same=false text=sig-bound' },
    @{ Name = '实例映射计数'; Pattern = 't4 mapping count = 1' },
    @{ Name = '托管返回还原实例'; Pattern = 't4 return is object = true' },
    @{ Name = '托管返回实例同一性'; Pattern = 't4 return same instance = true' },
    @{ Name = '实例释放后映射清理'; Pattern = 't4 mapping count after free = 0' },
    @{ Name = '释放实例按 null 转发'; Pattern = 'OnSignalObject target=null same=false text=sig-freed' },
    @{ Name = '未绑定实例明确报错'; Pattern = "no managed object mapped for Godot instance 'Node#" },
    @{ Name = '实例解绑'; Pattern = 't4 mapping count after unbind = 0' },
    @{ Name = '热更后显式映射失效'; Pattern = 't4 mapping count after reload = 0' },
    @{ Name = '热更后节点自动重绑'; Pattern = 'OnSignalObject target=PlayerController same=true text=sig-after-reload' },
    @{ Name = '热更后旧实例报错'; Pattern = 't4 stale instance error = no managed object mapped' },
    @{ Name = '测试完成标记'; Pattern = '=== stage C hot reload test done ===' }
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

function Copy-Asset([string]$Source, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "缺少文件：$Source"
    }
    Copy-Item -LiteralPath $Source -Destination $Target -Force
}

function Build-CSharp([string]$ProjectFile, [string]$Label, [string[]]$ExtraArgs = @(), [string]$LogSuffix = '') {
    Write-Host "  编译 $Label ($ProjectFile)"
    $log = Join-Path $logDir ('build_' + [System.IO.Path]::GetFileNameWithoutExtension($ProjectFile) + $LogSuffix + '.log')
    & dotnet build (Join-Path $demoDir $ProjectFile) -c Release -nologo -v:minimal @ExtraArgs *> $log
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath $log | Write-Host
        throw "dotnet build $ProjectFile 失败，exit=$LASTEXITCODE，日志：$log"
    }
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
Write-Stage '一键热更回归'

$dotnet = Assert-Command 'dotnet' '安装 .NET SDK 后重试'
if (-not (Test-Path -LiteralPath $godot)) {
    throw "缺少 Godot：$godot（见 docs/01）"
}
if ($Channel -ne 'cli' -and -not (Test-Path -LiteralPath $mcpServer)) {
    throw "缺少 godot-mcp：$mcpServer（见 docs/04 §8；或用 -Channel cli 跳过 MCP）"
}
$running = Get-Process -Name 'Godot_v4.5-stable_win64_console' -ErrorAction SilentlyContinue
if ($running) {
    throw '检测到运行中的 Godot 进程，请先执行 taskkill.exe //F //IM Godot_v4.5-stable_win64_console.exe //T'
}
foreach ($dir in @($logDir, $tmpDir, $assembliesDir, (Join-Path $tmpDir 'hot'))) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

if (-not $SkipBuild) {
    Write-Stage '1/3 编译程序集'
    Build-CSharp 'LeanClrGame.csproj' 'v1 基线（LeanClrGame）'
    Copy-Asset (Join-Path $assembliesDir 'LeanClrGame.dll') (Join-Path $tmpDir 'LeanClrGame.base.dll')
    $basePdb = Join-Path $assembliesDir 'LeanClrGame.pdb'
    if (Test-Path -LiteralPath $basePdb) {
        Copy-Asset $basePdb (Join-Path $tmpDir 'LeanClrGame.base.pdb')
    }
    Build-CSharp 'LeanClrExt.csproj' '跨模块引用（LeanClrExt）'
    Build-CSharp 'LeanClrExt2.csproj' '依赖链（LeanClrExt2）'
    Build-CSharp 'LeanClrCycleA.csproj' '循环引用 A_v1' @('-p:CycleStage=v1') '_a1'
    Build-CSharp 'LeanClrCycleB.csproj' '循环引用 B' @() '_b'
    Build-CSharp 'LeanClrCycleA.csproj' '循环引用 A_v2' @('-p:CycleStage=v2') '_a2'
    $cycleDir = Join-Path $tmpDir 'cycle'
    Copy-Asset (Join-Path (Join-Path $cycleDir 'v2') 'LeanClrCycleA.dll') (Join-Path $tmpDir 'LeanClrCycleA.dll')
    Copy-Asset (Join-Path (Join-Path $cycleDir 'b') 'LeanClrCycleB.dll') (Join-Path $tmpDir 'LeanClrCycleB.dll')
    Build-CSharp 'LeanClrGameHot.csproj' '热更版本（HOT_V2）'
    foreach ($variant in @('SIG_PARAM_TYPE', 'SIG_PARAM_COUNT', 'SIG_RETURN', 'SIG_REMOVED', 'SIG_ADDED')) {
        Build-CSharp 'LeanClrGameSig.csproj' "签名变体 $variant" @('-p:SigVariant=' + $variant) ('_' + $variant)
    }
    Copy-Asset (Join-Path (Join-Path $tmpDir 'hot') 'LeanClrGame.dll') (Join-Path $tmpDir 'LeanClrGame.hot.dll')
    $hotPdb = Join-Path (Join-Path $tmpDir 'hot') 'LeanClrGame.pdb'
    if (Test-Path -LiteralPath $hotPdb) {
        Copy-Asset $hotPdb (Join-Path $tmpDir 'LeanClrGame.hot.pdb')
    }
} else {
    Write-Stage '1/3 跳过编译（-SkipBuild）'
}

$results = @()
if ($Channel -ne 'mcp') {
    Write-Stage '2/3 CLI 回归'
    & $godot --headless --path $projectDir --quit-after 200 --log-file $cliLog $scene | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Godot CLI 运行失败，exit=$LASTEXITCODE，日志：$cliLog"
    }
    $results += Test-Regression $cliLog 'CLI'
}

if ($Channel -ne 'cli') {
    Write-Stage '3/3 MCP 回归'
    $node = Assert-Command 'node' '安装 Node.js >= 18 后重试'
    & $node (Join-Path $PSScriptRoot 'mcp_run_scene.mjs') `
        --project $projectDir `
        --scene $scene `
        --log $mcpLog `
        --raw-log $mcpRawLog `
        --godot $godot `
        --quit-after 200 `
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
