# LeanCLR for Godot

[LeanCLR](https://github.com/focus-creative-games/leanclr) 的 Godot 4.5 集成示例与回归工程：用 GDExtension 承载 leanclr（mono-4.5）解释器，在 Godot 中直接加载并调用 .NET Framework 程序集，支持 C# 模块级热更、信号转发、字段/参数/返回值编组与 P/Invoke 回桥。

本仓库以「可运行 + 可回归」为目标：所有能力都有对应的 GDScript 测试场景、日志断言和一键回归脚本。

## 特性

- **运行时嵌入**：加载完整 mono-4.5 BCL 与业务程序集，调用静态方法、实例方法与构造函数。
- **对象句柄**：托管对象由 `GCHandle` 持有，GDScript 通过 `int64` 句柄读写字段、传参、接收返回值。
- **字段 / 参数 / 返回值**：简单类型、枚举、struct（`PackedByteArray`）、引用类型（对象/数组，支持句柄与 `null` 双向传递）。
- **`LeanCLRNode` 宿主**：管理托管对象生命周期，转发 `OnEnterTree` / `OnReady` / `OnProcess` / `OnPhysicsProcess` / `OnExitTree`，并提供 `call_managed`、属性读写与信号绑定。
- **信号**：任意参数个数；引用参数支持句柄、`null` 与 Godot 实例；Godot 实例 ↔ 托管对象双向映射。
- **P/Invoke 回桥**：C# 直接调用注册过的 Godot 原生 API（节点、场景、资源等）。
- **热更**：阶段 B `reload_runtime()` 整体重启；阶段 C `reload_assembly()` 单程序集热更，支持依赖图整组重载、方法签名兼容校验、静态字段白名单迁移与失败回滚。
- **导出**：Windows / Linux PCK 导出回归，`bin/bcl` 与 `bin/assemblies` 通过 Godot VFS 加载。

## 环境要求

| 依赖 | 要求 |
|---|---|
| 操作系统 | Windows x64（开发与回归）；Linux x86_64 已验证导出产物运行 |
| Godot | 4.5 stable（本仓库放在 `.tools/godot45/Godot_v4.5-stable_win64_console.exe`） |
| 原生工具链 | Visual Studio Build Tools（MSVC x64）、CMake 3.20+ |
| .NET | .NET SDK（`dotnet build`），用于编译 `demo_csharp` 下的程序集 |
| Node.js | 仅 MCP 通道需要：本地 godot-mcp（`.tools/godot-mcp/build/index.js`） |
| 原生依赖 | `native/thirdparty` 下的 leanclr（mono 分支）与 godot-cpp 4.5，由 git submodule 固定；本地补丁在 `patches/`，构建前由脚本应用 |

## 目录结构

```text
leanclr_gotdot/
├─ .github/workflows/      GitHub Actions（Windows/Linux/macOS 回归、iOS 静态库、Android 构建导出）
├─ .gitmodules             thirdparty 依赖固定到具体 commit
├─ patches/                leanclr 热更补丁（构建前必须应用）
├─ native/                 GDExtension 源码（src）与 submodule 依赖（thirdparty）
├─ demo_csharp/            C# 测试程序集、可玩 demo（GameDemo*）与各热更/依赖/签名变体项目
├─ godot_project/          Godot 工程（bin/ 只放部署后的 .dll/.so 与 bcl/assemblies）
├─ scripts/                构建、部署、回归与代码包脚本
├─ docs/                   01–11 使用与实现文档
├─ out/                    所有编译产物、日志、导出与 APK（gitignore）
└─ .tools/                 Godot 4.5 与 godot-mcp（gitignore）
```

`out/` 与源码完全分离，构建脚本只写这里；`scripts/deploy_native.ps1` 再把产物复制到 `godot_project/bin`（`.gdextension` 里的 `res://bin/...` 指向部署结果）。布局：

```text
out/
├─ build/{windows,linux}/...           # CMake 中间物
├─ build/android/<abi>/{debug,release}
├─ bin/{windows,linux,android/<abi>}/  # 原生库编译产物（部署源）
├─ logs/                               # 构建与回归日志
├─ export/{dbg,rel,linux}/             # PCK 导出
├─ android/                            # APK
├─ packages/                           # 代码包 HTTP 源
└─ tmp/                                # 临时素材（如代码包变体）
```

## 快速开始

### 0. 获取依赖（首次 clone）

```bash
git clone --recurse-submodules <repo-url>
# 已 clone 但没带 submodule：
git submodule update --init --recursive
```

submodule 只固定 leanclr / godot-cpp 的上游 commit；本仓库需要的热更钩子保存在 `patches/leanclr-runtime-hotreload.patch`，必须应用（构建脚本也会自动调用）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ensure_deps.ps1   # submodule + 补丁
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\bootstrap_bcl.ps1  # 154 个 BCL dll
```

`ensure_deps.ps1` 幂等：已应用会跳过，上游升级导致冲突会直接报错，不会静默继续。它还会调用 `scripts/verify_submodules.ps1`，确认 submodule 工作区 HEAD 仍等于入库 gitlink（`.gitmodules` 不含 `branch`，`git submodule update` 不会跟随上游漂移）；有意升级的流程见 `docs/11-ci.md` §5。

依赖模型、fork 与 patches 的取舍见 `docs/01-environment.md` §3。

**机器相关路径不写死在仓库里**，脚本按下面顺序解析，找不到时给出明确错误：

| 变量 | 作用 | 默认回退 |
|---|---|---|
| `GODOT_BIN` | Godot 4.5 控制台版可执行文件（等同 `-GodotExe` 参数） | `.tools/godot45/Godot_v4.5-stable_win64_console.exe` |
| `ANDROID_HOME` / `ANDROID_SDK_ROOT` | Android SDK（adb、cmake/ninja、NDK 都从这里找） | `%LOCALAPPDATA%\Android\Sdk` |
| `ANDROID_DEBUG_KEYSTORE` | Android debug 签名 keystore | `~/.android/debug.keystore` |
| `LEANCLR_OUT` | 构建/日志/导出根目录 | 仓库内 `out/` |

### 1. 构建原生扩展

首次或修改 `CMakeLists.txt` / `leanclr` / `godot-cpp` 时用 CMake 全量构建；只改 `native/src` 时可直接跑脚本增量构建。

```bat
:: 日常构建（自动探测 VS，编译到 out/，再部署到 godot_project/bin）
scripts\build_native.bat

:: 导出 release 包时使用 template_release 扩展
scripts\build_native_release.bat
```

编译产物为 `out/bin/windows/leanclr_godot.dll`（release 为 `leanclr_godot.release.dll`），部署后对应 `godot_project/bin/` 下的同名文件。只做部署可执行 `scripts\deploy_native.ps1 -Platform windows -Configuration Both`。完整说明见 `docs/02-build.md`。

### 2. 构建托管程序集

```bat
dotnet build demo_csharp\LeanClrGame.csproj -c Release
```

csproj 已把输出目录设为 `godot_project/bin/assemblies`，无需手工复制。热更回归用到的 `LeanClrGameHot`、`LeanClrExt`、`LeanClrExt2`、`LeanClrCycleA/B`、`LeanClrGameSig` 由一键脚本按需构建，见「测试与回归」。

### 3. 运行 demo

干净工程首次运行前，先让编辑器导入一次 GDExtension 登记文件：

```bat
"./.tools/godot45/Godot_v4.5-stable_win64_console.exe" --headless --editor --path godot_project --quit-after 60
```

确认 `godot_project/.godot/extension_list.cfg` 含 `res://bin/leanclr_godot.gdextension` 后，运行主场景 `godot_project/demo.tscn`：

```bat
"./.tools/godot45/Godot_v4.5-stable_win64_console.exe" --headless --path godot_project --quit-after 120 --log-file out/logs/godot_demo.log
```

预期日志包含 `resolve assembly via Godot VFS: res://bin/bcl/mscorlib.dll`、`PlayerController::Add(2, 3) = 5`、`item handle = 2`、`call_managed(Add) = 9` 等；完整基线见 `docs/04-run-and-regression.md` §3。

### 4. 可玩热更 demo（改 C# 立即生效）

一个闭环小游戏：方向键移动，吃橙色目标得分，倒计时结束即失败，按 R 重开。移动、计时、吃目标判定、目标刷新与失败逻辑都在 C#；Godot 侧只挂节点、读输入、显示 HUD 并触发热更。

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\game_demo.ps1
```

脚本编译 `demo_csharp/LeanClrGameDemo.csproj` 后启动 `godot_project/game_demo.tscn`，并持续监视 `demo_csharp/GameDemo*.cs`：保存文件后自动重建并复制到 `godot_project/bin/assemblies`，游戏内轮询 DLL 变化并调用 `runtime.reload_assembly("LeanClrGameDemo")`，无需重启游戏。

演示步骤：

1. 启动上面的命令，用方向键吃几个目标，记下得分与手感。
2. 打开 [GameDemoTuning.cs](demo_csharp/GameDemoTuning.cs)，把 `MoveSpeed` 从 `180f` 改成 `320f`、`PointsPerTarget` 从 `10` 改成 `25`、`RoundSeconds` 从 `30f` 改成 `20f`，保存。
3. 观察日志与 HUD：`[hotreload] assembly reloaded: LeanClrGameDemo, generation=1, mode=assembly`、`[hotreload] node rebound: type=GameDemo, generation=1, signals=0`、`[demo] reload source=file-watch returned=true mode=assembly generation=0->1`；HUD 的「速度 / 版本 / generation」立即变化，得分与剩余时间保持热更前的进度。
4. 也可按 `F5` 手动热更，按 `R` 重开一局。

触发热更的方式：默认是**文件监视**（脚本重建 + 游戏内 DLL 修改时间轮询）；`F5` 是手动按键热更。两者走同一个 `reload_assembly` / generation 机制，没有额外的热更通道。

改哪里：

| 位置 | 作用 |
|---|---|
| `demo_csharp/GameDemoTuning.cs` | 速度、每次得分、单局时长、命中半径（推荐改这里） |
| `demo_csharp/GameDemo.cs` | 移动、计时、计分、失败与目标刷新等玩法逻辑 |
| `godot_project/game_demo.gd` | 仅输入、HUD 与热更触发，不含玩法 |

demo 的热更限制：改常量与方法体可立即生效；静态进度只在 `hotreload.statics.json` 白名单内的字段会保留（新增静态字段默认丢失进度，需要先加白名单）。改变已有方法签名/返回值会被签名校验拦截（`mode=signature-mismatch`，按 `hot_reload/on_unsafe` 处理）；新增类型或依赖关系变化建议重启游戏。完整说明见 `docs/04-run-and-regression.md` §11。

## 核心能力与用法

### 初始化与对象句柄

```gdscript
var runtime := LeanCLRRuntime.new()
var bcl_dir := ProjectSettings.globalize_path("res://bin/bcl")
var assembly_dir := ProjectSettings.globalize_path("res://bin/assemblies")
if not runtime.initialize(PackedStringArray([bcl_dir, assembly_dir])):
    push_error(runtime.get_last_error())
if not runtime.load_assembly("LeanClrGame"):
    push_error(runtime.get_last_error())

var handle := runtime.create_object("PlayerController")   # int64 句柄
print(runtime.invoke_method(handle, "Add", [2, 3]))       # 5
print(runtime.get_field(handle, "score"))
runtime.destroy_object(handle)
```

- `create_object` 失败返回 `0`，原因见 `get_last_error()`。
- 返回引用类型的方法/字段会复用已有对象句柄；`null` 返回 `null`。
- 热更后旧句柄报 `stale type identity: handle N belongs to unloaded assembly ...`，需重新创建对象。

### 字段、参数与返回值

- `get_field(handle, name)` / `set_field(handle, name, value)` 支持简单类型、枚举、struct（`PackedByteArray`）与引用类型。
- 引用类型字段可写入对象句柄或 `null`；数组以句柄形式传递。
- 方法参数支持 `int64`、`double`、`bool`、`string`、对象句柄、`null`，以及 Godot 实例（见「信号与实例映射」）。

### `LeanCLRNode` 宿主

```gdscript
var player := LeanCLRNode.new()
player.managed_type = "PlayerController"
player.managed_assembly = "LeanClrGame"
player.runtime = runtime
add_child(player)

player.call_managed("Add", [4, 5])
player.get_managed_property("score")
player.set_managed_property("score", 99)
```

节点入树后按约定回调托管方法（存在才调用）：`OnEnterTree` / `OnReady` / `OnProcess(delta)` / `OnPhysicsProcess(delta)` / `OnExitTree`，并自动注入 `SetOwnerId(long)`。

### 信号与实例映射

```gdscript
player.bind_signal("leanclr_signal", "OnSignal")
player.bind_signal_args("leanclr_signal_args2", "OnSignalArgs2", 2)  # 第三个参数仅记录，实际参数个数不限
player.emit_leanclr_signal_args2("hi", 9)

player.bind_signal("leanclr_signal_object", "OnSignalObject")        # C#: OnSignalObject(PlayerController target, string text)
player.emit_leanclr_signal_object(player, "sig-object")
```

- 内置发射器：`emit_leanclr_signal()`、`emit_leanclr_signal_args(text)`、`emit_leanclr_signal_args2(text, value)`、`emit_leanclr_signal_mixed(handle, text, value)`、`emit_leanclr_signal_object(instance, text)`。
- 引用参数可传句柄、`null` 或 Godot 实例；参数个数不限。
- **实例 → 托管对象**：`LeanCLRNode` 自动映射到其当前托管对象（热更重绑后自动指向新对象）；其他实例需 `runtime.bind_godot_object(instance, handle)`；未绑定实例明确报 `no managed object mapped for Godot instance '<Class>#<id>'`，不会隐式创建。
- **托管对象 → 实例**：方法返回值/字段命中已绑定映射且实例有效时返回 `Variant(Object)`，其余仍返回 `int64` 句柄。
- 映射为 1:1 强引用（映射存在期间托管对象不会被 GC）；可用 `runtime.unbind_godot_object(instance)` 解绑，`runtime.get_object_mapping_count()` 查看有效映射数（读取前会清扫已释放实例）。
- 传入已释放或 `null` 的实例按托管 `null` 处理；映射对象的类型必须可赋值给 C# 方法参数类型，否则报 `managed type mismatch`。

### P/Invoke 回桥

C# 侧声明并在 native 侧注册完整签名，即可在托管代码中调用 Godot API：

```csharp
[DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern void node_set_position(long instance_id, double x, double y);
```

注册名格式 `[<AssemblyName>]<Namespace>.<Class>::<Method>(<ParamType>,...)`，例如 `[LeanClrGame]GodotNative::node_set_position(System.Int64,System.Double,System.Double)`。新增接口流程见 `docs/05-add-godot-api-bridge.md`。

### C# 热更（阶段 B / C）

```gdscript
# 阶段 B：整体重启运行时（清空句柄与映射，重载程序集）
runtime.reload_runtime()

# 阶段 C：单程序集热更
runtime.reload_assembly("LeanClrGame")              # 仅自身，被引用时按 on_unsafe 策略
runtime.reload_assembly("LeanClrGame", true)        # 连同依赖方整组重载
runtime.get_last_reload_mode()                      # assembly / assembly+dependents / fallback / rejected / aborted / failed / signature-mismatch
runtime.get_generation()                            # 每次成功热更 +1
```

- 整组热更按原加载顺序**逆序卸载、正序重载**；组内文件缺失时 `mode=aborted` 且不改变任何状态。
- 重载后、执行托管代码前比对新旧方法签名：参数类型/数量/返回值变化或方法删除 → `mode=signature-mismatch` 并给出 `changed signature` / `removed method`；仅新增方法放行。
- 静态字段按 `godot_project/hotreload.statics.json` 白名单迁移，未列出的恢复为新版本初始值。
- 被其他程序集引用且未整组热更时，按 `leanclr/hot_reload/on_unsafe`（`unsafe` / `fallback` / `reject`）处理。
- `LeanCLRNode` 在 generation 变化后自动重建托管对象并恢复信号绑定。

### 代码包热更新（下载新程序集）

```gdscript
# 下载新包到 user://code_pkg/assemblies -> 校验 -> 安装 -> reload_runtime -> 执行新代码
var updater = preload("res://code_pkg_updater.gd").new()
add_child(updater)
updater.setup(runtime, "LeanClrCodePkg", "CodePkgNode")
var result = await updater.download_and_apply("http://127.0.0.1:18080/good")
print(result["ok"], result["version"], result["generation_after"])
```

- 初始化目录顺序固定为 `[bin/bcl, user://code_pkg/assemblies, bin/assemblies]`：覆盖包优先，删除后自动回退到内置版本；Android 上 `user://` 是唯一可写区。
- 包格式为 `manifest.json` + 内容哈希 DLL（`LeanClrCodePkg.<sha256前16位>.dll`）+ 文件 SHA-256；校验失败不安装、不 reload，reload 或类型探测失败会自动恢复上一份包并再次 reload。
- manifest 请求支持可选 query 破除 CDN 缓存：`updater.manifest_query = "v={version}"`（`{version}` 取已安装版本，另有 `{timestamp}` 毫秒时间戳），或 `updater.manifest_query_timestamp = true` 自动拼 `?v=<毫秒>`；默认空字符串即保持无 query 的旧行为。实际请求 URL 会打印为 `[codepkg] GET <url>`。
- DLL 采用内容哈希命名，DLL 内容一变文件名就变，可长期缓存；安装时在 staging 内改回固定名 `LeanClrCodePkg.dll`，保证 `code_pkg/assemblies` 只有一份生效程序集且旧哈希文件不残留。
- 桌面验证 `scripts\code_pkg_test.ps1`（CLI/MCP 各 70 项断言）；Android 实测 `scripts\code_pkg_android_test.ps1`（71 项 logcat 断言），支持 `-Abi x86_64|arm64-v8a|armeabi-v7a`。
- ABI 覆盖矩阵（MuMu 12 x86_64 + houdini 转译层，均 71/71 通过）：

  | ABI | APK 内 `lib/<abi>/` | 转译层 | 关键业务输出 | 证据 |
  |---|---|---|---|---|
  | `x86_64` | `libc++_shared.so`、`libgodot_android.so`、`libleanclr_godot.so` | 不涉及 | `pkg v2 compute 10 = 20`、`pkg v3 compute 10 = 30` | `out/logs/android_abi_x86_64.txt` |
  | `armeabi-v7a` | 同上（`lib/armeabi-v7a/`） | 是（`libhoudini.so`、`RunningArchitecture=armeabi-v7a`） | 同左 | `out/logs/android_abi_armeabi-v7a.txt` |
  | `arm64-v8a` | 同上（`lib/arm64-v8a/`） | 是（`lib64/libhoudini.so`、`RunningArchitecture=arm64-v8a`） | 同左 | `out/logs/android_abi_arm64-v8a.txt` |

  复现：`scripts\build_android_native.ps1 -Abi <abi>` 后执行 `scripts\code_pkg_android_test.ps1 -Abi <abi> -SkipBuild`；证据文件会记录导出 ABI、APK 内 `.so` 清单、设备 abi/abilist/nativebridge、安装结果、转译层日志与业务输出行。
- 从环境检查、构建、导出、MuMu 安装到日志断言的完整分步命令见 `docs/09-code-package-hot-update.md`（Android 打包与验证分步指南）。

### PCK 导出

```bat
:: 一键重建 + 导出 debug/release + 运行导出产物 + 断言（约 35–70s）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\pck_export.ps1 -IncludeLinux
```

手工导出命令：

```bat
:: debug（使用 template_debug 扩展）
"./.tools/godot45/Godot_v4.5-stable_win64_console.exe" --headless --path godot_project --export-debug "Windows Desktop" "out/export/dbg/leanclr_godot.exe"

:: release（先执行 scripts\build_native_release.bat）
"./.tools/godot45/Godot_v4.5-stable_win64_console.exe" --headless --path godot_project --export-release "Windows Desktop" "out/export/rel/leanclr_godot.exe"
```

PCK 包含 `bin/bcl/*.dll`、`bin/assemblies/*.dll` 与项目资源；`hotreload_tmp`、`recovery_tmp`、`game_demo_tmp` 与扩展 DLL 不进 PCK，扩展库由导出器复制到 exe 同级。判定标准、常见失败与 WSL Linux 命令见 `docs/04-run-and-regression.md` §6。

## 测试与回归

### 一键热更回归（推荐）

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\hotreload.ps1
```

| 参数 | 作用 |
|---|---|
| `-Channel both` | 默认；CLI 与 MCP 各跑一轮 |
| `-Channel cli` | 只跑 CLI（未安装 godot-mcp 时使用） |
| `-Channel mcp` | 只跑 MCP |
| `-SkipBuild` | 跳过编译，只重跑回归（调试断言时用） |

脚本依次完成：编译测试程序集（v1 基线 / 热更版 / 跨模块 / 依赖链 / 循环引用 / 5 个签名变体）→ CLI 回归 → MCP 回归 → 56 项日志断言判定。

输出示例：

```text
  CLI: PASS (56/56 断言)
  日志: ...\out\logs\godot_hotreload_c.log
  MCP: PASS (56/56 断言)
  日志: ...\out\logs\godot_hotreload_c_mcp.log
PASS  用时 10.2s
```

判定规则：每个通道 56 项断言全部命中，且日志不含 `SCRIPT ERROR`、`LeanCLR ... failed`、行首 `ERROR:`，才输出 `PASS` 并以退出码 0 结束；否则输出 `FAIL`、列出缺失断言并以退出码 1 结束。

### 可玩 demo 热更验证

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\game_demo_test.ps1            :: CLI + MCP
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\game_demo_test.ps1 -Channel cli
```

脚本编译 v1/v2 两版 `LeanClrGameDemo`（v2 放在 `godot_project/game_demo_tmp/hot`），运行 `game_demo_test.tscn` 做确定性驱动：断言 v1 速度 180 / 每次 10 分 / 30s / 半径 16、位移 = 90、超时失败、重开复位；安装 v2 热更后断言速度 320 / 每次 25 分 / 20s / 半径 22、位移 = 160、计分规则生效、静态分数与命中数保留、旧句柄报 `stale type identity`、`generation +1`、加载集合不变；再用真实 `LeanCLRNode` 断言 `Player`/`Target` 节点解析、热更后自动重绑并继续驱动节点。每个通道 39 项断言，CLI 与 MCP 均需全绿。

### 代码包热更新验证（桌面 + Android）

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\code_pkg_test.ps1 -Channel both
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\code_pkg_android_test.ps1 -Abi x86_64
```

桌面脚本构建 v1/v2/v3 与 `good`（v2）/`good-v3`（v3）/`bad-sha`/`broken-type` 四个包（DLL 均为内容哈希名），CLI 与 MCP 各 70 项断言；Android 脚本按 `-Abi` 导出 APK、`adb install`、`adb reverse` 后运行测试场景，对 logcat 做 71 项断言并把日志写入 `out/logs/android_code_pkg_<abi>.log`（ABI 证据在 `out/logs/android_abi_<abi>.txt`）。断言覆盖：DLL 文件名随内容变化、manifest 带 query 的实际请求 URL、安装后仅保留固定名并清理旧版本、坏 SHA 拒绝且回退到上一版。三种 ABI 的实测矩阵见 `docs/09-code-package-hot-update.md` §1.4。逐步命令、每步预期输出与失败排查见 `docs/09-code-package-hot-update.md`。

### 多代码包切换 demo（A / B）

预打包基线与 A、B 两套 `LeanClrCodePkg`（公开 API 相同、版本/返回值/计分规则不同），界面三个按钮分别切回基线与切到 A/B，复用同一条 manifest + 哈希 DLL + `reload_runtime` 链路：

```bat
:: 窗口模式：启动后点“切到代码包 A / B / 基线”，标题下显示当前版本、generation 与 ComputeScore
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\code_pkg_switch.ps1

:: 自动验证：A -> B -> A -> 重复 A（幂等）-> 坏 SHA -> 回基线，CLI 与 MCP 各 34 项断言
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\code_pkg_switch.ps1 -Test

:: Android：导出切换场景 APK，在 MuMu 上等效触发同一套断言（34 项）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\code_pkg_switch.ps1 -Android -Abi x86_64 -SkipBuild
```

行为差异：基线 `ComputeScore(10)=10`，A 为 30（橙色），B 为 40（青色）；重复切到当前版本直接跳过、不增加 generation；坏 SHA 包被拒绝且版本与 generation 保持不变。包生成、断言清单与改远端下载的改动点见 `docs/10-code-package-switch.md`。

#### CDN 配置建议

代码包发布到 CDN 时按「manifest 刷新、DLL 不变」两套策略：

| 资源 | 建议 `Cache-Control` | 原因 |
|---|---|---|
| `manifest.json` | `no-cache, max-age=0, must-revalidate`（或短 TTL，如 30–60s） | 每次发布都要让客户端看到新版本；必要时客户端用 query 强制绕过 |
| `LeanClrCodePkg.<hash>.dll` | `public, max-age=31536000, immutable` | 文件名由内容哈希决定，同 URL 字节永不变化，可长期缓存 |
| 其他资源 | `no-store` | 本地测试源默认策略，避免误缓存 |

发布流程只需「上传新哈希 DLL + 覆盖 manifest.json」：旧 DLL 不必删除（可保留做灰度回滚），客户端靠 manifest 里的新文件名自然拿到新内容。若 CDN 对 `manifest.json` 有较长的边缘缓存且无法改 TTL，用 `manifest_query = "v={version}"` 或 `manifest_query_timestamp = true` 让 URL 随版本/时间变化；`scripts/code_pkg_server.mjs` 已按上述规则返回缓存头并在日志打印完整请求 URL（含 query），本地即可核对。

### CLI 通道

```bat
"./.tools/godot45/Godot_v4.5-stable_win64_console.exe" --headless --path godot_project --quit-after 200 --log-file out/logs/godot_hotreload_c.log res://hotreload_c_test.tscn
```

测试场景 `godot_project/hotreload_c_test.tscn` 会从 `hotreload_tmp/LeanClrGame.base.dll` 还原基线，再覆盖为热更版本，覆盖静态迁移、句柄失效、依赖图热更、回滚、循环引用、签名校验、任意参数信号与实例映射。

### MCP 通道

```bat
node scripts\mcp_run_scene.mjs --project godot_project --scene res://hotreload_c_test.tscn --log out/logs/godot_hotreload_c_mcp.log --timeout 120
```

MCP 通道通过本地 godot-mcp（`.tools/godot-mcp/build/index.js`）调用 `run_project` 并轮询调试输出，需按 `docs/04-run-and-regression.md` §8 配置环境；未安装时可只用 `-Channel cli`。

### PCK 导出验证

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\pck_export.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\pck_export.ps1 -IncludeLinux  # 追加 WSL Linux
```

脚本重建 debug/release 扩展（`-SkipBuild` 可跳过）与托管程序集，按 `export_presets.cfg` 导出并运行产物，断言：退出码 0、基线 64 行、命中 `resolve assembly via Godot VFS: res://bin/bcl/mscorlib.dll`、无 filesystem 回退与错误行。详细步骤、产物构成与常见失败见 `docs/04-run-and-regression.md` §6。

## 已知限制

- 不能热更 corlib；被其他已注册程序集引用的程序集默认只能 `fallback` 或 `reject`，`include_dependents=true` 可整组热更，组外仍被引用时同样降级。
- 静态字段迁移必须显式列入 `hotreload.statics.json`；只校验字段名与尺寸，类型变化会跳过并保持新版本默认值。
- 热更前已捕获的自定义托管委托（`Action`/`Func`）不会自动迁移；`LeanCLRNode` 的信号绑定会重建。
- 卸载依赖两轮 GC；应用层仍持有未注册的原生指针指向旧模块时属于未定义行为。
- 实例映射只覆盖 `LeanCLRNode` 与显式绑定对象，且为强引用；不再需要时应解绑或释放 Godot 实例。
- 单线程模型：不能在 C# 侧跨线程回调 Godot。
- 纯解释执行，无 AOT；macOS 已纳入 CI（构建 + headless 回归），iOS 只构建静态库，两者都未做真机验证。Android 代码包热更新在 MuMu 12（x86_64）上以 x86_64 / armeabi-v7a / arm64-v8a 三种包验证通过，其中 arm 包走 MuMu 的 houdini 转译层；真实 arm 设备尚未验证。
- 代码包热更新按「整包替换 + `reload_runtime()`」生效：切换瞬间会重建 VM，旧句柄全部失效；不支持增量补丁、签名校验与断点续传。

## CI（GitHub Actions）

| 工作流 | 平台 | 内容 |
|---|---|---|
| `.github/workflows/ci.yml` | Windows / Ubuntu | submodule 检出 → `ensure_deps` + `bootstrap_bcl` → 构建 GDExtension → `hotreload.ps1 -Channel cli`（56 项）与 `code_pkg_test.ps1 -Channel cli`（70 项） |
| `.github/workflows/macos.yml` | macOS（arm64） | 构建 `.dylib`（`build_native_macos.sh`）→ 检查 `file`/`otool`/入口符号 → 同一组 CLI 回归 |
| `.github/workflows/ios.yml` | macOS（arm64 交叉编译） | 构建 iOS 静态库 `libleanclr_godot.ios.debug.a` → `lipo`/符号检查 → 上传产物；不导出 `.ipa`、不签名 |
| `.github/workflows/android.yml` | Ubuntu | 交叉编译 x86_64 / arm64-v8a / armeabi-v7a，导出 3 个 debug APK 并上传产物 |

- 所有工作流都用 `submodules: recursive` 检出，并复用本机同一套脚本（`ensure_deps.ps1`、`build_native_linux.sh`、`build_native_macos.sh`、`build_native_ios.sh`、`build_android_linux.sh`）。
- **submodule 只固定第三方来源，不能替代补丁**：`patches/leanclr-runtime-hotreload.patch` 必须在构建前应用，脚本已内置，冲突会失败而不是跳过。
- **平台特性宏由 CMake 统一提供**：leanclr 内置 zlib 需要 `HAVE_UNISTD_H=1`（根 `CMakeLists.txt` 的 `if(UNIX)` 分支），否则 Linux/macOS 的 `gz*.c` 缺 `<unistd.h>`，GCC 14+ 会直接编译失败。
- 各平台验到的层级：Windows 构建 + 导出 + 回归；Linux 构建 + 导出已验、headless 回归待 runner 首跑；macOS 构建 + headless 回归（首次运行前视为未验证）；iOS 只到静态库产物；Android 构建 + 导出、无设备测试。
- CI 不跑 MCP 通道（依赖未入库的 godot-mcp），也不做 Android 设备测试；设备侧证据仍以 MuMu 实测为准。
- 本地如何预演、缓存策略、未实跑部分与已知限制见 `docs/11-ci.md`。

## 文档索引

| 文档 | 内容 |
|---|---|
| `docs/01-environment.md` | 环境、工具链、依赖（submodule + 补丁）与目录约定 |
| `docs/02-build.md` | CMake / MSBuild 构建、三平台产物说明 |
| `docs/03-csharp-test-assembly.md` | C# 测试程序集编写、编译与生命周期约定 |
| `docs/04-run-and-regression.md` | 运行、CLI/MCP 回归、PCK 导出与一键流程 |
| `docs/05-add-godot-api-bridge.md` | 新增 C# → Godot P/Invoke 回桥 |
| `docs/06-add-node-lifecycle-and-fields.md` | `LeanCLRNode` 生命周期、字段与信号用法 |
| `docs/07-troubleshooting.md` | 常见问题与排查 |
| `docs/08-limits-and-roadmap.md` | 能力矩阵、验证证据、限制与路线 |
| `docs/09-code-package-hot-update.md` | 代码包热更：打包、缓存/哈希 manifest、Android 与 ABI 验证 |
| `docs/10-code-package-switch.md` | 多代码包切换 demo（A/B/基线） |
| `docs/11-ci.md` | CI 平台矩阵、本地预演步骤、已知限制 |

`AGENTS.md` 记录了本仓库的构建、测试与提交约定，提交前请先阅读。

## 相关仓库与许可

| 仓库 | 说明 |
|---|---|
| [leanclr](https://github.com/focus-creative-games/leanclr) | 运行时与工具链 |
| [leanclr-unity](https://github.com/focus-creative-games/leanclr-unity) | Unity 集成（本 README 的章节组织参考） |
| [hybridclr](https://github.com/focus-creative-games/hybridclr) | Unity 全平台原生 C# 热更新 |

本仓库未附带独立 LICENSE 文件；引入的 leanclr、godot-cpp 等第三方代码遵循其各自许可证（leanclr 为 MIT）。
