# 异常恢复路径隔离测试（破坏性）：独立脚本，不并入 scripts\hotreload.ps1 主回归。
# 覆盖 get_last_reload_mode() 的 failed / fallback-failed / dependents-failed(-unrecovered)：
#   用故意损坏或错名的镜像制造加载失败，再恢复镜像并手动 reload_runtime() 验证状态可用。
# 开始前备份 godot_project/bin/bcl 与 bin/assemblies，结束后恢复，保证可重复运行。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\recovery_test.ps1 [-Channel cli|mcp|both] [-SkipBuild]
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
$recoveryDir = Join-Path $projectDir 'recovery_tmp'
$pristineDir = Join-Path $recoveryDir 'pristine'
$assembliesDir = Join-Path $projectDir 'bin\assemblies'
$bclDir = Join-Path $projectDir 'bin\bcl'
$hotTmpDir = Join-Path $projectDir 'hotreload_tmp'
$backupDir = Join-Path $outRoot 'tmp\recovery_backup'
$godot = Resolve-GodotExe
$mcpServer = Join-Path $root '.tools\godot-mcp\build\index.js'
$scene = 'res://recovery_test.tscn'
$cliLog = Join-Path $logDir 'godot_recovery.log'
$mcpLog = Join-Path $logDir 'godot_recovery_mcp.log'
$mcpRawLog = Join-Path $logDir 'godot_mcp_recovery_raw.log'

$required = @(
    @{ Name = 'failed 返回 false'; Pattern = 'recovery failed returned = false' },
    @{ Name = 'failed 模式'; Pattern = 'recovery failed mode = failed' },
    @{ Name = 'failed 恢复后可用'; Pattern = 'recovery failed reload after restore = true' },
    @{ Name = 'failed 恢复后托管调用'; Pattern = 'recovery failed usable = true' },
    @{ Name = 'fallback-failed 返回 false'; Pattern = 'recovery fallback-failed returned = false' },
    @{ Name = 'fallback-failed 模式'; Pattern = 'recovery fallback-failed mode = fallback-failed' },
    @{ Name = 'fallback-failed 恢复后可用'; Pattern = 'recovery fallback-failed reload after restore = true' },
    @{ Name = 'fallback-failed 恢复后托管调用'; Pattern = 'recovery fallback-failed usable = true' },
    @{ Name = 'dependents 返回 false'; Pattern = 'recovery dependents returned = false' },
    @{ Name = 'dependents 未恢复模式'; Pattern = 'recovery dependents mode = dependents-failed-unrecovered' },
    @{ Name = 'dependents 恢复后可用'; Pattern = 'recovery dependents reload after restore = true' },
    @{ Name = 'dependents 恢复后托管调用'; Pattern = 'recovery dependents usable = true' },
    @{ Name = 'recovered 变体尝试返回 false'; Pattern = 'recovery dependents-recovered-attempt returned = false' },
    @{ Name = 'recovered 变体尝试模式'; Pattern = 'recovery dependents-recovered-attempt mode = dependents-failed-unrecovered' },
    @{ Name = 'recovered 变体恢复后可用'; Pattern = 'recovery dependents-recovered-attempt reload after restore = true' },
    @{ Name = '恢复后加载集合完整'; Pattern = 'recovery failed loaded after recovery = LeanClrGame,LeanClrExt,LeanClrExt2' },
    @{ Name = '收尾标记'; Pattern = '=== recovery isolated test done ===' }
)
$forbidden = @(
    @{ Name = '脚本错误'; Pattern = 'SCRIPT ERROR' },
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

function Backup-Dir([string]$Source, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Source)) {
        return
    }
    if (Test-Path -LiteralPath $Target) {
        Remove-Item -LiteralPath $Target -Recurse -Force
    }
    Copy-Item -LiteralPath $Source -Destination $Target -Recurse -Force
}

function Restore-Dir([string]$Backup, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Backup)) {
        Write-Host "  未找到备份，跳过恢复：$Target" -ForegroundColor Yellow
        return
    }
    if (Test-Path -LiteralPath $Target) {
        Remove-Item -LiteralPath $Target -Recurse -Force
    }
    Copy-Item -LiteralPath $Backup -Destination $Target -Recurse -Force
}

function Stop-GodotIfRunning() {
    $running = Get-Process -Name 'Godot_v4.5-stable_win64_console' -ErrorAction SilentlyContinue
    if ($running) {
        Write-Host '  停止残留 Godot 进程' -ForegroundColor Yellow
        $running | Stop-Process -Force
        Start-Sleep -Milliseconds 500
    }
}

function Build-CSharp([string]$ProjectFile, [string]$Label) {
    Write-Host "  编译 $Label ($ProjectFile)"
    $log = Join-Path $logDir ('build_recovery_' + [System.IO.Path]::GetFileNameWithoutExtension($ProjectFile) + '.log')
    & dotnet build (Join-Path $demoDir $ProjectFile) -c Release -nologo -v:minimal *> $log
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
Write-Stage '异常恢复路径隔离测试（破坏性）'

$dotnet = Assert-Command 'dotnet' '安装 .NET SDK 后重试'
if (-not (Test-Path -LiteralPath $godot)) {
    throw "缺少 Godot：$godot（见 docs/01）"
}
if ($Channel -ne 'cli' -and -not (Test-Path -LiteralPath $mcpServer)) {
    throw "缺少 godot-mcp：$mcpServer（见 docs/04 §8；或用 -Channel cli 跳过 MCP）"
}
Stop-GodotIfRunning
foreach ($dir in @($logDir, $backupDir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

Write-Stage '1/4 备份 BCL 与程序集'
Backup-Dir $bclDir (Join-Path $backupDir 'bcl')
Backup-Dir $assembliesDir (Join-Path $backupDir 'assemblies')

$results = @()
try {
    if (-not $SkipBuild) {
        Write-Stage '2/4 编译测试程序集'
        Build-CSharp 'LeanClrGame.csproj' 'v1 基线（LeanClrGame）'
        Build-CSharp 'LeanClrExt.csproj' '跨模块引用（LeanClrExt）'
        Build-CSharp 'LeanClrExt2.csproj' '依赖链末端（LeanClrExt2）'
    } else {
        Write-Stage '2/4 跳过编译（-SkipBuild）'
    }

    # 组装隔离目录：recovery_tmp 为主目录，pristine 保留可恢复的基线镜像。
    foreach ($dir in @($recoveryDir, $pristineDir)) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force
        }
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Copy-Asset (Join-Path $assembliesDir 'LeanClrGame.dll') (Join-Path $recoveryDir 'LeanClrGame.dll')
    Copy-Asset (Join-Path $hotTmpDir 'LeanClrExt.dll') (Join-Path $recoveryDir 'LeanClrExt.dll')
    Copy-Asset (Join-Path $hotTmpDir 'LeanClrExt2.dll') (Join-Path $recoveryDir 'LeanClrExt2.dll')
    foreach ($name in @('LeanClrGame.dll', 'LeanClrExt.dll', 'LeanClrExt2.dll')) {
        Copy-Asset (Join-Path $recoveryDir $name) (Join-Path $pristineDir $name)
    }

    if ($Channel -ne 'mcp') {
        Write-Stage '3/4 CLI 回归'
        & $godot --headless --path $projectDir --quit-after 300 --log-file $cliLog $scene
        if ($LASTEXITCODE -ne 0) {
            throw "CLI 运行失败，exit=$LASTEXITCODE，日志：$cliLog"
        }
        Stop-GodotIfRunning
        $results += Test-Regression $cliLog 'CLI'
    } else {
        Write-Stage '3/4 跳过 CLI'
    }

    if ($Channel -ne 'cli') {
        Write-Stage '4/4 MCP 回归'
        & node (Join-Path $PSScriptRoot 'mcp_run_scene.mjs') --project $projectDir --scene $scene `
            --log $mcpLog --raw-log $mcpRawLog --quit-after 300 --timeout 180
        if ($LASTEXITCODE -ne 0) {
            throw "MCP 运行失败，exit=$LASTEXITCODE，日志：$mcpLog"
        }
        Stop-GodotIfRunning
        $results += Test-Regression $mcpLog 'MCP'
    } else {
        Write-Stage '4/4 跳过 MCP'
    }
} finally {
    Write-Stage '恢复 BCL 与程序集'
    Stop-GodotIfRunning
    Restore-Dir (Join-Path $backupDir 'bcl') $bclDir
    Restore-Dir (Join-Path $backupDir 'assemblies') $assembliesDir
    if (Test-Path -LiteralPath $recoveryDir) {
        Remove-Item -LiteralPath $recoveryDir -Recurse -Force
    }
}

Write-Host '[结果]'
$failed = $false
foreach ($result in $results) {
    Print-Result $result
    if (-not $result.Passed) {
        $failed = $true
    }
}
$watch.Stop()
if ($results.Count -eq 0) {
    Write-Host '未执行任何通道' -ForegroundColor Red
    exit 1
}
if ($failed) {
    Write-Host ('FAIL  用时 {0:N1}s' -f $watch.Elapsed.TotalSeconds) -ForegroundColor Red
    exit 1
}
Write-Host ('PASS  用时 {0:N1}s' -f $watch.Elapsed.TotalSeconds) -ForegroundColor Green
exit 0
