# 公共路径解析：仓库根、输出目录、Godot、Android SDK 与 debug keystore。
# 引用方式（脚本内必须用嵌套 Join-Path，避免 Linux/macOS 下反斜杠失效）：
#   . (Join-Path (Join-Path $PSScriptRoot 'lib') 'repo.ps1')
# 优先级：显式参数 > 环境变量 > 仓库内默认相对位置；都找不到时抛出可读错误，不静默失败。

# 本文件位于 <repo>/scripts/lib/repo.ps1，因此上两级就是仓库根。
$LeanClrRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Get-RepoRoot {
    return $LeanClrRepoRoot
}

# 输出目录：默认 <repo>/out；可用 LEANCLR_OUT 覆盖（相对路径按仓库根解析）。
function Get-OutRoot {
    if ($env:LEANCLR_OUT) {
        if ([System.IO.Path]::IsPathRooted($env:LEANCLR_OUT)) { return $env:LEANCLR_OUT }
        return (Join-Path $LeanClrRepoRoot $env:LEANCLR_OUT)
    }
    return (Join-Path $LeanClrRepoRoot 'out')
}

# Godot 可执行文件：显式参数 > GODOT_BIN > <repo>/.tools/godot45/<FileName>。
function Resolve-GodotExe {
    param(
        [string]$Explicit = '',
        [string]$FileName = 'Godot_v4.5-stable_win64_console.exe'
    )
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) {
            throw "GodotExe 参数指向的文件不存在：$Explicit"
        }
        return (Resolve-Path -LiteralPath $Explicit).ProviderPath
    }
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:GODOT_BIN) { $candidates.Add($env:GODOT_BIN) }
    $candidates.Add((Join-Path (Join-Path (Join-Path $LeanClrRepoRoot '.tools') 'godot45') $FileName))
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).ProviderPath
        }
    }
    throw ("找不到 Godot 4.5 可执行文件。已尝试：`n  " + ($candidates -join "`n  ") +
        "`n请设置环境变量 GODOT_BIN 指向 Godot 4.5 控制台版，或把它放到仓库内 .tools/godot45/（见 docs/01-environment.md §3）")
}

# Android SDK：ANDROID_HOME > ANDROID_SDK_ROOT > %LOCALAPPDATA%/Android/Sdk。
function Resolve-AndroidSdk {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:ANDROID_HOME) { $candidates.Add($env:ANDROID_HOME) }
    if ($env:ANDROID_SDK_ROOT) { $candidates.Add($env:ANDROID_SDK_ROOT) }
    if ($env:LOCALAPPDATA) { $candidates.Add((Join-Path (Join-Path $env:LOCALAPPDATA 'Android') 'Sdk')) }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) { return $candidate }
    }
    throw ("找不到 Android SDK。已尝试：`n  " + ($candidates -join "`n  ") +
        "`n请设置 ANDROID_HOME 或 ANDROID_SDK_ROOT 指向 Android SDK 目录")
}

function Resolve-Adb {
    $sdk = Resolve-AndroidSdk
    $adb = Join-Path (Join-Path $sdk 'platform-tools') 'adb.exe'
    if (-not (Test-Path -LiteralPath $adb -PathType Leaf)) {
        throw "找不到 adb：$adb（安装 SDK platform-tools，或检查 ANDROID_HOME）"
    }
    return $adb
}

# debug 签名用的 keystore：ANDROID_DEBUG_KEYSTORE > ~/.android/debug.keystore。
function Resolve-DebugKeystore {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:ANDROID_DEBUG_KEYSTORE) { $candidates.Add($env:ANDROID_DEBUG_KEYSTORE) }
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { '' }
    if ($homeDir) { $candidates.Add((Join-Path (Join-Path $homeDir '.android') 'debug.keystore')) }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    throw ("找不到 Android debug keystore。已尝试：`n  " + ($candidates -join "`n  ") +
        "`n请用 keytool 生成 ~/.android/debug.keystore，或用 ANDROID_DEBUG_KEYSTORE 指向现有 keystore（见 docs/09-code-package-hot-update.md §3）")
}

# 导出前把 debug keystore 的绝对路径临时写入 export_presets.cfg，导出后原样还原。
# 入库的预设里该值为空，这样仓库不绑定任何本机路径；Godot 不会展开 ~ 或环境变量，必须写绝对路径。
function Invoke-WithDebugKeystore {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    $cfg = Join-Path $ProjectDir 'export_presets.cfg'
    if (-not (Test-Path -LiteralPath $cfg)) { throw "缺少导出预设：$cfg" }
    $original = [System.IO.File]::ReadAllText($cfg)
    $value = (Resolve-DebugKeystore).Replace('\', '/')
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] { param($match) 'keystore/debug="' + $value + '"' }
    $patched = [regex]::Replace($original, '(?m)^keystore/debug=.*$', $evaluator)
    try {
        [System.IO.File]::WriteAllText($cfg, $patched, (New-Object System.Text.UTF8Encoding($false)))
        & $Body
    } finally {
        [System.IO.File]::WriteAllText($cfg, $original, (New-Object System.Text.UTF8Encoding($false)))
    }
}
