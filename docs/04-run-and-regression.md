# 04 Godot 运行与回归测试

## 1. 运行前前置：扩展列表

Godot 运行时只加载 `.godot/extension_list.cfg` 中登记的 GDExtension。干净工程首次运行前必须先用编辑器模式导入一次：

```bat
"./.tools/godot45/Godot_v4.5-stable_win64_console.exe" --headless --editor --path godot_project --quit-after 60
```

该命令可能以 `signal 11` 结束，但只要生成了 `godot_project/.godot/extension_list.cfg` 即可继续。之后普通运行不会再崩溃。

判断扩展是否已登记：

```bat
type godot_project\.godot\extension_list.cfg
```

内容应包含 `res://bin/leanclr_godot.gdextension`。

## 2. 运行命令

```bat
"./.tools/godot45/Godot_v4.5-stable_win64_console.exe" --headless --path godot_project --quit-after 120 > out/logs/godot_<feature>.log 2>&1
```

- 日志必须写入 `out/logs/godot_<feature>.log`，不要只依赖终端输出。
- `<feature>` 使用本轮改动名，例如 `bridge`、`nodeapi`、`lifecycle`。
- 若环境禁止写 `user://`（例如受限沙箱），Godot 会在启动阶段崩溃且无输出；此时追加 `--log-file "<绝对路径>"`，把日志重定向到可写目录。

## 3. 回归基线

当前完整基线为 `out/logs/godot_reffield.log`，包含以下行（数值类允许变化）：

```text
[LeanCLR] resolve assembly via Godot VFS: res://bin/bcl/mscorlib.dll
[LeanCLR][0][info] PlayerController created
PlayerController::Add(2, 3) = 5
PlayerController::Describe() = PlayerController health=100
get score = 7
get score after set = 42
get title = Player
[LeanCLR][0][info] PlayerController created
[LeanCLR][0][info] PlayerController.OnEnterTree
[LeanCLR][0][info] PlayerController.OnReady
C# -> Godot print via P/Invoke
[LeanCLR][0][info] godot ticks=...
[LeanCLR][0][info] node inside_tree=True
[LeanCLR][0][info] target visible=False
[LeanCLR][0][info] target pos=12.5,34.5
[LeanCLR][0][info] target child count=0
[LeanCLR][0][info] target name=Marker
[LeanCLR][0][info] target parent=...
[LeanCLR][0][info] target child0=0
[LeanCLR][0][info] target class=Node2D
[LeanCLR][0][info] owner path=/root/Demo/@LeanCLRNode@...
[LeanCLR][0][info] instantiate scene id=...
[LeanCLR][0][info] scene name=DemoNode
[LeanCLR][0][info] owner child count=1
[LeanCLR][0][info] get_node by path=...
[LeanCLR][0][info] load resource id=...
[LeanCLR][0][info] resource path=res://demo_resource.tres
[LeanCLR][0][info] unload=True
[LeanCLR][0][info] signal arg=hello-args
[LeanCLR][0][info] signal args2=hello-args2,7
enum mode = 1
struct data = [3, 0, 0, 0, 4, 0, 0, 0]
struct data after set = [9, 0, 0, 0, 8, 0, 0, 0]
data x = 9
data y = 8
item handle = 2
item value = 5
item describe = PlayerItem=5
numbers sum = 12
returned item reuses handle = true
returned item value = 5
returned numbers is handle = true
returned null item = true
describe passed item = PlayerItem=5
sum passed numbers = 12
describe passed null = null
item reused handle = true
item value after set = 9
item cleared = true
item value after clear = -1
numbers sum after clear = -1
call_managed(Add) = 9
get_managed_property(score) = 7
get_managed_property(score) after set = 99
[LeanCLR][0][info] PlayerController.OnSignal
[LeanCLR][0][info] emit leanclr_signal from C#
[LeanCLR][0][info] PlayerController.OnSignal
physics ticks = ...
[LeanCLR][0][info] PlayerController.OnExitTree health=102
```

更早的基线：`out/logs/godot_bridge.log`（P/Invoke 回桥首轮）、`out/logs/godot_node.log`（实例对象与 Node 生命周期）、`out/logs/godot_run2.log`（静态方法与字符串返回值）。

## 4. 回归判定

1. **退出码为 0**。
2. 日志中**没有** `SCRIPT ERROR`。
3. 日志中**没有** `LeanCLR ... failed` / `LeanCLRNode create_object failed`。
4. 上一轮基线的每一行（数值可忽略）**仍然存在**。
5. 新功能输出与预期值**逐项一致**。
6. 不得出现 `get_last_error()` 非空导致的静默失败。

任一项不满足即视为回归失败，不得声称完成。

## 5. 常见非致命输出

- `[LeanCLR][1][中文] 你好，世界！` 在 Windows 控制台可能显示为乱码（UTF-8 被按 GBK 解码）。这是终端编码问题，不影响功能；以 Godot 日志中的英文/数字输出作为判定依据。

## 6. 导出（PCK）回归

导出预设为 `godot_project/export_presets.cfg`（`Windows Desktop` 与 `Linux` 两个预设）。一条命令完成重建、导出、运行与判定：

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\pck_export.ps1 [-Target both|debug|release] [-SkipBuild] [-IncludeLinux] [-WslDistro Ubuntu]
```

| 参数 | 作用 |
|---|---|
| `-Target both` | 默认；debug 与 release 都验证 |
| `-Target debug` / `release` | 只验证其中一个 |
| `-SkipBuild` | 跳过重建，只重跑导出与运行 |
| `-IncludeLinux` | 追加 Linux 导出与 WSL 运行 |
| `-ExpectedLines 64` | 基线行数，默认 64 |

脚本输出 12 项 PASS（debug/release 各 4 项，启用 Linux 再 4 项），全部通过才以退出码 0 结束。

### 6.1 导出前准备

1. **扩展 DLL（两个目标必须分开构建）**
   - debug：`scripts\build_native.bat` → `out/build/windows/debug/Release/leanclr_godot.dll` → `godot_project/bin/leanclr_godot.dll`
   - release：`scripts\build_native_release.bat` → `out/build/windows/release/Release/leanclr_godot.dll` → `godot_project/bin/leanclr_godot.release.dll`
2. **托管程序集与 BCL**
   - `dotnet build demo_csharp\LeanClrGame.csproj -c Release` → `godot_project/bin/assemblies/LeanClrGame.dll`
   - `godot_project/bin/bcl/mscorlib.dll` 必须已部署（见 `docs/02`）。
3. **导出模板就位**
   - Windows：`%APPDATA%\Godot\export_templates\4.5.stable\windows_debug_x86_64.exe`、`windows_release_x86_64.exe`
   - Linux：同目录 `linux_debug.x86_64`
   - 缺失时在编辑器「管理导出模板」安装 4.5.stable。
4. **关闭残留 Godot 进程**：`taskkill.exe //F //IM Godot_v4.5-stable_win64_console.exe //T`。

### 6.2 导出命令与产物构成

```bat
:: debug
"./.tools/godot45/Godot_v4.5-stable_win64_console.exe" --headless --path godot_project --export-debug "Windows Desktop" "<REPO_ROOT>/out/export/dbg/leanclr_godot.exe"

:: release（先执行 scripts\build_native_release.bat）
"./.tools/godot45/Godot_v4.5-stable_win64_console.exe" --headless --path godot_project --export-release "Windows Desktop" "<REPO_ROOT>/out/export/rel/leanclr_godot.exe"
```

产物：

| 文件 | 位置 | 说明 |
|---|---|---|
| `leanclr_godot.exe` | 导出目录 | 内嵌 PCK（`embed_pck=true`） |
| `leanclr_godot.console.exe` | 导出目录 | 控制台包装，headless 验证用它 |
| `leanclr_godot.dll` | debug 导出目录 | template_debug 扩展，必须与 exe 同级 |
| `leanclr_godot.release.dll` | release 导出目录 | template_release 扩展，必须与 exe 同级 |

PCK 内容由 `export_presets.cfg` 决定：`export_filter="all_resources"` + `include_filter="bin/bcl/*.dll,bin/assemblies/*.dll"` + `exclude_filter="hotreload_tmp/*,recovery_tmp/*"`。即 **BCL、`bin/assemblies` 下的托管程序集与项目资源进 PCK**；**测试素材目录与扩展 DLL 不进 PCK**。`.gdextension` 文本会进 PCK，但它引用的库文件由导出器复制到 exe 同级。

可在导出控制台日志（脚本保存为 `out/logs/export_console_debug.log` / `out/logs/export_console_release.log`）里用 `savepack` 行核对：

- 必须出现 `savepack: res://bin/bcl/mscorlib.dll`、`savepack: res://bin/assemblies/LeanClrGame.dll`；
- 不得出现 `savepack: ...hotreload_tmp` / `recovery_tmp`；
- 不得出现 `savepack: ...leanclr_godot.dll`。

### 6.3 运行与判定

```bat
cd out/export/dbg
./leanclr_godot.console.exe --headless --quit-after 120 --log-file "<REPO_ROOT>/out/logs/godot_pck_export_dbg.log"
```

release 同理（日志 `out/logs/godot_pck_export_rel.log`）。脚本自动完成并断言：

1. 退出码为 0；
2. 日志行数等于基线 64 行（`-ExpectedLines` 可调）；
3. 命中 `[LeanCLR] resolve assembly via Godot VFS: res://bin/bcl/mscorlib.dll`；
4. 不出现 `resolve assembly via filesystem`（导出后必须走 PCK 虚拟文件系统）；
5. 不出现 `SCRIPT ERROR`、行首 `ERROR:`、`LeanCLR ... failed`。

原理：导出后 `res://` 位于内嵌 PCK，`ProjectSettings.globalize_path("res://bin/bcl")` 只返回相对路径 `bin/bcl`。`file_loader` 先把 lib 目录映射为 `res://bin/bcl` 并用 `FileAccess` 读取，失败才回退 `std::ifstream`；导出环境里回退必然失败，所以出现回退行即代表 PCK 打包有问题。

### 6.4 常见失败现象

| 现象 | 原因 | 处理 |
|---|---|---|
| `Runtime::initialize failed: 26` | 26 = `RtErr::FileNotFound`：`bin/bcl` 不在 PCK 或缺文件 | 检查 `include_filter` 与导出日志的 `savepack` 行；确认 BCL 已部署 |
| `LeanCLRRuntime not declared` / `Class "LeanCLRRuntime" not found` | 扩展 DLL 未复制到 exe 同级，或误把 DLL 打进 PCK（无法从 PCK 内 `dlopen`） | 检查导出目录是否有 `leanclr_godot*.dll`；确认 `savepack` 无该 DLL |
| Linux `dlopen` / `Can't open dynamic library` / `No such file` | `.so` 未复制到可执行文件同级，或目标不匹配（debug 模板配了 release `.so`） | 确认导出目录有 `leanclr_godot.so`；`.gdextension` 的 linux 条目与模板一致 |
| 退出时 heap corruption（`0xC0000374`） | release 导出加载了 `template_debug` 编译的 DLL | 运行 `scripts\build_native_release.bat`，确认 exe 同级是 `leanclr_godot.release.dll` |
| 日志行数不足、出现 `resolve assembly via filesystem` | BCL / LeanClrGame 未打进 PCK | 检查 `export_presets.cfg` 的 include/exclude，重新导出 |
| 导出报 `No export template found` | 4.5.stable 模板未安装 | 编辑器「管理导出模板」安装后重试 |

### 6.5 Linux 导出与 WSL 运行

构建 `.so`（WSL 内，命令见 `docs/02` §7），复制到 `godot_project/bin/leanclr_godot.so` 后：

```bat
"./.tools/godot45/Godot_v4.5-stable_win64_console.exe" --headless --path godot_project --export-debug "Linux" "<REPO_ROOT>/out/export/linux/leanclr_gotdot.x86_64"
```

```bash
cd /mnt/<drive>/<path>/leanclr_gotdot/out/export/linux
chmod +x leanclr_gotdot.x86_64
./leanclr_gotdot.x86_64 --headless --quit-after 120 \
  --log-file /mnt/<drive>/<path>/leanclr_gotdot/out/logs/godot_pck_export_linux.log
```

与 Windows 的差异：可执行文件无 `.exe`、需 `chmod +x`、路径用 `/mnt/<drive>/...`、库文件是 `leanclr_godot.so`、日志路径也需写成 WSL 路径；PCK 打包规则与判定标准完全相同（同样 64 行、同样的 VFS 命中与禁止项）。`scripts\pck_export.ps1 -IncludeLinux` 会自动完成导出与 WSL 运行。

### 6.6 验证记录

- 2026-11-10：`scripts/pck_export.ps1 -IncludeLinux` 实测 12/12 PASS；Windows debug/release 与 Linux 均退出码 0、64 行、命中 Godot VFS，无 filesystem 回退与错误行。日志：`out/logs/godot_pck_export_dbg.log`、`out/logs/godot_pck_export_rel.log`、`out/logs/godot_pck_export_linux.log`。
- 历史问题：此前 release 导出在退出阶段 heap corruption（`0xC0000374`），原因是扩展按 `template_debug` 编译却加载进 release 模板引擎；改为双目标构建后消失。另有 `hotreload_tmp` 被打进 PCK 的问题，已通过 `exclude_filter` 修复（打包条目 335 → 323）。

## 7. 清理

运行结束后若需重新部署 DLL，先确认没有残留 Godot 进程：

```bat
taskkill.exe //F //IM Godot_v4.5-stable_win64_console.exe //T
```

再按 `docs/02-build.md` 部署。

## 8. MCP 验证通道（godot-mcp）

CLI 之外的第二种验证通道：通过 MCP 服务器调用 Godot，验证结果可与 CLI 基线逐行对照。

### 8.1 安装

```bat
git clone --depth 1 https://github.com/Coding-Solo/godot-mcp.git .tools/godot-mcp
cd .tools\godot-mcp
npm install --no-audit --no-fund
```

`.tools/` 已在 `.gitignore` 中，安装物不入库。Node 需 ≥ 18（本机 v22）。

### 8.2 注册

1. 在 Trae 设置 → MCP 中打开「启用项目级 MCP」开关并确认（默认关闭；未开启时 `.trae/mcp.json` 不会被读取，`mcp-servers-main.log` 为空、也不会出现服务进程）。
2. 在**工作区根目录**的 `.trae/mcp.json` 写入配置（本仓库的 `.trae/mcp.json` 不随仓库提交；`<REPO_ROOT>` 换成仓库根目录的绝对路径）：

```json
{
  "mcpServers": {
    "godot": {
      "command": "node",
      "args": ["<REPO_ROOT>/.tools/godot-mcp/build/index.js"],
      "env": {
        "GODOT_PATH": "<REPO_ROOT>/.tools/godot45/Godot_v4.5-stable_win64_console.exe",
        "GODOT_MCP_HEADLESS": "1",
        "GODOT_MCP_NO_DEBUG": "1",
        "GODOT_MCP_LOG_FILE": "<REPO_ROOT>/out/logs/godot_mcp_run.log"
      }
    }
  }
}
```

3. 保存后重载 Trae（Reload Window 或重启）。trae 在需要相关能力时自动加载该配置。
4. 重载后工具列表中应出现 `run_project` / `get_debug_output` / `stop_project` / `get_godot_version` 等；若仍无，检查 MCP 设置里 `godot` 服务是否显示连接失败。

实测记录（2026-11-09）：仅创建 `.trae/mcp.json` 并重载后，工具列表仍未出现 `godot` 服务；`%APPDATA%\Trae CN\logs\<session>\mcp-servers-main.log` 为 0 字节、无 `node .../godot-mcp/build/index.js` 进程，`~/.trae-cn/mcps/` 下也没有当前工作区目录，判定为“项目级 MCP 开关未启用”，配置未被读取。

### 8.3 本仓库对 godot-mcp 的本地补丁

上游实现无条件使用 `-d --path`、且不传 `--headless` / `--log-file`，在本机沙箱下会出现：

- `-d` 开启调试器需要绑定端口 → 沙箱报 `sandbox backend failed`；
- 不传 `--log-file` 时 Godot 写 `user://` 失败 → 同样失败或崩溃；
- 进程自行退出后 `get_debug_output` 因 `activeProcess` 被清空而丢失输出。

因此对 `.tools/godot-mcp`（未跟踪）做了本地补丁：四个可选环境变量控制启动参数，并保留最后一次输出。

| 环境变量 | 作用 |
|---|---|
| `GODOT_MCP_NO_DEBUG=1` | 去掉 `-d`，避免调试器端口 |
| `GODOT_MCP_HEADLESS=1` | 追加 `--headless` |
| `GODOT_MCP_LOG_FILE=<绝对路径>` | 追加 `--log-file`，规避 `user://` 不可写 |
| `GODOT_MCP_QUIT_AFTER=<帧数>` | 追加 `--quit-after`，让进程自行退出（可选） |

另外保留最后一次输出，使进程退出后 `get_debug_output` 仍能返回日志。

### 8.4 实跑验证

调用序列：`run_project({projectPath:"<REPO_ROOT>/godot_project"})` → 等待若干帧 → `get_debug_output()` → `stop_project()`。

实测（2026-11-09，Trae 已启用项目级 MCP，原生 MCP 工具直接调用）：

- `mcp_godot_get_godot_version` → `4.5.stable.official.876b29033`；
- `mcp_godot_run_project({projectPath:"<REPO_ROOT>/godot_project"})` → `Godot project started in debug mode`；
- `mcp_godot_get_debug_output` → 64 行，与 `out/logs/godot_mcp_run.log` 一致；
- `mcp_godot_stop_project` → `Godot project stopped`，返回完整 `finalOutput`；
- 与 CLI 基线 `out/logs/godot_refargs.log` 逐行对照：仅 5 行不同，全部为动态值——`godot ticks`（200 vs 122）、`physics ticks`（5 vs 2）、`target parent` / `instantiate scene id` / `get_node by path` 的实例 id、`load resource id`；业务输出行完全一致。

结论：MCP 通道（原生 Trae MCP 工具）能稳定复现 CLI 基线结果。

注意：MCP 通道依赖上述本地补丁与环境变量，单纯使用上游默认参数在本机沙箱下不可用。未设置 `GODOT_MCP_QUIT_AFTER` 时，需先调用 `get_debug_output` 再调用 `stop_project`；设置后进程会在指定帧数自行退出，退出后仍可通过 `get_debug_output` 拿到最后一次输出。

## 9 一键热更回归

改完 C# 后执行一条命令，完成「编译测试程序集 → CLI 回归 → MCP 回归 → 断言判定」：

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\hotreload.ps1
```

可选参数：

| 参数 | 作用 |
|---|---|
| `-Channel both`（默认） | CLI 与 MCP 各跑一轮 |
| `-Channel cli` | 只跑 CLI，适合未安装 godot-mcp 的环境 |
| `-Channel mcp` | 只跑 MCP |
| `-SkipBuild` | 跳过编译，只重跑回归（调试断言时用） |

执行步骤：

1. `dotnet build demo_csharp/LeanClrGame.csproj`：生成 v1 基线，复制为 `godot_project/hotreload_tmp/LeanClrGame.base.dll`；
2. `dotnet build demo_csharp/LeanClrExt.csproj`：生成跨模块引用测试程序集；
3. `dotnet build demo_csharp/LeanClrExt2.csproj`：生成依赖链末端程序集（Ext2 → Ext → Game）；
4. `dotnet build demo_csharp/LeanClrCycleA.csproj -p:CycleStage=v1` → `LeanClrCycleB.csproj` → `LeanClrCycleA.csproj -p:CycleStage=v2`：三段构建形成 A↔B 循环引用；
5. `dotnet build demo_csharp/LeanClrGameHot.csproj`：`HOT_V2` 热更版本，复制为 `hotreload_tmp/LeanClrGame.hot.dll`；
6. `dotnet build demo_csharp/LeanClrGameSig.csproj -p:SigVariant=<variant>`：生成 5 个签名变体到 `hotreload_tmp/sig/<variant>/`（`SIG_PARAM_TYPE` / `SIG_PARAM_COUNT` / `SIG_RETURN` / `SIG_REMOVED` / `SIG_ADDED`）；
7. CLI：`Godot --headless --path godot_project --quit-after 200 --log-file out/logs/godot_hotreload_c.log res://hotreload_c_test.tscn`；
8. MCP：`scripts/mcp_run_scene.mjs` 通过本地 godot-mcp stdio 服务调用 `run_project` → 轮询 `get_debug_output` → 进程自行退出后保存 `out/logs/godot_hotreload_c_mcp.log`。

成功判定（两个通道各自执行，全部满足才算 PASS）：

- Godot 退出码为 0；
- 日志包含阶段 C 全部 56 项断言：静态迁移（`counter=123, tag=persist-me`）、旧句柄 stale 报错、新代码 `build=v2`、节点信号重绑（`generation=1, signals=1`）与回调、跨模块引用判定、`reject` 模式为 `mode=rejected` 且不改代次、`fallback` 代次递增与回调；
- 多模块依赖图：卸载顺序 `LeanClrExt2,LeanClrExt,LeanClrGame`、`mode=assembly+dependents`、代次 +1、加载顺序恢复、`ExtUser2->ExtUser->PlayerItem=42`；
- 失败回滚：缺文件时 `mode=aborted`、代次与加载集合不变；循环引用：卸载顺序 `LeanClrCycleB,LeanClrCycleA`、重载后 `CycleA.Ping = cycle-a:cycle-b`；
- 签名兼容：参数类型/数量、返回值变化均为 `mode=signature-mismatch` + `changed signature` / `removed method` 明确错误；仅新增方法 `mode=assembly+dependents` 正常通过；
- 任意参数信号：0/1/2/3 参与引用句柄、`null`、string、int 混合转发（含 `OnSignalMixed target=PlayerItem=5` 与 `target=null`）；
- Godot 实例映射：传 `LeanCLRNode`/显式绑定实例得到对应托管对象（`OnSignalObject ... same=true/false`）、传 `null` 与已释放实例按 `null` 处理、未绑定实例报 `no managed object mapped`、`GetSelf()` 返回实例还原为 `Variant(Object)`、释放/解绑/热更后映射计数归零且旧实例失效、热更后 `LeanCLRNode` 自动重绑仍可映射；
- 结束标记 `=== stage C hot reload test done ===`；
- 日志不含 `SCRIPT ERROR`、`LeanCLR ... failed`、行首 `ERROR:`。

退出码与产物：

- 脚本退出码 0 = 全部 PASS；1 = 任一通道失败（会逐条打印缺失断言或命中的禁止项）。
- 编译日志：`out/logs/build_LeanClrGame.log`、`out/logs/build_LeanClrExt.log`、`out/logs/build_LeanClrExt2.log`、`out/logs/build_LeanClrCycleA_a1.log` / `_a2.log`、`out/logs/build_LeanClrCycleB_b.log`、`out/logs/build_LeanClrGameHot.log`、`out/logs/build_LeanClrGameSig_SIG_*.log`（仅失败时回显）。
- 回归日志：`out/logs/godot_hotreload_c.log`、`out/logs/godot_hotreload_c_mcp.log`；MCP 原始 `--log-file` 为 `out/logs/godot_mcp_hotreload_c_raw.log`。

注意事项：

- 脚本开始前会检查是否有运行中的 `Godot_v4.5-stable_win64_console`，有则直接报错，避免 DLL 被占用。
- 热更版本通过 `LeanClrGameHot.csproj` 的 `HOT_V2` 常量区分（`PlayerController.HotBuild` 为 `v2`）；修改演示代码时需同步该常量和断言。
- 测试开始时场景会从 `LeanClrGame.base.dll` 还原基线，因此同一工程可反复运行，无需手工清理 `bin/assemblies`。

## 10 异常恢复路径隔离测试（破坏性）

日常回归只覆盖正常热更与四类可恢复边界（`fallback` / `reject` / `aborted` / `signature-mismatch`）。`failed`、`fallback-failed`、`dependents-failed(-unrecovered)` 需要故意破坏镜像，因此单独放在独立脚本与独立场景中，不并入 `scripts/hotreload.ps1`，避免污染主流程。

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\recovery_test.ps1 [-Channel cli|mcp|both] [-SkipBuild]
```

- 场景：`godot_project/recovery_test.tscn`（脚本 `recovery_test.gd`）；
- 隔离目录：`godot_project/recovery_tmp/`（已 gitignore），内含 `pristine/` 基线镜像；`bin/bcl` 与 `bin/assemblies` 只读使用，场景只改写 `recovery_tmp`；
- 脚本开始前把 `bin/bcl` 与 `bin/assemblies` 备份到 `build/recovery_backup/`，结束后（含异常）原样恢复，再删除 `recovery_tmp`，可重复运行。

构造方式与预期：

| 用例 | 构造 | 预期 mode | 恢复后状态 |
|---|---|---|---|
| failed | 三程序集正常加载后，把 `LeanClrExt2.dll` 覆盖为文本垃圾；单模块 `reload_assembly("LeanClrExt2", false)` 卸载成功、加载失败 | `failed`（err=21 BadImageFormat） | 还原镜像后手动 `reload_runtime()` 返回 true，代次 +1，三程序集全部重载，`ExtUser2.Use() = ExtUser2->ExtUser->PlayerItem=42` |
| fallback-failed | 加载 Game+Ext，设置 `on_unsafe=fallback`；把被引用的 `LeanClrGame.dll` 覆盖为垃圾；`reload_assembly("LeanClrGame", false)` 触发 fallback，随后 `reload_runtime()` 读垃圾失败 | `fallback-failed` | 还原后 `reload_runtime()` 返回 true，Game+Ext 重载，`ExtUser.Use() = ExtUser->PlayerItem=42` |
| dependents-failed | 三程序集加载后，把 `LeanClrExt2.dll` 覆盖为垃圾；`reload_assembly("LeanClrGame", true)` 整组卸载后加载失败，`reload_runtime()` 兜底仍失败 | `dependents-failed-unrecovered` | 还原后 `reload_runtime()` 返回 true，三程序集重载，`ExtUser2.Use()` 正常 |
| dependents-failed（recovered 尝试） | 三程序集加载后，把 `LeanClrExt2.dll` 换成内部名为 `LeanClrGame` 的有效镜像；整组加载因 `ModuleAlreadyLoaded` 失败 | `dependents-failed-unrecovered`（err=28） | 还原后 `reload_runtime()` 返回 true，状态可用 |

关于 `dependents-failed`（`recovered=true`）：无法用镜像损坏构造。`load_group` 与兜底 `reload_runtime()` 读取同一组文件、同一加载顺序，任何镜像错误在 `Runtime::shutdown()` 后依然存在；上面的错名镜像实验也得到 `-unrecovered`。该分支只可能在两次加载之间文件被外部修复（瞬时 I/O）时触发，当前无注入点，因此不做断言。

判定：每个通道 17 项断言（3 个实际 mode + 1 个 recovered 尝试、4 次 `reload after restore`、4 次托管调用、加载集合、收尾标记），并禁止 `SCRIPT ERROR` 与行首 `ERROR:`。

实测（2026-11-10）：CLI 17/17、MCP 17/17；日志 `out/logs/godot_recovery.log`、`out/logs/godot_recovery_mcp.log`。

## 11 可玩热更 demo

一个闭环小游戏，用来演示「改 C# 脚本 → 热更生效」：方向键移动，吃橙色目标得分，单局倒计时结束即失败，按 `R` 重开。移动、计时、吃目标判定、目标刷新与失败逻辑都在 C#；Godot 侧只负责挂节点、读输入、显示 HUD 与触发热更。

| 文件 | 作用 |
|---|---|
| `demo_csharp/GameDemoTuning.cs` | 「改这里看效果」：`MoveSpeed` / `PointsPerTarget` / `RoundSeconds` / `TargetRadius` |
| `demo_csharp/GameDemo.cs` | 玩法逻辑与 `GodotNative` P/Invoke 声明 |
| `demo_csharp/LeanClrGameDemo.csproj` | 输出到 `godot_project/game_demo_tmp/build/<v1|v2>`；`-p:DemoVariant=v2` 定义 `DEMO_V2` |
| `godot_project/game_demo.tscn` / `game_demo.gd` | 场景、输入、HUD、DLL 变化轮询与 `reload_assembly` 触发 |
| `godot_project/game_demo_test.tscn` / `game_demo_test.gd` | 自动化验证场景 |
| `scripts/game_demo.ps1` | 构建 v1、启动游戏、监视 `GameDemo*.cs` 并自动重建 |
| `scripts/game_demo_test.ps1` | 一键双通道验证（39 项断言/通道） |

### 11.1 运行与演示

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\game_demo.ps1
```

脚本先 `dotnet build` v1 并复制到 `godot_project/bin/assemblies`，再以非 headless 启动 `res://game_demo.tscn`；随后每 400ms 检查 `demo_csharp/GameDemo*.cs` 的最后修改时间，发现变化就重新构建并复制 DLL。游戏内每 250ms 读取一次 DLL 的「修改时间 + 大小」，连续两次稳定后调用同一个 `runtime.reload_assembly("LeanClrGameDemo", false)`。

触发热更的两种方式：

- **文件监视（默认）**：保存 `GameDemoTuning.cs` / `GameDemo.cs` 即可，脚本负责重建，游戏内自动热更；
- **手动按键**：游戏窗口内按 `F5` 立即对当前 `bin/assemblies` 里的 DLL 触发热更；按 `R` 重开一局。

演示流程：

1. 启动后吃几个目标，记下 HUD 的速度、得分与剩余时间；
2. 把 `GameDemoTuning.cs` 的 `MoveSpeed` 改为 `320f`、`PointsPerTarget` 改为 `25`、`RoundSeconds` 改为 `20f` 并保存；
3. 观察控制台/`out/logs/godot_game_demo.log`：`[hotreload] assembly reloaded: LeanClrGameDemo, generation=1, mode=assembly`、`[hotreload] node rebound: type=GameDemo, generation=1, signals=0`、`[demo] reload source=file-watch returned=true mode=assembly generation=0->1`；
4. HUD 的速度/版本/generation 立即变化，得分与剩余时间保持热更前进度（静态字段按白名单迁移），玩家与目标节点继续被新代码驱动。

### 11.2 自动化验证

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\game_demo_test.ps1 [-Channel cli|mcp|both] [-SkipBuild]
```

脚本编译 v1/v2，把 v2 放到 `godot_project/game_demo_tmp/hot`，测试场景从 `game_demo_tmp/LeanClrGameDemo.base.dll` 还原基线后确定性驱动 `GameDemo`：

- v1 基线：速度 180、每次 10 分、30s、命中半径 16；`SetInput(1,0)` + `OnProcess(0.5)` 位移 90；吃到目标 +10；`SetTimeLeft(0.2)` + `OnProcess(1.0)` 后 `state=over`、时间归零；`Restart()` 复位。
- 热更后：`reload_assembly` 返回 true、`mode=assembly`、`generation +1`、加载集合不变；旧句柄调用返回 `null` 且报 `stale type identity: ... 'LeanClrGameDemo' ...`；新对象速度 320、每次 25 分、20s、半径 22；位移 160；计分规则变为 +25；热更前的分数 20 与命中数 2 保留。
- 节点重绑：真实 `LeanCLRNode` 入树后通过 `node_get_node(ownerId, "../Player"/"../Target")` 解析节点并同步位置；再次热更回 v1 后 `get_bound_generation()` 等于当前 generation、`has_pending_rebind()==false`、速度回到 180、节点位置继续跟随 C# 状态。
- 判定：每通道 39 项断言全部命中，且无 `SCRIPT ERROR`、`LeanCLR[^\r\n]*failed`、行首 `ERROR:`。

实测（2026-11-10）：CLI 39/39、MCP 39/39；日志 `out/logs/godot_game_demo_test.log`、`out/logs/godot_game_demo_test_mcp.log`。另用 headless 启动 `game_demo.tscn` 并在运行中替换 DLL，实测 `generation 0->1->2`、`[hotreload] statics: restored ...` 共 8 个字段、`node rebound` 正常，无脚本错误（`out/logs/godot_game_demo_watch.log`）。

### 11.3 demo 的热更限制

- 修改常量与方法体可立即生效；改静态字段初值也会生效（未列入白名单的静态字段恢复为新版本初始值）。
- 静态进度只保留 `godot_project/hotreload.statics.json` 白名单内的字段；demo 已登记 `s_score` / `s_timeLeft` / `s_state` / `s_playerX` / `s_playerY` / `s_targetX` / `s_targetY` / `s_hits`。
- 改变已有方法签名、参数数量或返回值会被签名校验拦截，`mode=signature-mismatch` 并按 `hot_reload/on_unsafe` 处理；演示时请只改方法体或调参常量。
- 新增类型、改变程序集依赖结构、修改 corlib 不在 demo 的热更范围内，需要重启游戏（或按 `docs/04` §9 的热更规则处理）。
- HUD 在热更成功后的当帧会跳过读取（旧句柄已失效、下一帧重绑），属于预期行为。

## 12 代码包热更新回归（桌面 + Android）

代码包热更新是「下载新程序集包 → 落到 `user://` → `reload_runtime()` → 执行新代码」，与 §9–§11 的同进程 `reload_assembly` 不同。Android 从环境检查到日志断言的逐步命令、预期输出与排障见 `docs/09-code-package-hot-update.md`。

### 12.1 桌面 CLI + MCP

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\code_pkg_test.ps1 -Channel both
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\code_pkg_test.ps1 -Channel cli -SkipBuild
```

脚本流程：编译 v1/v2 → 部署 v1 到 `bin/assemblies` → 生成 `out/packages/{good,bad-sha,broken-type}` → 启动 `scripts/code_pkg_server.mjs`（`127.0.0.1:18080`）→ CLI 与 MCP 各跑一轮 `res://code_pkg_test.tscn` → 42 项断言。

判定：每通道 42 项断言全部命中，且无 `SCRIPT ERROR`、`LeanCLR[^\r\n]*failed`、行首 `ERROR:`。日志：`out/logs/godot_code_pkg_test.log`、`out/logs/godot_code_pkg_test_mcp.log`。2026-11-10 实测 CLI 42/42、MCP 42/42。

### 12.2 Android（MuMu x86_64）

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\code_pkg_android_test.ps1
:: -Serial 127.0.0.1:16384 | -SkipBuild | -SkipExport | -TimeoutSeconds 180
```

脚本会：编译 v1/v2 与 Android Debug 原生库 → 生成三个包 → 临时把 `project.godot` 主场景切到 `res://code_pkg_test.tscn` 导出 APK 并在 `finally` 还原 → `adb connect/install/reverse/pm clear` → 起本地 HTTP 源并 `am start` → 轮询 logcat 至 `=== code pkg test done ===` → 41 项断言。

关键断言：`pkg user dir = /data/data/org.godotengine.leanclrcodepkg/files/code_pkg/assemblies`、`[LeanCLR] lib dir=<上述路径>`、`resolve assembly via filesystem: .../code_pkg/assemblies/LeanClrCodePkg.dll`、`[codepkg] applied version=v2 files=1 generation=0->1`、`[hotreload] node rebound: type=CodePkgNode, generation=1`、坏 SHA 拒绝、坏类型回退到 v2。禁止项：`F/libc`、`Fatal signal`、`SCRIPT ERROR`、`LeanCLR ... failed`。

2026-11-10 实测：MuMu 12 / Android 12 / x86_64，`PASS (41/41 断言)`，约 60s（含构建与导出）；日志 `out/logs/android_code_pkg.log`。Android 导出前置（`.so` 以 `lib` 开头、`INTERNET` 权限、`import_etc2_astc`、debug keystore）见 `docs/09` §3.1，失败排查见 §8。
