extends Node

const DLL_REL := "res://bin/assemblies/LeanClrGame.dll"
const HOT_DLL_REL := "res://hotreload_tmp/LeanClrGame.hot.dll"

func _install_hot_dll() -> bool:
	var src := ProjectSettings.globalize_path(HOT_DLL_REL)
	var data := FileAccess.get_file_as_bytes(src)
	if data.is_empty():
		push_error("[hotreload] read hot dll failed: " + src)
		return false
	var dst := ProjectSettings.globalize_path(DLL_REL)
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f == null:
		push_error("[hotreload] write dll failed: " + dst)
		return false
	f.store_buffer(data)
	f.close()
	return true

func _ready() -> void:
	var runtime := LeanCLRRuntime.new()
	var bcl_dir := ProjectSettings.globalize_path("res://bin/bcl")
	var assembly_dir := ProjectSettings.globalize_path("res://bin/assemblies")
	if not runtime.initialize(PackedStringArray([bcl_dir, assembly_dir])):
		push_error("[hotreload] initialize failed: " + runtime.get_last_error())
		get_tree().quit(1)
		return
	if not runtime.load_assembly("LeanClrGame"):
		push_error("[hotreload] load_assembly failed: " + runtime.get_last_error())
		get_tree().quit(1)
		return

	var old_handle := runtime.create_object("PlayerController")
	print("[hotreload] generation=", runtime.get_generation())
	print("[hotreload] before=", runtime.invoke_method(old_handle, "Describe", []))

	if not _install_hot_dll():
		get_tree().quit(1)
		return
	if not runtime.reload_runtime():
		push_error("[hotreload] reload_runtime failed: " + runtime.get_last_error())
		get_tree().quit(1)
		return
	print("[hotreload] generation after reload=", runtime.get_generation())
	print("[hotreload] old handle invoke=", runtime.invoke_method(old_handle, "Describe", []), " err=", runtime.get_last_error())
	print("[hotreload] old handle field=", runtime.get_field(old_handle, "score"), " err=", runtime.get_last_error())

	var new_handle := runtime.create_object("PlayerController")
	print("[hotreload] after=", runtime.invoke_method(new_handle, "Describe", []))
	runtime.shutdown()
	get_tree().quit(0)
