# 代码包热更新（下载新程序集并执行新代码）Spec

## 1. 目标与边界

目标：在 Godot 4.5 + leanclr 工程中，实现一条与同进程 `reload_assembly` 不同的更新链路：

1. 运行时先执行 APK/工程内置的旧程序集（v1）。
2. 从本地 HTTP 源下载一份新的程序集包（manifest + DLL）。
3. 落到 `user://code_pkg/assemblies`（Android 唯一可写区），校验 SHA-256。
4. 调用 `LeanCLRRuntime.reload_runtime()` 重新初始化 VM，并按新的 `lib_dirs` 顺序重新解析程序集。
5. 新代码生效（版本号、返回值、行为均变化），旧对象句柄按既有规则失效，`LeanCLRNode` 依靠 generation 变化自动重绑。
6. 失败时回退到上一份可用包并再次 reload，不允许把运行时留在坏包上。

不在本次范围：增量补丁、代码签名、CDN、断点续传、AOT、修改 leanclr/godot-cpp 第三方源码。

## 2. 已确认的环境事实

- 本机 Godot：`.tools/godot45/Godot_v4.5-stable_win64_console.exe`。
- 导出模板：`%APPDATA%\Godot\export_templates\4.5.stable`，含 `android_debug.apk` / `android_release.apk`。
- Android SDK：`%LOCALAPPDATA%\Android\Sdk`（或 `ANDROID_HOME`），含 platforms、build-tools、NDK 与 `cmake\<version>\bin\ninja.exe`。
- JDK：`%ProgramFiles%\Microsoft\jdk-17.x`（任意 JDK 17）。
- MuMu：`<MuMu 安装目录>`，自带 adb 在 `nx_device\<version>\shell\adb.exe`；SDK adb 可连接 `127.0.0.1:16384` / `127.0.0.1:7555` / `emulator-5554`。
- MuMu ABI：`x86_64`（`ro.product.cpu.abi=x86_64`，Android 12）。
- 当前缺口：`godot_project/bin/leanclr_godot.gdextension` 无 Android 条目，`bin` 下无 Android `.so`。
- BCL：`godot_project/bin/bcl` 共 154 个 DLL（约 59 MB）；导出预设已用 `include_filter` 打入包内。

## 3. 加载路径设计（桌面与 Android 一致）

`LeanCLRRuntime.initialize(lib_dirs)` 传入：

```
[bcl_dir,
 globalize_path("user://code_pkg/assemblies"),
 bundled_assemblies_dir]
```

依据 `native/src/leanclr_runtime.cpp`：

- `file_loader` 按 `lib_dirs_` 顺序查找，先 Godot VFS（`res://`），再真实文件系统。
- `map_to_res_dir` 只映射 `res://` 与 `res root` 下路径；`user://` 的绝对路径不会被映射，因此走 `std::ifstream` 分支，桌面与 Android 都可读。
- `apply_settings` 以 `lib_dirs_.front()` 作为 data/config dir；`hotreload.statics.json` 以 `lib_dirs_.back()` 查找。故 user 覆盖目录必须放中间，bundled 目录保持最后。

生效机制选择 `reload_runtime()`，理由：

- 比重启场景/进程更可测、可在同一进程内断言 generation。
- 比 `reload_assembly` 更彻底：释放全部句柄、关闭 VM、重新初始化，再按 `loaded_assemblies_` 重新解析新包。
- `LeanCLRNode.check_generation()` 已内置自动重绑，代码包更新可直接复用。

## 4. 包格式与落盘布局

HTTP 目录结构：

```
<base_url>/manifest.json
<base_url>/<file>.dll
```

`manifest.json`：

```json
{
  "package_version": "v2",
  "assembly": "LeanClrCodePkg",
  "files": [
    { "name": "LeanClrCodePkg.dll", "size": 6656, "sha256": "<hex>" }
  ]
}
```

`user://` 布局：

```
user://code_pkg/
├── assemblies/           # 当前生效的覆盖包（下载后由 staging 重命名而来）
├── download/<version>/   # 下载与校验暂存区
├── backup/               # 安装前的上一份 assemblies（回退用）
└── state.json            # {version, assembly, source, installed_at}
```

流程：下载 manifest → 下载各文件到 staging → 校验 size + sha256 → `assemblies` 重命名为 `backup` → staging 重命名为 `assemblies` → `reload_runtime()` → `create_object(managed_type)` 健康检查 → 成功写 `state.json`。

失败回退：校验失败不安装、不 reload；reload 失败或类型探测失败时删除新 `assemblies`，把 `backup` 重命名回来并恢复旧 `state.json`，再次 `reload_runtime()`，返回 `rolled_back=true`。

## 5. 新增/修改文件清单

### 5.1 C# 程序集

- 新增 `demo_csharp/CodePkg.cs`
  - `CodePkgNative.print(string)` P/Invoke（`leanclr_godot.dll`）。
  - `public class CodePkgNode`
    - 构造：`CodePkgNative.print("[codepkg] CodePkgNode created version=...")`
    - `SetOwnerId(long)`、`OnEnterTree()`、`OnProcess(float)`
    - `GetVersion()`、`GetAnswer()`、`GetFeature()`、`ComputeScore(int)`、`GetOwnerId()`
    - v1（默认）：`version=v1`、`answer=11`、`feature=base-score`、`ComputeScore(n)=n`
    - v2（`PKG_V2`）：`version=v2`、`answer=22`、`feature=double-score`、`ComputeScore(n)=n*2`
- 新增 `demo_csharp/LeanClrCodePkg.csproj`
  - `AssemblyName=LeanClrCodePkg`，`PkgVariant` 默认 `v1`。
  - 输出 `../godot_project/code_pkg_tmp/build/$(PkgVariant)`。
  - `PKG_V2` 定义、独立 `obj/codepkg_$(PkgVariant)`。

### 5.2 Godot 侧

- 新增 `godot_project/code_pkg_updater.gd`（`class_name CodePkgUpdater extends Node`）
  - `setup(runtime, assembly_name="LeanClrCodePkg", managed_type="CodePkgNode")`
  - `user_assemblies_dir() -> String`
  - `reset_local_state()`：删除 `user://code_pkg` 并重建目录。
  - `installed_version() -> String`
  - `download_and_apply(base_url) -> Dictionary`（协程）：manifest → 下载 → 校验 → 安装 → `reload_runtime` → 类型探测 → 成功/回退；返回 `{ok, stage, version, files, generation_before, generation_after, rolled_back, version_after, error}`。
  - 内部：`_http_get_join`、`_remove_tree`、`_rollback`、`_write_state`、`_read_text`。
- 新增 `godot_project/code_pkg_demo.gd` + `code_pkg.tscn`（可演示）
  - 初始化三目录运行时，加载 `LeanClrCodePkg`，挂 `LeanCLRNode`。
  - HUD 显示版本/Answer/Feature/ComputeScore/generation/覆盖版本。
  - `U`：从 `--code-pkg-url=` 或默认 `http://127.0.0.1:18080/good` 下载并应用。
  - `C`：清除本地覆盖并 reload，回到内置 v1。
- 新增 `godot_project/code_pkg_test.gd` + `code_pkg_test.tscn`（自动化）
  - 开始先 `reset_local_state()`，保证从内置 v1 起步。
  - 断言 v1 基线、下载校验、user 路径加载日志、generation +1、旧句柄失效、v2 行为、节点重绑、坏 SHA 拒绝、坏类型回退。
- 修改 `godot_project/hotreload.statics.json`：本方案不依赖静态迁移，不改。

### 5.3 脚本

- 新增 `scripts/code_pkg_server.mjs`
  - 静态 HTTP 服务，默认 `127.0.0.1:18080`，`--root` 指定包目录，`--port` 可覆盖；支持 `application/json` 与 `.dll`。
- 新增 `scripts/code_pkg_test.ps1`
  - 参数 `-Channel cli|mcp|both`、`-SkipBuild`。
  - 构建 v1/v2；部署 v1 到 `bin/assemblies`；生成 `build/code_pkg_packages/{good,bad-sha,broken-type}` 与 manifest（`Get-FileHash` 计算 SHA-256）。
  - 启动 HTTP 服务；CLI 与 MCP 分别运行 `res://code_pkg_test.tscn`；按断言表判定；finally 停止服务。
- 新增 `scripts/code_pkg_demo.ps1`
  - 构建 v1 与 v2 包 → 生成 good 包 → 启动 HTTP 服务 → 启动 `res://code_pkg.tscn`（非 headless）→ 退出时停服务。
  - 参数 `-SkipBuild`、`-Url`（默认 `http://127.0.0.1:18080/good`）。

### 5.4 Android 构建与导出

- 修改 `godot_project/bin/leanclr_godot.gdextension`：新增
  - `android.debug.x86_64 = "res://bin/android/x86_64/leanclr_godot.so"`
  - `android.release.x86_64 = "res://bin/android/x86_64/leanclr_godot.release.so"`
- 新增 `scripts/build_android_native.ps1`
  - 使用 NDK 28.2 的 `android.toolchain.cmake`、Ninja、`ANDROID_ABI=x86_64`、`ANDROID_PLATFORM=android-24`，分别构建 Debug/Release。
  - 产物复制到 `godot_project/bin/android/x86_64/`。
- 修改 `godot_project/export_presets.cfg`：新增 Android 预设
  - `platform="Android"`，`architectures/x86_64=true`，`architectures/arm64-v8a=true`。
  - `include_filter` 保留 `bin/bcl/*.dll,bin/assemblies/*.dll,bin/android/x86_64/*.so`。
  - `exclude_filter` 增加 `code_pkg_tmp/*,code_pkg_android_tmp/*`。
  - `gradle_build/use_gradle_build=false`（直接用已安装的导出模板）。
- 新增 `scripts/code_pkg_android_test.ps1`
  - 导出 debug APK → `adb install -r` → `adb reverse tcp:18080 tcp:18080` → 启动 Activity → `adb logcat` 抓 `[codepkg]` / `[LeanCLR]` / `[hotreload]` → 断言与桌面相同的关键行；同时把关键日志写入 `build/android_code_pkg.log`。

### 5.5 文档

- `README.md`：新增「代码包热更新（下载新程序集）」小节：包布局、可写路径、下载与生效、回退、桌面/Android 命令。
- `docs/09-code-package-hot-update.md`（新增）：完整说明架构、加载优先级、包格式、失败回退、Android 包布局与 adb 流程、排障。
- `docs/04-run-and-regression.md`：追加 `code_pkg_test.ps1` 的 CLI/MCP 用法与日志名。
- `docs/08-limits-and-roadmap.md`：更新能力矩阵一行（代码包热更新已验证范围）。

## 6. 验证与断言

### 6.1 桌面 CLI + MCP（必须）

`scripts/code_pkg_test.ps1` 每个通道至少包含：

| 断言 | 期望输出 |
| --- | --- |
| 初始内置版本 | `pkg v1 version = v1` |
| v1 Answer | `pkg v1 answer 11 = true` |
| v1 行为 | `pkg v1 compute 10 = 10` |
| v1 Feature | `pkg v1 feature base = true` |
| 下载 manifest 版本 | `pkg manifest version = v2` |
| 文件校验 | `pkg verified files = 1` |
| 落到 user:// | `pkg user assembly exists = true` |
| 从 user 加载 | `resolve assembly via filesystem: .*LeanClrCodePkg\.dll` |
| reload 返回 | `pkg reload returned = true` |
| generation +1 | `pkg generation delta = 1` |
| 旧句柄失效 | `pkg old handle is null = true` |
| v2 版本 | `pkg v2 version = v2` |
| v2 Answer | `pkg v2 answer 22 = true` |
| v2 行为 | `pkg v2 compute 10 = 20` |
| v2 Feature | `pkg v2 feature double = true` |
| 节点重绑 | `pkg node rebound version = v2` / `bound generation = true` |
| 坏 SHA 拒绝 | `pkg bad sha rejected = true` |
| 拒绝后版本不变 | `pkg version after bad sha = v2` |
| 坏类型回退 | `pkg broken type rolled back = true` |
| 回退后版本 | `pkg version after rollback = v2` |
| 完成标记 | `=== code pkg test done ===` |

禁止项：`SCRIPT ERROR`、`LeanCLR[^\r\n]*failed`、`(?m)^ERROR:`。

### 6.2 Android（能实测则必须给真实日志）

1. 构建 x86_64 Android `.so` 并更新 `.gdextension`。
2. 导出 `build/android/LeanClrCodePkg.apk`。
3. `adb -s 127.0.0.1:16384 install -r <apk>`。
4. `adb -s 127.0.0.1:16384 reverse tcp:18080 tcp:18080`。
5. `adb shell am start -n org.godotengine.leanclr/.GodotApp`（包名以导出预设为准）。
6. `adb logcat -s godot:V` 或 `godot:V` 抓取日志，断言：
   - `[LeanCLR] lib dir=/data/user/0/<pkg>/files/code_pkg/assemblies`
   - `[LeanCLR] resolve assembly via filesystem: /data/user/0/<pkg>/files/code_pkg/assemblies/LeanClrCodePkg.dll`
   - `[codepkg] applied version=v2 generation=...`
   - `[hotreload] node rebound: type=CodePkgNode, generation=...`
7. 若原生交叉编译或运行失败：记录完整命令、错误原文、缺失组件，明确声明 Android 结论未达成，不得用桌面结果替代。

## 7. 风险与应对

- Android `.so` 交叉编译失败（leanclr POSIX 代码 / godot-cpp Android 配置）：先尝试仅构建 `leanclr_godot` Debug x86_64；失败则保留日志并汇报具体错误与缺失工具。
- MuMu 网络：优先 `adb reverse`；失败改用 `10.0.2.2:18080` 或宿主机局域网 IP。
- 坏包导致原生崩溃：先做 SHA 校验；回退测试使用「合法 PE 但类型不存在」的包，避免非法字节流触发解析崩溃。
- 文件被占用导致重命名失败：安装前先确保无活动句柄；Windows 下 leanclr 读文件后立即关闭，风险低；失败时报告并保留旧目录。

## 8. 验收标准

- 桌面 CLI 与 MCP 两个通道均通过全部断言，日志可复查。
- `user://` 覆盖目录确实被优先解析，日志可见。
- v1 → 下载 v2 → 新代码执行 → 旧句柄失效 → 节点重绑，全链路有输出。
- 坏 SHA 被拒绝；坏类型触发回退且版本恢复。
- Android 给出真实 adb/logcat 输出；若阻塞，给出缺失项、失败命令与卡点。
- README + docs 完成并提交。
