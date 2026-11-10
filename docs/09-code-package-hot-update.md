# 09 代码包热更新：Android 打包与验证分步指南

本指南从零开始，按顺序完成「构建 Android 包 → 安装到 MuMu → 准备新版本代码包 → 下载并生效 → 确认执行到新代码」。每一步都给出可直接复制执行的命令与预期输出，并注明验证状态：

- **【已实测】** 2026-11-10 在 Windows + MuMu 12（Android 12，x86_64）+ Godot 4.5.stable + JDK 17.0.18 + NDK 28.2 上完整走通。
- **【需额外条件】** 本机不具备该条件或尚未验证，按提示补齐后可用。

约定：

- 所有命令默认在**仓库根目录**下用 PowerShell 执行；下文的 `<REPO>` 指仓库根目录的绝对路径，`<SDK>` 指 Android SDK 目录。
- 文中的 `$adb` 指 `$env:ANDROID_HOME\platform-tools\adb.exe`（未设置 `ANDROID_HOME` 时脚本会回退到 `%LOCALAPPDATA%\Android\Sdk`，都找不到会直接报错）。
- 与机器相关的路径一律走环境变量或脚本探测，不在仓库里写死：`GODOT_BIN`（Godot 4.5 控制台版）、`ANDROID_HOME` / `ANDROID_SDK_ROOT`、`ANDROID_DEBUG_KEYSTORE`、`LEANCLR_OUT`（输出目录，默认 `<REPO>/out`）。
- 只想跑通全流程时，直接用第 7.4 节的一键脚本；想理解每一步或排查问题时按第 1–7 节手工执行。

## 0. 总览与路径速查

| 步骤 | 做什么 | 手工入口 | 一键脚本中的阶段 |
|---|---|---|---|
| 1 | 环境前置：SDK/NDK/JDK/导出模板、MuMu + adb、ABI | 本文 §1 | 脚本启动前的隐式前置 |
| 2 | 构建 Android 原生库与内置 v1 托管程序集 | `build_android_native.ps1` + `dotnet build` | `1/5` |
| 3 | 导出 APK（主场景临时切到测试场景） | `godot --export-debug` | `3/5` |
| 4 | 安装到 MuMu 并启动 | `adb install` / `am start` | `4/5` |
| 5 | 准备新版本代码包并起下载源 | `dotnet build` + `manifest.json` + `code_pkg_server.mjs` | `2/5` |
| 6 | 触发下载与生效 | App 启动 / `download_and_apply` | `5/5` |
| 7 | 确认跑的是新代码 | `adb logcat` + 断言 | 日志断言 |
| 8 | 失败排查 | 本文 §8 | `FAIL` 输出 |

关键路径：

| 项 | 路径 |
|---|---|
| Godot 4.5 控制台 | `.tools\godot45\Godot_v4.5-stable_win64_console.exe` |
| Android SDK | `%LOCALAPPDATA%\Android\Sdk` |
| 导出模板 | `%APPDATA%\Godot\export_templates\4.5.stable\android_debug.apk` |
| Android 原生库 | `out\bin\android\<abi>\libleanclr_godot.so`（部署到 `godot_project\bin\android\<abi>\`） |
| 内置 v1 程序集 | `godot_project\bin\assemblies\LeanClrCodePkg.dll` |
| 导出 APK | `out\android\LeanClrCodePkg-<abi>.apk` |
| 下载包根目录 | `out\packages\`（`good` / `bad-sha` / `broken-type`） |
| Android 可写覆盖目录 | `/data/data/org.godotengine.leanclrcodepkg/files/code_pkg/assemblies` |
| 运行日志 | `out\logs\android_code_pkg_<abi>.log`、`out\logs\android_abi_<abi>.txt` |

## 1. 环境前置

### 1.1 检查 SDK / NDK / JDK / 导出模板【已实测】

```powershell
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
$adb = Join-Path $sdk 'platform-tools\adb.exe'
Write-Host "SDK = $sdk"
Test-Path $adb
Get-ChildItem "$sdk\ndk" -Directory | Select-Object -ExpandProperty Name
Test-Path "$sdk\cmake\3.22.1\bin\ninja.exe"
Get-ChildItem "$sdk\build-tools" -Directory | Select-Object -ExpandProperty Name
java -version
Get-ChildItem "$env:APPDATA\Godot\export_templates\4.5.stable\android_*.apk" | Select-Object Name
```

本机实际输出：

```text
SDK = %LOCALAPPDATA%\Android\Sdk
True
28.2.13676358
True
35.0.0
36.0.0
openjdk version "17.0.18" 2026-01-20 LTS
OpenJDK Runtime Environment Microsoft-13106358 (build 17.0.18+8-LTS)

Name
----
android_debug.apk
android_release.apk
```

要求说明：

| 依赖 | 用途 | 缺失时 |
|---|---|---|
| `platform-tools\adb.exe` | 安装、端口映射、日志 | `sdkmanager "platform-tools"`【需额外条件】 |
| NDK `28.2.13676358` | 交叉编译 `libleanclr_godot.so` | `sdkmanager "ndk;28.2.13676358"`【需额外条件】 |
| `cmake\3.22.1\bin\ninja.exe` | `build_android_native.ps1` 指定的 Ninja | `sdkmanager "cmake;3.22.1"`【需额外条件】 |
| `build-tools`（35/36） | 导出时签名 APK | `sdkmanager "build-tools;35.0.0"`【需额外条件】 |
| JDK 17 | Godot 的 Android 设置与 Gradle 构建；本机为 Microsoft OpenJDK 17.0.18 | 安装 JDK 17 并在编辑器设置中指向【需额外条件】 |
| 导出模板 `4.5.stable` | 导出 APK；**版本必须与编辑器一致** | 编辑器「编辑器 → 管理导出模板」下载安装【需额外条件】 |

> 本工程使用预编译模板导出（`gradle_build/use_gradle_build=false`），不会真正调用 Gradle；JDK 缺失通常不会卡住模板导出，但切到 Gradle 构建或自定义 Android 构建时必须补齐。

### 1.2 启动 MuMu 并连接 adb【已实测】

先启动 MuMu 模拟器。若从未开启过调试：在 MuMu 内进入「设置 → 关于平板电脑」，连续点击版本号开启开发者选项，再在「开发者选项」中打开「USB 调试」。MuMu 12 默认 adb 端口为 `16384`；旧版 MuMu 常见 `7555`（以 MuMu 设置或 `netstat -ano | findstr 16384` 为准）。

```powershell
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
$adb = Join-Path $sdk 'platform-tools\adb.exe'
& $adb connect 127.0.0.1:16384
& $adb devices
& $adb -s 127.0.0.1:16384 shell getprop ro.product.cpu.abi
& $adb -s 127.0.0.1:16384 shell getprop ro.build.version.release
```

本机实际输出：

```text
connected to 127.0.0.1:16384
List of devices attached
127.0.0.1:16384	device
emulator-5554	device
x86_64
12
```

要点：

- `adb devices` 可能同时列出 `emulator-5554`。**后续所有 adb 命令统一加 `-s 127.0.0.1:16384`**，否则会报 `more than one device/emulator`。
- 若连接失败：确认 MuMu 已完全启动、端口正确；也可直接使用 `adb devices` 中显示的序列号（例如 `emulator-5554`）覆盖后续命令里的 `-s` 参数。`code_pkg_android_test.ps1` 支持 `-Serial <序列号>`。
- 本机每次新的 PowerShell/Shell 会话会重启 adb daemon，`connect` 与后续 `install/reverse/am start` 要放在同一条命令里执行；交互式终端不受影响。

### 1.3 选择 ABI

| MuMu/设备 ABI | 导出预设 | 原生库构建参数 | 状态 |
|---|---|---|---|
| `x86_64`（MuMu 12 默认） | `Android x86_64` | `-Abi x86_64` | **已实测**（构建 + 导出 + MuMu 热更） |
| `arm64-v8a`（多数真机、部分模拟器） | `Android arm64-v8a` | `-Abi arm64-v8a` | **已实测**（MuMu 转译层，71/71） |
| `armeabi-v7a` | `Android armeabi-v7a` | `-Abi armeabi-v7a` | **已实测**（MuMu 转译层，71/71） |

规则：**设备 ABI、导出架构、`.so` 架构三者必须一致**。MuMu 为 x86_64 时使用 x86_64 模板与 x86_64 原生库；装成 arm 包能否运行取决于 MuMu 的转译层（见 §1.4）。

### 1.4 ABI 覆盖矩阵（MuMu 12 x86_64 + 转译层）【已实测】

本机 MuMu 12 设备属性固定为：

```text
ro.product.cpu.abi      = x86_64
ro.product.cpu.abilist  = x86_64,arm64-v8a,x86,armeabi-v7a,armeabi
ro.enable.native.bridge.exec = 1
ro.dalvik.vm.isa.arm    = x86
ro.dalvik.vm.isa.arm64  = x86_64
```

因此 `armeabi-v7a` / `arm64-v8a` 包在 MuMu 上运行时必须经过 houdini 转译层。三次实测均完成「构建 → 导出 → 安装 → 运行 → HTTP 下载 v2/v3 → reload → 断言」全链路：

| ABI | 原生库构建 | APK 内 `lib/<abi>/` | 转译层 | 命中新包 | 关键业务输出 | 断言 | 证据 |
|---|---|---|---|---|---|---|---|
| `x86_64` | 通过 | `libc++_shared.so`、`libgodot_android.so`、`libleanclr_godot.so` | 不涉及（原生） | 是 | `pkg v2 compute 10 = 20`、`pkg v3 compute 10 = 30` | **71/71** | `out/logs/android_code_pkg_x86_64.log`、`out/logs/android_abi_x86_64.txt` |
| `armeabi-v7a` | 通过 | 同上（`lib/armeabi-v7a/`） | **是**（`libnb: enter native_bridge2_initialize ... arm`、`Found /system/lib/libhoudini.so`、`RunningArchitecture=armeabi-v7a`） | 是 | `pkg v2 compute 10 = 20`、`pkg v3 compute 10 = 30` | **71/71** | `out/logs/android_code_pkg_armeabi-v7a.log`、`out/logs/android_abi_armeabi-v7a.txt` |
| `arm64-v8a` | 通过 | 同上（`lib/arm64-v8a/`） | **是**（`libnb: enter native_bridge2_initialize ... arm64`、`Found /system/lib64/libhoudini.so`、`RunningArchitecture=arm64-v8a`） | 是 | `pkg v2 compute 10 = 20`、`pkg v3 compute 10 = 30` | **71/71** | `out/logs/android_code_pkg_arm64-v8a.log`、`out/logs/android_abi_arm64-v8a.txt` |

复现命令（三种 ABI 相同，只换 `-Abi`）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_android_native.ps1 -Abi armeabi-v7a -Configuration Debug
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\code_pkg_android_test.ps1 -Abi armeabi-v7a -SkipBuild
```

脚本会把「导出 ABI、APK 内 `.so` 清单、设备 abi/abilist/nativebridge 属性、安装结果、`hit_new_pkg`/`v2_result`、转译层日志、业务输出行、日志路径」写入 `out/logs/android_abi_<abi>.txt`，可直接作为证据。

**已知坑（armeabi-v7a 首轮 4 项失败，已修复）**：首轮 armv7 只有 `pkg v1/v2/v3/after rollback compute 10 = 0` 失败，版本、字段、节点重绑、回滚均正常。根因在 `native/src/leanclr_runtime.cpp` 的 `invoke_method`：`this` 之后的参数偏移用了 `sizeof(void *)`，而 leanclr 的 `RtStackObject` 固定 8 字节（`interp/interp_defs.h` 有 `static_assert(sizeof(RtStackObject) == 8)`）。32 位平台 `sizeof(void *) == 4`，后续 `int` 参数整体错位 4 字节被读成 0；x86_64/arm64 因指针恰好 8 字节而未暴露。修复为按 `sizeof(leanclr::interp::RtStackObject)` 推进偏移后，armv7 71/71 通过。

## 2. 构建原生扩展与托管程序集

### 2.1 交叉编译 Android 原生库【已实测】

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_android_native.ps1 -Abi x86_64 -Configuration Debug
```

预期输出（节选）：

```text
SDK   : %LOCALAPPDATA%\Android\Sdk
NDK   : %LOCALAPPDATA%\Android\Sdk\ndk\<version>
CMake : <VS 安装目录>\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe
Ninja : %LOCALAPPDATA%\Android\Sdk\cmake\<version>\bin\ninja.exe
ABI   : x86_64
[x86_64][Debug] configure (template_debug)
...
[x86_64][Debug] -> <REPO>\out\bin\android\x86_64\libleanclr_godot.so
  deploy ... -> <REPO>\godot_project\bin\android\x86_64\libleanclr_godot.so
Android 原生库构建完成：x86_64（产物 out\bin\android\x86_64，已部署到 godot_project\bin\android\x86_64）
```

核对产物（编译产物在 out/，工程内是部署副本）：

```powershell
Get-Item out\bin\android\x86_64\libleanclr_godot.so, godot_project\bin\android\x86_64\libleanclr_godot.so | Select-Object FullName,Length,LastWriteTime
```

本机 x86_64 Debug 为 41,568,328 字节（未裁剪）。

关键约束：

- 文件名必须以 `lib` 开头。Godot 导出会报 `Android .so file names must start with "lib"`。
- `.gdextension` 必须包含对应条目：

  ```ini
  android.debug.x86_64 = "res://bin/android/x86_64/libleanclr_godot.so"
  android.release.x86_64 = "res://bin/android/x86_64/libleanclr_godot.release.so"
  ```

- 脚本固定使用 `android-24`、`c++_shared`，并附加 `-include unistd.h`（zlib 的 `gzlib.c` 在 Android/Clang 19 下需要）。日志在 `out\logs\android_native_<abi>_<cfg>.log`。
- Release 原生库：`-Configuration Release` / `Both`，产物为 `libleanclr_godot.release.so`；Android release APK 导出未在本机实测。【需额外条件】

### 2.2 编译内置 v1 托管程序集【已实测】

```powershell
dotnet build demo_csharp\LeanClrCodePkg.csproj -c Release -p:PkgVariant=v1
Copy-Item out\tmp\code_pkg\v1\LeanClrCodePkg.dll godot_project\bin\assemblies\LeanClrCodePkg.dll -Force
```

预期：

```text
  LeanClrCodePkg -> <REPO>\out\tmp\code_pkg\v1\LeanClrCodePkg.dll
    1 个警告（MSB3539：BaseIntermediateOutputPath 被 csproj 复用，可忽略）
    0 个错误
```

`PkgVariant=v1` 是默认值；`v1` 与 `v2` 的公开 API 完全相同，只改变版本号、返回值和 `ComputeScore` 行为，用于证明「换包后执行到新代码」。

核对：

```powershell
Get-Item godot_project\bin\assemblies\LeanClrCodePkg.dll | Select-Object Length
```

## 3. 导出 APK

### 3.1 导出预设必须项【已实测】

`godot_project/export_presets.cfg` 中的 `Android x86_64` 预设必须满足：

| 配置项 | 值 | 作用 |
|---|---|---|
| `architectures/x86_64` | `true` | 与 MuMu ABI 一致 |
| 其他 `architectures/*` | `false` | 避免导出体积与 ABI 混淆 |
| `permissions/internet` | `true` | 否则 APK 无 `INTERNET` 权限，下载直接失败 |
| `include_filter` | `bin/bcl/*.dll,bin/assemblies/*.dll` | 把 BCL 与内置程序集打进 PCK |
| `package/unique_name` | `org.godotengine.leanclrcodepkg` | 与安装/启动命令一致 |
| `keystore/debug` | 空字符串 | 入库不绑定本机路径；导出脚本会临时注入实际路径，导出后还原 |
| `keystore/debug_user` | `androiddebugkey` | 必须与编辑器设置 `export/android/debug_keystore_user` 一致 |
| `gradle_build/use_gradle_build` | `false` | 使用预编译模板，避免 Gradle 依赖 |

另外两个隐藏前置（缺失时只报 `configuration errors`，没有明细）：

- 编辑器设置 `export/android/debug_keystore_user=androiddebugkey`。
- 项目设置 `rendering/textures/vram_compression/import_etc2_astc=true`（Android 纹理导入需要）。

核对：

```powershell
Select-String godot_project\export_presets.cfg -Pattern 'architectures/x86_64|permissions/internet|include_filter|keystore/debug'
```

预期包含：

```text
include_filter="bin/bcl/*.dll,bin/assemblies/*.dll"
architectures/x86_64=true
keystore/debug=""
permissions/internet=true
```

### 3.2 临时把主场景切到测试场景【已实测】

APK 启动只运行 `run/main_scene`。自动下载并断言需要 `res://code_pkg_test.tscn`，因此导出前临时改主场景，导出后立即还原：

```powershell
$project = 'godot_project\project.godot'
$original = [System.IO.File]::ReadAllText($project)
$patched = [regex]::Replace($original, 'run/main_scene="[^"]*"', 'run/main_scene="res://code_pkg_test.tscn"')
if ($patched -eq $original) { throw 'project.godot 中未找到 run/main_scene' }
$utf8 = New-Object System.Text.UTF8Encoding($false)
New-Item -ItemType Directory -Path out\android -Force | Out-Null
try {
    [System.IO.File]::WriteAllText($project, $patched, $utf8)
    & $env:GODOT_BIN --headless --path godot_project --export-debug "Android x86_64" "out\android\LeanClrCodePkg-x86_64.apk"
} finally {
    [System.IO.File]::WriteAllText($project, $original, $utf8)
}
```

预期：

- 命令退出码 `0`，无交互等待。
- 输出中会出现 `ERROR: No project icon specified.`，这是导出器的警告，不影响产物（退出码仍为 0）。
- 打包阶段可见 `Adding permission android.permission.INTERNET`，说明下载权限已写入 APK。
- 末尾为 `Signing binary using: ... apksigner.bat sign ...`、`Signed`、`[ DONE ] export`。
- 产物约 90 MB（本机实测 94,120,591 字节）。

核对：

```powershell
$LASTEXITCODE
Test-Path out\android\LeanClrCodePkg-x86_64.apk
(Get-Item out\android\LeanClrCodePkg-x86_64.apk).Length
Select-String godot_project\project.godot -Pattern 'run/main_scene'
```

预期：`0`、`True`、约 `94 MB`、主场景已还原为 `res://demo.tscn`。

> 不要用 `*>` 重定向导出输出并配合 `$ErrorActionPreference='Stop'`：Godot 把 `No project icon` 写到 stderr，会被 PowerShell 当成终止错误而中断导出。一键脚本改用 `Start-Process` 分别收集 stdout/stderr。

### 3.3 一键完成构建 + 导出

第 7.4 节的 `scripts\code_pkg_android_test.ps1` 会按 §2–§6 自动完成构建、临时改主场景、导出、安装、启动与断言；需要逐步观察或排查时再用本节的命令。已有 APK 想跳过导出时用 `-SkipExport`，已有 v1/v2 与原生库时用 `-SkipBuild`。

## 4. 安装到 MuMu 并启动

### 4.1 安装、端口映射与清空本地覆盖【已实测】

```powershell
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
& $adb connect 127.0.0.1:16384
& $adb -s 127.0.0.1:16384 install -r out\android\LeanClrCodePkg-x86_64.apk
& $adb -s 127.0.0.1:16384 reverse tcp:18080 tcp:18080
& $adb -s 127.0.0.1:16384 shell pm clear org.godotengine.leanclrcodepkg
```

预期：

```text
connected to 127.0.0.1:16384
Performing Streamed Install
Success
Success
```

说明：

- `adb reverse tcp:18080 tcp:18080` 把设备上的 `127.0.0.1:18080` 转发到宿主机的 `18080`，App 内固定用 `http://127.0.0.1:18080/good` 即可，不需要局域网 IP。
- `pm clear` 会删除 App 的 `user://`（包括已下载的覆盖包与 `state.json`），让每次验证都从内置 v1 开始。**验证「覆盖包在重启后仍然生效」时不要执行 `pm clear`。**
- 若上一份 APK 已安装，`install -r` 会覆盖安装；签名不一致时需先 `adb uninstall org.godotengine.leanclrcodepkg`。

核对安装：

```powershell
& $adb -s 127.0.0.1:16384 shell pm path org.godotengine.leanclrcodepkg
```

预期：

```text
package:/data/app/~~.../org.godotengine.leanclrcodepkg-.../base.apk
```

### 4.2 启动冒烟【已实测】

```powershell
& $adb -s 127.0.0.1:16384 logcat -c
& $adb -s 127.0.0.1:16384 shell am start -n org.godotengine.leanclrcodepkg/com.godot.game.GodotApp
Start-Sleep -Seconds 5
& $adb -s 127.0.0.1:16384 logcat -d | Select-String 'Godot Engine|pkg user dir|pkg initial'
```

预期：

```text
Starting: Intent { cmp=org.godotengine.leanclrcodepkg/com.godot.game.GodotApp }
I godot : Godot Engine v4.5.stable.official...
I godot : pkg user dir = /data/data/org.godotengine.leanclrcodepkg/files/code_pkg/assemblies
I godot : pkg initial override = false
I godot : pkg initial generation = 0
```

此时若第 5 节的 HTTP 源尚未启动，日志还会出现 `pkg apply error = manifest download failed: ...`，属于预期：说明 App、原生库与 GDScript 已正常加载，只是下载源没开。完成第 5 节后重新启动即可跑完整链路。

## 5. 准备新版本代码包

### 5.1 编译 v2 程序集【已实测】

```powershell
dotnet build demo_csharp\LeanClrCodePkg.csproj -c Release -p:PkgVariant=v2
```

预期：

```text
  LeanClrCodePkg -> <REPO>\out\tmp\code_pkg\v2\LeanClrCodePkg.dll
    1 个警告（MSB3539：BaseIntermediateOutputPath 被 csproj 复用，可忽略）
    0 个错误
```

v2 的行为差异：`GetVersion()` 返回 `v2`、`GetAnswer()` 返回 `22`、`ComputeScore(10)` 返回 `20`、`GetFeature()` 返回 `double-score`。

### 5.2 生成包目录与 manifest.json（内容哈希命名）【已实测】

包目录是任意静态目录，DLL 用「程序集名 + SHA-256 前 16 位」命名，manifest 记录实际文件名与完整哈希：

```text
out\packages\good\
├── manifest.json
└── LeanClrCodePkg.3d37ad92cb82e27d.dll
```

生成命令（自动算 SHA-256、复制为哈希名、写 manifest）：

```powershell
$pkg = 'out\packages\good'
New-Item -ItemType Directory -Path $pkg -Force | Out-Null
$src = 'out\tmp\code_pkg\v2\LeanClrCodePkg.dll'
$sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $src).Hash.ToLower()
$name = 'LeanClrCodePkg.' + $sha.Substring(0, 16) + '.dll'
Copy-Item $src "$pkg\$name" -Force
$dll = Get-Item "$pkg\$name"
$json = @"
{
  "package_version": "v2",
  "assembly": "LeanClrCodePkg",
  "files": [
    { "name": "$name", "size": $($dll.Length), "sha256": "$sha" }
  ]
}
"@
[System.IO.File]::WriteAllText((Join-Path $pkg 'manifest.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
Get-Content "$pkg\manifest.json"
```

预期（哈希与文件名以实际内容为准）：

```json
{
  "package_version": "v2",
  "assembly": "LeanClrCodePkg",
  "files": [
    { "name": "LeanClrCodePkg.3d37ad92cb82e27d.dll", "size": 4608, "sha256": "3d37ad92cb82e27d..." }
  ]
}
```

再编译 v3 生成第二份包，文件名会随内容变化：

```powershell
dotnet build demo_csharp\LeanClrCodePkg.csproj -c Release -p:PkgVariant=v3
:: 把上面的 $pkg 换成 out\packages\good-v3，$src 换成 out\tmp\code_pkg\v3，package_version 改成 v3
```

本机 v2 → `LeanClrCodePkg.3d37ad92cb82e27d.dll`，v3 → `LeanClrCodePkg.1aace0253a187a3e.dll`。

字段与命名约束：

- `files[].name` 是 CDN 上的真实文件名，不能包含 `/` 或 `\`；建议固定为 `<Assembly>.<sha256 前 16 位>.dll`。
- `sha256` 为 64 位小写十六进制，必须与文件一致；`size` 必须与实际文件一致。
- `package_version` 非空，作为下载暂存目录名（`user://code_pkg/download/v2/`）。
- `assembly` 必须等于更新器配置的程序集名（默认 `LeanClrCodePkg`）。
- **安装时会改回固定名**：下载/校验用哈希名，写入 `user://code_pkg/assemblies/LeanClrCodePkg.dll` 时去掉哈希段。原因是 leanclr 按程序集名解析文件（`file_loader` 查 `<name>.dll`），改运行时的解析规则风险更高；固定名还保证同一目录下永远只有一份生效程序集。
- 先生成 manifest 再改动 DLL 会导致 SHA 不符；任何重新编译都要重新生成 manifest。

### 5.3 启动本地 HTTP 下载源与缓存语义【已实测】

```powershell
node scripts\code_pkg_server.mjs --root out\packages --port 18080
```

预期（请求日志会打印完整 URL，含 query）：

```text
[code_pkg_server] listening http://127.0.0.1:18080/ root=<REPO>\out\packages
```

另开一个终端核对内容与缓存头：

```powershell
Invoke-WebRequest http://127.0.0.1:18080/good/manifest.json -UseBasicParsing | Select-Object -ExpandProperty Content
$manifest = (Invoke-WebRequest http://127.0.0.1:18080/good/manifest.json -Method Head -UseBasicParsing).Headers['Cache-Control']
$dll = (Invoke-WebRequest "http://127.0.0.1:18080/good/LeanClrCodePkg.3d37ad92cb82e27d.dll" -Method Head -UseBasicParsing).Headers['Cache-Control']
$manifest
$dll
```

预期：

```text
no-cache, max-age=0, must-revalidate
public, max-age=31536000, immutable
```

缓存策略（CDN 配置建议）：

| 资源 | 文件名 | 建议响应头 | 理由 |
|---|---|---|---|
| `manifest.json` | 固定 | `Cache-Control: no-cache, max-age=0, must-revalidate` 或短 TTL（≤60s） | 版本入口，必须能及时看到新包；旧缓存会导致一直拿到旧 DLL 名 |
| DLL | `LeanClrCodePkg.<hash>.dll` | `Cache-Control: public, max-age=31536000, immutable` | 名字含内容哈希，内容变则名字变；同一个 URL 永不改内容 |
| 其他 | — | `no-store` | 非包资源不参与缓存 |

`code_pkg_server.mjs` 已按上述规则设置；换成 Nginx/对象存储时照此配置即可。仅刷新 manifest（或给 manifest 带 query）就能让客户端发现新 DLL，其余 DLL 全部走长缓存。

提供下载源的其他方式：

- **局域网/真机**：把 `out\packages` 整个目录放到任意静态文件服务器，App 内把 base_url 改成 `http://<宿主机IP>:<端口>/good`。APK 已含 `INTERNET` 权限。【需额外条件】真机与 HTTPS 未实测。
- **CDN/对象存储**：需支持 GET、正确 `Content-Length` 与上面的 `Cache-Control`；manifest 可额外配置“目录刷新/URL 刷新”。哈希 DLL 不要配置自动刷新，长缓存即可。

### 5.4 构造坏包（验证拒绝与回退）【已实测】

一键脚本会自动生成 `bad-sha` 与 `broken-type`；手工构造如下（沿用 good 的哈希文件名）。

SHA 不符（文件改一个字节，manifest 仍沿用 v2 的哈希名与 SHA，`size` 不变）：

```powershell
$bad = 'out\packages\bad-sha'
New-Item -ItemType Directory -Path $bad -Force | Out-Null
$name = 'LeanClrCodePkg.3d37ad92cb82e27d.dll'
$bytes = [System.IO.File]::ReadAllBytes("out\packages\good\$name")
$index = [int]($bytes.Length / 2)
$bytes[$index] = [byte](($bytes[$index] + 1) % 256)
[System.IO.File]::WriteAllBytes("$bad\$name", $bytes)
Copy-Item out\packages\good\manifest.json "$bad\manifest.json" -Force
```

合法 PE 但类型不存在（用 `bin\assemblies` 下另一个 DLL，按其自身哈希命名）：

```powershell
$broken = 'out\packages\broken-type'
New-Item -ItemType Directory -Path $broken -Force | Out-Null
$other = Get-ChildItem godot_project\bin\assemblies -Filter *.dll |
    Where-Object { $_.Name -notlike 'LeanClrCodePkg*' -and $_.Name -notlike 'mscorlib*' -and $_.Name -notlike 'System*' } |
    Select-Object -First 1
$dll = Get-Item $other.FullName
$sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $dll.FullName).Hash.ToLower()
$name = 'LeanClrCodePkg.' + $sha.Substring(0, 16) + '.dll'
Copy-Item $dll.FullName "$broken\$name" -Force
$json = @"
{
  "package_version": "broken-type",
  "assembly": "LeanClrCodePkg",
  "files": [
    { "name": "$name", "size": $($dll.Length), "sha256": "$sha" }
  ]
}
"@
[System.IO.File]::WriteAllText("$broken\manifest.json", $json, (New-Object System.Text.UTF8Encoding($false)))
```

## 6. 触发下载与生效

### 6.1 自动触发（测试场景）【已实测】

`res://code_pkg_test.tscn` 启动后会依次执行：初始化运行时 → 加载内置 v1 → 应用 `good`（v2）→ 应用 `good-v3`（v3，验证哈希名变化与旧包清理）→ 坏 SHA 包 → 坏类型包（回退到 v3）。因此第 5 节的 HTTP 源必须先就绪，然后：

```powershell
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
& $adb -s 127.0.0.1:16384 shell am force-stop org.godotengine.leanclrcodepkg
& $adb -s 127.0.0.1:16384 shell pm clear org.godotengine.leanclrcodepkg
& $adb -s 127.0.0.1:16384 reverse tcp:18080 tcp:18080
& $adb -s 127.0.0.1:16384 logcat -c
& $adb -s 127.0.0.1:16384 shell am start -n org.godotengine.leanclrcodepkg/com.godot.game.GodotApp
```

预期 App 内自动完成：下载 → 校验 → 安装到 `user://code_pkg/assemblies` → `reload_runtime()` → 执行 v2 → 再执行 v3 → 坏包拒绝与回退，最后打印 `=== code pkg test done ===`。

### 6.2 在自己的场景中调用【已实测】

更新器只要求一个已初始化的 `LeanCLRRuntime`。初始化目录顺序必须是 `[bin/bcl, user://code_pkg/assemblies, bin/assemblies]`：

```gdscript
var runtime := LeanCLRRuntime.new()
var updater := preload("res://code_pkg_updater.gd").new()
add_child(updater)
updater.setup(runtime, "LeanClrCodePkg", "CodePkgNode")
# 可选：manifest 缓存破除。留空 = 无 query（保持旧行为）。
updater.manifest_query = "v={version}"            # 例：.../manifest.json?v=v2
# updater.manifest_query_timestamp = true         # 未设置 manifest_query 时使用 ?v=<毫秒时间戳>

var dirs := PackedStringArray([
    ProjectSettings.globalize_path("res://bin/bcl"),
    updater.user_assemblies_dir(),                       # user://code_pkg/assemblies
    ProjectSettings.globalize_path("res://bin/assemblies"),
])
if not runtime.initialize(dirs):
    push_error(runtime.get_last_error())
if not runtime.load_assembly("LeanClrCodePkg"):
    push_error(runtime.get_last_error())

var result: Dictionary = await updater.download_and_apply("http://127.0.0.1:18080/good")
print(result["ok"], result["stage"], result["version"], result["generation_after"])
print(result["manifest_url"], result["file_name"], result["installed_names"])
```

query 占位符：

| 配置 | 结果 |
|---|---|
| `manifest_query = ""`（默认） | `.../manifest.json`，无 query |
| `manifest_query = "v={version}"` | 已安装 v2 时 `.../manifest.json?v=v2`；无版本时 `?v=0` |
| `manifest_query = "t={timestamp}"` | `.../manifest.json?t=<毫秒时间戳>`，每次请求都不同 |
| `manifest_query_timestamp = true` | 等价于上面的时间戳模式，仅在 `manifest_query` 为空时生效 |

实际请求 URL 会以 `[codepkg] GET <url>` 打印，可直接对照 CDN/服务端日志。

返回字典的关键字段：`ok`、`stage`（`manifest|download|verify|install|reload|probe|done|rollback`）、`version`、`files`、`manifest_url`、`file_name`（manifest 中的哈希文件名）、`file_names`、`installed_names`（实际落盘名）、`generation_before/after`、`rolled_back`、`version_after`、`error`。

### 6.3 生效语义

- 更新器安装新包后调用 `runtime.reload_runtime()`：释放句柄/映射/静态快照 → `Runtime::shutdown()` → 重新 `initialize()` → 按目录顺序重新解析程序集 → `generation += 1`。
- 安装时把 manifest 中的哈希文件名改回固定名 `<Assembly>.dll`，再整体替换 `user://code_pkg/assemblies`；成功后清空 `user://code_pkg/download/`，旧版本的哈希 DLL 不会残留或被误用。
- 旧句柄全部失效（`pkg old handle is null = true`）；`LeanCLRNode` 在 generation 变化后自动重绑（`[hotreload] node rebound: ...`）。
- 覆盖包位于 `lib_dirs` 中间：同名 DLL 优先于 `res://bin/assemblies`，删除覆盖目录即回退到内置版本。
- `user://` 在 App 重启后保留；不执行 `pm clear` 时，下次启动会直接加载已安装的版本（`state.json` 记录版本与来源）。测试场景为了可重复，会在启动时调用 `reset_local_state()` 清空覆盖目录。

## 7. 确认跑的是新代码

### 7.1 抓取并过滤 logcat【已实测】

```powershell
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
& $adb -s 127.0.0.1:16384 logcat -d > out\logs\android_code_pkg.log
Select-String -Path out\logs\android_code_pkg.log -Pattern 'pkg |\[codepkg\]|\[hotreload\]|resolve assembly'
```

本机真实输出（节选，已包含 query URL 与哈希文件名）：

```text
I godot : pkg user dir = /data/data/org.godotengine.leanclrcodepkg/files/code_pkg/assemblies
I godot : [LeanCLR] lib dir=bin/bcl
I godot : [LeanCLR] lib dir=/data/data/org.godotengine.leanclrcodepkg/files/code_pkg/assemblies
I godot : [LeanCLR] lib dir=bin/assemblies
I godot : pkg initial override = false
I godot : pkg initial generation = 0
I godot : pkg loaded assemblies = LeanClrCodePkg
I godot : pkg v1 version = v1
I godot : pkg v1 compute 10 = 10
I godot : pkg v1 feature base = true
I godot : pkg v2 manifest url = http://127.0.0.1:18080/good/manifest.json?v=0
I godot : pkg v2 manifest url has query = true
I godot : [codepkg] GET http://127.0.0.1:18080/good/manifest.json?v=0
I godot : pkg manifest version = v2
I godot : pkg manifest file = LeanClrCodePkg.3d37ad92cb82e27d.dll
I godot : pkg manifest file hashed = true
I godot : [codepkg] GET http://127.0.0.1:18080/good/LeanClrCodePkg.3d37ad92cb82e27d.dll
I godot : pkg verified files = 1
I godot : pkg reload returned = true
I godot : pkg reload stage = done
I godot : pkg generation delta = 1
I godot : pkg installed names = LeanClrCodePkg.dll
I godot : pkg user dir files = LeanClrCodePkg.dll
I godot : pkg download dir empty = true
I godot : pkg installed state version = v2
I godot : [LeanCLR] resolve assembly via filesystem: /data/data/org.godotengine.leanclrcodepkg/files/code_pkg/assemblies/LeanClrCodePkg.dll
I godot : [codepkg] applied version=v2 files=1 generation=0->1 installed=["LeanClrCodePkg.dll"]
I godot : pkg old handle is null = true
I godot : pkg v2 version = v2
I godot : pkg v2 compute 10 = 20
I godot : pkg v2 feature double = true
I godot : [hotreload] node rebound: type=CodePkgNode, generation=1, signals=0
I godot : pkg v3 manifest url = http://127.0.0.1:18080/good-v3/manifest.json?v=v2
I godot : pkg v3 manifest url uses v2 = true
I godot : [codepkg] GET http://127.0.0.1:18080/good-v3/manifest.json?v=v2
I godot : pkg v3 manifest version = v3
I godot : pkg v3 manifest file = LeanClrCodePkg.1aace0253a187a3e.dll
I godot : pkg v3 file name changed = true
I godot : pkg v3 manifest file hashed = true
I godot : [codepkg] GET http://127.0.0.1:18080/good-v3/LeanClrCodePkg.1aace0253a187a3e.dll
I godot : pkg v3 reload stage = done
I godot : pkg v3 generation delta = 1
I godot : pkg v3 installed state version = v3
I godot : pkg v3 user dir files = LeanClrCodePkg.dll
I godot : pkg old v2 dll absent = true
I godot : pkg old v2 download absent = true
I godot : pkg download dir empty after v3 = true
I godot : [codepkg] applied version=v3 files=1 generation=1->2 installed=["LeanClrCodePkg.dll"]
I godot : pkg v3 version = v3
I godot : pkg v3 compute 10 = 30
I godot : pkg v3 feature triple = true
I godot : [hotreload] node rebound: type=CodePkgNode, generation=2, signals=0
I godot : pkg bad sha rejected = true
I godot : pkg bad sha error = sha256 mismatch for LeanClrCodePkg.dll: ...
I godot : pkg version after bad sha = v3
I godot : pkg generation after bad sha = true
I godot : pkg broken type rolled back = true
I godot : [codepkg] rollback done=true version_after=v3 generation=4 ...
I godot : pkg version after rollback = v3
I godot : pkg after rollback compute 10 = 30
I godot : === code pkg test done ===
```

证明缓存/哈希语义的关键三行：

- `GET .../manifest.json?v=0`、`GET .../manifest.json?v=v2`：manifest 请求确实带 query，且 v3 用的是「已安装版本 v2」。
- `pkg manifest file = LeanClrCodePkg.3d37ad92cb82e27d.dll` → v3 变为 `1aace0253a187a3e`：内容变则文件名变。
- `pkg user dir files = LeanClrCodePkg.dll` + `pkg old v2 dll absent = true`：安装后目录只剩固定名，旧哈希 DLL 不残留。

### 7.2 设备侧文件与状态【已实测】

debug 包可直接 `run-as` 查看：

```powershell
& $adb -s 127.0.0.1:16384 shell run-as org.godotengine.leanclrcodepkg ls -l files/code_pkg/assemblies
& $adb -s 127.0.0.1:16384 shell run-as org.godotengine.leanclrcodepkg cat files/code_pkg/state.json
```

预期：

```text
total 8
-rw------- 1 u0_a49 u0_a49 4608 2026-11-10 14:40 LeanClrCodePkg.dll
{
  "assembly": "LeanClrCodePkg",
  "installed_at": "2026-11-10T06:40:20",
  "source": "http://127.0.0.1:18080/good-v3",
  "version": "v3"
}
```

`state.json` 只在安装并健康检查通过后写入；坏 SHA 包不会改变它，坏类型包回退后会恢复为上一份内容。`source` 只记录 base URL（不含 manifest 的 query），避免把时间戳写进状态。

### 7.3 手工断言清单【已实测】

| 检查点 | 依据 | 期望 |
|---|---|---|
| 覆盖目录进入加载路径 | `[LeanCLR] lib dir=.../code_pkg/assemblies` | 位于 `bin/bcl` 与 `bin/assemblies` 之间 |
| 初始运行内置 v1 | `pkg v1 version = v1` / `pkg v1 compute 10 = 10` | `v1` / `10` |
| manifest 请求带 query | `pkg v2 manifest url = ...?v=0` / `[codepkg] GET ...?v=0` | 两次出现同一带 query URL |
| DLL 为内容哈希名 | `pkg manifest file = LeanClrCodePkg.<16 hex>.dll` | 命中 |
| 下载与校验 | `pkg manifest version = v2` / `pkg verified files = 1` | `v2` / `1` |
| 安装改名固定名 | `pkg installed names = LeanClrCodePkg.dll` / `pkg user dir files = LeanClrCodePkg.dll` | 目录无哈希名 |
| 暂存清理 | `pkg download dir empty = true` | `true` |
| 安装并 reload | `pkg reload stage = done` / `pkg generation delta = 1` | `done` / `1` |
| 从可写目录加载 | `resolve assembly via filesystem: .../code_pkg/assemblies/LeanClrCodePkg.dll` | 路径在 `user://` 下 |
| 执行到新代码 | `pkg v2 compute 10 = 20` / `pkg v2 feature double = true` | `20` / `true` |
| 旧句柄失效 | `pkg old handle is null = true` | `true` |
| 节点自动重绑 | `[hotreload] node rebound: type=CodePkgNode, generation=1` | 出现 |
| 内容变则名变 | v3 `LeanClrCodePkg.<不同 hash>.dll` + `pkg v3 file name changed = true` | `true` |
| 旧版本 DLL 不残留 | `pkg old v2 dll absent = true` / `pkg old v2 download absent = true` | 均为 `true` |
| 坏 SHA 拒绝 | `pkg bad sha rejected = true` / `pkg version after bad sha = v3` | 拒绝且版本不变 |
| 坏包回退 | `[codepkg] rollback done=true version_after=v3` | 回退到 v3 且仍可执行 |
| 全流程完成 | `=== code pkg test done ===` | 出现 |
| 无崩溃 | 日志不含 `F/libc`、`Fatal signal`、`SCRIPT ERROR` | 均不出现 |

### 7.4 一键断言【已实测】

手工核对之后，用脚本做完整回归（71 项 logcat 断言）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\code_pkg_android_test.ps1 -Abi x86_64
```

本机结果：

```text
  PASS (71/71 断言)
  日志: <REPO>\out\logs\android_code_pkg.log
PASS  用时 74.2s
```

用时包含编译 v1/v2/v3、交叉编译原生库、导出与安装；设备内测试本身约 15s。

脚本参数：

| 参数 | 作用 |
|---|---|
| `-Serial 127.0.0.1:16384` | 指定设备；默认自动 `adb connect 127.0.0.1:16384` |
| `-SkipBuild` | 复用已有 v1/v2/v3 与原生库（要求 `out\tmp\code_pkg`、`out\packages` 已存在） |
| `-SkipExport` | 复用已有 APK |
| `-TimeoutSeconds 180` | logcat 轮询超时 |

桌面双通道回归（CLI + MCP，各 70 项）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\code_pkg_test.ps1 -Channel both
```

本机结果：

```text
CLI  PASS (70/70 断言)
MCP  PASS (70/70 断言)
```

## 8. 失败排查

### 8.1 导出 / 模板 / ABI

| 现象 | 原因 | 处理 |
|---|---|---|
| `Invalid export preset name: Android` | 预设名含空格，参数被拆成两个 | 命令中给 `"Android x86_64"` 加双引号 |
| `No project icon specified` | 项目未配置图标 | 仅警告；退出码 0 且 APK 存在即可继续 |
| `No export template found` / 找不到 `android_debug.apk` | 未安装 4.5.stable 导出模板或版本不一致 | 编辑器「管理导出模板」安装 4.5.stable |
| `Android .so file names must start with "lib"` | 原生库文件名不以 `lib` 开头 | 使用 `libleanclr_godot.so` / `libleanclr_godot.release.so` |
| 导出报 `configuration errors` 但无明细 | 缺 `debug_keystore_user` 或 `import_etc2_astc` | 按 §3.1 补齐编辑器/项目设置 |
| 启动即 `dlopen failed` / `F/libc` / `SIGILL` | `.so` 与设备 ABI 不匹配 | MuMu 为 x86_64；用 `build_android_native.ps1` 重建并确认 `lib\x86_64\` 产物 |
| 改了 C# 但 APK 里还是旧行为 | 导出前没有把 v1 复制进 `bin\assemblies`，或 PCK 未包含 DLL | 重跑 §2.2；确认 `include_filter` |

### 8.2 安装 / 启动 / 连接

| 现象 | 原因 | 处理 |
|---|---|---|
| `more than one device/emulator` | `emulator-5554` 与 `127.0.0.1:16384` 同时在线 | 所有命令加 `-s 127.0.0.1:16384` |
| `device offline` | MuMu 未完全启动或端口错误 | 重启 MuMu，`adb connect`；或改用 `emulator-5554` |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | 已安装包签名不同 | `adb uninstall org.godotengine.leanclrcodepkg` 后重装 |
| `Activity class ... does not exist` | package/activity 名写错 | 使用 `org.godotengine.leanclrcodepkg/com.godot.game.GodotApp` |
| App 启动后立即退出 | 原生库缺失/ABI 不符/assert | 看 `adb logcat -d` 的 `F/libc`、`Fatal signal`、`assertion` |
| 启动后不是测试流程 | 导出时主场景没切到 `res://code_pkg_test.tscn` | 按 §3.2 重新导出；核对 `project.godot` 已还原 |

### 8.3 下载 / 校验 / 加载

| 现象 | 原因 | 处理 |
|---|---|---|
| `manifest download failed` | 下载源未启动、端口不对、未做 `adb reverse` | 先起 `code_pkg_server.mjs`；执行 `adb reverse tcp:18080 tcp:18080`；`adb reverse --list` 核对 |
| `HTTPRequest` 超时 | APK 缺 `INTERNET` 权限或宿主防火墙拦截 | 确认 `permissions/internet=true`；用 `aapt dump permissions` 检查 |
| CDN 仍返回旧 manifest | manifest 被长缓存，且未启用 query | 设 `manifest_query="v={version}"` 或 `manifest_query_timestamp=true`；CDN 侧对 `manifest.json` 设 `no-cache`/短 TTL |
| `pkg v2 manifest url has query = false` | 没设置 `manifest_query`，也没开 `manifest_query_timestamp` | 按 §6.2 配置；注意默认是「不加 query」以保持兼容 |
| manifest 里找不到 DLL（404） | manifest 的 `files[].name` 与 CDN 上的哈希文件名不一致 | 重新生成 manifest；确认发布时用同一个哈希名上传 |
| 安装目录出现 `LeanClrCodePkg.<hash>.dll` | 安装阶段未改名（旧版本更新器） | 用当前 `code_pkg_updater.gd`；正常情况下 `assemblies/` 只应有一个固定名 |
| `sha256 mismatch for ...: expected ... got ...` | manifest 与 DLL 不一致（改过 DLL、换行/编码变化、用了旧 manifest） | 重新执行 §5.2；确保先复制 DLL 再算 SHA |
| `size mismatch for ...` | manifest 的 `size` 与实际文件不一致 | 同上，重新生成 manifest |
| `manifest assembly mismatch` | `assembly` 字段不是 `LeanClrCodePkg` | 改成更新器构造时的程序集名 |
| 找不到程序集（`load_assembly failed` / 无 `resolve assembly`） | 目录顺序错误、DLL 未打进 PCK、覆盖目录文件名不对 | 核对三行 `[LeanCLR] lib dir=` 顺序；确认 `user://code_pkg/assemblies/LeanClrCodePkg.dll` 存在 |
| 仍然执行 v1 | 覆盖目录未生效或包安装到错误目录 | 看 `resolve assembly via filesystem` 路径是否在 `code_pkg/assemblies`；检查 `state.json` |
| `pkg initial override = true`（预期为 false） | 上次运行留下了覆盖包 | `adb shell pm clear org.godotengine.leanclrcodepkg`；或删 `files/code_pkg` |

### 8.4 崩溃 / assert / 回退失败

| 现象 | 原因 | 处理 |
|---|---|---|
| `assertion "g_domain_name == nullptr" failed`，`SIGABRT` | 原生库是旧版本，`Settings` 全局字符串未随 `Runtime::shutdown()` 重置 | 用当前源码重跑 `scripts\build_android_native.ps1 -Configuration Debug` 并重新导出 |
| 新包中带 `[DllImport]` 的方法首次调用崩溃 | `reload_runtime()` 重新 `initialize()` 后未重新注册 P/Invoke | 已在 `reload_runtime()` 内调用 `register_godot_bridge()`；确认原生库为最新 |
| `pkg broken type rolled back = false` | 回退时 `reload_runtime()` 失败 | 看 `[codepkg] rollback ... error=`；确认 `backup/` 目录存在且可写 |
| 回退后仍无法执行 | `backup/` 内容损坏或首次安装即坏包 | 删除 `user://code_pkg` 后回到内置 v1；重新发包 |
| `SCRIPT ERROR` | GDScript 运行时错误（例如接口名/节点名写错） | 按日志行号修复；测试场景与更新器接口见 §6.2 |

### 8.5 推荐定位顺序

1. 看 `pkg user dir` 与三行 `[LeanCLR] lib dir=`，确认覆盖目录位于中间。
2. 看是否出现 `resolve assembly via filesystem: .../code_pkg/assemblies/LeanClrCodePkg.dll`。
3. 看 `[codepkg]` 的 `applied` 或 `apply failed`/`rollback` 行，确认失败阶段（`manifest`/`download`/`verify`/`reload`/`probe`）。
4. 确认没有 `F/libc`、`Fatal signal`、`SCRIPT ERROR`、`LeanCLR ... failed`。
5. 仍无法定位时，跑 `scripts\code_pkg_android_test.ps1 -SkipBuild -SkipExport` 复现并保留 `out\logs\android_code_pkg_<abi>.log`。

## 9. 原理与约束

### 9.1 方案选择

| 方案 | 做法 | 结论 |
|---|---|---|
| 阶段 B `reload_runtime()` | 释放全部句柄/映射/静态快照 → `Runtime::shutdown()` → 重新 `initialize()` → 按原顺序重载程序集 | **采用** |
| 阶段 C `reload_assembly()` | 模块级卸载后重载同名程序集 | 不适用：下载的是「新包覆盖目录」，不是替换同名模块 |
| 重启场景/进程 | 让 Godot 重新加载主场景或重启 App | 不可测且用户体验差 |

选用 `reload_runtime()` 的原因：

- 同一进程内可断言 `generation` 变化，CLI/MCP/Android 都能自动化验证。
- 会关闭并重建 VM，`lib_dirs` 顺序在 `apply_settings()` 中重新确定，新包目录立即生效。
- `LeanCLRNode` 已内置 generation 变化后自动重绑，代码包替换无需额外适配。
- 不需要重启进程，也不需要 Android 侧的 `Activity` 重建。

### 9.2 加载优先级与可写路径

```gdscript
runtime.initialize(PackedStringArray([
    ProjectSettings.globalize_path("res://bin/bcl"),                 # 1. BCL（只读，PCK 内）
    ProjectSettings.globalize_path("user://code_pkg/assemblies"),    # 2. 下载的覆盖包（可写）
    ProjectSettings.globalize_path("res://bin/assemblies"),          # 3. 内置业务程序集（只读）
]))
```

解析规则（`native/src/leanclr_runtime.cpp::file_loader`）：

1. 按 `lib_dirs_` 顺序查找。
2. `res://` 路径先走 Godot VFS（PCK 内可读）。
3. `user://` 的绝对路径不会被映射到 `res://`，直接走真实文件系统。
4. 命中即返回；覆盖目录中的同名 DLL 遮蔽内置版本，删除覆盖包后自动回退。

约束：

- `apply_settings()` 把 `lib_dirs_.front()` 作为 data/config dir，因此 **BCL 必须排第一**。
- `hotreload.statics.json` 从 `lib_dirs_.back()` 读取，因此 **内置业务目录必须排最后**。
- 覆盖目录只能放中间，否则静态迁移与 BCL 初始化会走错目录。

平台路径：

| 平台 | `user://code_pkg/assemblies` 实际路径 | 权限 |
|---|---|---|
| Windows | `%APPDATA%\Godot\app_userdata\LeanCLR Godot POC\code_pkg\assemblies` | 可写 |
| Android | `/data/data/org.godotengine.leanclrcodepkg/files/code_pkg/assemblies` | 应用私有可写 |
| APK 内 PCK | `assets/` 下的 `bin/bcl`、`bin/assemblies` | 只读 |

Android 上 APK 内的 PCK 只读，`user://` 是唯一可写区，因此下载的程序集必须落到上表路径。

### 9.3 包格式与本地布局

```text
<base_url>/manifest.json                     # 每次发布都刷新（不缓存或短 TTL）
<base_url>/LeanClrCodePkg.<hash>.dll         # 内容哈希名，immutable 长缓存
```

`<hash>` 为文件 SHA-256 的前 16 位小写十六进制，例如 `LeanClrCodePkg.3d37ad92cb82e27d.dll`。DLL 内容变化时哈希名必然变化，因此同一 URL 永远对应同一份字节。

`manifest.json`：

```json
{
  "package_version": "v2",
  "assembly": "LeanClrCodePkg",
  "files": [
    { "name": "LeanClrCodePkg.3d37ad92cb82e27d.dll", "size": 4608, "sha256": "<hex>" }
  ]
}
```

契约：

- `files[].name` 是**下载地址的最后一段**，也是哈希名来源；更新器按它拼接 URL，但安装落盘时改回 `<assembly>.dll`。
- `sha256` 为完整 64 位 hex，更新器按 `name` 下载后重新计算并比对，命中 `verify` 阶段失败才拒绝。
- 可选 query 只作用于 manifest 请求（`manifest_query` / `manifest_query_timestamp`），DLL 请求直接使用 manifest 中的哈希名，不再附加 query。

为什么安装时改名而不是按哈希名直读：

- leanclr 的 `file_loader` 按程序集名解析 `<Assembly>.dll`，改原生解析规则的风险与改动面都更大。
- 固定名保证 `code_pkg/assemblies` 始终只有一份生效程序集，不会出现两个哈希 DLL 并存导致「加载到旧版本」。
- 哈希名只承担传输与 CDN 缓存职责；安装阶段的 staging 目录里改名，整体 rename 后旧目录被替换，天然清理旧版本。

`user://` 布局：

```text
user://code_pkg/
├── assemblies/           # 当前生效的覆盖包（只含固定名 LeanClrCodePkg.dll）
├── download/<version>/   # 下载与校验暂存区（含哈希名，安装后清空）
├── backup/               # 安装前的上一份 assemblies（回退用）
└── state.json            # {version, assembly, source, installed_at}
```

下载与生效流程（`godot_project/code_pkg_updater.gd`）：

1. 按 `build_manifest_url()` 生成 manifest URL（可选 query），下载并解析，校验 `package_version` 与 `assembly` 字段。
2. 按 `files[].name` 下载各文件到 `user://code_pkg/download/<version>/`。
3. 逐文件校验 `size` 与 SHA-256；任一不符即终止，**不安装、不 reload**。
4. 在 staging 内把哈希名改回 `<Assembly>.dll`。
5. 把现有 `assemblies/` 重命名为 `backup/`，再把 staging 重命名为 `assemblies/`。
6. 调用 `runtime.reload_runtime()`。
7. 用 `invoke_static("CodePkgNode", "Describe", [])` 做健康检查（类型不存在即视为坏包）。
8. 成功写 `state.json` 并清空 `download/`；失败进入回退。

### 9.4 失败与回退

| 失败点 | 行为 | 结果 |
|---|---|---|
| manifest 缺失/字段不符 | 终止，不落盘 | `ok=false`, `stage=manifest` |
| 下载失败 | 保留旧 `assemblies/` | `ok=false`, `stage=download` |
| size/SHA-256 不符 | 删除暂存文件，不安装、不 reload | `ok=false`, `stage=verify`，generation 不变 |
| reload 失败 | 恢复 `backup/` 并再次 reload | `rolled_back=true` |
| 类型探测失败（合法 PE 但缺类型） | 删除新包，恢复 `backup/` 并再次 reload | `rolled_back=true`, `version_after` 为上一份版本 |
| 回退后仍失败 | 保留错误，运行时处于最后一次可用的初始化结果 | `ok=false`，`error` 带原因 |

任何情况下都不会把运行时留在「已安装但无法执行」的新包上。

### 9.5 reload 相关的两个必要修复

- **P/Invoke 重新注册**：`Runtime::shutdown()` 会清空 P/Invoke/InternalCall 注册表，`reload_runtime()` 在重新 `initialize()` 后必须再调用 `register_godot_bridge()`，否则新包里带 `[DllImport]` 的方法会在首次调用时崩溃。
- **Settings 全局状态清理**：`Settings::set_domain_name` 等只允许设置一次（`assert(g_domain_name == nullptr)`）。桌面 Release 因 `NDEBUG` 关闭 assert 未暴露，Android Debug 会在第二次 `apply_settings()` 直接 `SIGABRT`。修复方式：新增 `Settings::shutdown()`（释放并置空 domain/config/data/temp/config 与命令行参数），由 `Runtime::shutdown()` 调用；补丁清单见 `AGENTS.md` §8。

## 10. 相关文件与脚本入口

| 文件 | 作用 |
|---|---|
| `demo_csharp/CodePkg.cs` / `LeanClrCodePkg.csproj` | v1/v2/v3 示例程序集（`PkgVariant` 切换行为） |
| `godot_project/code_pkg_updater.gd` | 下载、校验、哈希名改固定名、reload、回退 |
| `godot_project/code_pkg_test.gd` / `code_pkg_test.tscn` | 桌面与 Android 共用的自动化断言场景 |
| `godot_project/code_pkg_demo.gd` / `code_pkg.tscn` | 桌面可演示 HUD（`U` 应用 / `C` 清除） |
| `scripts/code_pkg_server.mjs` | 本地静态 HTTP 源（日志含完整 URL 与 Cache-Control） |
| `scripts/code_pkg_test.ps1` | 桌面 CLI + MCP 双通道回归（各 70 项断言） |
| `scripts/code_pkg_android_test.ps1` | Android 构建、导出、安装、运行与 71 项 logcat 断言 |
| `scripts/build_android_native.ps1` | 按 ABI（x86_64 / arm64-v8a / armeabi-v7a）交叉编译 Android 原生库 |
| `scripts/code_pkg_demo.ps1` | 桌面一键演示（非 Android） |
