# 08 能力矩阵、限制与路线

## 1. 已实现能力

### 1.1 运行时嵌入

- leanclr mono 运行时 + 完整 mono-4.5 BCL 加载。
- 静态方法调用、实例方法调用、无参构造。
- 对象句柄由 `GCHandle` 持有，避免 GC 提前回收。
- `Debugger.Log` 回调转发到 Godot 输出。

### 1.2 Godot → C#

| 能力 | 接口 |
|---|---|
| 节点生命周期 | `OnEnterTree` / `OnReady` / `OnProcess` / `OnPhysicsProcess` / `OnExitTree` |
| 通用方法调用 | `LeanCLRNode.call_managed(method, args)` |
| 字段读写 | 简单类型 + 枚举 + struct（`PackedByteArray`）+ 引用类型（对象/数组返回可复用对象句柄，支持写句柄或 `null`） |
| 信号转发 | `bind_signal` / `bind_signal_args`（任意参数个数；引用类型参数用对象句柄或 `null`） |
| 宿主 ID 注入 | 自动调用 C# `SetOwnerId(long)` |

### 1.3 C# → Godot（P/Invoke 回桥）

| 接口 | 说明 |
|---|---|
| `print(string)` | 输出到 Godot |
| `get_ticks_msec()` | 运行毫秒 |
| `node_is_inside_tree(long)` | 节点是否在树中 |
| `node_set_position(long, double, double)` | Node2D 位置 |
| `node_set_visible(long, bool)` / `node_get_visible(long)` | CanvasItem 可见性 |
| `node_get_position_x/y(long)` | Node2D 位置读取 |
| `node_get_child_count(long)` | 子节点数量 |
| `node_get_name(long)` | 节点名（返回 `string`） |
| `node_get_parent(long)` | 父节点 `instance_id` |
| `node_get_child(long, int)` | 子节点 `instance_id`（越界返回 0） |
| `node_emit_signal(long, string)` | C# 主动发信号 |
| `node_get_node(long, string)` | 按相对路径找节点 |
| `instantiate_scene(string)` | 实例化 `PackedScene` |
| `node_add_child(long, long)` | 挂载子节点 |
| `node_queue_free(long)` | 延迟释放节点 |
| `load_resource(string)` | 加载资源并持有 `Ref` |
| `unload_resource(long)` | 释放资源引用 |
| `resource_get_path(long)` | 读取资源路径 |
| `node_get_class(long)` | 节点类名（返回 `string`） |
| `node_get_path(long)` | 节点路径（返回 `string`） |

### 1.4 资源加载

- BCL 与测试程序集优先通过 Godot 虚拟文件系统（`FileAccess` + `res://`）读取，导出为 PCK 后仍可加载；Linux/编辑器环境下自动回退 `std::ifstream`。

### 1.5 引用类型字段

- `get_field` 读取 class/object/array/泛型实例/`Var` 字段时返回对象句柄（`int64`），`null` 字段返回 `null`。
- 同一对象复用同一句柄：按 `GCHandle::get_target` 去重，不会因多次读字段而持续新建句柄。
- `set_field` 接受句柄或 `null`；句柄必须由本运行时注册，否则报 `invalid object handle`。
- 写回后即可用该句柄调用实例方法（回归中的 `PlayerItem.Describe()` 与数组字段求和）。
- 方法返回值中的 class/object/array/泛型实例/`Var` 同样走句柄路径，`null` 返回 `null`；`invoke_method`、`invoke_static`、`call_managed` 共用 `read_return_value` 的这套语义。
- 方法参数中的引用类型接受句柄或 `null`（`push_argument_value`），因此“取字段/取返回值 → 作为实参传给另一个方法”可以闭环。

## 2. 不可行项（不要再尝试）

### 2.1 完整 `ScriptLanguageExtension`

结论：在 GDExtension 层面不可行。

原因：

- Godot 4.5 的 godot-cpp 绑定**没有 `ScriptInstance`**。
- `Script` 的 `_instance_create` 等扩展点**没有通过 GDVIRTUAL 暴露**。
- 因此 `ScriptLanguageExtension::_create_script` 无法返回可实例化的自定义 `Script`。

替代：以 `LeanCLRNode` 作为脚本宿主形态。仅当改为引擎模块（非 GDExtension）集成时，才重新评估。

### 2.2 直接复用 GodotSharp

不采用。GodotSharp 依赖 CoreCLR/mono 宿主与完整 BCL/icall 面，替换成本远高于 GDExtension 嵌入。

### 2.3 C# 热更 / 程序集重载

结论：**阶段 B（运行时重启式热更）与阶段 C（单程序集热更）均已实现并验证**。日常仍可用“冷更新”：停止进程 → 替换 `godot_project/bin/assemblies/*.dll` → 重新启动场景/游戏。

阶段 B 现状（2026-11-09）：

- `Runtime::shutdown()`（`native/thirdparty/leanclr/src/runtime/vm/runtime.cpp`）已实现真实清理：GC/GC 句柄、`MetadataCache`、`MachineState`、module/assembly 表、AppDomain/Thread、P/Invoke 与 InternalCall 注册、Class/ArrayClass/Reflection/Monitor/GenericMethod 缓存等；`initialize()` 可重复调用。
- `native/src/leanclr_runtime.cpp` 新增 `reload_runtime()` 与 `get_generation()`：reload 前释放本层全部 `GCHandle` 与资源引用，`shutdown → initialize →` 按原顺序重载 `loaded_assemblies_`；旧句柄统一返回 `invalid object handle`，`next_handle_id_` 不重置以保证句柄 id 永不复用。
- 上述改动是 leanclr 的本地补丁，授权与逐文件清单见 `AGENTS.md` §8；上游源码以 git submodule 固定，补丁以 `patches/leanclr-runtime-hotreload.patch` 入库，构建前由 `scripts/ensure_deps.ps1` 应用。
- 实现期间修复的关键问题：`Reflection::s_class_reflection_type_map` 未清理，导致 reload 后取到上一代 `RtReflectionType*`，在 `Class::is_assignable_from` 触发访问冲突。

验证证据：

- `out/logs/godot_hotreload_b.log`（CLI）与 `out/logs/godot_hotreload_b_mcp.log`（MCP）各 64 行，与 `out/logs/godot_refargs.log` 逐行一致，仅动态值不同（`godot ticks`、实例/资源 id、`physics ticks`）。
- `out/logs/godot_hotreload_b_semantic.log`：同一进程内替换 `LeanClrGame.dll` 后 `reload_runtime()`，`generation` 0→1，旧句柄 `invoke_method`/`get_field` 均返回 `invalid object handle`，新对象 `Describe()` 读到新字符串。
- `leanclr_smoke` 两轮 `initialize → run → shutdown → initialize → run` 输出 `SMOKE_OK`。
- 可复现入口：`godot_project/hotreload_test.tscn`（把新 DLL 放到 `res://hotreload_tmp/LeanClrGame.hot.dll` 后运行）。

阶段 C 现状（2026-11-09）：

用法（GDScript）：

```gdscript
var runtime := LeanCLRRuntime.new()
runtime.initialize(PackedStringArray([bcl_dir, assembly_dir]))
runtime.load_assembly("LeanClrGame")
# 替换 bin/assemblies/LeanClrGame.dll 后：
runtime.reload_assembly("LeanClrGame")
print(runtime.get_last_reload_mode())   # assembly | fallback | rejected
print(runtime.get_generation())         # 每次有效热更 +1
# 连引用方一起热更（依赖链/循环引用）：
runtime.reload_assembly("LeanClrGame", true)   # mode = assembly+dependents
print(runtime.get_loaded_assemblies())          # 加载顺序保持
```

- **C1 模块卸载**：leanclr 本地补丁新增 `Assembly::unload_module(name)`，真正释放 `RtModuleDef`/`RtAssembly`/`PdbImage`/模块 `MemPool` 与 DLL/PDB 原始数据。卸载顺序为：第一轮 GC → 释放模块静态区 → 清懒重建缓存（ptr/generic/fnptr、`MetadataCache`、`Reflection`、`GenericMethod`）→ 第二轮 GC → 注销并删除模块。`ArrayClass` 只移除元素类属于目标模块的数组类，**不能整体 `shutdown()`**（会清掉 corlib 数组模板，重载后首次构造抛 `System.BadImageFormatException`）。
- **C2 类型身份隔离**：句柄表记录 `module_name` 与 `generation`。卸载前释放该模块全部 `GCHandle` 并记入 stale 表；旧句柄调用返回 `stale type identity: handle <id> belongs to unloaded assembly '<name>' (generation <g>)`。
- **C3 静态字段迁移**：`godot_project/hotreload.statics.json` 白名单，格式 `{"statics":["Assembly!Namespace.Type::field", ...]}`。卸载前按白名单快照，重载后先执行新类 `.cctor` 再写回同名同尺寸字段；引用类型（含 `String`）用 `GCHandle` 保活，避免被 GC 回收。
- **C4 委托/信号重绑定**：`LeanCLRNode.bind_signal_args` 记录逻辑绑定（signal + managed method + 参数个数）并用可变参数 `CallableCustom` 转发器连接信号（参数个数任意）。`_process`/`_physics_process` 检测到 generation 变化时重建托管对象、重新 `SetOwnerId`/`OnEnterTree` 并恢复全部信号绑定，输出 `[hotreload] node rebound: type=..., generation=..., signals=N`；重建失败则保持 pending 并每帧重试。
- **C5 安全卸载与降级**：热更前检查目标存在、非 corlib、且没有其他已注册模块引用（`RtModuleDef::references_assembly`）。不安全时由 `leanclr/hot_reload/on_unsafe` 决定：
  - `fallback`（默认）：退回阶段 B，整运行时重启（`reload_runtime()`），`generation` +1，旧句柄全部 `invalid object handle`；
  - `reject`：拒绝本次热更，返回 `unsafe to unload: <原因>`，运行状态与 `generation` 均不变。
  - 该开关可在 `project.godot` 的 `leanclr` 段 `hot_reload/on_unsafe` 配置，也可运行时用 `LeanCLRRuntime.hot_reload_on_unsafe` 属性或 `set_hot_reload_on_unsafe("fallback"|"reject")` 切换。
- **C6 多模块依赖图热更（2026-11-10）**：`reload_assembly(name, include_dependents=true)` 先求“传递引用目标”的模块闭包，按 `loaded_assemblies_` 逆序卸载（引用方先）、原顺序重载；一次成功只 `generation += 1`，`mode=assembly+dependents`。
  - 循环引用：leanclr 新增 `Assembly::unload_module_unchecked`（跳过跨模块引用检查），由 native 确认组外无引用后整组卸载。
  - 失败回滚：卸载前预检组内所有镜像存在，任一缺失 → `mode=aborted`，`generation` 与加载集合完全不变；加载阶段失败 → `reload_runtime()` 兜底，`mode=dependents-failed`。
  - 静态字段快照按 `assembly_name` 归属，重载时逐模块恢复。
  - 默认 `include_dependents=false` 完全保持原单模块行为。
- **C7 热更签名兼容校验（2026-11-10）**：卸载前对组内每个模块快照全部类型的方法签名（类型名、方法名、参数类型/数量、返回值、static），重载并完成类元数据初始化后立即比对。
  - 参数类型/数量或返回值变化 → `changed signature: <old> -> <new>`；方法删除 → `removed method: <sig>`；新增方法放行。
  - 不兼容：`last_error = "signature mismatch in '<assembly>': ..."`、`mode=signature-mismatch`、`reload_runtime()` 恢复一致状态、返回 false；错误在任何业务托管代码执行前给出。
  - 校验为“加载新镜像后”而非“卸载前预探测”：leanclr 按程序集名注册，预探测需额外的别名加载接口，后续如需可再扩展。
- **C8 任意参数信号（2026-11-10）**：`LeanCLRNode` 使用 `CallableCustom` 转发器接收信号实际发出的任意数量参数，`bind_signal_args` 不再限制 0..2；引用类型参数接受 `create_object` 返回的 int64 句柄与 `null`，Godot 实例的映射见 C9。
  - 回归覆盖 0/1/2/3 参与混合类型（句柄 + string + int），3 参场景使用新增的 `leanclr_signal_mixed(handle, text, value)` 信号。
- **C9 Godot 实例 ↔ 托管对象双向映射（2026-11-10）**：`LeanCLRRuntime` 维护 `instance_id ↔ int64 句柄` 1:1 双向表（`instance_mappings_` / `handle_mappings_`），映射复用既有句柄的强 `GCHandle`，映射存在期间托管对象不会被 GC。
  - 入参：`Variant::OBJECT` 若是 `LeanCLRNode` 取其当前 `object_handle_`（热更重绑后自动指向新对象）；否则查显式绑定表。未绑定 → `no managed object mapped for Godot instance '<Class>#<id>'`，不隐式创建；类型不是参数声明类的可赋值类型 → `managed type mismatch: ...`；已释放或 `null` 实例按托管 `null` 处理。
  - 出参：方法返回值/字段读取若命中反向表且实例仍有效，返回 `Variant(Object)`，否则维持 int64 句柄。
  - API：`bind_godot_object(instance, handle)`、`unbind_godot_object(instance)`、`get_object_mapping_count()`（读取前先清扫失效映射）；新增信号 `leanclr_signal_object(instance, text)`。
  - 生命周期：Godot 实例释放后映射在下次访问或计数时清除；`destroy_object`、`invalidate_module_handles(module)`、`reload_runtime()`/`shutdown()` 同步删除映射，热更后旧实例再传入按“未映射”报错，旧句柄仍按 stale 规则报错。

验证证据（CLI `out/logs/godot_hotreload_c.log` 与 MCP `out/logs/godot_hotreload_c_mcp.log`，两轮内容一致）：

- 跨模块引用：`[hotreload] unsafe to unload: assembly 'LeanClrGame' is referenced by 'LeanClrExt'`；`reject` 时 `reload_assembly=false`、`generation unchanged = true`；`fallback` 时 `generation after fallback = 2`，`ExtUser.Use() after fallback = ExtUser->PlayerItem=42`。
- 静态迁移：`statics after reload: counter=123, tag=persist-me`。
- 委托/信号重绑定：`[hotreload] node rebound: type=PlayerController, generation=1, signals=1`，信号回调输出 `OnHotSignal build=v2 text=post-reload`；fallback 后同样重建并输出 `build=v2 text=post-fallback`。
- 任意参数信号：0 参 `PlayerController.OnSignal`、1 参 `signal arg=hello`、2 参 `signal args2=hi,9`、3 参句柄 `OnSignalMixed target=PlayerItem=5 text=sig3 value=42`、3 参 null `OnSignalMixed target=null text=sig-null value=7`。
- Godot 实例映射：`OnSignalObject target=PlayerController same=true text=sig-object`、显式绑定 `same=false`、`null`/已释放/热更后旧实例 `target=null` 或 `no managed object mapped for Godot instance 'Node#...'`；托管返回 `GetSelf()` 还原为实例（`t4 return is object = true`、`t4 return same instance = true`）；释放后 `t4 mapping count after free = 0`，热更后 `t4 mapping count after reload = 0`。
- 卸载后失效：`old handle error = stale type identity: handle 2 belongs to unloaded assembly 'LeanClrGame' (generation 0)`；新对象 `new object build = v2`。
- 可复现入口：`godot_project/hotreload_c_test.tscn`（测试开始会从 `res://hotreload_tmp/LeanClrGame.base.dll` 还原基线，再覆盖为热更版本）。
- 测试素材（`godot_project/hotreload_tmp/`，已 gitignore）生成方式：在 `demo_csharp` 下依次 `dotnet build LeanClrGame.csproj -c Release`（v1 基线，复制为 `hotreload_tmp/LeanClrGame.base.dll`）、`dotnet build LeanClrGameHot.csproj -c Release`（输出到 `hotreload_tmp/hot/`，复制为 `LeanClrGame.hot.dll`）、`dotnet build LeanClrExt.csproj -c Release`（输出 `LeanClrExt.dll`）；依赖图另需 `LeanClrExt2.csproj`、`LeanClrCycleA.csproj`（`-p:CycleStage=v1|v2`）与 `LeanClrCycleB.csproj`，签名变体用 `LeanClrGameSig.csproj -p:SigVariant=SIG_PARAM_TYPE|SIG_PARAM_COUNT|SIG_RETURN|SIG_REMOVED|SIG_ADDED`。以上均由 `scripts/hotreload.ps1` 的构建阶段自动完成，无需手工执行。
- **一键流程**：改完 C# 后执行 `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\hotreload.ps1`，自动完成编译、CLI 回归、MCP 回归与 56 项断言判定；`-Channel cli|mcp|both` 选择通道，`-SkipBuild` 只重跑回归。用法与成功/失败判定见 `docs/04` §9。
- 异常恢复路径（破坏性隔离）：`scripts/recovery_test.ps1` 用损坏/错名镜像构造 `mode=failed`、`fallback-failed`、`dependents-failed-unrecovered`，CLI 与 MCP 各 17 项断言通过；还原镜像后 `reload_runtime()` 均返回 true 且依赖链调用正常。`dependents-failed` 的 `recovered=true` 分支经错名镜像实验确认无法构造（两次加载读取同一组文件），仅有 `-unrecovered`。用法与构造见 `docs/04` §10。
- PCK 导出回归：`scripts/pck_export.ps1` 重建双目标扩展与托管程序集，按 `export_presets.cfg` 导出并运行 debug/release（`-IncludeLinux` 追加 WSL Linux）；断言退出码 0、基线 64 行、`resolve assembly via Godot VFS` 命中、无 filesystem 回退与错误行，并核对 `savepack` 内容（BCL/程序集进 PCK，测试素材与扩展 DLL 不进）。2026-11-10 实测 12/12 PASS，用法见 `docs/04` §6。
- 可玩热更 demo：`scripts/game_demo_test.ps1` 编译 v1/v2 后 CLI 与 MCP 各 39 项断言通过（2026-11-10）。实测热更前后 `MoveSpeed 180→320`、`PointsPerTarget 10→25`、`RoundSeconds 30→20`、`TargetRadius 16→22`，0.5s 位移 `90→160`，静态分数 20 与命中数 2 保留，旧句柄报 `stale type identity`，真实 `LeanCLRNode` 自动重绑并继续驱动节点；运行中替换 DLL 实测 generation `0→1→2` 且无脚本错误。玩法与演示入口见 `docs/04` §11。

仍存在的限制：

- 不能热更 corlib；被其他已注册程序集引用的程序集默认只能走 `fallback` 或 `reject`；传入 `include_dependents=true` 可整组热更，但组外仍被引用时按同样策略降级。
- 静态字段迁移必须显式列入 `hotreload.statics.json`，未列入的静态字段在热更后恢复为新版本初始值。
- 热更前已捕获的托管委托（C# `Action`/`Func`）无法自动迁移；`LeanCLRNode` 的信号绑定会重建，但自定义委托需应用层在 generation 变化后重新注册。
- `hotreload.statics.json` 只校验字段名与尺寸；字段类型变更（如 `int` → `long`）会被跳过并保持新版本默认值。
- 卸载依赖两轮 GC；若应用层仍持有未注册的原生指针（非本运行时节柄）指向旧模块，无法检测，属于未定义行为。
- 实例映射只覆盖 `LeanCLRNode` 与显式绑定对象，且为强引用：映射存在期间托管对象不会被 GC，不再需要时应 `unbind_godot_object` 或释放 Godot 实例。

难点：

- **GC 句柄存活**：`GCHandle` 指向旧堆；重载必须全部失效并重建，不能留下悬空句柄。
- **静态状态**：类静态字段、cctor 完成标记、字符串驻留、线程/AppDomain 状态都绑定在旧元数据上，无法跨版本迁移。
- **方法/模块缓存失效**：全局 module 表按名字缓存（上条已确认），不清理则永远返回旧代码；解释器内联缓存与已解析方法指针也需作废。
- **对象身份与句柄语义**：`LeanCLRNode` 持有 `int64` 句柄；重载后旧句柄必须明确报 `invalid object handle`，对象需重建。
- **回桥注册**：`register_godot_bridge()` 在 `initialize()` 时注册 P/Invoke 与 InternalCall，重载后需重新注册，且不能重复注册。
- **原生全局状态**：`g_resource_refs`、`s_lib_dirs`、`object_handles_` 等都需随重载重置。

最小可行路径（按成本递增）：

1. **阶段 A（可用）**：冷更新。编辑 C# → csc 编译 → 覆盖 `bin/assemblies` → 重启 Godot 进程/场景，再跑基线回归。无需改动代码。
2. **阶段 B（已完成，运行时重启）**：`Runtime::shutdown()` 真实清理 + native `reload_runtime()`：`shutdown → initialize →` 重载程序集 → 旧句柄全部失效并重建对象。已按本页“验证证据”通过 CLI、MCP 与同进程换 DLL 三项验证。
3. **阶段 C（已完成，单程序集热更）**：`reload_assembly()` 做模块级卸载与类型身份隔离；静态字段经 `hotreload.statics.json` 迁移，`LeanCLRNode` 信号绑定自动重建；不安全场景按 `leanclr/hot_reload/on_unsafe` 回退或拒绝；`include_dependents=true` 支持依赖链与循环引用整组热更；重载前后校验方法签名；信号转发支持任意参数与 Godot 实例映射。方案与影响面见 `.trae/specs/hot-reload-runtime-restart/spec.md` §5 与 `.trae/specs/hotreload-3items/spec.md`。

### 2.4 代码包热更新（下载新程序集，2026-11-10）

- 与 B/C 的区别：不替换同名模块，而是把整包下载到 `user://code_pkg/assemblies`，校验 SHA-256 后安装，再调用 `reload_runtime()`，按 `[bin/bcl, user 覆盖目录, bin/assemblies]` 重新解析程序集。
- 包格式 `manifest.json` + 文件 size/SHA-256；校验失败不安装、不 reload；reload 或类型探测失败会恢复 `backup/` 并再次 reload，`generation` 继续递增。
- 期间修复两处 reload 阻塞：`reload_runtime()` 必须在重新 `initialize()` 后再次 `register_godot_bridge()`；新增 `Settings::shutdown()` 释放一次性全局字符串（Android Debug 下 `assert(g_domain_name == nullptr)` 会直接 `SIGABRT`）。
- 验证证据：桌面 CLI/MCP 各 42 项断言（`out/logs/godot_code_pkg_test*.log`）；Android MuMu 12 x86_64 41 项 logcat 断言（`out/logs/android_code_pkg.log`），真实日志包含 `user://` 绝对路径、`generation 0->1`、`node rebound`、坏 SHA 拒绝与坏包回退到 v2。
- 入口：`scripts\code_pkg_test.ps1`、`scripts\code_pkg_android_test.ps1`、`scripts\code_pkg_demo.ps1`；说明见 `docs/09-code-package-hot-update.md`。

## 3. 已知限制

| 限制 | 影响 | 方向 |
|---|---|---|
| Godot 实例 ↔ 托管对象映射 | 仅支持 `LeanCLRNode` 自身与显式 `bind_godot_object` 绑定的实例；未绑定实例明确报错，不做隐式创建或代理包装 | 如后续需要任意实例自动映射，需新增托管代理类型或按 `managed_type` 自动创建 |
| 映射参数类型 | Godot 实例映射到的托管对象必须可赋值给方法参数声明的类型，否则报 `managed type mismatch` | 由应用层保证信号方法的参数类型 |
| 单线程模型 | 不能在 C# 侧跨线程回调 Godot | 主线程调度队列 |
| 无 AOT | 纯解释执行性能有限 | 后续评估 LeanAOT |
| 平台覆盖 | Windows x64 与 Linux x86_64 已构建并验证；Android x86_64 已完成代码包热更新实测（MuMu 12）；macOS 与其他 Android ABI 未验证 | macOS 宿主见 `docs/02` §7；其他 Android ABI 需对应导出模板与设备 |
| C# 热更 | 阶段 B `reload_runtime()` 整体重启；阶段 C `reload_assembly()` 单程序集热更（旧句柄报 stale、静态字段按白名单迁移、节点信号自动重绑）；corlib 与被引用程序集不可单模块卸载 | 见 §2.3 |
| 异常恢复路径 | `failed` / `fallback-failed` / `dependents-failed` 仅由破坏性隔离用例 `scripts/recovery_test.ps1` 覆盖，不并入日常主回归；`dependents-failed` 的 `recovered=true` 无镜像注入点 | 见 `docs/04` §10 |
| PCK 导出验证 | debug/release 必须分别使用对应目标的扩展 DLL（错配会 heap corruption）；Linux release 目标仍未单独构建 | 由 `scripts/pck_export.ps1` 一键验证 debug/release（可选 Linux debug）；Linux release 见 `docs/02` §7 待办 |

## 4. 后续路线（按依赖顺序）

1. **主线程调度队列**：C# 侧线程回调 Godot（需引入线程池与同步验证）。
2. **多平台**：Linux x86_64 已完成（WSL 构建 + 导出运行验证）；Windows x64 已完成；Android x86_64 已完成代码包热更新实测（MuMu 12）。macOS 与其他 Android ABI 待具备宿主/设备后按 `docs/02` §7 清单推进。
3. **AOT**：评估 leanclr LeanAOT，依赖 .NET SDK 与上游 LeanAOT 工具链，状态未接入。
4. **C# 热更**：阶段 B（运行时重启）与阶段 C（单程序集热更）均已完成并验证；后续可评估增量 IL 补丁与自动化构建/部署流水线，见 §2.3。

## 5. 每阶段验收标准

- 新增接口有 C# 声明、native invoker、注册名三处一致。
- Godot headless 日志包含新功能的具体数值/字符串证据。
- 旧基线（`out/logs/godot_reffield.log`）全部旧行保留。
- 涉及加载路径时，额外跑一遍 `docs/04` 第 6 节的导出回归。
- 无 `SCRIPT ERROR`、无 `LeanCLR ... failed`。
- 更新 `AGENTS.md` 文档索引或对应流程文档。