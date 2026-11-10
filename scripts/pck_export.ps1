# PCK 导出后运行验证：重建扩展与托管程序集 -> 导出 debug/release -> 运行导出产物 -> 断言。
# 非破坏性；不改动 bin 下的程序集（只读取），产物写入 out/export/{dbg,rel,linux}，日志写入 out/logs。
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\pck_export.ps1 [-Target both|debug|release] [-SkipBuild] [-IncludeLinux]
[CmdletBinding()]
param(
    [ValidateSet('both', 'debug', 'release')]
    [string]$Target = 'both',
    [switch]$SkipBuild,
    [switch]$IncludeLinux,
    [string]$WslDistro = 'Ubuntu',
    [int]$ExpectedLines = 64
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'repo.ps1')
$root = Split-Path -Parent $PSScriptRoot
$projectDir = Join-Path $root 'godot_project'
$outRoot = Get-OutRoot
$logDir = Join-Path $outRoot 'logs'
$godot = Resolve-GodotExe
$bclCore = Join-Path $projectDir 'bin\bcl\mscorlib.dll'
$managedGame = Join-Path $projectDir 'bin\assemblies\LeanClrGame.dll'

$results = @()

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

function Stop-GodotIfRunning() {
    $running = Get-Process -Name 'Godot_v4.5-stable_win64_console' -ErrorAction SilentlyContinue
    if ($running) {
        throw '检测到运行中的 Godot 进程，请先执行 taskkill.exe //F //IM Godot_v4.5-stable_win64_console.exe //T'
    }
}

function Get-TemplateDir([string]$VersionPrefix) {
    $rootDir = Join-Path $env:APPDATA 'Godot\export_templates'
    if (-not (Test-Path -LiteralPath $rootDir)) {
        throw "缺少 Godot 导出模板目录：$rootDir（编辑器里安装对应版本模板）"
    }
    $dir = Get-ChildItem -LiteralPath $rootDir -Directory | Where-Object { $_.Name -like "$VersionPrefix*" } | Select-Object -First 1
    if (-not $dir) {
        throw "缺少 $VersionPrefix 导出模板：$rootDir（编辑器里安装 4.5.stable 模板）"
    }
    return $dir.FullName
}

function Assert-Template([string]$TemplateDir, [string]$Pattern, [string]$Label) {
    $file = Get-ChildItem -LiteralPath $TemplateDir -File | Where-Object { $_.Name -like $Pattern } | Select-Object -First 1
    if (-not $file) {
        throw "缺少导出模板 $Label（$Pattern）：$TemplateDir"
    }
}

function Convert-ToWslPath([string]$WinPath) {
    $full = [System.IO.Path]::GetFullPath($WinPath)
    $drive = $full.Substring(0, 1).ToLower()
    $rest = $full.Substring(2).Replace('\', '/')
    return "/mnt/$drive$rest"
}

function Add-Failure([string]$Label, [string]$Message) {
    $script:results += [pscustomobject]@{ Label = $Label; Passed = $false; Message = $Message }
}

function Add-Pass([string]$Label) {
    $script:results += [pscustomobject]@{ Label = $Label; Passed = $true; Message = '' }
}

function Assert-Packed([string]$LogPath, [string]$Label) {
    $content = Get-Content -LiteralPath $LogPath -Raw
    $failures = @()
    if ($content -notmatch 'savepack.*bin/bcl/mscorlib\.dll') {
        $failures += '未打包 bin/bcl/mscorlib.dll'
    }
    if ($content -notmatch 'savepack.*bin/assemblies/LeanClrGame\.dll') {
        $failures += '未打包 bin/assemblies/LeanClrGame.dll'
    }
    if ($content -match 'savepack.*hotreload_tmp') {
        $failures += '测试素材 hotreload_tmp 被打进 PCK'
    }
    if ($content -match 'savepack.*recovery_tmp') {
        $failures += '测试素材 recovery_tmp 被打进 PCK'
    }
    if ($content -match 'savepack.*leanclr_godot\.dll') {
        $failures += 'GDExtension DLL 被打进 PCK（应留在 exe 同级）'
    }
    if ($failures.Count -gt 0) {
        Add-Failure "$Label 打包内容" ($failures -join '；')
    } else {
        Add-Pass "$Label 打包内容"
    }
}

function Assert-RunLog([string]$LogPath, [string]$Label) {
    if (-not (Test-Path -LiteralPath $LogPath)) {
        Add-Failure "$Label 运行日志" '日志文件不存在'
        return
    }
    $lines = (Get-Content -LiteralPath $LogPath).Count
    $content = Get-Content -LiteralPath $LogPath -Raw
    $failures = @()
    if ($lines -ne $ExpectedLines) {
        $failures += "基线行数 $lines != $ExpectedLines"
    }
    if ($content -notmatch '\[LeanCLR\] resolve assembly via Godot VFS: res://bin/bcl/mscorlib\.dll') {
        $failures += '缺少 Godot VFS 解析命中'
    }
    if ($content -match 'resolve assembly via filesystem') {
        $failures += '出现 filesystem 回退'
    }
    if ($content -match 'SCRIPT ERROR') {
        $failures += '出现 SCRIPT ERROR'
    }
    if ($content -match '(?m)^ERROR:') {
        $failures += '出现行首 ERROR:'
    }
    if ($content -match 'LeanCLR[^\r\n]*failed') {
        $failures += '出现 LeanCLR ... failed'
    }
    if ($failures.Count -gt 0) {
        Add-Failure "$Label 运行判定" ($failures -join '；')
    } else {
        Add-Pass "$Label 运行判定（$lines 行）"
    }
}

function Export-Preset([string]$Mode, [string]$Preset, [string]$OutDir, [string]$ExeName) {
    if (Test-Path -LiteralPath $OutDir) {
        Remove-Item -LiteralPath $OutDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $exePath = Join-Path $OutDir $ExeName
    $consoleLog = Join-Path $logDir ("export_console_$Mode.log")
    Write-Host "  导出 $Mode -> $exePath"
    & $godot --headless --path $projectDir "--export-$Mode" $Preset $exePath *> $consoleLog
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath $consoleLog | Write-Host
        throw "$Preset $Mode 导出失败，exit=$LASTEXITCODE，日志：$consoleLog"
    }
    Assert-Packed $consoleLog "$Mode 导出"
    return $OutDir
}

function Test-Windows([string]$Mode, [string]$Preset, [string]$OutDir, [string]$ExeName, [string]$ExtensionDll, [string]$RunLog) {
    Write-Stage "导出并运行 $Mode"
    $dir = Export-Preset $Mode $Preset $OutDir $ExeName
    $consoleExe = Join-Path $dir ([System.IO.Path]::GetFileNameWithoutExtension($ExeName) + '.console.exe')
    $extPath = Join-Path $dir $ExtensionDll
    if (-not (Test-Path -LiteralPath $consoleExe)) {
        Add-Failure "$Mode exe 同级文件" "缺少 $consoleExe"
    }
    if (-not (Test-Path -LiteralPath $extPath)) {
        Add-Failure "$Mode exe 同级文件" "缺少扩展库 $ExtensionDll"
    }
    if ((Test-Path -LiteralPath $consoleExe) -and (Test-Path -LiteralPath $extPath)) {
        Add-Pass "$Mode exe 同级文件（console + $ExtensionDll）"
    }
    Push-Location $dir
    try {
        & $consoleExe --headless --quit-after 120 --log-file $RunLog
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($code -ne 0) {
        Add-Failure "$Mode 退出码" "exit=$code"
    } else {
        Add-Pass "$Mode 退出码（0）"
    }
    Assert-RunLog $RunLog $Mode
}

function Test-Linux() {
    Write-Stage '导出并运行 Linux（WSL）'
    $so = Join-Path $projectDir 'bin\leanclr_godot.so'
    if (-not (Test-Path -LiteralPath $so)) {
        throw "缺少 Linux 扩展库：$so（构建命令见 docs/02 §7 / docs/04 §6.2）"
    }
    $outDir = Join-Path $outRoot 'export\linux'
    $exeName = 'leanclr_gotdot.x86_64'
    $dir = Export-Preset 'debug' 'Linux' $outDir $exeName
    $soCopy = Join-Path $dir 'leanclr_godot.so'
    if (Test-Path -LiteralPath $soCopy) {
        Add-Pass 'Linux exe 同级文件（leanclr_godot.so）'
    } else {
        Add-Failure 'Linux exe 同级文件' '缺少 leanclr_godot.so'
    }
    $runLog = Join-Path $logDir 'godot_pck_export_linux.log'
    $wslDir = Convert-ToWslPath $dir
    $wslLog = Convert-ToWslPath $runLog
    $output = & wsl -d $WslDistro -- bash -lc "cd '$wslDir' && chmod +x $exeName && ./$exeName --headless --quit-after 120 --log-file '$wslLog'; echo RUN_EXIT=`$?"
    $output | Write-Host
    if (($output -join "`n") -notmatch 'RUN_EXIT=0') {
        Add-Failure 'Linux 退出码' '非 0'
    } else {
        Add-Pass 'Linux 退出码（0）'
    }
    Assert-RunLog $runLog 'Linux'
}

$watch = [System.Diagnostics.Stopwatch]::StartNew()
Write-Stage 'PCK 导出后运行验证'

Assert-Command 'dotnet' '安装 .NET SDK 后重试' | Out-Null
if (-not (Test-Path -LiteralPath $godot)) {
    throw "缺少 Godot：$godot（见 docs/01）"
}
Stop-GodotIfRunning
foreach ($dir in @($logDir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$templateDir = Get-TemplateDir '4.5'
if ($Target -ne 'release') {
    Assert-Template $templateDir 'windows_debug_x86_64*.exe' 'windows_debug_x86_64.exe'
}
if ($Target -ne 'debug') {
    Assert-Template $templateDir 'windows_release_x86_64*.exe' 'windows_release_x86_64.exe'
}
if ($IncludeLinux) {
    Assert-Template $templateDir 'linux_debug.x86_64' 'linux_debug.x86_64'
}

if (-not $SkipBuild) {
    Write-Stage '1/3 重建扩展与托管程序集'
    if ($Target -ne 'release') {
        Write-Host '  构建 template_debug 扩展（scripts\build_native.bat）'
        & (Join-Path $PSScriptRoot 'build_native.bat')
        if ($LASTEXITCODE -ne 0) { throw "build_native.bat 失败，exit=$LASTEXITCODE" }
    }
    if ($Target -ne 'debug') {
        Write-Host '  构建 template_release 扩展（scripts\build_native_release.bat）'
        & (Join-Path $PSScriptRoot 'build_native_release.bat')
        if ($LASTEXITCODE -ne 0) { throw "build_native_release.bat 失败，exit=$LASTEXITCODE" }
    }
    Write-Host '  构建托管程序集（LeanClrGame v1）'
    & dotnet build (Join-Path $root 'demo_csharp\LeanClrGame.csproj') -c Release -nologo -v:minimal
    if ($LASTEXITCODE -ne 0) { throw "dotnet build LeanClrGame.csproj 失败，exit=$LASTEXITCODE" }
} else {
    Write-Stage '1/3 跳过重建（-SkipBuild）'
}

if (-not (Test-Path -LiteralPath $bclCore)) {
    throw "缺少 BCL：$bclCore（见 docs/02）"
}
if (-not (Test-Path -LiteralPath $managedGame)) {
    throw "缺少托管程序集：$managedGame（先编译 LeanClrGame.csproj）"
}

Write-Stage '2/3 Windows 导出与运行'
if ($Target -ne 'release') {
    Test-Windows 'debug' 'Windows Desktop' (Join-Path $outRoot 'export\dbg') 'leanclr_godot.exe' 'leanclr_godot.dll' (Join-Path $logDir 'godot_pck_export_dbg.log')
}
if ($Target -ne 'debug') {
    Test-Windows 'release' 'Windows Desktop' (Join-Path $outRoot 'export\rel') 'leanclr_godot.exe' 'leanclr_godot.release.dll' (Join-Path $logDir 'godot_pck_export_rel.log')
}

if ($IncludeLinux) {
    Write-Stage '3/3 Linux 导出与 WSL 运行'
    Test-Linux
} else {
    Write-Stage '3/3 跳过 Linux（加 -IncludeLinux 启用）'
}

Write-Host '[结果]'
$failed = $false
foreach ($result in $results) {
    if ($result.Passed) {
        Write-Host "  PASS  $($result.Label)" -ForegroundColor Green
    } else {
        Write-Host "  FAIL  $($result.Label)：$($result.Message)" -ForegroundColor Red
        $failed = $true
    }
}
$watch.Stop()
if ($failed) {
    Write-Host ('FAIL  用时 {0:N1}s' -f $watch.Elapsed.TotalSeconds) -ForegroundColor Red
    exit 1
}
Write-Host ('PASS  用时 {0:N1}s' -f $watch.Elapsed.TotalSeconds) -ForegroundColor Green
exit 0
