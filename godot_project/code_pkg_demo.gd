extends Node2D
# 代码包热更新演示：内置 v1 先运行；按 U 从本地 HTTP 下载 v2 包到 user://，
# 校验后 reload_runtime，由 LeanCLRNode 自动重绑并执行新代码；按 C 清除覆盖回到 v1。

const ASSEMBLY := "LeanClrCodePkg"
const MANAGED_TYPE := "CodePkgNode"
const DEFAULT_URL := "http://127.0.0.1:18080/good"
const CodePkgUpdaterScript = preload("res://code_pkg_updater.gd")

var runtime: LeanCLRRuntime
var updater
var host: LeanCLRNode
var info: Label
var notice: Label

var _notice_text := ""
var _notice_timer := 0.0
var _busy := false
var _base_url := DEFAULT_URL


func _ready() -> void:
	info = $HUD/Info
	notice = $HUD/Notice
	_base_url = _resolve_url()

	runtime = LeanCLRRuntime.new()
	updater = CodePkgUpdaterScript.new()
	updater.name = "CodePkgUpdater"
	add_child(updater)
	updater.setup(runtime, ASSEMBLY, MANAGED_TYPE)
	if "--code-pkg-reset" in OS.get_cmdline_user_args():
		updater.reset_local_state()

	var bcl_dir := ProjectSettings.globalize_path("res://bin/bcl")
	var bundled_dir := ProjectSettings.globalize_path("res://bin/assemblies")
	# 优先级：BCL -> user:// 覆盖目录 -> 内置/PCK 程序集。
	var lib_dirs := PackedStringArray([bcl_dir, updater.user_assemblies_dir(), bundled_dir])
	if not runtime.initialize(lib_dirs):
		push_error("LeanCLR initialize failed: " + runtime.get_last_error())
		return
	if not runtime.load_assembly(ASSEMBLY):
		push_error("LeanCLR load_assembly failed: " + runtime.get_last_error())
		return

	host = LeanCLRNode.new()
	host.name = "LeanCLRHost"
	host.managed_type = MANAGED_TYPE
	host.managed_assembly = ASSEMBLY
	host.runtime = runtime
	add_child(host)

	print("[codepkg-demo] ready version=", host.call_managed("GetVersion", []),
		" user_override=", updater.has_override(),
		" installed=", updater.installed_version(),
		" generation=", runtime.get_generation(),
		" url=", _base_url,
		" user_dir=", updater.user_assemblies_dir())
	_show_notice("U 下载并应用新包  |  C 清除覆盖回到内置版本")


func _process(delta: float) -> void:
	if host == null:
		return
	_update_hud(delta)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.keycode == KEY_U:
		_apply_package()
	elif event.keycode == KEY_C:
		_clear_package()


func _apply_package() -> void:
	if _busy:
		return
	_busy = true
	_show_notice("下载中：" + _base_url)
	print("[codepkg-demo] download start url=", _base_url)
	var result: Dictionary = await updater.download_and_apply(_base_url)
	print("[codepkg-demo] result ok=", result["ok"], " stage=", result["stage"],
		" version=", result["version"], " files=", result["files"],
		" generation=", result["generation_before"], "->", result["generation_after"],
		" rolled_back=", result["rolled_back"], " error=", result["error"])
	if result["ok"]:
		_show_notice("更新成功：%s，generation %d → %d" % [
			result["version"], result["generation_before"], result["generation_after"]
		])
	else:
		_show_notice("更新失败（%s）：%s" % [result["stage"], result["error"]])
	await get_tree().process_frame
	await get_tree().process_frame
	_busy = false


func _clear_package() -> void:
	if _busy:
		return
	_busy = true
	var before := runtime.get_generation()
	updater.reset_local_state()
	var ok := runtime.reload_runtime()
	print("[codepkg-demo] cleared override reload=", ok, " generation=", before, "->", runtime.get_generation())
	_show_notice("已清除本地代码包，回到内置版本" if ok else "清除失败：" + runtime.get_last_error())
	await get_tree().process_frame
	await get_tree().process_frame
	_busy = false


func _update_hud(delta: float) -> void:
	var version: Variant = host.call_managed("GetVersion", [])
	if version == null:
		info.text = "重载中，等待节点重绑..."
		return
	info.text = "版本 %s    Answer %d    特性 %s    ComputeScore(10)=%d    generation %d" % [
		str(version),
		int(host.call_managed("GetAnswer", [])),
		str(host.call_managed("GetFeature", [])),
		int(host.call_managed("ComputeScore", [10])),
		host.get_bound_generation(),
	]
	if updater.has_override():
		info.text += "    本地覆盖 %s" % updater.installed_version()

	if _notice_timer > 0.0:
		_notice_timer -= delta
		notice.text = _notice_text
	else:
		notice.text = "U 下载并应用  |  C 清除覆盖  |  服务：%s" % _base_url


func _resolve_url() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--code-pkg-url="):
			return arg.substr("--code-pkg-url=".length())
	return DEFAULT_URL


func _show_notice(text: String) -> void:
	_notice_text = text
	_notice_timer = 4.0
