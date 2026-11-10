# AGENTS.md

本仓库将 leanclr（`focus-creative-games/leanclr` 的 **mono 分支**）作为 C#/.NET 运行时嵌入 Godot 4.5 GDExtension。任何 AI 或开发者在本仓库改动前，必须先读本文件，再读 `docs/` 中对应流程文档。

## 1. 不可回退的架构决策

- 运行时使用 leanclr **mono 分支**，源码位于 `native/thirdparty/leanclr/src/runtime`（git submodule，固定 commit）。
- BCL 使用**完整 mono-4.5 目录**，位于 `godot_project/bin/bcl`；不得只部署 `mscorlib.dll` / `System.dll` 等核心集。
- 宿主使用 Godot 4.5 + **godot-cpp 4.5**，源码位于 `native/thirdparty/godot-cpp`（git submodule），产物为 `leanclr_godot.dll`。
- **不使用 IL2CPP 兼容层**：Godot 没有 IL2CPP 管线，leanclr 以独立嵌入方式工作。
- **不实现完整 `ScriptLanguageExtension`**：Godot 4.5 的 GDExtension 未暴露 `ScriptInstance`，也未绑定 `Script::_instance_create` 等扩展点，`_create_script` 无法返回可实例化脚本。脚本宿主固定为 `LeanCLRNode`。
- 不修改 `native/thirdparty/leanclr` 与 `native/thirdparty/godot-cpp` 的源码；所有适配写在 `native/src`。**例外**：C# 热更所需的运行时清理钩子已获用户授权，见 §8。这些修改必须在 `patches/leanclr-runtime-hotreload.patch` 中同步更新，不能只留在工作区。

## 2. 目录结构

```text
leanclr_gotdot/
├── AGENTS.md                    # 本文件
├── CMakeLists.txt               # native 构建入口
├── .gitmodules                  # leanclr / godot-cpp 固定到具体 commit
├── patches/                     # leanclr 热更补丁（构建前必须应用）
├── docs/                        # 分阶段流程文档
├── .github/workflows/           # CI：Windows/Linux 回归、Android 构建导出
├── native/
│   ├── src/                     # 适配层源码（唯一改动区）
│   │   ├── register_types.*     # GDExtension 入口与类注册
│   │   ├── leanclr_runtime.*    # 运行时、对象、字段、P/Invoke 回桥
│   │   ├── leanclr_node.*       # LeanCLRNode 节点宿主
│   │   └── smoke_main.cpp       # 不依赖 Godot 的 native 验证程序
│   └── thirdparty/              # git submodule（入库为 gitlink，见 §8 补丁说明）
│       ├── leanclr/src/runtime/ # leanclr mono 分支运行时
│       └── godot-cpp/           # godot-cpp 4.5
├── demo_csharp/                 # C# 测试程序集源码与编译产物
├── godot_project/               # Godot 工程
│   ├── bin/
│   │   ├── leanclr_godot.gdextension
│   │   ├── leanclr_godot.dll    # 构建产物（部署）
│   │   ├── bcl/                 # 完整 mono-4.5 BCL（不入库）
│   │   └── assemblies/          # LeanClrGame.dll 等业务程序集（不入库）
│   ├── demo.gd
│   └── demo.tscn
├── scripts/
│   ├── hotreload.ps1            # 一键热更回归（编译 + CLI/MCP 验证 + 断言）
│   └── mcp_run_scene.mjs        # 通过 godot-mcp stdio 运行场景并收集输出
├── build/                       # CMake/MSBuild 产物与运行日志（gitignore）
├── .refs/                       # 上游参考仓库（gitignore）
└── .tools/godot45/              # 本机 Godot 4.5（gitignore）
```

## 3. 强制流程（每次改动必须全部执行）

0. **依赖就位**：首次 clone 或切换 submodule 后执行 `scripts/ensure_deps.ps1`（`submodule update` + 应用 `patches/*.patch`），BCL 缺失时执行 `scripts/bootstrap_bcl.ps1`。构建脚本会自动调用，但改动 leanclr 相关代码后必须确认 `git -C native/thirdparty/leanclr status --short` 与 `patches/leanclr-runtime-hotreload.patch` 一致（补丁是唯一入库形式）。
1. **改代码**：仅改 `native/src`、`demo_csharp`、`godot_project` 下的文件。
2. **改 C# 时编译**：按 `docs/03-csharp-test-assembly.md` 在 `demo_csharp` 目录内用系统自带 csc 编译。
3. **构建 native**：
   - 只改 `native/src`：用 **MSBuild 增量**（几秒），见 `docs/02-build.md`。
   - 改了 `CMakeLists.txt` 或 leanclr/godot-cpp 源码：用 **CMake 全量**（数分钟）。
   - 新增 `.cpp` 必须显式加入 `CMakeLists.txt` 的 `add_library(leanclr_godot ...)`。
4. **部署 DLL**：先复制 C# DLL；native DLL 若覆盖失败，先删除旧文件再复制。
5. **运行 Godot headless 回归**：日志写入 `out/logs/godot_<feature>.log`，见 `docs/04-run-and-regression.md`。C# 热更改动可直接运行 `scripts/hotreload.ps1`（编译 + CLI/MCP 双通道 + 断言，见 `docs/04` §9）。
6. **回归对比**：逐项确认上一轮日志中的旧输出行仍然存在，再确认新功能输出正确。
7. **提交 git**：每完成一个功能点或文档变更提交一次，便于溯源；提交前用 `git status --short` 确认没有第三方依赖/构建产物。
8. **更新记忆**：将本轮结论、坑与验证结果写入项目记忆。

任何一步失败都不得声称完成；必须报告失败命令、错误原文与下一步。

### 提交规范

- `feat: ...`：新增能力，message 中写明关键验证输出或日志路径。
- `fix: ...`：修复问题，写明根因。
- `docs: ...`：文档变更。
- `chore: ...`：工程/构建/依赖调整。
- 一个功能点一个提交，不要混入无关改动；提交前执行 `git status --short` 检查。

## 4. 常用命令

先探测并设置工具变量（路径来自环境变量，不含个人绝对路径）：

```bat
for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
set "VS_MSBUILD=%VSPATH%\MSBuild\Current\Bin\MSBuild.exe"
set "VS_CMAKE=%VSPATH%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
```

MSBuild 增量构建：

```bat
"%VS_MSBUILD%" out/build/windows/debug/leanclr_godot.vcxproj -p:Configuration=Release -p:Platform=x64 -p:BuildProjectReferences=false -m -v:minimal
```

CMake 全量构建：

```bat
"%VS_CMAKE%" --build out\build\windows\debug --config Release --target leanclr_godot --parallel
```

依赖与补丁（幂等，可反复执行）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_submodules.ps1   # submodule HEAD 必须等于入库 gitlink
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ensure_deps.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\bootstrap_bcl.ps1
```

Linux（WSL/CI 同一份脚本）：

```bash
bash scripts/build_native_linux.sh
```

编译 C#（工作目录必须是 `demo_csharp`）：

```bat
"%CSC%" -nologo -target:library -out:LeanClrGame.dll LeanClrGame.cs
```

运行 Godot 回归：

```bat
"./.tools/godot45/Godot_v4.5-stable_win64_console.exe" --headless --path godot_project --quit-after 120 > out/logs/godot_<feature>.log 2>&1
```

## 5. 完成定义（DoD）

- C# 程序集与 native DLL 均已部署到 `godot_project/bin`。
- Godot headless 运行退出码为 0，日志中无 `SCRIPT ERROR`、无 `LeanCLR ... failed`。
- 上一轮回归基线（`out/logs/godot_bridge.log`、`out/logs/godot_nodeapi.log`、`out/logs/godot_stringsignal2.log`、`out/logs/godot_scene.log`、`out/logs/godot_resource.log`、`out/logs/godot_signalargs.log`、`out/logs/godot_fieldtypes.log`、`out/logs/godot_classpath.log`、`out/logs/godot_pck.log`、`out/logs/godot_reffield.log`、`out/logs/godot_retref.log`、`out/logs/godot_refargs.log`）中的旧输出行全部保留。
- 新功能有明确日志证据（具体到方法名/数值），不是“应该可以”。
- 已记录本轮改动涉及的注册名、接口签名或生命周期约定。

## 6. 文档索引

| 文档 | 内容 |
|---|---|
| `docs/01-environment.md` | 工具链、路径、沙箱网络与执行约束 |
| `docs/02-build.md` | CMake 全量 vs MSBuild 增量的选择与排障 |
| `docs/03-csharp-test-assembly.md` | C# 测试程序集编译、部署与 P/Invoke 声明 |
| `docs/04-run-and-regression.md` | Godot 运行前置、日志命名与回归判定 |
| `docs/05-add-godot-api-bridge.md` | 新增 C# → Godot P/Invoke 接口的标准步骤 |
| `docs/06-add-node-lifecycle-and-fields.md` | 新增节点生命周期、字段、信号接口 |
| `docs/07-troubleshooting.md` | 已知故障与对应处理 |
| `docs/08-limits-and-roadmap.md` | 能力矩阵、已知限制与后续路线 |
| `docs/09-code-package-hot-update.md` | 代码包热更：打包、缓存/哈希 manifest、Android 与 ABI 验证 |
| `docs/10-code-package-switch.md` | 多代码包切换 demo（A/B/基线） |
| `docs/11-ci.md` | CI 平台矩阵、本地预演、缓存与已知限制 |

## 7. 禁止事项

- 不要再尝试实现完整 `ScriptLanguageExtension`（原因见 `docs/08-limits-and-roadmap.md`）。
- 不要用 `curl` / `winget` 下载依赖（沙箱会拦截）；依赖获取走 `git` 或本机安装包。
- 不要用管道（`| tail`）观察长构建，管道缓冲会掩盖输出并造成“卡死”假象。
- 不要在后台执行长构建（后台会被限流而停滞）。
- 不要直接覆盖被 Godot 进程占用或正在写入的 DLL。
- 不要把测试程序集直接编译输出到 `godot_project/bin/assemblies`，必须先输出到 `demo_csharp` 再复制。

## 8. 第三方源码本地补丁授权与清单

用户于 **2026-11-09** 明确授权修改 `native/thirdparty/leanclr`，用于实现 C# 热更。原 §1「不修改第三方源码」的约束仅对该范围放开。

授权范围：仅限运行时生命周期清理与模块卸载所需的 `shutdown/reset` 钩子，以及为支持重载而必须的静态状态重置。

约定：补丁以「新增函数 + 在 `Runtime::shutdown()` 中调用」为主，尽量不改上游已有函数语义；本清单用于与上游 diff 区分。上游同步后需逐项复核。

本地补丁清单（阶段 B）：

| 文件 | 本地新增 |
| --- | --- |
| `runtime/alloc/metadata_allocation.h` | `destroy()` |
| `runtime/metadata/module_def.h/.cpp` | `clear_modules()`；`g_next_image_id` 可重置 |
| `runtime/metadata/metadata_cache.h/.cpp` | `reset()` |
| `runtime/gc/gc_roots.h/.cpp` | `clear()` |
| `runtime/gc/mark_sweep/small_heap_arena.h` | `~SizeClassPool()` |
| `runtime/gc/mark_sweep/mark_sweep_heap.h/.cpp` | `shutdown()` |
| `runtime/gc/gc_finalizer.h/.cpp` | `reset()` |
| `runtime/vm/gc.h/.cpp` | `GC::shutdown()` |
| `runtime/vm/gchandle.h/.cpp` | `reset()` |
| `runtime/vm/appdomain.h/.cpp` | `shutdown()` |
| `runtime/vm/rt_thread.h/.cpp` | `shutdown()` |
| `runtime/vm/rt_string.h/.cpp` | `shutdown()` |
| `runtime/vm/rt_exception.h/.cpp` | `shutdown()` |
| `runtime/vm/environment.cpp` | `shutdown()` 补全静态重置 |
| `runtime/vm/pinvoke.h/.cpp` | `shutdown()` |
| `runtime/vm/internal_calls.h/.cpp` | `shutdown()` |
| `runtime/vm/intrinsics.h/.cpp` | `shutdown()` |
| `runtime/vm/reflection.h/.cpp` | `shutdown()`（含 `s_class_reflection_type_map`；遗漏该项会导致 reload 后取到上一代 `RtReflectionType*`） |
| `runtime/vm/class.h/.cpp` | `shutdown()` |
| `runtime/vm/array_class.h/.cpp` | `shutdown()` |
| `runtime/vm/monitor.h/.cpp` | `shutdown()` |
| `runtime/vm/generic_method.h/.cpp` | `shutdown()` |
| `runtime/interp/machine_state.h/.cpp` | 复用已有 `reset()`（未新增函数） |
| `runtime/vm/runtime.cpp` | `Runtime::shutdown()` 实现（调用上述钩子） |
| `runtime/vm/settings.h/.cpp` | `shutdown()`：释放并清空 domain/config/data/temp/config 与命令行参数，使同一进程内可再次 `Runtime::initialize()` |

说明：`runtime/vm/delegate.h/.cpp` 无静态注册表，未改动；`runtime/vm/environment.h/.cpp` 复用并补全 `Environment::reset()`。`Runtime::initialize()`、`Class::initialize*()` 中仅保留上游逻辑，未保留任何本地调试输出。

本地补丁清单（阶段 C，单程序集热更）：

| 文件 | 本地新增 |
| --- | --- |
| `runtime/metadata/module_def.h/.cpp` | `references_assembly(name_no_ext)`：遍历 AssemblyRef 判断其他模块是否引用目标程序集 |
| `runtime/vm/assembly.h/.cpp` | `Assembly::unload_module(name_no_ext)`：两轮 GC + 静态区/缓存清理 + 注销并释放模块（`RtModuleDef`/`RtAssembly`/`PdbImage`/`MemPool`/DLL/PDB 数据）；`Assembly::unload_module_unchecked(name_no_ext)`：与前者共用主体、跳过跨模块引用检查，仅供依赖组整组卸载（调用方保证组外无引用） |
| `runtime/vm/class.h/.cpp` | `remove_static_data_for_module(module)`：按 image 过滤 `s_all_classes_with_static_data` 并释放静态区；`clear_caches_for_module_unload()`：清 ptr/generic/fnptr 懒重建缓存 |
| `runtime/vm/array_class.h/.cpp` | `remove_module_classes(module)`：只移除元素类属于目标模块的数组类并清 `g_arrayGenericMethodCache`（不可整体 `shutdown()`，否则破坏 corlib 数组模板） |
| `runtime/metadata/pdb_image.h` | `get_raw_image_data()`：暴露 PDB 原始数据指针，供卸载时释放 |

阶段 C 的 `unload_module` 调用顺序为：第一轮 GC → 释放模块静态区 → 清懒重建缓存 → 第二轮 GC → 注销并删除模块；顺序变更会引入悬空 `RtClass*` 或重复释放。

**入库形式**：以上全部修改（含阶段 C 与 arm32 参数偏移修复）已固化为 `patches/leanclr-runtime-hotreload.patch`，由 `scripts/apply_patches.ps1` / `.sh` 幂等应用。只改 submodule 工作区而不更新补丁，改动就无法复现；提交前务必重新生成补丁（步骤见 `docs/11-ci.md` §5）。