# 03 C# 测试程序集：编译与部署

## 1. 源码与约定

- 源码：`demo_csharp/LeanClrGame.cs`
- 程序集名：`LeanClrGame`
- 目标：.NET Framework 程序集，引用 mono-4.5 BCL 兼容类型。
- 输出：`demo_csharp/LeanClrGame.dll`，再复制到 `godot_project/bin/assemblies/LeanClrGame.dll`。

## 2. 编译命令（必须在源文件目录执行）

先按 `AGENTS.md` 的常用命令设置 `CSC`，然后：

```bat
cd demo_csharp
"%CSC%" -nologo -target:library -out:LeanClrGame.dll LeanClrGame.cs
```

必须在 `demo_csharp` 目录执行，原因：沙箱环境下其他工作目录/绝对源路径会丢失目录段，报“源文件找不到”。参数使用 `-` 风格，避免 MSYS 把 `/nologo` 转成路径。

## 3. 部署顺序

1. 编译输出到 `demo_csharp/LeanClrGame.dll`。
2. 复制到工程：

```bat
cp demo_csharp/LeanClrGame.dll godot_project/bin/assemblies/LeanClrGame.dll
```

不要直接 `-out:godot_project/bin/assemblies/...`，目标目录可能被 Godot 进程或文件锁占用，csc 会报“生成 Win32 资源时出错：拒绝访问”。

## 4. P/Invoke 声明约定

C# 侧声明：

```csharp
[DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern void node_set_position(long instance_id, double x, double y);
```

- 库名 `leanclr_godot.dll` 是占位，实际由 native 注册表按方法全名匹配。
- 注册名必须与 C# 方法全名和参数类型完全一致，例如：
  - `[LeanClrGame]GodotNative::node_set_position(System.Int64,System.Double,System.Double)`
- 新增接口时 native 侧同时注册带模块名与不带模块名两种形式，降低匹配失败概率。
- 类型对应：`long` → `System.Int64`，`int` → `System.Int32`，`bool` → `System.Boolean`，`double` → `System.Double`，`string` → `System.String`。

## 5. 测试类的生命周期约定

`LeanCLRNode` 会按以下名字回调 C# 实例方法（存在才调用）：

| 时机 | C# 方法 |
|---|---|
| 节点入树、对象创建后 | `OnEnterTree()` |
| 节点 `_ready` | `OnReady()` |
| 每帧 | `OnProcess(float delta)` |
| 物理帧 | `OnPhysicsProcess(float delta)` |
| 节点退树 | `OnExitTree()` |

`LeanCLRNode` 还会在创建对象后自动调用：

| 方法 | 参数 | 用途 |
|---|---|---|
| `SetOwnerId(long)` | Godot `instance_id` | 让 C# 拿到宿主节点 ID |
| `SetTargetId(long)` | 由业务脚本注入 | 测试节点操作接口用 |

## 6. 新增 C# 测试方法的流程

1. 在 `demo_csharp/LeanClrGame.cs` 增加方法/字段。
2. 在 `demo_csharp` 目录编译。
3. 复制 DLL 到 `godot_project/bin/assemblies`。
4. 在 `godot_project/demo.gd` 通过 `call_managed` 或生命周期触发。
5. 运行 Godot 回归，见 `docs/04-run-and-regression.md`。

## 7. BCL 依赖注意

- 必须使用完整 mono-4.5 BCL 目录；缺失 `Mono.Security.dll` 等会导致 `System.dll` 引用链加载失败。
- 若使用 `dotnet build` 生成 netstandard2.0 程序集，必须把 `godot_project/bin/bcl/Facades/netstandard.dll` 复制到 `godot_project/bin/bcl/netstandard.dll`。
- 优先使用系统 .NET Framework csc，生成的原生 .NET Framework 程序集与 mono-4.5 BCL 更匹配。

## 8. SDK 版本与中间目录

- 仓库根 `global.json` 固定 .NET SDK `10.0.100`（`rollForward: latestFeature`），因此本机必须是 10.0.x；只有 9.x 时 `dotnet build` 会直接报 `A compatible .NET SDK was not found`。成因与安装方式见 `docs/11-ci.md` §4.2。
- `demo_csharp/*.csproj` 平铺在同一目录，默认会共享 `demo_csharp/obj/`。`BaseIntermediateOutputPath` 统一由 `demo_csharp/Directory.Build.props` 设为 `obj/$(MSBuildProjectName)/`，**不要写回单个 csproj**（会触发 MSB3539，并让所有项目继续共用一份 `project.assets.json`）；各项目只在自己的 csproj 里设 `IntermediateOutputPath = $(BaseIntermediateOutputPath)<变体>/`。
- 用 `HintPath` 引用另一个测试程序集时（例如 `LeanClrCycleA` ↔ `LeanClrCycleB`），若被引用方又反过来引用当前程序集的旧输出，需要给该引用加 `<Private>false</Private>` 与 `<FindDependencies>false</FindDependencies>`，否则 SDK 10 会在 `GenerateDepsFile` 因同名条目抛 MSB4018。