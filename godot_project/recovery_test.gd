extends Node

# 异常恢复路径隔离测试：只读写 res://recovery_tmp，不触碰 bin/assemblies 与 bin/bcl。
# 由 scripts/recovery_test.ps1 准备 recovery_tmp（含 pristine 基线副本）并负责备份/恢复。
const BCL_DIR := "res://bin/bcl"
const LIB_DIR := "res://recovery_tmp"

const GAME_DLL := "res://recovery_tmp/LeanClrGame.dll"
const EXT_DLL := "res://recovery_tmp/LeanClrExt.dll"
const EXT2_DLL := "res://recovery_tmp/LeanClrExt2.dll"

const GAME_BASE := "res://recovery_tmp/pristine/LeanClrGame.dll"
const EXT_BASE := "res://recovery_tmp/pristine/LeanClrExt.dll"
const EXT2_BASE := "res://recovery_tmp/pristine/LeanClrExt2.dll"


func install_file(source_res: String, target_res: String) -> bool:
	var err := DirAccess.copy_absolute(
		ProjectSettings.globalize_path(source_res),
		ProjectSettings.globalize_path(target_res))
	if err != OK:
		push_error("recovery copy failed: %s -> %s (%d)" % [source_res, target_res, err])
		return false
	return true


func write_garbage(target_res: String) -> bool:
	var file := FileAccess.open(ProjectSettings.globalize_path(target_res), FileAccess.WRITE)
	if file == null:
		push_error("recovery open for write failed: " + target_res)
		return false
	file.store_string("this is not a managed assembly")
	file.close()
	return true


func restore_pristine() -> void:
	install_file(GAME_BASE, GAME_DLL)
	install_file(EXT_BASE, EXT_DLL)
	install_file(EXT2_BASE, EXT2_DLL)


func new_runtime() -> LeanCLRRuntime:
	var runtime := LeanCLRRuntime.new()
	var dirs := PackedStringArray([
		ProjectSettings.globalize_path(BCL_DIR),
		ProjectSettings.globalize_path(LIB_DIR),
	])
	if not runtime.initialize(dirs):
		push_error("recovery initialize failed: " + runtime.get_last_error())
		return null
	return runtime


func load_all(runtime: LeanCLRRuntime) -> bool:
	for name in ["LeanClrGame", "LeanClrExt", "LeanClrExt2"]:
		if not runtime.load_assembly(name):
			push_error("recovery load " + name + " failed: " + runtime.get_last_error())
			return false
	return true


func joined(runtime: LeanCLRRuntime) -> String:
	var text := ""
	for name in runtime.get_loaded_assemblies():
		if text != "":
			text += ","
		text += name
	return text


# 恢复镜像后手动调用 reload_runtime()，验证状态可继续执行托管代码。
# create_object / invoke_method 只在“最后加载的程序集”里查类型，故用依赖链末端类。
func finish_case(runtime: LeanCLRRuntime, label: String, type_name: String, expected: String) -> void:
	restore_pristine()
	var recovered = runtime.reload_runtime()
	print("recovery ", label, " reload after restore = ", recovered, " error=", runtime.get_last_error())
	print("recovery ", label, " generation after recovery = ", runtime.get_generation())
	print("recovery ", label, " loaded after recovery = ", joined(runtime))
	var handle = runtime.create_object(type_name)
	var describe = runtime.invoke_method(handle, "Use", [])
	print("recovery ", label, " usable = ", describe == expected, " describe=", describe)
	runtime.shutdown()


# failed：单模块卸载成功、加载损坏镜像失败（无兜底）。
func case_failed() -> void:
	print("--- recovery case: failed ---")
	var runtime := new_runtime()
	if runtime == null:
		return
	if not load_all(runtime):
		runtime.shutdown()
		return
	write_garbage(EXT2_DLL)
	print("recovery failed returned = ", runtime.reload_assembly("LeanClrExt2", false))
	print("recovery failed mode = ", runtime.get_last_reload_mode())
	print("recovery failed error = ", runtime.get_last_error())
	finish_case(runtime, "failed", "ExtUser2", "ExtUser2->ExtUser->PlayerItem=42")


# fallback-failed：被引用程序集触发 fallback，但 reload_runtime() 读到损坏镜像而失败。
func case_fallback_failed() -> void:
	print("--- recovery case: fallback-failed ---")
	var runtime := new_runtime()
	if runtime == null:
		return
	if not runtime.load_assembly("LeanClrGame") or not runtime.load_assembly("LeanClrExt"):
		push_error("recovery fallback-failed load failed: " + runtime.get_last_error())
		runtime.shutdown()
		return
	runtime.set_hot_reload_on_unsafe("fallback")
	write_garbage(GAME_DLL)
	print("recovery fallback-failed returned = ", runtime.reload_assembly("LeanClrGame", false))
	print("recovery fallback-failed mode = ", runtime.get_last_reload_mode())
	print("recovery fallback-failed error = ", runtime.get_last_error())
	finish_case(runtime, "fallback-failed", "ExtUser", "ExtUser->PlayerItem=42")


# dependents-failed：整组卸载后加载损坏镜像失败，reload_runtime() 也无法恢复。
func case_dependents_failed() -> void:
	print("--- recovery case: dependents-failed ---")
	var runtime := new_runtime()
	if runtime == null:
		return
	if not load_all(runtime):
		runtime.shutdown()
		return
	write_garbage(EXT2_DLL)
	print("recovery dependents returned = ", runtime.reload_assembly("LeanClrGame", true))
	print("recovery dependents mode = ", runtime.get_last_reload_mode())
	print("recovery dependents error = ", runtime.get_last_error())
	finish_case(runtime, "dependents", "ExtUser2", "ExtUser2->ExtUser->PlayerItem=42")


# dependents-failed 的 recovered 变体尝试：有效镜像但内部程序集名错误。
# load_group 因 ModuleAlreadyLoaded 失败，reload_runtime() 重新加载时同样冲突，预期仍不可恢复。
func case_dependents_recovered_attempt() -> void:
	print("--- recovery case: dependents-failed (recovered attempt) ---")
	var runtime := new_runtime()
	if runtime == null:
		return
	if not load_all(runtime):
		runtime.shutdown()
		return
	install_file(GAME_BASE, EXT2_DLL)
	print("recovery dependents-recovered-attempt returned = ", runtime.reload_assembly("LeanClrGame", true))
	print("recovery dependents-recovered-attempt mode = ", runtime.get_last_reload_mode())
	print("recovery dependents-recovered-attempt error = ", runtime.get_last_error())
	finish_case(runtime, "dependents-recovered-attempt", "ExtUser2", "ExtUser2->ExtUser->PlayerItem=42")


func _ready() -> void:
	print("=== recovery isolated test ===")
	restore_pristine()
	case_failed()
	case_fallback_failed()
	case_dependents_failed()
	case_dependents_recovered_attempt()
	restore_pristine()
	print("=== recovery isolated test done ===")
	get_tree().quit(0)
