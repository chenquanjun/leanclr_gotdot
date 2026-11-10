# 任务清单：代码包热更新（桌面 → Android）

> 对应 `specs/code-pkg-android-hotupdate/spec.md`。按顺序执行，每步有明确产物与验证。

## [x] T1. 新增代码包 C# 程序集

- 创建 `demo_csharp/CodePkg.cs`：`CodePkgNative` + `CodePkgNode`（v1/v2 由 `PKG_V2` 切换）。
- 创建 `demo_csharp/LeanClrCodePkg.csproj`：`PkgVariant=v1|v2`，输出到 `godot_project/code_pkg_tmp/build/<variant>`。
- 验证：
  ```powershell
  dotnet build demo_csharp/LeanClrCodePkg.csproj -c Release -p:PkgVariant=v1
  dotnet build demo_csharp/LeanClrCodePkg.csproj -c Release -p:PkgVariant=v2
  ```
  两个 DLL 均生成。

## [x] T2. 实现下载/校验/安装/回退

- 创建 `godot_project/code_pkg_updater.gd`（`class_name CodePkgUpdater`）：
  - `setup` / `user_assemblies_dir` / `reset_local_state` / `installed_version`
  - `download_and_apply(base_url)`：manifest → 下载 → size+sha256 → 备份/安装 → `reload_runtime` → 类型探测 → 成功/回退。
- 创建 `godot_project/code_pkg_demo.gd`、`code_pkg.tscn`：
  - 三目录初始化、LeanCLRNode、HUD、`U` 应用、`C` 清除覆盖。
- 验证：本地起 `code_pkg_server.mjs` 后手动跑一次，HUD 从 v1 变 v2。

## [x] T3. 桌面自动化双通道

- 创建 `scripts/code_pkg_server.mjs`。
- 创建 `scripts/code_pkg_test.gd`、`code_pkg_test.tscn`：按 spec §6.1 输出断言行。
- 创建 `scripts/code_pkg_test.ps1`：构建 v1/v2、生成 good/bad-sha/broken-type 包、起服务、CLI/MCP 运行、断言。
- 验证：
  ```powershell
  powershell -ExecutionPolicy Bypass -File scripts/code_pkg_test.ps1 -Channel both
  ```
  CLI 与 MCP 均 PASS；日志 `build/godot_code_pkg_test.log`、`build/godot_code_pkg_test_mcp.log`。

## [x] T4. 一键演示脚本

- 创建 `scripts/code_pkg_demo.ps1`：构建 v1/v2 → 生成 good 包 → 起服务 → 启动 `res://code_pkg.tscn`。
- 验证：运行后按 `U`，HUD/日志出现 `applied version=v2`；按 `C` 回 v1。

## [x] T5. Android 原生库交叉编译

- 创建 `scripts/build_android_native.ps1`（NDK 28.2 + Ninja + `ANDROID_ABI=x86_64` / `ANDROID_PLATFORM=android-24`，Debug/Release）。
- 修改 `godot_project/bin/leanclr_godot.gdextension` 增加 android x86_64 条目。
- 产物：`godot_project/bin/android/x86_64/libleanclr_godot.so`、`libleanclr_godot.release.so`（Android 要求文件名以 `lib` 开头）。
- 验证：`llvm-readelf -h` 显示 `Machine: Advanced Micro Devices X86-64`；`nm -D` 含 `leanclr_godot_init`。
- 若失败：保存 `build/android_native_build.log`，记录首个错误与缺失项，转 T8 汇报。

## [x] T6. Android 导出与 MuMu 实测

- 修改 `godot_project/export_presets.cfg` 新增 Android 预设（x86_64，内置导出模板，include BCL/assemblies/so）。
- 创建 `scripts/code_pkg_android_test.ps1`：
  - 导出 APK → `adb install -r` → `adb reverse tcp:18080 tcp:18080` → 启动 → `adb logcat` 抓日志 → 断言 spec §6.2。
- 验证：`build/android_code_pkg.log` 含 user:// 路径、`resolve assembly via filesystem`、`applied version=v2`、`node rebound`。
- 实测：MuMu 12 / Android 12 / x86_64，`PASS (41/41 断言)`；期间修复 `reload_runtime()` 的 P/Invoke 重注册与 `Settings::shutdown()` 断言。

## [x] T7. 文档与提交

- 新增 `docs/09-code-package-hot-update.md`。
- 更新 `README.md`、`docs/04-run-and-regression.md`、`docs/08-limits-and-roadmap.md`。
- 提交：
  - `feat: add downloadable code package hot update with user:// override`
  - `docs: document code package layout and Android verification`
  - Android 实测随功能提交说明（MuMu x86_64 41/41）。

## [x] T8. 汇报

- 桌面 CLI/MCP 通过数量与日志路径。
- Android 实测结果（真实 adb/logcat 摘录）或缺失项与卡点。
- 演示入口与文件位置。
