# 02 构建流程

## 0. 构建目录约定

源码与编译产物分离：所有 CMake 中间物、原生库、日志、APK、导出包都写入仓库根的 `out/`（已在 `.gitignore`），工程内只保留部署结果。

```text
out/
├─ build/windows/{debug,release}      # CMake 构建目录（中间物）
├─ build/linux/{debug,release}
├─ build/android/<abi>/{debug,release}
├─ bin/windows/  bin/linux/  bin/android/<abi>/   # 编译产物（部署源）
├─ logs/                              # 构建与回归日志
├─ export/{dbg,rel,linux}             # PCK 导出
├─ android/                           # APK
├─ packages/                          # 代码包 HTTP 源
└─ tmp/                               # 临时素材
```

构建与部署分两步：先编译到 `out/bin/...`，再由 `scripts/deploy_native.ps1` 复制到 `godot_project/bin`（`.gdextension` 里写的是 `res://bin/...`，与此对应）。清空 `out/` 只会丢构建产物，不会影响源码。

### 0.1 依赖获取：submodule + 补丁

leanclr 与 godot-cpp 由 `.gitmodules` 固定到具体 commit：

| 路径 | 上游 | 固定 commit |
|---|---|---|
| `native/thirdparty/leanclr` | `focus-creative-games/leanclr`（mono 分支） | `8e024dfe` |
| `native/thirdparty/godot-cpp` | `godotengine/godot-cpp`（4.5） | `27d9dd23` |

首次 clone 后初始化：

```bash
git submodule update --init --recursive
```

leanclr 在本仓库需要的热更能力（`Runtime::shutdown()`、`Assembly::unload_module()` 等，清单见 `AGENTS.md` §8）**不在上游提交里**，以 `patches/leanclr-runtime-hotreload.patch` 保存。补丁不是可选项，构建前必须应用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ensure_deps.ps1
```

该脚本做三件事：`git submodule update --init --recursive` → 校验 `native/thirdparty/leanclr/src/runtime` 存在 → 应用 `patches/*.patch`（反向可应用视为已应用，可重复执行；冲突直接报错退出）。`scripts/build_native.bat`、`build_native_release.bat`、`build_android_native.ps1`、`build_native_linux.sh`、`build_android_linux.sh` 都会先调用它，因此本地与 CI 走同一套逻辑。CI 的注意事项见 `docs/11-ci.md`。

## 1. 两种构建路径

先设置工具变量：

```bat
for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
set "VS_MSBUILD=%VSPATH%\MSBuild\Current\Bin\MSBuild.exe"
set "VS_CMAKE=%VSPATH%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
```

| 场景 | 命令 | 耗时 |
|---|---|---|
| 只改 `native/src` | MSBuild 直连 `leanclr_godot.vcxproj`，跳过项目引用 | 数秒 |
| 改 `CMakeLists.txt` / leanclr / godot-cpp | CMake `/` 或 `scripts/build_native.bat` | 数分钟（godot-cpp 全量重编 2000+ 文件） |

### 1.1 MSBuild 增量构建（日常）

```bat
"%VS_MSBUILD%" out\build\windows\debug\leanclr_godot.vcxproj -p:Configuration=Release -p:Platform=x64 -p:BuildProjectReferences=false -m -v:minimal
```

- `-p:BuildProjectReferences=false` 跳过 `godot-cpp` 与 `leanclr` 依赖项目。
- 前提：`out/build/windows/debug/` 已经由 CMake 成功配置过，且 `godot-cpp` / `leanclr` 静态库已存在。
- 产物：`out/build/windows/debug/Release/leanclr_godot.dll`；部署仍走 `scripts/deploy_native.ps1 -Platform windows -Configuration Debug`。

### 1.2 CMake 全量构建

首次配置（只有第一次或删除 `out/` 后需要）：

```bat
"%VS_CMAKE%" -S . -B out\build\windows\debug -G "Visual Studio 17 2022" -A x64 -DGODOTCPP_TARGET=template_debug
```

构建：

```bat
"%VS_CMAKE%" --build out\build\windows\debug --config Release --target leanclr_godot --parallel
```

或直接运行 `scripts/build_native.bat`（会自动探测 VS，把产物写到 `out/bin/windows/leanclr_godot.dll` 并部署到 `godot_project/bin`）。

### 1.3 template_release 双目标构建

导出 release 包必须使用按 `template_release` 编译的扩展，否则引擎在退出阶段会报 heap corruption（`0xC0000374`）。两种目标产物并存：

| 目标 | 构建目录 | 部署文件名 | 用途 |
|---|---|---|---|
| `template_debug` | `out/build/windows/debug` | `godot_project/bin/leanclr_godot.dll` | 编辑器、debug 导出 |
| `template_release` | `out/build/windows/release` | `godot_project/bin/leanclr_godot.release.dll` | release 导出 |

`godot_project/bin/leanclr_godot.gdextension` 已按 feature tag 分别指向两个文件。

构建 release 目标（首次会重新编译 godot-cpp，耗时数分钟）：

```bat
scripts\build_native_release.bat
```

日常只改 `native/src` 时，同样可以走 MSBuild 增量：

```bat
"%VS_MSBUILD%" out\build\windows\release\leanclr_godot.vcxproj -p:Configuration=Release -p:Platform=x64 -p:BuildProjectReferences=false -m -v:minimal
```

产物复制为 `godot_project/bin/leanclr_godot.release.dll`。

### 1.4 Linux 构建（WSL）

Linux 产物为 `leanclr_godot.so`（CMake 已设 `PREFIX ""`，无 `lib` 前缀）。在 WSL 或 Linux 主机上直接跑脚本（内部会初始化 submodule、应用补丁、编译并部署）：

```bash
cd /mnt/<drive>/<path>/leanclr_gotdot
bash scripts/build_native_linux.sh
```

等价的手工命令：

```bash
cmake -S . -B out/build/linux/debug -DCMAKE_BUILD_TYPE=Release -DGODOTCPP_TARGET=template_debug
cmake --build out/build/linux/debug --target leanclr_godot --parallel
mkdir -p out/bin/linux && cp out/build/linux/debug/leanclr_godot.so out/bin/linux/
```

脚本最后会用 `pwsh scripts/deploy_native.ps1 -Platform linux -Configuration Debug` 部署；没有 `pwsh` 时退化为直接 `cp` 到 `godot_project/bin/leanclr_godot.so`。

要点：

- `CMAKE_POSITION_INDEPENDENT_CODE=ON` 是必须的（`CMakeLists.txt` 已内置）：`libleanclr.a` 若未按 `-fPIC` 编译，链接 `leanclr_godot.so` 会报
  `relocation R_X86_64_PC32 against symbol ... can not be used when making a shared object; recompile with -fPIC`。
- 首次构建会全量编译 godot-cpp（约 1000 个目标文件），4 核 `-j4` 下需要数分钟；构建输出重定向到文件（`out/logs/build_linux_cmake.log`、`out/logs/build_linux_make.log`）。
- 不需要 scons / ninja / xvfb-run：构建走 CMake+make，运行验证用 `--headless`。
- `out/` 已在 `.gitignore` 中；`godot_project/bin/leanclr_godot*.so` 也不入库。

## 2. 为什么 CMake 会反复全量重编

`godot-cpp` 的绑定生成 custom command 会被判定为每次过期，触发 `Generating bindings` 并重编全部生成类。因此：

- 日常只改 `native/src` 时不要用 CMake，用 MSBuild。
- CMake 构建耗时属正常现象，不要中途判定失败。
- 构建输出必须重定向到文件后再读取，不要用 `| tail`。

## 3. 新增源文件的规则

新增 `.cpp` 后必须显式加入 `CMakeLists.txt`：

```cmake
add_library(leanclr_godot SHARED
    native/src/register_types.cpp
    native/src/leanclr_runtime.cpp
    native/src/leanclr_node.cpp
    native/src/<新增文件>.cpp
)
```

否则 CMake 不会编译该文件（现象：代码里新方法不存在或链接报未定义符号）。新增文件后需要执行一次 CMake 全量构建。

## 4. 构建产物与部署

| 产物 | 路径 |
|---|---|
| GDExtension DLL（debug 目标） | `out/bin/windows/leanclr_godot.dll` → `godot_project/bin/leanclr_godot.dll` |
| GDExtension DLL（release 目标） | `out/bin/windows/leanclr_godot.release.dll` → `godot_project/bin/leanclr_godot.release.dll` |
| native smoke | `out/build/windows/debug/Release/leanclr_smoke.exe` |

部署统一由 `scripts/deploy_native.ps1` 完成（`-Platform windows|linux|android`、`-Configuration Debug|Release|Both`、Android 追加 `-Abi`）。部署前若目标 DLL 被 Godot 占用，先删除再复制。

## 5. 构建失败处理

1. 先看错误原文中的文件与行号（如 `native/src/leanclr_runtime.cpp(112,5): error C2065`）。
2. 清理残留进程后再重试：

```bat
taskkill.exe //F //IM MSBuild.exe //T
taskkill.exe //F //IM cmake.exe //T
```

3. 若提示未定义符号，先检查新文件是否已列入 `CMakeLists.txt`。
4. 若 CMake 卡在某个 `.cpp`，检查是否后台执行被限流；改为前台长超时。

## 6. native smoke（可选）

不启动 Godot，直接验证 leanclr 嵌入链路：

```bat
out\build\windows\debug\Release\leanclr_smoke.exe godot_project\bin\bcl godot_project\bin\assemblies
```

期望输出包含 `test.App::Run(1, 2) = 3` 与 `SMOKE_OK`。

## 7. 多平台构建环境清单

| 平台 | 构建状态 | 运行验证 | 缺口 |
|---|---|---|---|
| Windows x64 | 已完成（`template_debug` + `template_release`） | 编辑器 headless + debug/release 导出运行通过 | — |
| Linux x86_64 | 已完成（WSL 实测） | 导出包 headless 退出码 0，64 行与 Windows 导出基线一致 | release 目标未单独构建；未在桌面环境验证窗口/音频 |
| macOS | 未构建 | 未验证 | 需要 macOS 宿主、Xcode CLT、`macos.zip` 模板、签名 |
| Android | 未构建 | 未验证 | 需要 SDK/NDK/JDK、`android_*.apk` 模板、设备或模拟器 |
| AOT | 未接入 | 未验证 | 需要 .NET SDK 与 leanclr LeanAOT 上游工具链 |

### 7.1 Linux x86_64

- 工具链：amd64 Linux（已验证 WSL Ubuntu 22.04.1），g++ ≥ 11、CMake ≥ 3.20、make、python3。不需要 scons / ninja / xvfb-run。
- 必须 `-DCMAKE_POSITION_INDEPENDENT_CODE=ON`（`CMakeLists.txt` 已内置），否则链接报 `recompile with -fPIC`。
- 导出模板：`linux_debug.x86_64`、`linux_release.x86_64`（4.5.stable 目录自带）。
- 工程改动：`.gdextension` 的 `linux.debug.x86_64` / `linux.release.x86_64`；`export_presets.cfg` 的 `[preset.1] Linux`；产物 `leanclr_godot.so` / `leanclr_godot.release.so`。
- 验证：按 §1.4 构建 `out/bin/linux/leanclr_godot.so`，执行 `scripts\deploy_native.ps1 -Platform linux -Configuration Debug`，再按 `docs/04` §6.5 导出并在 WSL headless 运行对比基线（或直接执行 `scripts\pck_export.ps1 -IncludeLinux`）。
- 待补：Linux release 目标构建脚本（对应 Windows 的 `scripts/build_native_release.bat`）。

### 7.2 macOS

- 宿主与工具链：macOS 12+；Xcode Command Line Tools（clang / ld / codesign）；CMake ≥ 3.20；python3。编辑器与 `--export` 必须在 macOS 上执行，Windows 编辑器无法导出 macOS 包。
- 架构：Apple Silicon 用 `-DCMAKE_OSX_ARCHITECTURES=arm64`，Intel 用 `x86_64`，通用包用 `"arm64;x86_64"`；godot-cpp 与 leanclr 需按同一架构集编译。
- 导出模板：`macos.zip`（4.5.stable 自带）。
- 工程改动：`.gdextension` 增加 `macos.debug.arm64` / `macos.release.arm64`（及 `x86_64` 变体），指向 `leanclr_godot.dylib` / `leanclr_godot.release.dylib`；`export_presets.cfg` 增加 macOS 预设。
- 签名：GDExtension 库随 `.app` 一起签名，本地验证至少 ad-hoc `codesign --force --deep -s - X.app`；分发需 Developer ID 与公证。
- 验证：`X.app/Contents/MacOS/X --headless --quit-after 120 --log-file <绝对路径>`，按 `docs/04` 第 3 节基线比对。
- 当前缺口：无 macOS 宿主，无法在本机完成。

### 7.3 Android

- 工具链：Android SDK（platform-tools、build-tools）、NDK 28.2.13676358、JDK 17；本仓库使用预编译模板导出（不走 Gradle）。
- 导出模板：`android_debug.apk` / `android_release.apk`；需要自定义 gradle 工程时用 `android_source.zip`。
- 构建：`scripts/build_android_native.ps1 -Abi x86_64|arm64-v8a|armeabi-v7a -Configuration Debug|Release|Both`，内部用 NDK 的 `android.toolchain.cmake`，构建目录 `out/build/android/<abi>/<cfg>`，产物 `out/bin/android/<abi>/libleanclr_godot.so`，并自动部署到 `godot_project/bin/android/<abi>/`。等价手工命令：

```bash
cmake -S . -B out/build/android/arm64-v8a/debug \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 -DANDROID_STL=c++_shared \
  -DGODOTCPP_TARGET=template_debug -DCMAKE_POSITION_INDEPENDENT_CODE=ON
cmake --build out/build/android/arm64-v8a/debug -j4
```

- 产物命名：Android 要求 `lib` 前缀，`.gdextension` 按 ABI 指向 `res://bin/android/<abi>/libleanclr_godot.so`，Godot 导出时把 `.so` 放进 APK 的 `lib/<abi>/`。
- BCL 与业务程序集仍通过 `res://` + PCK 加载，无需额外改动。
- 验证：`adb install -r out/android/LeanClrCodePkg-<abi>.apk` → 启动应用 → `adb logcat` 抓取日志，按 `docs/09` 断言脚本核对。
- 当前状态：x86_64 已在 MuMu 12 实跑通过；arm 两个 ABI 的覆盖情况见 `docs/09` 的 ABI 矩阵。

### 7.4 AOT（LeanAOT）

- 依赖：.NET SDK（运行 LeanAOT 工具与 IL 分析）与 leanclr mono 分支的 LeanAOT 工具链；产物必须与目标平台/架构一致。
- 工作内容：把 `LeanClrGame.dll`（以及 BCL 中实际用到的部分）预编译为 AOT 模块，运行时改为加载 AOT 产物，解释器保留为回退路径。
- 验证：与当前解释执行日志逐行对比（`docs/04` 第 3 节基线），确认方法调用、字段、引用类型句柄、信号结果一致；再对比启动耗时与 `OnProcess` 开销。
- 状态：未接入。上游 LeanAOT 的产物格式与加载 API 未在本仓库验证，属外部工具链依赖，暂不排期。