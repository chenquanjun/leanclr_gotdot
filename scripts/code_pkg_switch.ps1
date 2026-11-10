# 多代码包切换 demo：构建基线/A/B 三套程序集，生成带内容哈希名的代码包，
# 启动本地 HTTP 源并运行 godot_project/code_pkg_switch.tscn。
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\code_pkg_switch.ps1            # 交互式（窗口 + 按钮）
#   powershell -ExecutionPolicy Bypass -File scripts\code_pkg_switch.ps1 -Test      # CLI + MCP 自动断言
#   powershell -ExecutionPolicy Bypass -File scripts\code_pkg_switch.ps1 -Test -Channel cli
#   powershell -ExecutionPolicy Bypass -File scripts\code_pkg_switch.ps1 -Android   # MuMu 上等效触发 A/B/A
[CmdletBinding()]
param(
    [switch]$Test,
    [ValidateSet('cli', 'mcp', 'both')]
    [string]$Channel = 'both',
    [switch]$SkipBuild,
    [switch]$SkipExport,
    [switch]$Android,
    [ValidateSet('x86_64', 'arm64-v8a', 'armeabi-v7a')]
    [string]$Abi = 'x86_64',
    [string]$Serial = '',
    [int]$TimeoutSeconds = 180,
    [int]$Port = 18080
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'repo.ps1')
$root = Split-Path -Parent $PSScriptRoot
$projectDir = Join-Path $root 'godot_project'
$demoDir = Join-Path $root 'demo_csharp'
$outRoot = Get-OutRoot
$logDir = Join-Path $outRoot 'logs'
$pkgTmp = Join-Path $outRoot 'tmp\code_pkg'
$packagesRoot = Join-Path $outRoot 'packages'
$switchRoot = Join-Path $packagesRoot 'switch'
$assembliesDir = Join-Path $projectDir 'bin\assemblies'
$godot = Resolve-GodotExe
$mcpServer = Join-Path $root '.tools\godot-mcp\build\index.js'
$scene = 'res://code_pkg_switch.tscn'
$serverLog = Join-Path $logDir 'code_pkg_server.log'
$serverErr = Join-Path $logDir 'code_pkg_server.err.log'
$preset = "Android $Abi"
$apk = Join-Path $outRoot ("android\LeanClrCodePkgSwitch-" + $Abi + '.apk')
$exportLog = Join-Path $logDir ("android_switch_export_" + $Abi + '.log')
$androidLog = Join-Path $logDir ("android_code_pkg_switch_" + $Abi + '.log')
$package = 'org.godotengine.leanclrcodepkg'
$activity = 'com.godot.game.GodotApp'

$required = @(
    @{ Name = '测试开始'; Pattern = '=== code pkg switch test ===' },
    @{ Name = '初始版本'; Pattern = 'switch initial version = v1' },
    @{ Name = '初始代次'; Pattern = 'switch initial generation = 0' },
    @{ Name = '初始计分'; Pattern = 'switch initial compute 10 = 10' },
    @{ Name = 'A 版本'; Pattern = 'switch a version = A' },
    @{ Name = 'A 计分'; Pattern = 'switch a compute 10 = 30' },
    @{ Name = 'A 特性'; Pattern = 'switch a feature = triple-score-a' },
    @{ Name = 'A 代次 +1'; Pattern = 'switch a generation delta = 1' },
    @{ Name = 'A 状态版本'; Pattern = 'switch a state version = A' },
    @{ Name = 'A 颜色'; Pattern = 'switch a color = A' },
    @{ Name = 'A 旧句柄失效'; Pattern = 'switch a old handle stale = true' },
    @{ Name = 'A manifest query'; Pattern = 'switch manifest url = http://127\.0\.0\.1:18080/switch/a/manifest\.json\?v=0' },
    @{ Name = 'B 版本'; Pattern = 'switch b version = B' },
    @{ Name = 'B 计分'; Pattern = 'switch b compute 10 = 40' },
    @{ Name = 'B 特性'; Pattern = 'switch b feature = quad-score-b' },
    @{ Name = 'B 代次 +1'; Pattern = 'switch b generation delta = 1' },
    @{ Name = 'B 状态版本'; Pattern = 'switch b state version = B' },
    @{ Name = 'B 颜色'; Pattern = 'switch b color = B' },
    @{ Name = 'B manifest query 使用已装版本'; Pattern = 'switch manifest url = http://127\.0\.0\.1:18080/switch/b/manifest\.json\?v=A' },
    @{ Name = 'A 往返版本'; Pattern = 'switch a2 version = A' },
    @{ Name = 'A 往返代次'; Pattern = 'switch a2 generation delta = 1' },
    @{ Name = 'A 往返计分'; Pattern = 'switch a2 compute 10 = 30' },
    @{ Name = '重复切换幂等'; Pattern = 'switch a3 skipped = true' },
    @{ Name = '幂等不增代次'; Pattern = 'switch a3 generation delta = 0' },
    @{ Name = '幂等保持版本'; Pattern = 'switch a3 version = A' },
    @{ Name = '坏哈希拒绝'; Pattern = 'switch bad rejected = true' },
    @{ Name = '坏哈希原因'; Pattern = 'switch bad error = sha256 mismatch' },
    @{ Name = '坏包后保持版本'; Pattern = 'switch bad version kept = A' },
    @{ Name = '坏包不增代次'; Pattern = 'switch bad generation unchanged = true' },
    @{ Name = '回基线版本'; Pattern = 'switch baseline version = v1' },
    @{ Name = '回基线代次'; Pattern = 'switch baseline generation delta = 1' },
    @{ Name = '回基线清除覆盖'; Pattern = 'switch baseline override cleared = true' },
    @{ Name = '回基线节点版本'; Pattern = 'switch baseline node version = v1' },
    @{ Name = '完成标记'; Pattern = '=== code pkg switch done ===' }
)
$forbidden = @(
    @{ Name = '脚本错误'; Pattern = 'SCRIPT ERROR' },
    @{ Name = '扩展加载失败'; Pattern = 'Failed to load library' }
)

function Write-Stage([string]$Text) {
    Write-Host "[$Text]" -ForegroundColor Cyan
}

function Assert-Command([string]$Name, [string]$Hint) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "找不到 $Name：$Hint" }
    return $cmd.Source
}

function Build-Pkg([string]$Variant, [string]$Label) {
    Write-Host "  编译 $Label (PkgVariant=$Variant)"
    $log = Join-Path $logDir ("build_LeanClrCodePkg_" + $Variant + '.log')
    & dotnet build (Join-Path $demoDir 'LeanClrCodePkg.csproj') -c Release -nologo -v:minimal -p:PkgVariant=$Variant *> $log
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath $log | Write-Host
        throw "dotnet build LeanClrCodePkg ($Variant) 失败，exit=$LASTEXITCODE，日志：$log"
    }
}

function Get-HashedName([string]$Sha256) {
    return 'LeanClrCodePkg.' + $Sha256.Substring(0, 16) + '.dll'
}

function Write-Manifest([string]$Dir, [string]$Version, [string]$Name, [string]$DllPath, [string]$Sha256) {
    $size = (Get-Item -LiteralPath $DllPath).Length
    $json = @"
{
  "package_version": "$Version",
  "assembly": "LeanClrCodePkg",
  "files": [
    { "name": "$Name", "size": $size, "sha256": "$Sha256" }
  ]
}
"@
    [System.IO.File]::WriteAllText((Join-Path $Dir 'manifest.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Prepare-Packages {
    foreach ($dir in @($switchRoot)) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force
        }
    }
    foreach ($name in @('a', 'b', 'bad-sha')) {
        New-Item -ItemType Directory -Path (Join-Path $switchRoot $name) -Force | Out-Null
    }

    $aDll = Join-Path $pkgTmp 'a\LeanClrCodePkg.dll'
    $bDll = Join-Path $pkgTmp 'b\LeanClrCodePkg.dll'
    foreach ($dll in @($aDll, $bDll)) {
        if (-not (Test-Path -LiteralPath $dll)) {
            throw "缺少程序集：$dll（去掉 -SkipBuild 重新构建）"
        }
    }

    $aSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $aDll).Hash.ToLower()
    $aName = Get-HashedName $aSha
    Copy-Item -LiteralPath $aDll -Destination (Join-Path (Join-Path $switchRoot 'a') $aName) -Force
    Write-Manifest (Join-Path $switchRoot 'a') 'A' $aName (Join-Path (Join-Path $switchRoot 'a') $aName) $aSha

    $bSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $bDll).Hash.ToLower()
    $bName = Get-HashedName $bSha
    Copy-Item -LiteralPath $bDll -Destination (Join-Path (Join-Path $switchRoot 'b') $bName) -Force
    Write-Manifest (Join-Path $switchRoot 'b') 'B' $bName (Join-Path (Join-Path $switchRoot 'b') $bName) $bSha

    # 坏包：manifest 声明 A 的哈希，实际内容换成 B，用于验证 SHA 校验拒绝。
    $badName = Get-HashedName $aSha
    Copy-Item -LiteralPath $bDll -Destination (Join-Path (Join-Path $switchRoot 'bad-sha') $badName) -Force
    Write-Manifest (Join-Path $switchRoot 'bad-sha') 'bad' $badName (Join-Path (Join-Path $switchRoot 'bad-sha') $badName) $aSha

    Write-Host "  包目录 $switchRoot"
    Get-ChildItem -LiteralPath $switchRoot -Recurse -File | ForEach-Object {
        Write-Host ("    {0}  {1} bytes" -f $_.FullName.Substring($switchRoot.Length + 1), $_.Length)
    }
}

function Export-Apk {
    $projectFile = Join-Path $projectDir 'project.godot'
    $original = [System.IO.File]::ReadAllText($projectFile)
    $patched = [regex]::Replace($original, 'run/main_scene="[^"]*"', ('run/main_scene="' + $scene + '"'))
    if ($patched -eq $original) {
        throw 'project.godot 中未找到 run/main_scene，无法切换到切换 demo 场景'
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $apk) -Force | Out-Null
    try {
        [System.IO.File]::WriteAllText($projectFile, $patched, (New-Object System.Text.UTF8Encoding($false)))
        # 预设里的 keystore 路径入库时为空，导出前注入本机/CI 的实际路径，导出后还原。
        Invoke-WithDebugKeystore -ProjectDir $projectDir -Body {
            $proc = Start-Process -FilePath $godot -PassThru -Wait -NoNewWindow `
                -ArgumentList @('--headless', '--path', $projectDir, '--export-debug', ('"' + $preset + '"'), $apk) `
                -RedirectStandardOutput $exportLog -RedirectStandardError ($exportLog + '.err')
            if ($proc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $apk)) {
                Get-Content -LiteralPath $exportLog | Select-Object -Last 20 | Write-Host
                throw "Android 导出失败，exit=$($proc.ExitCode)，日志：$exportLog"
            }
        }
    } finally {
        [System.IO.File]::WriteAllText($projectFile, $original, (New-Object System.Text.UTF8Encoding($false)))
    }
    Write-Host "  APK $apk"
}

function Invoke-AndroidTest {
    $adb = Resolve-Adb
    if (-not $Serial) {
        & $adb connect 127.0.0.1:16384 | Out-Null
        Start-Sleep -Seconds 2
        $script:Serial = '127.0.0.1:16384'
    } elseif ($Serial -match ':\d+$') {
        & $adb connect $Serial | Out-Null
        Start-Sleep -Seconds 2
    }
    $state = (& $adb -s $Serial get-state 2>&1) -join ' '
    if ($state -notmatch 'device') { throw "设备 $Serial 不可用（$state）" }
    Write-Host "  设备 $Serial ($(& $adb -s $Serial shell getprop ro.product.cpu.abi))"
    $install = (& $adb -s $Serial install -r $apk 2>&1) -join "`n"
    if ($install -notmatch 'Success') { throw "adb install 失败：`n$install" }
    & $adb -s $Serial reverse "tcp:$Port" "tcp:$Port" | Out-Null
    & $adb -s $Serial shell pm clear $package | Out-Null
    # Android 无法注入环境变量，用 user:// 标记文件触发与桌面相同的自动断言。
    & $adb -s $Serial shell "run-as $package sh -c 'mkdir -p files; echo 1 > files/switch_autotest.flag'" | Out-Null
    $flag = (& $adb -s $Serial shell "run-as $package ls files" 2>&1) -join ' '
    if ($flag -notmatch 'switch_autotest\.flag') { throw "无法创建 user:// 触发标记：$flag" }
    & $adb -s $Serial logcat -c
    & $adb -s $Serial shell am start -n "$package/$activity" | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 5
        $lines = & $adb -s $Serial logcat -d 2>&1
    } while ((Get-Date) -lt $deadline -and
        -not ($lines -match 'code pkg switch done ===') -and
        -not ($lines -match 'F/libc') -and
        -not ($lines -match 'Fatal signal'))
    & $adb -s $Serial shell am force-stop $package 2>&1 | Out-Null
    $lines | Set-Content -LiteralPath $androidLog -Encoding UTF8
    Write-Host "  logcat $androidLog"
}

function Test-Regression([string]$LogPath, [string]$Label) {
    $content = Get-Content -LiteralPath $LogPath -Raw -Encoding UTF8
    $passed = 0
    $failed = @()
    foreach ($item in $required) {
        if ($content -match $item.Pattern) {
            $passed++
        } else {
            $failed += $item
        }
    }
    foreach ($item in $forbidden) {
        if ($content -match $item.Pattern) {
            $failed += $item
        }
    }
    return [pscustomobject]@{
        Label = $Label
        Passed = ($failed.Count -eq 0)
        Matched = $passed
        Total = $required.Count
        Failed = $failed
        Log = $LogPath
    }
}

function Print-Result($Result) {
    if ($Result.Passed) {
        Write-Host ("  {0}: {1}/{2} 项通过" -f $Result.Label, $Result.Matched, $Result.Total) -ForegroundColor Green
    } else {
        Write-Host ("  {0}: {1}/{2} 项通过，失败：" -f $Result.Label, $Result.Matched, $Result.Total) -ForegroundColor Red
        foreach ($item in $Result.Failed) {
            Write-Host ("    - {0}（{1}）" -f $item.Name, $item.Pattern)
        }
    }
    Write-Host "  日志: $($Result.Log)"
}

$watch = [System.Diagnostics.Stopwatch]::StartNew()
Write-Stage '多代码包切换 demo'

$dotnet = Assert-Command 'dotnet' '安装 .NET SDK 后重试'
$node = Assert-Command 'node' '安装 Node.js >= 18 后重试'
if (-not (Test-Path -LiteralPath $godot)) {
    throw "缺少 Godot：$godot（见 docs/01）"
}
if ($Test -and $Channel -ne 'cli' -and -not (Test-Path -LiteralPath $mcpServer)) {
    throw "缺少 godot-mcp：$mcpServer（见 docs/04 §8；或用 -Channel cli 跳过 MCP）"
}
if (-not $Android) {
    $running = Get-Process -Name 'Godot_v4.5-stable_win64_console' -ErrorAction SilentlyContinue
    if ($running) {
        throw '检测到运行中的 Godot 进程，请先关闭游戏窗口再重试'
    }
}
foreach ($dir in @($logDir, $pkgTmp, $assembliesDir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

if (-not $SkipBuild) {
    Write-Stage '1/3 编译基线/A/B 程序集'
    Build-Pkg 'v1' '内置基线（v1）'
    Build-Pkg 'a' '代码包 A'
    Build-Pkg 'b' '代码包 B'
    $v1Dll = Join-Path $pkgTmp 'v1\LeanClrCodePkg.dll'
    if (-not (Test-Path -LiteralPath $v1Dll)) {
        throw "缺少 v1 程序集：$v1Dll"
    }
    Copy-Item -LiteralPath $v1Dll -Destination (Join-Path $assembliesDir 'LeanClrCodePkg.dll') -Force
} else {
    Write-Stage '1/3 跳过编译（-SkipBuild）'
}

Write-Stage '2/3 生成代码包与本地 HTTP 源'
Prepare-Packages

$server = $null
$results = @()
try {
    $server = Start-Process -FilePath $node -PassThru -NoNewWindow `
        -ArgumentList @((Join-Path $PSScriptRoot 'code_pkg_server.mjs'), '--root', $packagesRoot, '--port', "$Port") `
        -RedirectStandardOutput $serverLog -RedirectStandardError $serverErr
    $deadline = (Get-Date).AddSeconds(10)
    $listening = $false
    while ((Get-Date) -lt $deadline -and -not $listening) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $client.Connect('127.0.0.1', $Port)
            $client.Close()
            $listening = $true
        } catch {
            Start-Sleep -Milliseconds 200
        }
    }
    if (-not $listening) {
        throw "本地 HTTP 服务未就绪，日志：$serverLog / $serverErr"
    }
    Write-Host "  HTTP 源 http://127.0.0.1:$Port/switch/<a|b|bad-sha>"

    if ($Android) {
        Write-Stage "3/3 Android 等效触发（$Abi）"
        if (-not $SkipExport) {
            Export-Apk
        } elseif (-not (Test-Path -LiteralPath $apk)) {
            throw "缺少 APK：$apk（去掉 -SkipExport 重新导出）"
        }
        Invoke-AndroidTest
        $results += Test-Regression $androidLog "Android $Abi"
    } elseif ($Test) {
        Write-Stage '3/3 自动验证'
        $env:LEANCLR_SWITCH_TEST = '1'
        try {
            if ($Channel -ne 'mcp') {
                $cliLog = Join-Path $logDir 'code_pkg_switch_cli.log'
                & $godot --headless --path $projectDir --quit-after 900 --log-file $cliLog $scene | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Godot CLI 运行失败，exit=$LASTEXITCODE，日志：$cliLog"
                }
                $results += Test-Regression $cliLog 'CLI'
            }
            if ($Channel -ne 'cli') {
                $mcpLog = Join-Path $logDir 'code_pkg_switch_mcp.log'
                $mcpRawLog = Join-Path $logDir 'code_pkg_switch_mcp_raw.log'
                & $node (Join-Path $PSScriptRoot 'mcp_run_scene.mjs') `
                    --project $projectDir `
                    --scene $scene `
                    --log $mcpLog `
                    --raw-log $mcpRawLog `
                    --godot $godot `
                    --quit-after 900 `
                    --timeout 180
                if ($LASTEXITCODE -ne 0) {
                    throw "MCP 通道运行失败，exit=$LASTEXITCODE，日志：$mcpLog"
                }
                $results += Test-Regression $mcpLog 'MCP'
            }
        } finally {
            Remove-Item Env:\LEANCLR_SWITCH_TEST -ErrorAction SilentlyContinue
        }
    } else {
        Write-Stage '3/3 交互式运行（点击按钮切换代码包）'
        & $godot --path $projectDir $scene
        Write-Host '  窗口已关闭，HTTP 源将停止'
    }
} finally {
    if ($server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
}

if (-not $Test -and -not $Android) {
    $watch.Stop()
    Write-Host ("DONE  用时 {0:N1}s" -f $watch.Elapsed.TotalSeconds) -ForegroundColor Green
    exit 0
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
