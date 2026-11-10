# 验收清单：代码包热更新（桌面 → Android）

## 加载路径

- [x] 初始化目录顺序为 `[bin/bcl, user://code_pkg/assemblies, bin/assemblies]`，覆盖目录位于中间
- [x] 桌面日志出现 `[LeanCLR] resolve assembly via filesystem: ...\code_pkg\assemblies\LeanClrCodePkg.dll`
- [x] Android 日志出现 `pkg user dir = /data/data/org.godotengine.leanclrcodepkg/files/code_pkg/assemblies` 且该路径进入 `lib dir` 列表
- [x] 删除/重置覆盖目录后回退到内置 `bin/assemblies` 版本

## 代码包流程

- [x] `manifest.json` 校验 `package_version` / `assembly` / 文件 `size` / SHA-256
- [x] 校验失败（bad-sha）不安装、不 reload，`generation` 不变
- [x] 安装成功后 `reload_runtime()` 返回 true，`generation` +1
- [x] reload 后重新注册 P/Invoke（`native/src/leanclr_runtime.cpp` 中 `register_godot_bridge()`）
- [x] `Settings` 全局字符串随 `Runtime::shutdown()` 重置，Android Debug 不再 `SIGABRT`
- [x] 类型探测失败（broken-type）恢复 `backup/` 并再次 reload，`version_after` 为上一份版本

## 桌面验证

- [x] `scripts\code_pkg_test.ps1 -Channel both` CLI 42/42 断言通过
- [x] 同一脚本 MCP 42/42 断言通过
- [x] 日志：`build/godot_code_pkg_test.log`、`build/godot_code_pkg_test_mcp.log`

## Android 验证

- [x] Android x86_64 Debug 原生库构建成功，`.so` 以 `lib` 开头并写入 `.gdextension`
- [x] APK 含 `lib/x86_64/libleanclr_godot.so` 与 `INTERNET` 权限
- [x] `scripts\code_pkg_android_test.ps1` 可一键导出、安装、运行并断言
- [x] MuMu 12 / Android 12 / x86_64 实测 41/41 断言通过
- [x] logcat 真实包含 `applied version=v2 files=1 generation=0->1`、`node rebound: type=CodePkgNode`、坏 SHA 拒绝与回退
- [x] 日志：`build/android_code_pkg.log`

## 文档与脚本

- [x] 新增 `docs/09-code-package-hot-update.md`：包格式、可写路径、下载生效、失败回退、Android 实测与排障
- [x] `README.md` 增加代码包热更新用法、验证命令与文档索引
- [x] `docs/04-run-and-regression.md` 增加 §12 桌面 + Android 回归
- [x] `docs/08-limits-and-roadmap.md` 增加 §2.4 与平台覆盖更新
- [x] `AGENTS.md` §8 记录 `runtime/vm/settings.h/.cpp` 本地补丁
