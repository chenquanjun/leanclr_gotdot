# 01 环境与依赖

## 1. 目标环境

- 操作系统：Windows 11（git-bash / MSYS 终端）。
- 引擎：Godot 4.5 stable（标准版，非 mono 版）。
- 运行时：leanclr mono 分支。
- 绑定层：godot-cpp 4.5。
- 跨平台：Linux x86_64 已通过 WSL 完成构建与导出运行验证；macOS、Android、AOT 的工具链与模板清单见 `docs/02-build.md` §7。

## 2. 工具链与路径

| 工具 | 版本/路径 | 用途 |
|---|---|---|
| Visual Studio | 2022 Professional（安装路径由 `vswhere` 探测） | MSVC 编译器 |
| MSVC | 14.44.35207 | 编译 native |
| MSBuild | `.../MSBuild/Current/Bin/MSBuild.exe` | 增量构建 |
| CMake | `.../Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe` | 配置与全量构建 |
| Windows SDK | 10.0.26100.0 | 系统头文件与库 |
| Python | 3.14（PATH 中的 `python`） | godot-cpp 生成绑定 |
| .NET Framework csc | `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe` | 编译 C# 测试程序集 |
| Godot 4.5 | 默认 `.tools/godot45/Godot_v4.5-stable_win64_console.exe`，可用 `GODOT_BIN` 覆盖 | headless 运行回归 |
| godot-mcp | `.tools/godot-mcp`（Node ≥ 18，`npm install` 后可用） | MCP 验证通道，见 `docs/04` §8 |

换机时用以下命令探测 VS 安装路径：

```bat
"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
```

## 3. 依赖来源

leanclr 与 godot-cpp 以 git submodule 固定在 `.gitmodules`，不再手工复制：

| 依赖 | 位置 | 获取方式 |
|---|---|---|
| leanclr mono 分支 | `native/thirdparty/leanclr`（运行时在 `src/runtime`） | submodule 固定到 `8e024dfe`；`git submodule update --init --recursive` |
| godot-cpp 4.5 | `native/thirdparty/godot-cpp` | submodule 固定到 `27d9dd23`；同上 |
| 本地热更补丁 | `patches/leanclr-runtime-hotreload.patch` | `scripts/ensure_deps.ps1`（或 `scripts/apply_patches.ps1`）应用，构建脚本会自动调用 |
| mono-4.5 BCL | `godot_project/bin/bcl` | `scripts/bootstrap_bcl.ps1`：从 submodule 的 `src/libraries/mono-4.5` 复制**全部顶层 dll**，另将 `Facades/netstandard.dll` 复制到 BCL 根目录（共 154 个） |
| Godot 4.5 | `.tools/godot45` | 本机 `Godot_v4.5-stable_win64.exe.zip`，用 `tar.exe` 解压；CI 从 godot-builds 下载（见 `docs/11-ci.md`） |

为什么 submodule 之外仍需补丁：submodule 只固定上游 commit，阶段 B/C 的运行时清理钩子（`Runtime::shutdown()`、`Assembly::unload_module()`、各单例 `shutdown()`）以及 Android arm32 的 `RtStackObject` 偏移修复都在本仓库工作区，不在上游。两条路线的取舍：

- **submodule 指上游 + `patches/`（本仓库当前方案）**：不需要维护 fork，升级上游只需改 gitlink 并重跑 `scripts/apply_patches.ps1`；代价是补丁可能随上游演进而冲突（脚本会 `--check` 报错，不会静默跳过）。
- **推一个 fork、submodule 指向 fork**：clone 即得完整能力，无需应用补丁；代价是要维护 fork 与上游同步、CI 依赖该 fork 的可见性，且本仓库提交记录看不到改了什么。

版本固化：`.gitmodules` 不含 `branch`，submodule 版本由父仓库索引里的 gitlink 决定，所以 `git submodule update`（不带 `--remote`）不会被上游更新带偏。`scripts/verify_submodules.ps1` 会逐项比对 submodule HEAD 与 gitlink，不一致或未初始化都直接报错；`ensure_deps.ps1` 与 CI 都会调用它。有意升级见 `docs/11-ci.md` §5。

## 4. 沙箱/终端约束

- `curl` 与 `winget` 下载被沙箱拦截；`git` 可用。
- 交互式、长阻塞命令会卡住会话；构建输出必须重定向到日志文件，再读取日志。
- 后台执行的构建会被限流而停滞；长构建放前台并设置长超时。
- 向系统软件根级目录解压可能被拒绝；工具产物放在工程内 `.tools/`。
- `Expand-Archive` 解压后可能不生成目录，使用 `tar.exe -xf <zip> -C <dir>`。
- MSYS 会把 `/nologo` 之类参数当成路径；csc 参数使用 `-` 风格，且工作目录切到源文件目录。

## 5. 目录与忽略规则

`.gitignore` 已忽略：`out/`（全部编译产物与日志）、`.refs/`、`.tools/`、`godot_project/.godot/`、`godot_project/bin/{bcl,assemblies}/`、`godot_project/bin/*.dll|*.so|*.pdb`、`godot_project/bin/android/`、`demo_csharp/obj|bin|*.dll|*.pdb`。**注意 `native/thirdparty/` 不再被忽略**：它是 submodule，gitlink 与 `.gitmodules` 必须入库。

需要提交的产物：`.gitmodules`、`patches/`、`native/src`、`CMakeLists.txt`、`godot_project`（除 `.godot` 与二进制）、`demo_csharp/*.cs|*.csproj`、`scripts/`、`.github/workflows/`、`AGENTS.md`、`docs/`。

`godot_project/bin/bcl` 与 `godot_project/bin/assemblies` 的二进制不入库；首次构建用 `scripts/bootstrap_bcl.ps1` 生成，热更/代码包测试脚本会自行编译所需程序集。