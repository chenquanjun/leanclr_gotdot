# 代码包热更新 Android 实测：导出 APK -> adb 安装 -> HTTP 下载 v2 -> user:// 加载 -> reload -> 断言 logcat。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\code_pkg_android_test.ps1 [-Abi x86_64|arm64-v8a|armeabi-v7a] [-Serial 127.0.0.1:16384] [-SkipBuild] [-SkipExport]
[CmdletBinding()]
param(
    [ValidateSet('x86_64', 'arm64-v8a', 'armeabi-v7a')]
    [string]$Abi = 'x86_64',
    [string]$Serial = '',
    [switch]$SkipBuild,
    [switch]$SkipExport,
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'repo.ps1')
$root = Split-Path -Parent $PSScriptRoot
$demoDir = Join-Path $root 'demo_csharp'
$projectDir = Join-Path $root 'godot_project'
$outRoot = Get-OutRoot
$logDir = Join-Path $outRoot 'logs'
$pkgTmp = Join-Path $outRoot 'tmp\code_pkg'
$assembliesDir = Join-Path $projectDir 'bin\assemblies'
$packagesRoot = Join-Path $outRoot 'packages'
$godot = Resolve-GodotExe
$preset = "Android $Abi"
$apk = Join-Path $outRoot ("android\LeanClrCodePkg-" + $Abi + '.apk')
$exportLog = Join-Path $logDir ("android_export_" + $Abi + '.log')
$androidLog = Join-Path $logDir ("android_code_pkg_" + $Abi + '.log')
$abiEvidence = Join-Path $logDir ("android_abi_" + $Abi + '.txt')
$serverLog = Join-Path $logDir 'code_pkg_server.log'
$serverErr = Join-Path $logDir 'code_pkg_server.err.log'
$package = 'org.godotengine.leanclrcodepkg'
$activity = 'com.godot.game.GodotApp'
$port = 18080
$testScene = 'res://code_pkg_test.tscn'

$required = @(
    @{ Name = 'user 覆盖目录'; Pattern = 'pkg user dir = /data/data/org\.godotengine\.leanclrcodepkg/files/code_pkg/assemblies' },
    @{ Name = 'user 目录进入 lib dirs'; Pattern = '\[LeanCLR\] lib dir=/data/data/org\.godotengine\.leanclrcodepkg/files/code_pkg/assemblies' },
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
    @{ Name = '从 user 路径加载'; Pattern = 'resolve assembly via filesystem: /data/data/org\.godotengine\.leanclrcodepkg/files/code_pkg/assemblies/LeanClrCodePkg\.dll' },
    @{ Name = '旧句柄失效'; Pattern = 'pkg old handle is null = true' },
    @{ Name = 'v2 版本'; Pattern = 'pkg v2 version = v2' },
    @{ Name = 'v2 Answer'; Pattern = 'pkg v2 answer 22 = true' },
    @{ Name = 'v2 行为'; Pattern = 'pkg v2 compute 10 = 20' },
    @{ Name = 'v2 特性'; Pattern = 'pkg v2 feature double = true' },
    @{ Name = '节点重绑版本'; Pattern = 'pkg node rebound version = v2' },
    @{ Name = '节点重绑代次'; Pattern = 'pkg node rebound generation = true' },
    @{ Name = '原生节点重绑日志'; Pattern = '\[hotreload\] node rebound: type=CodePkgNode, generation=1' },
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
    @{ Name = '原生节点重绑日志 v3'; Pattern = '\[hotreload\] node rebound: type=CodePkgNode, generation=2' },
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
    @{ Name = '回退完成日志'; Pattern = '\[codepkg\] rollback done=true version_after=v3' },
    @{ Name = '完成标记'; Pattern = '=== code pkg test done ===' }
)
$forbidden = @(
    @{ Name = '原生崩溃'; Pattern = 'F/libc' },
    @{ Name = '致命信号'; Pattern = 'Fatal signal' },
    @{ Name = '脚本错误'; Pattern = 'SCRIPT ERROR' },
    @{ Name = 'LeanCLR 失败'; Pattern = 'LeanCLR[^\r\n]*failed' }
)

function Write-Stage([string]$Text) {
    Write-Host "[$Text]" -ForegroundColor Cyan
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

    $v2Dll = Join-Path $pkgTmp 'v2\LeanClrCodePkg.dll'
    if (-not (Test-Path -LiteralPath $v2Dll)) {
        throw "缺少 v2 程序集：$v2Dll（去掉 -SkipBuild 重新构建）"
    }
    $goodSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $v2Dll).Hash.ToLower()
    $goodName = Get-HashedName $goodSha
    $goodDll = Join-Path $goodDir $goodName
    Copy-Item -LiteralPath $v2Dll -Destination $goodDll -Force
    Write-Manifest $goodDir 'v2' $goodName $goodDll $goodSha

    $v3Dll = Join-Path $pkgTmp 'v3\LeanClrCodePkg.dll'
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

    # 同长度改一个字节：size 通过、sha256 不通过。
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

function Export-Apk {
    $projectFile = Join-Path $projectDir 'project.godot'
    $original = [System.IO.File]::ReadAllText($projectFile)
    $patched = [regex]::Replace($original, 'run/main_scene="[^"]*"', ('run/main_scene="' + $testScene + '"'))
    if ($patched -eq $original) {
        throw 'project.godot 中未找到 run/main_scene，无法切换到测试场景'
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $apk) -Force | Out-Null
    try {
        [System.IO.File]::WriteAllText($projectFile, $patched, (New-Object System.Text.UTF8Encoding($false)))
        # 用 Start-Process 收集 stdout/stderr：Godot 导出会把 "No project icon" 写到 stderr，
        # 若用 *> 重定向且 ErrorActionPreference=Stop，会把警告当成终止错误中断导出。
        # 预设里的 keystore 路径入库时为空，导出前注入本机/CI 的实际路径，导出后还原。
        Invoke-WithDebugKeystore -ProjectDir $projectDir -Body {
            $proc = Start-Process -FilePath $godot -PassThru -Wait -NoNewWindow `
                -ArgumentList @('--headless', '--path', $projectDir, '--export-debug', ('"' + $preset + '"'), $apk) `
                -RedirectStandardOutput $exportLog -RedirectStandardError ($exportLog + '.err')
            if ($proc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $apk)) {
                Get-Content -LiteralPath $exportLog | Select-Object -Last 20 | Write-Host
                Get-Content -LiteralPath ($exportLog + '.err') | Select-Object -Last 20 | Write-Host
                throw "Android 导出失败，exit=$($proc.ExitCode)，日志：$exportLog"
            }
        }
    } finally {
        # 导出后立刻还原主场景，避免把测试场景留在工程里。
        [System.IO.File]::WriteAllText($projectFile, $original, (New-Object System.Text.UTF8Encoding($false)))
    }
    Write-Host "  APK $apk"
    # 记录 APK 内实际打包的原生库，作为 ABI 覆盖证据。
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($apk)
    try {
        $libs = @($zip.Entries | Where-Object { $_.FullName -like 'lib/*' } | Select-Object -ExpandProperty FullName)
    } finally {
        $zip.Dispose()
    }
    $expected = "lib/$Abi/libleanclr_godot.so"
    if ($libs -notcontains $expected) {
        throw "APK 内缺少 $expected；实际 lib 内容：`n$($libs -join "`n")"
    }
    Write-Host "  APK lib/$Abi/ = $($libs -join ', ')"
    Add-Content -LiteralPath $abiEvidence -Encoding UTF8 -Value ("abi={0}`npreset={1}`napk={2}`nlib_entries={3}" -f $Abi, $preset, $apk, ($libs -join ','))
}

$watch = [System.Diagnostics.Stopwatch]::StartNew()
Write-Stage 'Android 代码包热更新验证'
Remove-Item -LiteralPath $abiEvidence -Force -ErrorAction SilentlyContinue

$adb = Resolve-Adb
$node = (Get-Command node -ErrorAction Stop).Source
foreach ($dir in @($logDir, (Join-Path $outRoot 'android'), $pkgTmp, $assembliesDir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

if (-not $SkipBuild) {
    Write-Stage '1/5 编译 v1/v2/v3 与 Android 原生库'
    Build-Pkg 'v1' '内置基线（v1）'
    Build-Pkg 'v2' '下载包（v2）'
    Build-Pkg 'v3' '第二版下载包（v3，验证哈希名随内容变化）'
    & (Join-Path $PSScriptRoot 'build_android_native.ps1') -Abi $Abi -Configuration Debug | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Android 原生库构建失败（ABI=$Abi），见 out\logs\android_native_$Abi`_debug.log"
    }
    Write-Stage '2/5 生成代码包与本地 HTTP 源'
    $v1Dll = Join-Path $pkgTmp 'v1\LeanClrCodePkg.dll'
    if (-not (Test-Path -LiteralPath $v1Dll)) {
        throw "缺少 v1 程序集：$v1Dll"
    }
    Copy-Item -LiteralPath $v1Dll -Destination (Join-Path $assembliesDir 'LeanClrCodePkg.dll') -Force
    Prepare-Packages
} else {
    Write-Stage '1/5 跳过编译（-SkipBuild）'
    Write-Stage '2/5 复用已有代码包'
    if (-not (Test-Path -LiteralPath (Join-Path $packagesRoot 'good\manifest.json'))) {
        throw "缺少代码包：$packagesRoot（去掉 -SkipBuild 重新生成）"
    }
}

if (-not $SkipExport) {
    Write-Stage '3/5 导出 APK（临时主场景 code_pkg_test.tscn）'
    Export-Apk
} else {
    Write-Stage "3/5 复用已有 APK"
    if (-not (Test-Path -LiteralPath $apk)) {
        throw "缺少 APK：$apk（去掉 -SkipExport 重新导出）"
    }
}

if (-not (Test-Path -LiteralPath $godot)) {
    throw "缺少 Godot：$godot（见 docs/01）"
}

Write-Stage "4/5 连接设备并安装（$Serial）"
if (-not $Serial) {
    & $adb connect 127.0.0.1:16384 | Out-Null
    Start-Sleep -Seconds 2
    $Serial = '127.0.0.1:16384'
} elseif ($Serial -match ':\d+$') {
    & $adb connect $Serial | Out-Null
    Start-Sleep -Seconds 2
}
$state = (& $adb -s $Serial get-state 2>&1) -join ' '
if ($state -notmatch 'device') {
    throw "设备 $Serial 不可用（$state）。启动 MuMu 后重试，或传 -Serial <adb序列号>"
}
Write-Host "  设备 $Serial ($(& $adb -s $Serial shell getprop ro.product.cpu.abi))"
$deviceAbi = ((& $adb -s $Serial shell getprop ro.product.cpu.abi) -join '').Trim()
$deviceAbiList = ((& $adb -s $Serial shell getprop ro.product.cpu.abilist) -join '').Trim()
$nativeBridge = ((& $adb -s $Serial shell getprop ro.dalvik.vm.nativebridge) -join '').Trim()
$nativeBridgeAbi = ((& $adb -s $Serial shell getprop ro.enable.native.bridge.exec) -join '').Trim()
$isaArm = ((& $adb -s $Serial shell getprop ro.dalvik.vm.isa.arm) -join '').Trim()
$isaArm64 = ((& $adb -s $Serial shell getprop ro.dalvik.vm.isa.arm64) -join '').Trim()
Write-Host "  设备 abilist=$deviceAbiList nativebridge=$nativeBridge"
Add-Content -LiteralPath $abiEvidence -Encoding UTF8 -Value (
    "device_abi={0}`ndevice_abilist={1}`nnativebridge={2}`nnativebridge_exec={3}`nisa_arm={4}`nisa_arm64={5}" -f `
        $deviceAbi, $deviceAbiList, $nativeBridge, $nativeBridgeAbi, $isaArm, $isaArm64)

$install = (& $adb -s $Serial install -r $apk 2>&1) -join "`n"
if ($install -notmatch 'Success') {
    throw "adb install 失败：`n$install"
}
Add-Content -LiteralPath $abiEvidence -Encoding UTF8 -Value ("install={0}" -f ($install -replace "`r?`n", ' | '))
& $adb -s $Serial reverse "tcp:$port" "tcp:$port" | Out-Null
& $adb -s $Serial shell pm clear $package | Out-Null

Write-Stage '5/5 运行并抓取 logcat'
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

    & $adb -s $Serial logcat -c
    & $adb -s $Serial shell am start -n "$package/$activity" | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 5
        $log = & $adb -s $Serial logcat -d 2>&1
    } while ((Get-Date) -lt $deadline -and
        -not ($log -match 'code pkg test done ===') -and
        -not ($log -match 'F/libc') -and
        -not ($log -match 'Fatal signal'))
} finally {
    if ($server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
    & $adb -s $Serial shell am force-stop $package 2>&1 | Out-Null
}

$log | Set-Content -LiteralPath $androidLog -Encoding UTF8
$content = ($log -join "`n")
# 提取运行日志中的 ABI/转译层提示，作为「MuMu 是否用转译层跑 arm 包」的直接证据。
$bridgeLines = @($log | Where-Object { $_ -match 'nativebridge|libnb|houdini|RunningArchitecture' } |
    Select-Object -First 4 | ForEach-Object { ($_ -replace '^\S+\s+\S+\s+\S+\s+\S+\s+', '').Trim() })
$businessLines = @($log | Where-Object { $_ -match 'pkg v2 version =|pkg v2 compute 10 =|pkg v3 version =|pkg v3 compute 10 =|pkg after rollback compute 10 =' } |
    ForEach-Object { ($_ -replace '^\S+\s+\S+\s+\S+\s+\S+\s+', '').Trim() })
Add-Content -LiteralPath $abiEvidence -Encoding UTF8 -Value (
    "hit_new_pkg={0}`nv2_result={1}`nbridge={2}`nbusiness={3}`nlog={4}" -f `
        ($content -match 'pkg v2 compute 10 = 20'), ($content -match 'pkg v2 compute 10 = 20'),
        ($bridgeLines -join ' || '), ($businessLines -join ' || '), $androidLog)

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

$watch.Stop()
if ($missing.Count -eq 0 -and $hits.Count -eq 0) {
    Write-Host ("  PASS ({0}/{0} 断言)" -f $required.Count) -ForegroundColor Green
    Write-Host "  日志: $androidLog"
    Write-Host ("PASS  用时 {0:N1}s" -f $watch.Elapsed.TotalSeconds) -ForegroundColor Green
    exit 0
}

Write-Host '  FAIL' -ForegroundColor Red
foreach ($name in $missing) {
    Write-Host "    缺少断言: $name" -ForegroundColor Red
}
foreach ($name in $hits) {
    Write-Host "    命中禁止项: $name" -ForegroundColor Red
}
Write-Host "  日志: $androidLog"
Write-Host ("FAIL  用时 {0:N1}s" -f $watch.Elapsed.TotalSeconds) -ForegroundColor Red
exit 1
