extends Control
# 多代码包切换 demo：基线 / A / B 三个按钮，复用 code_pkg_updater.gd 的
# manifest + 内容哈希 DLL + reload_runtime 链路；不另起一套热更机制。

const ASSEMBLY := "LeanClrCodePkg"
const MANAGED_TYPE := "CodePkgNode"
const BASE_URL := "http://127.0.0.1:18080/switch"
const AUTOTEST_FLAG := "user://switch_autotest.flag"
const CodePkgUpdaterScript = preload("res://code_pkg_updater.gd")

const COLOR_V1 := Color(0.75, 0.75, 0.75)
const COLOR_A := Color(1.0, 0.55, 0.15)
const COLOR_B := Color(0.25, 0.8, 0.95)

var runtime: LeanCLRRuntime
var updater
var host: LeanCLRNode
var busy := false

var version_label: Label
var generation_label: Label
var score_label: Label
var status_label: Label
var a_button: Button
var b_button: Button
var baseline_button: Button


func _ready() -> void:
	_build_ui()
	var initialized: bool = await _initialize()
	if not initialized:
		return
	_refresh_ui("ready")
	# 桌面用环境变量，Android 无法注入环境变量，改用 user:// 标记文件等效触发。
	if OS.get_environment("LEANCLR_SWITCH_TEST") == "1" or FileAccess.file_exists(AUTOTEST_FLAG):
		_run_auto_test()


func _build_ui() -> void:
	var panel := VBoxContainer.new()
	panel.name = "Panel"
	panel.position = Vector2(48, 40)
	panel.custom_minimum_size = Vector2(560, 0)
	panel.add_theme_constant_override("separation", 12)
	add_child(panel)

	var title := Label.new()
	title.text = "多代码包切换 Demo（基线 / A / B）"
	title.add_theme_font_size_override("font_size", 26)
	panel.add_child(title)

	version_label = Label.new()
	version_label.add_theme_font_size_override("font_size", 22)
	panel.add_child(version_label)

	generation_label = Label.new()
	panel.add_theme_font_size_override("font_size", 18)
	panel.add_child(generation_label)

	score_label = Label.new()
	score_label.add_theme_font_size_override("font_size", 18)
	panel.add_child(score_label)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 12)
	panel.add_child(buttons)

	baseline_button = Button.new()
	baseline_button.text = "切到基线"
	baseline_button.custom_minimum_size = Vector2(160, 56)
	baseline_button.pressed.connect(_on_baseline_pressed)
	buttons.add_child(baseline_button)

	a_button = Button.new()
	a_button.text = "切到代码包 A"
	a_button.custom_minimum_size = Vector2(160, 56)
	a_button.pressed.connect(_on_a_pressed)
	buttons.add_child(a_button)

	b_button = Button.new()
	b_button.text = "切到代码包 B"
	b_button.custom_minimum_size = Vector2(160, 56)
	b_button.pressed.connect(_on_b_pressed)
	buttons.add_child(b_button)

	status_label = Label.new()
	status_label.add_theme_font_size_override("font_size", 16)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size = Vector2(560, 0)
	panel.add_child(status_label)


func _initialize() -> bool:
	runtime = LeanCLRRuntime.new()
	updater = CodePkgUpdaterScript.new()
	updater.name = "CodePkgUpdater"
	add_child(updater)
	updater.setup(runtime, ASSEMBLY, MANAGED_TYPE)
	updater.reset_local_state()
	# 与线上 CDN 一致：manifest 带版本 query，避免命中旧缓存。
	updater.manifest_query = "v={version}"

	var bcl_dir := ProjectSettings.globalize_path("res://bin/bcl")
	var bundled_dir := ProjectSettings.globalize_path("res://bin/assemblies")
	if not runtime.initialize(PackedStringArray([bcl_dir, updater.user_assemblies_dir(), bundled_dir])):
		_show_error("initialize failed: " + runtime.get_last_error())
		return false
	if not runtime.load_assembly(ASSEMBLY):
		_show_error("load_assembly failed: " + runtime.get_last_error())
		return false

	host = LeanCLRNode.new()
	host.name = "LeanCLRHost"
	host.managed_type = MANAGED_TYPE
	host.managed_assembly = ASSEMBLY
	host.runtime = runtime
	add_child(host)
	return true


func _on_a_pressed() -> void:
	await _switch_to("A")


func _on_b_pressed() -> void:
	await _switch_to("B")


func _on_baseline_pressed() -> void:
	await _switch_to_baseline()


func _switch_to(target: String) -> Dictionary:
	var result := {
		"ok": false,
		"skipped": false,
		"generation_delta": 0,
	}
	if busy:
		print("switch busy = true target=", target)
		return result
	busy = true
	_set_buttons_enabled(false)
	status_label.text = "正在切换到代码包 %s ..." % target

	var installed: String = updater.installed_version()
	if installed == target:
		print("switch skip target=", target, " installed=", installed)
		result["ok"] = true
		result["skipped"] = true
		status_label.text = "已在使用代码包 %s（幂等，未重复 reload）" % target
		busy = false
		_set_buttons_enabled(true)
		_refresh_ui("skip")
		return result

	var generation_before := runtime.get_generation()
	var applied: Dictionary = await updater.download_and_apply(BASE_URL + "/" + target.to_lower())
	var generation_delta := int(applied["generation_after"]) - generation_before
	result["ok"] = bool(applied["ok"])
	result["generation_delta"] = generation_delta
	print("switch apply target=", target, " ok=", applied["ok"], " stage=", applied["stage"],
		" version=", applied["version"], " generation_delta=", generation_delta)
	print("switch manifest url = ", applied["manifest_url"])
	if not applied["ok"]:
		print("switch apply error = ", applied["error"])
		status_label.text = "切换 %s 失败，保持版本 %s：%s" % [target, updater.installed_version(), applied["error"]]
	else:
		status_label.text = "已切换到代码包 %s" % target

	await get_tree().process_frame
	await get_tree().process_frame
	busy = false
	_set_buttons_enabled(true)
	_refresh_ui("switch")
	return result


func _switch_to_baseline() -> Dictionary:
	var result := {"ok": false, "skipped": false, "generation_delta": 0}
	if busy:
		return result
	busy = true
	_set_buttons_enabled(false)
	if updater.installed_version() == "" and not updater.has_override():
		print("switch baseline skip = true")
		result["ok"] = true
		result["skipped"] = true
		busy = false
		_set_buttons_enabled(true)
		_refresh_ui("skip")
		return result

	var generation_before := runtime.get_generation()
	updater.reset_local_state()
	var reload_ok := runtime.reload_runtime()
	var generation_delta := runtime.get_generation() - generation_before
	result["ok"] = reload_ok
	result["generation_delta"] = generation_delta
	print("switch baseline ok=", reload_ok, " generation_delta=", generation_delta)
	status_label.text = "已回到内置基线（清除 user:// 覆盖）" if reload_ok else "回到基线失败：" + runtime.get_last_error()
	await get_tree().process_frame
	await get_tree().process_frame
	busy = false
	_set_buttons_enabled(true)
	_refresh_ui("baseline")
	return result


func _refresh_ui(source: String) -> void:
	if host == null:
		return
	var version := str(host.call_managed("GetVersion", []))
	var generation := runtime.get_generation()
	var score := int(host.call_managed("ComputeScore", [10]))
	version_label.text = "当前生效版本：%s" % version
	version_label.add_theme_color_override("font_color", _version_color(version))
	generation_label.text = "generation：%d" % generation
	score_label.text = "ComputeScore(10)：%d" % score
	status_label.add_theme_color_override("font_color", Color.WHITE)
	if source != "skip":
		status_label.text = "状态已刷新（%s）" % source


func _version_color(version: String) -> Color:
	if version == "A":
		return COLOR_A
	if version == "B":
		return COLOR_B
	return COLOR_V1


func _version_color_name(version: String) -> String:
	if version == "A":
		return "A"
	if version == "B":
		return "B"
	return "baseline"


func _set_buttons_enabled(enabled: bool) -> void:
	baseline_button.disabled = not enabled
	a_button.disabled = not enabled
	b_button.disabled = not enabled


func _show_error(text: String) -> void:
	push_error(text)
	if status_label != null:
		status_label.text = text


func _run_auto_test() -> void:
	print("=== code pkg switch test ===")
	await get_tree().process_frame
	print("switch initial version = ", host.call_managed("GetVersion", []))
	print("switch initial generation = ", runtime.get_generation())
	print("switch initial compute 10 = ", host.call_managed("ComputeScore", [10]))
	var initial_handle := runtime.create_object(MANAGED_TYPE)

	var first_a := await _switch_to("A")
	print("switch a version = ", host.call_managed("GetVersion", []))
	print("switch a compute 10 = ", host.call_managed("ComputeScore", [10]))
	print("switch a feature = ", host.call_managed("GetFeature", []))
	print("switch a generation delta = ", first_a["generation_delta"])
	print("switch a state version = ", updater.installed_version())
	print("switch a color = ", _version_color_name(str(host.call_managed("GetVersion", []))))
	var stale: Variant = runtime.invoke_method(initial_handle, "GetVersion", [])
	print("switch a old handle stale = ", stale == null)

	var first_b := await _switch_to("B")
	print("switch b version = ", host.call_managed("GetVersion", []))
	print("switch b compute 10 = ", host.call_managed("ComputeScore", [10]))
	print("switch b generation delta = ", first_b["generation_delta"])
	print("switch b state version = ", updater.installed_version())
	print("switch b feature = ", host.call_managed("GetFeature", []))
	print("switch b color = ", _version_color_name(str(host.call_managed("GetVersion", []))))

	var second_a := await _switch_to("A")
	print("switch a2 version = ", host.call_managed("GetVersion", []))
	print("switch a2 node version = ", host.call_managed("GetVersion", []))
	print("switch a2 generation delta = ", second_a["generation_delta"])
	print("switch a2 compute 10 = ", host.call_managed("ComputeScore", [10]))

	var generation_before_repeat := runtime.get_generation()
	var repeat := await _switch_to("A")
	print("switch a3 skipped = ", repeat["skipped"])
	print("switch a3 generation delta = ", runtime.get_generation() - generation_before_repeat)
	print("switch a3 version = ", host.call_managed("GetVersion", []))

	var generation_before_bad := runtime.get_generation()
	var bad: Dictionary = await updater.download_and_apply(BASE_URL + "/bad-sha")
	print("switch bad rejected = ", not bad["ok"] and str(bad["stage"]) == "verify")
	print("switch bad error = ", bad["error"])
	print("switch bad version kept = ", updater.installed_version())
	print("switch bad generation unchanged = ", runtime.get_generation() == generation_before_bad)

	var baseline := await _switch_to_baseline()
	await get_tree().process_frame
	await get_tree().process_frame
	print("switch baseline version = ", host.call_managed("GetVersion", []))
	print("switch baseline generation delta = ", baseline["generation_delta"])
	print("switch baseline override cleared = ", not updater.has_override())
	print("switch baseline node version = ", host.call_managed("GetVersion", []))
	print("=== code pkg switch done ===")
	get_tree().quit()
