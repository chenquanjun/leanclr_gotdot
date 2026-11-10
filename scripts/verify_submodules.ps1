# 校验 native/thirdparty 的 submodule 是否固定在入库的 gitlink commit。
# 目的：防止误把 submodule 更新到别的 commit 后提交，导致别人 clone 后构建不出同样结果。
# 有意升级 submodule 的流程见 docs/11-ci.md §5（升级后必须重新生成 patches 并跑回归）。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\verify_submodules.ps1 [-Quiet]
[CmdletBinding()]
param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$gitmodules = Join-Path $root '.gitmodules'
if (-not (Test-Path -LiteralPath $gitmodules)) {
    throw "缺少 .gitmodules：$gitmodules"
}

$lines = Get-Content -LiteralPath $gitmodules
$branchLines = @($lines | Where-Object { $_ -match '^\s*branch\s*=' })
if ($branchLines.Count -gt 0) {
    throw (".gitmodules 不允许出现 branch 跟踪（会让 submodule 跟随上游分支漂移）：`n  " + ($branchLines -join "`n  "))
}

$paths = New-Object System.Collections.Generic.List[string]
foreach ($line in $lines) {
    if ($line -match '^\s*path\s*=\s*(.+?)\s*$') { $paths.Add($Matches[1]) }
}
if ($paths.Count -eq 0) {
    throw '.gitmodules 中未解析到任何 submodule path'
}

function Invoke-Git([string]$WorkTree, [string[]]$Arguments) {
    # PowerShell 5.1 会把 git 的 stderr 当错误记录，这里临时降级后按退出码判断。
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & git -C $WorkTree @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return @{ Code = $code; Output = @($output | ForEach-Object { "$_" }) }
}

$failures = New-Object System.Collections.Generic.List[string]
foreach ($path in $paths) {
    $entry = Invoke-Git $root @('ls-tree', 'HEAD', '--', $path)
    $expected = ''
    $fromIndex = $false
    if ($entry.Code -eq 0 -and $entry.Output.Count -gt 0) {
        if ($entry.Output[0] -notmatch '^160000 commit ([0-9a-f]{40})\s') {
            $failures.Add("$path：HEAD 条目不是 gitlink：$($entry.Output[0])")
            continue
        }
        $expected = $Matches[1]
    } else {
        # 尚未提交时可退回暂存区 gitlink，保证本地提交前也能做同一套校验。
        $staged = Invoke-Git $root @('ls-files', '-s', '--', $path)
        if ($staged.Code -ne 0 -or $staged.Output.Count -eq 0 -or $staged.Output[0] -notmatch '^160000 ([0-9a-f]{40})\s') {
            $failures.Add("$path：HEAD 与暂存区都没有该 gitlink（submodule 是否已 git add？）")
            continue
        }
        $expected = $Matches[1]
        $fromIndex = $true
    }
    $actual = Invoke-Git (Join-Path $root $path) @('rev-parse', 'HEAD')
    if ($actual.Code -ne 0 -or $actual.Output.Count -eq 0) {
        $failures.Add("$path：submodule 未初始化（先运行 scripts/ensure_deps.ps1）")
        continue
    }
    $head = $actual.Output[0].Trim()
    if ($head -ne $expected) {
        $failures.Add("$path：工作区 HEAD=$head，入库 gitlink=$expected")
        continue
    }
    if (-not $Quiet) {
        $note = if ($fromIndex) { '（暂存区，尚未提交）' } else { '' }
        Write-Host "  ok $path @ $($expected.Substring(0, 12))$note"
    }
}

if ($failures.Count -gt 0) {
    throw ("submodule 固定版本校验失败：`n  " + ($failures -join "`n  ") +
        "`n请执行 git submodule update --init --recursive 回到入库 commit；有意升级按 docs/11-ci.md §5 操作")
}
if (-not $Quiet) {
    Write-Host "submodule 固定版本校验通过（$($paths.Count) 个）"
}
