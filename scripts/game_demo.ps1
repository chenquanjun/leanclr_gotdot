# 启动可玩热更 demo：构建 v1 -> 启动 Godot -> 监视 GameDemo*.cs 变化并自动重建。
# 游戏内轮询 bin/assemblies/LeanClrGameDemo.dll 的修改时间，重建复制后自动 reload_assembly。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\game_demo.ps1 [-NoWatch] [-SkipBuild]
[CmdletBinding()]
param(
    [switch]$NoWatch,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'repo.ps1')
$root = Split-Path -Parent $PSScriptRoot
$demoDir = Join-Path $root 'demo_csharp'
$projectDir = Join-Path $root 'godot_project'
$outRoot = Get-OutRoot
$logDir = Join-Path $outRoot 'logs'
$godot = Resolve-GodotExe
$v1Dir = Join-Path $projectDir 'game_demo_tmp\build\v1'
$assembliesDir = Join-Path $projectDir 'bin\assemblies'
$dstDll = Join-Path $assembliesDir 'LeanClrGameDemo.dll'
$dstPdb = Join-Path $assembliesDir 'LeanClrGameDemo.pdb'
$logFile = Join-Path $logDir 'godot_game_demo.log'
$buildLog = Join-Path $logDir 'build_game_demo.log'

function Build-Demo {
    Write-Host '[build] dotnet build LeanClrGameDemo.csproj (v1)'
    & dotnet build (Join-Path $demoDir 'LeanClrGameDemo.csproj') -c Release -nologo -v:minimal -p:DemoVariant=v1 *> $buildLog
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath $buildLog | Write-Host
        Write-Host "[build] 失败，日志：$buildLog" -ForegroundColor Red
        return $false
    }
    New-Item -ItemType Directory -Path $assembliesDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $v1Dir 'LeanClrGameDemo.dll') -Destination $dstDll -Force
    $pdb = Join-Path $v1Dir 'LeanClrGameDemo.pdb'
    if (Test-Path -LiteralPath $pdb) {
        Copy-Item -LiteralPath $pdb -Destination $dstPdb -Force
    }
    Write-Host "[build] 已部署 $dstDll"
    return $true
}

function Get-NewestSourceTime {
    $latest = [datetime]::MinValue
    foreach ($file in Get-ChildItem -Path $demoDir -Filter 'GameDemo*.cs') {
        if ($file.LastWriteTimeUtc -gt $latest) {
            $latest = $file.LastWriteTimeUtc
        }
    }
    return $latest
}

if (-not (Test-Path -LiteralPath $godot)) {
    throw "缺少 Godot：$godot（见 docs/01）"
}
$running = Get-Process -Name 'Godot_v4.5-stable_win64_console' -ErrorAction SilentlyContinue
if ($running) {
    throw '检测到运行中的 Godot 进程，请先关闭游戏窗口再重试'
}
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

if (-not $SkipBuild -and -not (Build-Demo)) {
    throw "编译 LeanClrGameDemo 失败，日志：$buildLog"
}

Write-Host '[launch] 启动 Godot（非 headless）'
$process = Start-Process -FilePath $godot -PassThru -ArgumentList @(
    '--path', $projectDir,
    '--log-file', $logFile,
    'res://game_demo.tscn'
)
Write-Host "游戏已启动（PID $($process.Id)）"
Write-Host "日志：$logFile"
Write-Host '操作：方向键移动吃橙色目标；F5 手动热更；R 重开；时间到即失败。'
Write-Host '改 demo_csharp/GameDemoTuning.cs 或 GameDemo.cs 并保存，脚本会自动重建，游戏内自动热更。'

if ($NoWatch) {
    $process.WaitForExit()
    exit $process.ExitCode
}

$lastSourceTime = Get-NewestSourceTime
try {
    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 400
        $newest = Get-NewestSourceTime
        if ($newest -le $lastSourceTime) {
            continue
        }
        # 等编辑器把文件写完，再构建。
        Start-Sleep -Milliseconds 300
        if (Build-Demo) {
            Write-Host '[watch] 已重建并复制，游戏内将在 0.25s 内自动热更' -ForegroundColor Cyan
        }
        $lastSourceTime = Get-NewestSourceTime
    }
} finally {
    if (-not $process.HasExited) {
        $process.Kill()
    }
}
