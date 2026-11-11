# 07 故障排查

## 1. Godot 报 “Identifier "LeanCLRRuntime" not declared”

**原因**：`.godot/extension_list.cfg` 不存在，Godot 没有加载 GDExtension。

**处理**：

1. 先用编辑器模式导入一次：
   ```bat
   "./.tools/godot45/Godot_v4.5-stable_win64_console.exe" --headless --editor --path godot_project --quit-after 60
   ```
2. 确认 `godot_project/.godot/extension_list.cfg` 包含 `res://bin/leanclr_godot.gdextension`。
3. 再普通运行。

编辑器 headless 导入时报 `signal 11` 属已知现象，只要 `extension_list.cfg` 已生成即可。触发条件是「没有 `.godot` 的首次导入」，且崩溃发生在编辑器退出阶段，详见 `docs/11` §4.1。

## 2. GDExtension 加载失败 / 找不到 DLL

检查：

- `godot_project/bin/leanclr_godot.dll` 是否存在。
- `.gdextension` 中的 `entry_symbol = "leanclr_godot_init"` 与 DLL 导出一致。
- DLL 是否被其它进程占用（复制失败）。

用 dumpbin 检查导出：

```bat
MSYS_NO_PATHCONV=1 "<VS>/VC/Tools/MSVC/<ver>/bin/Hostx64/x64/dumpbin.exe" -exports out/build/windows/debug/Release/leanclr_godot.dll
```

## 3. 复制 DLL 报“拒绝访问”或命令卡住

**原因**：Godot 进程仍持有 DLL，或文件系统锁。

**处理**：

1. 结束 Godot：
   ```bat
   taskkill.exe //F //IM Godot_v4.5-stable_win64_console.exe //T
   ```
2. 删除旧 DLL，再复制新 DLL。
3. 不要直接覆盖被占用文件。

## 4. CMake 构建很慢或“卡死”

**原因**：

- godot-cpp 绑定每次被判定过期，触发全量重编 2000+ 文件。
- 输出经 `| tail` 管道缓冲，看不到进度。
- 后台执行被沙箱限流。

**处理**：

- 只改 `native/src` 时用 MSBuild 增量构建。
- 构建输出重定向到文件，再读日志。
- 清理残留进程：
  ```bat
  taskkill.exe //F //IM MSBuild.exe //T
  taskkill.exe //F //IM cmake.exe //T
  ```

## 5. csc 报“未能找到源文件”或“生成 Win32 资源时出错：拒绝访问”

**原因**：工作目录不对、路径被 MSYS 转换、目标目录被占用。

**处理**：

- 在 `demo_csharp` 目录执行 csc。
- 参数使用 `-` 风格（`-nologo`、`-target:library`）。
- 先输出到 `demo_csharp/LeanClrGame.dll`，再复制到工程目录。

## 6. csc 报“error CS1504: 源文件...未能打开”

现象：报错路径丢失了目录段（例如 `leanclr_gotdot\LeanClrGame.cs`）。

**处理**：切换工作目录到源文件所在目录，只传文件名。

## 7. 编译报 `error C2065: “Unit”: 未声明的标识符`

**原因**：`RET_VOID_OK()` 展开为 `Unit{}`，`Unit` 位于 `leanclr::core`。

**处理**：在全局命名空间的 invoker 中改为：

```cpp
return leanclr::core::Unit{};
```

## 8. C# 调用 P/Invoke 无效果 / 返回默认值

**原因**：注册名与 C# 方法签名不匹配。

**处理**：

- 检查程序集名是否为 `LeanClrGame`。
- 检查类与方法全名是否用 `::` 分隔。
- 检查参数类型内部名：`System.Int64`、`System.Double`、`System.Boolean`、`System.String`。
- 无参方法必须写成 `Method()`。
- 同时注册带模块名与不带模块名两种形式。

## 9. 加载 BCL 报引用链失败

现象：`Failed to load reference assembly System, error: 26`。

**原因**：BCL 部署不完整（缺 `Mono.Security.dll` 等）。

**处理**：复制完整 mono-4.5 BCL 目录到 `godot_project/bin/bcl`；netstandard2.0 程序集还需把 `Facades/netstandard.dll` 复制到 BCL 根目录。

## 10. 中文日志乱码

现象：`[LeanCLR][1][ä¸­æ] ...`。

**原因**：Windows 控制台按 GBK 解码 UTF-8。

**处理**：不影响功能；以英文/数字输出作为判定依据。

## 11. `LeanCLRNode create_object failed`

检查：

- `managed_type` 是否为完整类名（如 `PlayerController`）。
- `managed_assembly` 是否已加载（`LeanClrGame`）。
- BCL/程序集目录路径是否正确（`ProjectSettings.globalize_path("res://bin/...")`）。
- 查看紧随其后的 `get_last_error()` 文本。