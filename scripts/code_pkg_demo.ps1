# 代码包热更新一键演示：构建内置 v1 与下载包 v2 -> 启动本地 HTTP 源 -> 打开演示场景。
# 操作：U 下载并应用 v2；C 清除本地覆盖回到 v1。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\code_pkg_demo.ps1 [-SkipBuild] [-Url http://127.0.0.1:18080/good]
[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [string]$Url = 'http://127.0.0.1:18080/good'
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
$serverLog = Join-Path $logDir 'code_pkg_demo_server.log'
$serverErr = Join-Path $logDir 'code_pkg_demo_server.err.log'
$port = 18080

function Write-Manifest([string]$Dir, [string]$Version, [string]$DllPath) {
    $size = (Get-Item -LiteralPath $DllPath).Length
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $DllPath).Hash.ToLower()
    $json = @"
{
  "package_version": "$Version",
  "assembly": "LeanClrCodePkg",
  "files": [
    { "name": "LeanClrCodePkg.dll", "size": $size, "sha256": "$sha" }
  ]
}
"@
    [System.IO.File]::WriteAllText((Join-Path $Dir 'manifest.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
}

if (-not (Test-Path -LiteralPath $godot)) {
    throw "缺少 Godot：$godot"
}
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) {
    throw '缺少 node，无法启动本地 HTTP 源'
}
foreach ($dir in @($logDir, $pkgTmp, $assembliesDir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

if (-not $SkipBuild) {
    Write-Host '[1/4] 编译内置 v1 与下载包 v2'
    foreach ($variant in @('v1', 'v2')) {
        $log = Join-Path $logDir ("build_LeanClrCodePkg_" + $variant + '.log')
        & dotnet build (Join-Path $demoDir 'LeanClrCodePkg.csproj') -c Release -nologo -v:minimal -p:PkgVariant=$variant *> $log
        if ($LASTEXITCODE -ne 0) {
            Get-Content -LiteralPath $log | Write-Host
            throw "编译 $variant 失败，日志：$log"
        }
    }
} else {
    Write-Host '[1/4] 跳过编译'
}

Write-Host '[2/4] 生成 v2 代码包'
$v1Dll = Join-Path $pkgTmp 'v1\LeanClrCodePkg.dll'
$v2Dll = Join-Path $pkgTmp 'v2\LeanClrCodePkg.dll'
if (-not (Test-Path -LiteralPath $v1Dll) -or -not (Test-Path -LiteralPath $v2Dll)) {
    throw '缺少 v1/v2 程序集，请去掉 -SkipBuild 重新构建'
}
Copy-Item -LiteralPath $v1Dll -Destination (Join-Path $assembliesDir 'LeanClrCodePkg.dll') -Force
$goodDir = Join-Path $packagesRoot 'good'
if (Test-Path -LiteralPath $packagesRoot) {
    Remove-Item -LiteralPath $packagesRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $goodDir -Force | Out-Null
Copy-Item -LiteralPath $v2Dll -Destination (Join-Path $goodDir 'LeanClrCodePkg.dll') -Force
Write-Manifest $goodDir 'v2' (Join-Path $goodDir 'LeanClrCodePkg.dll')

Write-Host '[3/4] 启动本地 HTTP 源'
$server = Start-Process -FilePath $node -PassThru -NoNewWindow `
    -ArgumentList @((Join-Path $PSScriptRoot 'code_pkg_server.mjs'), '--root', $packagesRoot, '--port', "$port") `
    -RedirectStandardOutput $serverLog -RedirectStandardError $serverErr

try {
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
        throw "HTTP 源未就绪，见 $serverLog / $serverErr"
    }
    Write-Host "      $Url"
    Write-Host '[4/4] 启动演示：U 应用新包，C 回到内置版本，Esc 退出'
    & $godot --path $projectDir 'res://code_pkg.tscn' -- '--code-pkg-reset' "--code-pkg-url=$Url"
} finally {
    if ($server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
}
