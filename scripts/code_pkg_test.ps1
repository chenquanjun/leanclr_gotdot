# 代码包热更新验证：构建 v1/v2 -> 本地 HTTP 源 -> CLI/MCP 双通道 -> 断言。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\code_pkg_test.ps1 [-Channel cli|mcp|both] [-SkipBuild]
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
$pkgTmp = Join-Path (Join-Path $outRoot 'tmp') 'code_pkg'
$assembliesDir = Join-Path (Join-Path $projectDir 'bin') 'assemblies'
$packagesRoot = Join-Path $outRoot 'packages'
$godot = Resolve-GodotExe -Explicit $GodotExe
$mcpServer = Join-Path (Join-Path (Join-Path $root '.tools') 'godot-mcp') (Join-Path 'build' 'index.js')
$scene = 'res://code_pkg_test.tscn'
$cliLog = Join-Path $logDir 'godot_code_pkg_test.log'
$mcpLog = Join-Path $logDir 'godot_code_pkg_test_mcp.log'
$mcpRawLog = Join-Path $logDir 'godot_mcp_code_pkg_raw.log'
$serverLog = Join-Path $logDir 'code_pkg_server.log'
$serverErr = Join-Path $logDir 'code_pkg_server.err.log'
$port = 18080

$required = @(
    @{ Name = '初始无覆盖'; Pattern = 'pkg initial override = false' },
    @{ Name = '初始 generation'; Pattern = 'pkg initial generation = 0' },
    @{ Name = '加载程序集'; Pattern = 'pkg loaded assemblies = LeanClrCodePkg' },
    @{ Name = 'v1 版本'; Pattern = 'pkg v1 version = v1' },
    @{ Name = 'v1 Answer'; Pattern = 'pkg v1 answer 11 = true' },
    @{ Name = 'v1 行为'; Pattern = 'pkg v1 compute 10 = 10' },
    @{ Name = 'v1 特性'; Pattern = 'pkg v1 feature base = true' },
    @{ Name = '节点创建'; Pattern = 'pkg node created = true' },
    @{ Name = '节点初始版本'; Pattern = 'pkg node v1 version = v1' },
    @{ Name = '节点初始代次'; Pattern = 'pkg node bound generation = true' },
    @{ Name = 'manifest 版本'; Pattern = 'pkg manifest version = v2' },
    @{ Name = 'manifest query 拼接'; Pattern = 'pkg v2 manifest url = http://127\.0\.0\.1:18080/good/manifest\.json\?v=0' },
    @{ Name = 'manifest query 生效'; Pattern = 'pkg v2 manifest url has query = true' },
    @{ Name = '实际请求 URL 带 query'; Pattern = '\[codepkg\] GET http://127\.0\.0\.1:18080/good/manifest\.json\?v=0' },
    @{ Name = 'DLL 内容哈希名'; Pattern = 'pkg manifest file = LeanClrCodePkg\.[0-9a-f]{16}\.dll' },
    @{ Name = 'DLL 哈希名判定'; Pattern = 'pkg manifest file hashed = true' },
    @{ Name = '文件校验数'; Pattern = 'pkg verified files = 1' },
    @{ Name = 'reload 返回'; Pattern = 'pkg reload returned = true' },
    @{ Name = 'reload 阶段'; Pattern = 'pkg reload stage = done' },
    @{ Name = '代次 +1'; Pattern = 'pkg generation delta = 1' },
    @{ Name = '落到 user://'; Pattern = 'pkg user assembly exists = true' },
    @{ Name = '安装固定名'; Pattern = 'pkg installed names = LeanClrCodePkg\.dll' },
    @{ Name = 'user 目录仅固定名'; Pattern = 'pkg user dir files = LeanClrCodePkg\.dll' },
    @{ Name = '暂存区已清理'; Pattern = 'pkg download dir empty = true' },
    @{ Name = '状态版本'; Pattern = 'pkg installed state version = v2' },
    @{ Name = 'user 路径加载'; Pattern = 'resolve assembly via filesystem: .*code_pkg[\\/]assemblies[\\/]LeanClrCodePkg\.dll' },
    @{ Name = '旧句柄失效'; Pattern = 'pkg old handle is null = true' },
    @{ Name = '旧句柄报错'; Pattern = 'pkg old handle error = (invalid object handle|stale type identity)' },
    @{ Name = 'v2 版本'; Pattern = 'pkg v2 version = v2' },
    @{ Name = 'v2 Answer'; Pattern = 'pkg v2 answer 22 = true' },
    @{ Name = 'v2 行为'; Pattern = 'pkg v2 compute 10 = 20' },
    @{ Name = 'v2 特性'; Pattern = 'pkg v2 feature double = true' },
    @{ Name = '节点重绑版本'; Pattern = 'pkg node rebound version = v2' },
    @{ Name = '节点重绑代次'; Pattern = 'pkg node rebound generation = true' },
    @{ Name = '节点无待重绑'; Pattern = 'pkg node pending rebind = false' },
    @{ Name = '原生节点重绑日志'; Pattern = '\[hotreload\] node rebound: type=CodePkgNode, generation=1, signals=0' },
    @{ Name = 'v3 query 使用已装版本'; Pattern = 'pkg v3 manifest url uses v2 = true' },
    @{ Name = 'v3 实际请求 URL 带 query'; Pattern = '\[codepkg\] GET http://127\.0\.0\.1:18080/good-v3/manifest\.json\?v=v2' },
    @{ Name = 'v3 manifest 版本'; Pattern = 'pkg v3 manifest version = v3' },
    @{ Name = 'v3 DLL 哈希名'; Pattern = 'pkg v3 manifest file = LeanClrCodePkg\.[0-9a-f]{16}\.dll' },
    @{ Name = '哈希名随内容变化'; Pattern = 'pkg v3 file name changed = true' },
    @{ Name = 'v3 哈希名判定'; Pattern = 'pkg v3 manifest file hashed = true' },
    @{ Name = 'v3 reload 阶段'; Pattern = 'pkg v3 reload stage = done' },
    @{ Name = 'v3 代次 +1'; Pattern = 'pkg v3 generation delta = 1' },
    @{ Name = 'v3 状态版本'; Pattern = 'pkg v3 installed state version = v3' },
    @{ Name = 'v3 仅固定名'; Pattern = 'pkg v3 user dir files = LeanClrCodePkg\.dll' },
    @{ Name = '旧 v2 DLL 未被误用'; Pattern = 'pkg old v2 dll absent = true' },
    @{ Name = '旧 v2 暂存已清理'; Pattern = 'pkg old v2 download absent = true' },
    @{ Name = 'v3 暂存区已清理'; Pattern = 'pkg download dir empty after v3 = true' },
    @{ Name = 'v3 版本'; Pattern = 'pkg v3 version = v3' },
    @{ Name = 'v3 行为'; Pattern = 'pkg v3 compute 10 = 30' },
    @{ Name = 'v3 特性'; Pattern = 'pkg v3 feature triple = true' },
    @{ Name = 'v3 节点版本'; Pattern = 'pkg node v3 version = v3' },
    @{ Name = 'v3 节点代次'; Pattern = 'pkg node v3 generation = true' },
    @{ Name = '原生节点重绑日志 v3'; Pattern = '\[hotreload\] node rebound: type=CodePkgNode, generation=2, signals=0' },
    @{ Name = '坏 SHA 拒绝'; Pattern = 'pkg bad sha rejected = true' },
    @{ Name = '坏 SHA 原因'; Pattern = 'pkg bad sha error = sha256 mismatch' },
    @{ Name = '坏 SHA 后版本'; Pattern = 'pkg version after bad sha = v3' },
    @{ Name = '坏 SHA 后代次'; Pattern = 'pkg generation after bad sha = true' },
    @{ Name = '坏类型回退'; Pattern = 'pkg broken type rolled back = true' },
    @{ Name = '回退后版本'; Pattern = 'pkg version after rollback = v3' },
    @{ Name = '回退版本一致'; Pattern = 'pkg rolled back version matches = true' },
    @{ Name = '回退后已 reload'; Pattern = 'pkg rollback reloaded = true' },
    @{ Name = '回退后可执行'; Pattern = 'pkg after rollback version = v3' },
    @{ Name = '回退后行为'; Pattern = 'pkg after rollback compute 10 = 30' },
    @{ Name = '回退后节点版本'; Pattern = 'pkg node after rollback version = v3' },
    @{ Name = '回退后节点代次'; Pattern = 'pkg node after rollback gen = true' },
    @{ Name = '应用成功日志'; Pattern = '\[codepkg\] applied version=v2 files=1 generation=0->1 installed=\["LeanClrCodePkg\.dll"\]' },
    @{ Name = '应用 v3 日志'; Pattern = '\[codepkg\] applied version=v3 files=1 generation=1->2 installed=\["LeanClrCodePkg\.dll"\]' },
    @{ Name = '完成标记'; Pattern = '=== code pkg test done ===' }
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
    if (Test-Path -LiteralPath $packagesRoot) {
        Remove-Item -LiteralPath $packagesRoot -Recurse -Force
    }
    $goodDir = Join-Path $packagesRoot 'good'
    $v3Dir = Join-Path $packagesRoot 'good-v3'
    $badDir = Join-Path $packagesRoot 'bad-sha'
    $brokenDir = Join-Path $packagesRoot 'broken-type'
    foreach ($dir in @($goodDir, $v3Dir, $badDir, $brokenDir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $v2Dll = Join-Path (Join-Path $pkgTmp 'v2') 'LeanClrCodePkg.dll'
    if (-not (Test-Path -LiteralPath $v2Dll)) {
        throw "缺少 v2 程序集：$v2Dll（去掉 -SkipBuild 重新构建）"
    }
    $goodSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $v2Dll).Hash.ToLower()
    $goodName = Get-HashedName $goodSha
    $goodDll = Join-Path $goodDir $goodName
    Copy-Item -LiteralPath $v2Dll -Destination $goodDll -Force
    Write-Manifest $goodDir 'v2' $goodName $goodDll $goodSha

    $v3Dll = Join-Path (Join-Path $pkgTmp 'v3') 'LeanClrCodePkg.dll'
    if (-not (Test-Path -LiteralPath $v3Dll)) {
        throw "缺少 v3 程序集：$v3Dll（去掉 -SkipBuild 重新构建）"
    }
    $v3Sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $v3Dll).Hash.ToLower()
    $v3Name = Get-HashedName $v3Sha
    $v3Out = Join-Path $v3Dir $v3Name
    Copy-Item -LiteralPath $v3Dll -Destination $v3Out -Force
    Write-Manifest $v3Dir 'v3' $v3Name $v3Out $v3Sha
    if ($v3Name -eq $goodName) {
        throw "v2/v3 内容哈希名相同，无法验证命名策略：$goodName"
    }

    # 同长度、改一个字节：size 通过、sha256 不通过。
    $badDll = Join-Path $badDir $goodName
    $bytes = [System.IO.File]::ReadAllBytes($goodDll)
    $index = [int]($bytes.Length / 2)
    $bytes[$index] = [byte](($bytes[$index] + 1) % 256)
    [System.IO.File]::WriteAllBytes($badDll, $bytes)
    Write-Manifest $badDir 'v2-badsha' $goodName $badDll $goodSha

    # 合法 PE 但不是 LeanClrCodePkg：reload 后类型探测失败，触发回退。
    $other = Get-ChildItem -LiteralPath $assembliesDir -Filter '*.dll' |
        Where-Object { $_.Name -notlike 'LeanClrCodePkg*' -and $_.Name -notlike 'mscorlib*' -and $_.Name -notlike 'System*' } |
        Select-Object -First 1
    if (-not $other) {
        throw "缺少可用于构造坏类型包的程序集（bin/assemblies 下没有其他 DLL）"
    }
    $brokenSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $other.FullName).Hash.ToLower()
    $brokenName = Get-HashedName $brokenSha
    $brokenDll = Join-Path $brokenDir $brokenName
    Copy-Item -LiteralPath $other.FullName -Destination $brokenDll -Force
    Write-Manifest $brokenDir 'broken-type' $brokenName $brokenDll $brokenSha
    Write-Host "  v2 DLL  $goodName"
    Write-Host "  v3 DLL  $v3Name"
    Write-Host "  坏类型包使用 $($other.Name)"
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
Write-Stage '代码包热更新验证'

$dotnet = Assert-Command 'dotnet' '安装 .NET SDK 后重试'
$node = Assert-Command 'node' '安装 Node.js >= 18 后重试'
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
foreach ($dir in @($logDir, $pkgTmp, $assembliesDir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

if (-not $SkipBuild) {
    Write-Stage '1/4 编译 v1/v2/v3 程序集'
    Build-Pkg 'v1' '内置基线（v1）'
    Build-Pkg 'v2' '下载包（v2）'
    Build-Pkg 'v3' '第二版下载包（v3，验证哈希名随内容变化）'
} else {
    Write-Stage '1/4 跳过编译（-SkipBuild）'
}

Write-Stage '2/4 生成代码包与本地 HTTP 源'
$v1Dll = Join-Path (Join-Path $pkgTmp 'v1') 'LeanClrCodePkg.dll'
if (-not (Test-Path -LiteralPath $v1Dll)) {
    throw "缺少 v1 程序集：$v1Dll"
}
Copy-Item -LiteralPath $v1Dll -Destination (Join-Path $assembliesDir 'LeanClrCodePkg.dll') -Force
Prepare-Packages

$server = $null
try {
    $server = Start-Process -FilePath $node -PassThru -NoNewWindow `
        -ArgumentList @((Join-Path $PSScriptRoot 'code_pkg_server.mjs'), '--root', $packagesRoot, '--port', "$port") `
        -RedirectStandardOutput $serverLog -RedirectStandardError $serverErr
    $deadline = (Get-Date).AddSeconds(10)
    $listening = $false
    while ((Get-Date) -lt $deadline -and -not $listening) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $client.Connect('127.0.0.1', $port)
            $client.Close()
            $listening = $true
        } catch {
            Start-Sleep -Milliseconds 200
        }
    }
    if (-not $listening) {
        throw "本地 HTTP 服务未就绪，日志：$serverLog / $serverErr"
    }
    Write-Host "  HTTP 源 http://127.0.0.1:$port/ root=$packagesRoot"
    $manifestHeaders = (Invoke-WebRequest "http://127.0.0.1:$port/good/manifest.json" -Method Head -UseBasicParsing).Headers
    $dllName = (Get-ChildItem -LiteralPath (Join-Path $packagesRoot 'good') -Filter '*.dll' | Select-Object -First 1).Name
    $dllHeaders = (Invoke-WebRequest "http://127.0.0.1:$port/good/$dllName" -Method Head -UseBasicParsing).Headers
    $manifestCache = ($manifestHeaders['Cache-Control'] -join '')
    $dllCache = ($dllHeaders['Cache-Control'] -join '')
    if ($manifestCache -notmatch 'no-cache') {
        throw "manifest Cache-Control 不符合预期: $manifestCache"
    }
    if ($dllCache -notmatch 'immutable') {
        throw "哈希 DLL Cache-Control 不符合预期: $dllCache"
    }
    Write-Host "  缓存头 manifest=$manifestCache"
    Write-Host "  缓存头 dll=$dllCache"

    $results = @()
    if ($Channel -ne 'mcp') {
        Write-Stage '3/4 CLI 验证'
        & $godot --headless --path $projectDir --quit-after 600 --log-file $cliLog $scene | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Godot CLI 运行失败，exit=$LASTEXITCODE，日志：$cliLog"
        }
        $results += Test-Regression $cliLog 'CLI'
    }

    if ($Channel -ne 'cli') {
        Write-Stage '4/4 MCP 验证'
        & $node (Join-Path $PSScriptRoot 'mcp_run_scene.mjs') `
            --project $projectDir `
            --scene $scene `
            --log $mcpLog `
            --raw-log $mcpRawLog `
            --godot $godot `
            --quit-after 600 `
            --timeout 180
        if ($LASTEXITCODE -ne 0) {
            throw "MCP 通道运行失败，exit=$LASTEXITCODE，日志：$mcpLog"
        }
        $results += Test-Regression $mcpLog 'MCP'
    }
} finally {
    if ($server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
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
