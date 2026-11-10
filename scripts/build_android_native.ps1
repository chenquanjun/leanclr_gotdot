# 交叉编译 Android 版 leanclr_godot GDExtension（可指定 ABI）。
# 依赖：Android SDK/NDK、Visual Studio 自带 CMake、SDK 自带 Ninja。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\build_android_native.ps1 [-Abi x86_64|arm64-v8a|armeabi-v7a] [-Configuration Debug|Release|Both] [-Clean]
[CmdletBinding()]
param(
    [ValidateSet('x86_64', 'arm64-v8a', 'armeabi-v7a')]
    [string]$Abi = 'x86_64',
    [ValidateSet('Debug', 'Release', 'Both')]
    [string]$Configuration = 'Both',
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'repo.ps1')
$root = Split-Path -Parent $PSScriptRoot
$sdk = Resolve-AndroidSdk
$ndkDir = Get-ChildItem -LiteralPath (Join-Path $sdk 'ndk') -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1
if (-not $ndkDir) {
    throw "找不到 NDK：$sdk\ndk（用 sdkmanager 安装 ndk;28.2.13676358）"
}
$ndk = $ndkDir.FullName
$toolchain = Join-Path $ndk 'build\cmake\android.toolchain.cmake'
if (-not (Test-Path -LiteralPath $toolchain)) {
    throw "NDK 缺少 CMake toolchain：$toolchain"
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw '找不到 vswhere.exe，无法定位 Visual Studio CMake'
}
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$cmake = Join-Path $vsPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
if (-not (Test-Path -LiteralPath $cmake)) {
    throw "找不到 CMake：$cmake"
}
$ninjaDir = Get-ChildItem -LiteralPath (Join-Path $sdk 'cmake') -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1
$ninja = if ($ninjaDir) { Join-Path (Join-Path $ninjaDir.FullName 'bin') 'ninja.exe' } else { '' }
if (-not $ninja -or -not (Test-Path -LiteralPath $ninja)) {
    throw "找不到 Ninja：$sdk\cmake\<version>\bin\ninja.exe（用 sdkmanager 安装 cmake;3.22.1）"
}

Write-Host "SDK   : $sdk"
Write-Host "NDK   : $ndk"
Write-Host "CMake : $cmake"
Write-Host "Ninja : $ninja"
Write-Host "ABI   : $Abi"

& (Join-Path $PSScriptRoot 'ensure_deps.ps1')
if ($LASTEXITCODE -ne 0) {
    throw '依赖准备失败（submodule 或补丁），先执行 scripts\ensure_deps.ps1'
}

$configs = if ($Configuration -eq 'Both') { @('Debug', 'Release') } else { @($Configuration) }
$outRoot = Get-OutRoot
$binDir = Join-Path $outRoot "bin\android\$Abi"
$logDir = Join-Path $outRoot 'logs'
New-Item -ItemType Directory -Path $binDir -Force | Out-Null
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

foreach ($config in $configs) {
    $label = $config.ToLower()
    $buildDir = Join-Path $outRoot ("build\android\" + $Abi + "\" + $label)
    $log = Join-Path $logDir ("android_native_" + $Abi + "_" + $label + '.log')
    $template = if ($config -eq 'Debug') { 'template_debug' } else { 'template_release' }
    if ($Clean -and (Test-Path -LiteralPath $buildDir)) {
        Remove-Item -LiteralPath $buildDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $buildDir -Force | Out-Null

    Write-Host "[$Abi][$config] configure ($template)"
    $configureArgs = @(
        '-S', $root,
        '-B', $buildDir,
        '-G', 'Ninja',
        "-DCMAKE_MAKE_PROGRAM=$ninja",
        "-DCMAKE_TOOLCHAIN_FILE=$toolchain",
        "-DANDROID_ABI=$Abi",
        '-DANDROID_PLATFORM=android-24',
        '-DANDROID_STL=c++_shared',
        # zlib 的 gzlib.c 未显式包含 unistd.h，Android/Clang 19 会把 lseek 视为未声明。
        '-DCMAKE_C_FLAGS=-include unistd.h',
        "-DCMAKE_BUILD_TYPE=$config",
        "-DGODOTCPP_TARGET=$template"
    )
    & $cmake @configureArgs *>&1 | Tee-Object -FilePath $log
    if ($LASTEXITCODE -ne 0) {
        throw "[$Abi][$config] CMake configure 失败，日志：$log"
    }

    Write-Host "[$Abi][$config] build leanclr_godot"
    & $cmake --build $buildDir --target leanclr_godot --parallel *>&1 | Tee-Object -FilePath $log -Append
    if ($LASTEXITCODE -ne 0) {
        throw "[$Abi][$config] 交叉编译失败，日志：$log"
    }

    $built = Join-Path $buildDir 'leanclr_godot.so'
    if (-not (Test-Path -LiteralPath $built)) {
        throw "[$Abi][$config] 未生成 $built"
    }
    $dest = if ($config -eq 'Debug') {
        Join-Path $binDir 'libleanclr_godot.so'
    } else {
        Join-Path $binDir 'libleanclr_godot.release.so'
    }
    Copy-Item -LiteralPath $built -Destination $dest -Force
    Write-Host "[$Abi][$config] -> $dest"

    & (Join-Path $PSScriptRoot 'deploy_native.ps1') -Platform android -Abi $Abi -Configuration $config
    if ($LASTEXITCODE -ne 0) {
        throw "[$Abi][$config] 部署失败"
    }
}

Write-Host "Android 原生库构建完成：$Abi（产物 out\bin\android\$Abi，已部署到 godot_project\bin\android\$Abi）"
