extends Node2D
# 可玩热更 demo 的 Godot 侧：只负责初始化运行时、挂托管对象、读输入、显示 HUD 和触发热更。
# 玩法逻辑（移动/计时/计分/失败判定）全部在 demo_csharp/GameDemo.cs 里。

const ASSEMBLY := "LeanClrGameDemo"
const DLL_RES := "res://bin/assemblies/LeanClrGameDemo.dll"
const POLL_INTERVAL := 0.25

var runtime: LeanCLRRuntime
var demo: LeanCLRNode
var info: Label
var notice: Label
var help: Label

var _dll_path := ""
var _last_signature := ""
var _pending_signature := ""
var _poll_timer := 0.0
var _notice_text := ""
var _notice_timer := 0.0


func _ready() -> void:
	info = $HUD/Info
	notice = $HUD/Notice
	help = $HUD/Help

	runtime = LeanCLRRuntime.new()
	var bcl_dir := ProjectSettings.globalize_path("res://bin/bcl")
	var assembly_dir := ProjectSettings.globalize_path("res://bin/assemblies")
	if not runtime.initialize(PackedStringArray([bcl_dir, assembly_dir])):
		push_error("LeanCLR initialize failed: " + runtime.get_last_error())
		return
	if not runtime.load_assembly(ASSEMBLY):
		push_error("LeanCLR load_assembly failed: " + runtime.get_last_error())
		return

	demo = LeanCLRNode.new()
	demo.name = "LeanCLRHost"
	demo.managed_type = "GameDemo"
	demo.managed_assembly = ASSEMBLY
	demo.runtime = runtime
	add_child(demo)
	demo.call_managed("Restart", [])

	_dll_path = ProjectSettings.globalize_path(DLL_RES)
	_last_signature = _dll_signature()
	print("[demo] ready build=", demo.call_managed("GetBuildTag", []),
		" generation=", runtime.get_generation(), " dll=", _dll_path)


func _process(delta: float) -> void:
	if demo == null:
		return
	var input := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	demo.call_managed("SetInput", [input.x, input.y])
	_update_hud(delta)
	_poll_hot_reload(delta)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.keycode == KEY_F5:
		_trigger_reload("F5")
	elif event.keycode == KEY_R:
		demo.call_managed("Restart", [])
		_show_notice("已重开")


func _update_hud(delta: float) -> void:
	# 热更成功后的当帧旧句柄已失效，LeanCLRNode 会在下一帧重绑；这里跳过一帧避免读空值。
	var raw_score: Variant = demo.call_managed("GetScore", [])
	if raw_score == null:
		info.text = "热更中，等待节点重绑..."
		return
	var build := str(demo.call_managed("GetBuildTag", []))
	var score := int(raw_score)
	var left := float(demo.call_managed("GetTimeLeft", []))
	var speed := float(demo.call_managed("GetSpeed", []))
	var state := int(demo.call_managed("GetState", []))
	info.text = "得分 %d    时间 %.1f    速度 %.0f    版本 %s    generation %d" % [
		score, left, speed, build, demo.get_bound_generation()
	]
	if state == 1:
		info.text += "    时间到！按 R 重开"

	if _notice_timer > 0.0:
		_notice_timer -= delta
		notice.text = _notice_text
	else:
		notice.text = ""


func _poll_hot_reload(delta: float) -> void:
	_poll_timer += delta
	if _poll_timer < POLL_INTERVAL:
		return
	_poll_timer = 0.0
	var signature := _dll_signature()
	if signature == "" or signature == _last_signature:
		return
	# 连续两次读到同一签名才触发，避免构建/复制过程中的半成品被加载。
	if signature == _pending_signature:
		_pending_signature = ""
		_last_signature = signature
		_trigger_reload("file-watch")
	else:
		_pending_signature = signature


func _trigger_reload(source: String) -> void:
	var before := runtime.get_generation()
	var ok := runtime.reload_assembly(ASSEMBLY, false)
	var mode := runtime.get_last_reload_mode()
	var error := runtime.get_last_error()
	print("[demo] reload source=", source, " returned=", ok, " mode=", mode,
		" generation=", before, "->", runtime.get_generation(), " error=", error)
	if ok:
		_show_notice("热更成功（%s）：%s，gen %d → %d" % [source, mode, before, runtime.get_generation()])
	else:
		_show_notice("热更失败（%s）：%s %s" % [source, mode, error])
	_last_signature = _dll_signature()
	_pending_signature = ""


func _show_notice(text: String) -> void:
	_notice_text = text
	_notice_timer = 4.0


func _dll_signature() -> String:
	var mtime := FileAccess.get_modified_time(_dll_path)
	var size := 0
	var file := FileAccess.open(_dll_path, FileAccess.READ)
	if file != null:
		size = file.get_length()
		file.close()
	return "%d:%d" % [mtime, size]
