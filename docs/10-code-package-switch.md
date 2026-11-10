# 10 多代码包切换 demo（A / B）

一个可交互的演示：工程里预置基线 `LeanClrCodePkg`（v1），再从本地 HTTP 源下载 A、B 两份同 API 的程序集，点按钮即时切换到对应代码，界面直接显示当前版本、generation 与计算结果。

它不引入新的热更机制：仍然复用 `godot_project/code_pkg_updater.gd` 的 manifest 解析、内容哈希 DLL 下载、SHA 校验、固定名安装、`reload_runtime` 与健康检查回退。

## 1. 三套代码的差异

| 版本 | 来源 | `ComputeScore(10)` | 界面颜色 | 说明 |
|---|---|---|---|---|
| 基线 v1 | `godot_project/bin/assemblies`（随工程/PCK） | 10 | 灰 | 未安装覆盖包时的默认实现 |
| A | `out/packages/switch/a` | 30 | 橙 | `Feature = triple-score-a` |
| B | `out/packages/switch/b` | 40 | 青 | `Feature = quad-score-b` |

A/B 与 v1 的公开 API 完全一致（`GetVersion` / `GetAnswer` / `GetFeature` / `ComputeScore` / `Describe`），差异只在常量与方法体，符合「同签名热更」的约束。

## 2. 运行

```bat
:: 交互式：启动本地 HTTP 源 + Godot 窗口，点按钮切换
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\code_pkg_switch.ps1

:: 自动验证：CLI + MCP 双通道
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\code_pkg_switch.ps1 -Test
```

脚本做的事：

1. 用 `dotnet build -p:PkgVariant=<v1|a|b>` 编译三套程序集到 `out/tmp/code_pkg/<variant>`；
2. 生成 `out/packages/switch/{a,b,bad-sha}`：manifest 记录 `package_version`、文件名、大小与 sha256，DLL 以 `LeanClrCodePkg.<sha256 前 16 位>.dll` 命名；
3. 启动 `scripts/code_pkg_server.mjs`（root=`out/packages`，端口 18080）；
4. 交互模式运行 `res://code_pkg_switch.tscn`；`-Test` 模式以 `LEANCLR_SWITCH_TEST=1` 环境变量驱动场景自动跑完整序列并断言日志。

`bad-sha` 包故意把 manifest 里的 sha256 写成 A 的值、内容放 B 的 DLL，用于验证校验拒绝。

## 3. 为什么用本地 HTTP 源，而不是把包装进工程

- 复用现有链路：下载、哈希命名、暂存区、安装与 CDN 缓存头全部和线上一致，demo 不是在「模拟」热更。
- 换成远端只改一处：`godot_project/code_pkg_switch.gd` 里的 `BASE_URL`（当前 `http://127.0.0.1:18080/switch`），改成 CDN 前缀即可；服务端只需保持 `<base>/<a|b>/manifest.json` 与同名哈希 DLL 的目录结构。
- 若确实要内置离线包，可把 `out/packages/switch/*` 拷到 `godot_project/code_pkg_bundles/` 并让 `BASE_URL` 支持 `res://` 读取；但导出过滤需包含 `*.dll`，且会失去「下载后安装」这一层验证，因此默认不选。

## 4. 切换语义与正确性

- **SHA 校验**：沿用 updater 的 size + sha256 校验；校验失败时停在 `stage=verify`，不改状态、不 reload。
- **幂等**：切换前比较 `updater.installed_version()` 与目标版本；相同则直接返回 `skipped=true`，不重复下载/reload，generation 不变。
- **失败保持原版本**：下载或校验失败不触碰已安装目录；reload/健康检查失败由 updater 回滚到上一份 assemblies 并再次 reload。
- **旧句柄失效**：切换走 `reload_runtime`，旧对象句柄按既有规则报 `stale type identity`，`LeanCLRNode` 自动重绑到新对象。
- **回基线**：清除 `user://code_pkg` 覆盖（`reset_local_state`）后 `reload_runtime`，重新加载内置 v1，generation +1。

## 5. 自动断言（34 项 / 通道）

| 分组 | 关键断言 |
|---|---|
| 初始 | `switch initial version = v1`、`generation = 0`、`ComputeScore(10) = 10` |
| A | `switch a version = A`、`compute 10 = 30`、`feature = triple-score-a`、`generation delta = 1`、`state version = A`、`color = A`、`old handle stale = true` |
| A 的 manifest URL | `switch manifest url = http://127.0.0.1:18080/switch/a/manifest.json?v=0` |
| B | `switch b version = B`、`compute 10 = 40`、`feature = quad-score-b`、`generation delta = 1`、`state version = B`、`color = B` |
| B 的 manifest URL | `.../switch/b/manifest.json?v=A`（query 使用当前已安装版本） |
| 往返 A | `switch a2 version = A`、`generation delta = 1`、`compute 10 = 30` |
| 幂等 | `switch a3 skipped = true`、`generation delta = 0`、`version = A` |
| 坏包 | `switch bad rejected = true`、`error = sha256 mismatch`、`version kept = A`、`generation unchanged = true` |
| 回基线 | `switch baseline version = v1`、`generation delta = 1`、`override cleared = true`、`node version = v1` |

日志：`out/logs/code_pkg_switch_cli.log`、`out/logs/code_pkg_switch_mcp.log`。

## 6. Android 实测（MuMu x86_64）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\code_pkg_switch.ps1 -Android -Abi x86_64 -SkipBuild
```

脚本会：临时把主场景切到 `res://code_pkg_switch.tscn` 并导出 `out/android/LeanClrCodePkgSwitch-<abi>.apk` → `adb install -r` → `adb reverse tcp:18080 tcp:18080` → `pm clear` → 通过 `run-as` 写入 `user://switch_autotest.flag` → 启动 App → 抓取 logcat 断言 34 项。

- Android 无法注入环境变量，因此场景在 `_ready()` 中除了读取 `LEANCLR_SWITCH_TEST=1`，还会检测 `user://switch_autotest.flag`；两者触发的是同一套按钮处理函数与断言序列（等效触发）。
- 也可去掉 `-Android` 但保留场景导出后手工点击按钮：按钮布局为「切到基线 / 切到代码包 A / 切到代码包 B」，切换后界面会显示当前版本、generation、`ComputeScore(10)` 与不同颜色。
- 本机实测结果：`Android x86_64: 34/34 项通过`，日志 `out/logs/android_code_pkg_switch_x86_64.log`（含 A→B→A、幂等、坏哈希拒绝、回基线）。arm ABI 的同一条 updater 链路已由 `docs/09` §1.4 的 71 项用例覆盖，切换 demo 未在 arm 包上重复导出。

## 7. 与线上发布的差异

| 项目 | demo | 线上建议 |
|---|---|---|
| 包来源 | 本地 HTTP 源（`out/packages`） | CDN/对象存储 |
| manifest 缓存 | 服务端返回 `no-cache`；URL 带 `?v=<已装版本>` | 短 TTL 或 no-cache，必须能刷新 |
| DLL 缓存 | 内容哈希名 + `immutable` | 长 TTL + immutable |
| 版本回滚 | 保留上一份 assemblies 备份 | 保留最近 N 个版本，按 manifest 回退 |
