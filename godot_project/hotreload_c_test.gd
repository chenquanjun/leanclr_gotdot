extends Node

const ASSEMBLY_DLL := "res://bin/assemblies/LeanClrGame.dll"
const ASSEMBLY_PDB := "res://bin/assemblies/LeanClrGame.pdb"
const BASE_DLL := "res://hotreload_tmp/LeanClrGame.base.dll"
const BASE_PDB := "res://hotreload_tmp/LeanClrGame.base.pdb"
const HOT_DLL := "res://hotreload_tmp/LeanClrGame.hot.dll"
const HOT_PDB := "res://hotreload_tmp/LeanClrGame.hot.pdb"
const EXT_DLL := "res://hotreload_tmp/LeanClrExt.dll"
const EXT_DST := "res://bin/assemblies/LeanClrExt.dll"
const EXT2_DLL := "res://hotreload_tmp/LeanClrExt2.dll"
const EXT2_DST := "res://bin/assemblies/LeanClrExt2.dll"
const CYCLE_A_DLL := "res://hotreload_tmp/LeanClrCycleA.dll"
const CYCLE_A_DST := "res://bin/assemblies/LeanClrCycleA.dll"
const CYCLE_B_DLL := "res://hotreload_tmp/LeanClrCycleB.dll"
const CYCLE_B_DST := "res://bin/assemblies/LeanClrCycleB.dll"


func joined_assemblies(runtime: LeanCLRRuntime) -> String:
	var text := ""
	for name in runtime.get_loaded_assemblies():
		if text != "":
			text += ","
		text += name
	return text

func install_file(source_res: String, target_res: String) -> bool:
	var source := ProjectSettings.globalize_path(source_res)
	var target := ProjectSettings.globalize_path(target_res)
	var err := DirAccess.copy_absolute(source, target)
	if err != OK:
		push_error("copy failed: %s -> %s (%d)" % [source_res, target_res, err])
		return false
	return true


func restore_baseline() -> void:
	install_file(BASE_DLL, ASSEMBLY_DLL)
	if FileAccess.file_exists(BASE_PDB):
		install_file(BASE_PDB, ASSEMBLY_PDB)
	elif FileAccess.file_exists(ASSEMBLY_PDB):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ASSEMBLY_PDB))


func run_signature_variant(runtime: LeanCLRRuntime, variant_dir: String, label: String) -> void:
	# 上一变体若触发 signature-mismatch，运行时会从磁盘重载该变体；先换回基线并整运行时重置。
	install_file(HOT_DLL, ASSEMBLY_DLL)
	runtime.reload_runtime()
	install_file("res://hotreload_tmp/sig/" + variant_dir + "/LeanClrGame.dll", ASSEMBLY_DLL)
	print("sig ", label, " returned = ", runtime.reload_assembly("LeanClrGame", true))
	print("sig ", label, " mode = ", runtime.get_last_reload_mode())
	print("sig ", label, " error = ", runtime.get_last_error())


func _ready() -> void:
	print("=== stage C hot reload test ===")
	restore_baseline()
	var runtime := LeanCLRRuntime.new()
	var bcl_dir := ProjectSettings.globalize_path("res://bin/bcl")
	var assembly_dir := ProjectSettings.globalize_path("res://bin/assemblies")
	if not runtime.initialize(PackedStringArray([bcl_dir, assembly_dir])):
		push_error("initialize failed: " + runtime.get_last_error())
		return
	if not runtime.load_assembly("LeanClrGame"):
		push_error("load_assembly failed: " + runtime.get_last_error())
		return
	print("on_unsafe default = ", runtime.get_hot_reload_on_unsafe())

	# C4: a live node whose signal bindings must survive the module reload.
	var player := LeanCLRNode.new()
	player.managed_type = "PlayerController"
	player.managed_assembly = "LeanClrGame"
	player.runtime = runtime
	add_child(player)
	player.bind_signal_args("leanclr_signal_args", "OnHotSignal", 1)
	player.emit_leanclr_signal_args("pre-reload")
	print("node generation before reload = ", player.get_bound_generation())
	await get_tree().process_frame

	# C3: static fields to migrate.
	runtime.invoke_static("HotState", "SetCounter", [123])
	runtime.invoke_static("HotState", "SetTag", ["persist-me"])
	print("statics before reload: counter=", runtime.invoke_static("HotState", "GetCounter", []),
		", tag=", runtime.invoke_static("HotState", "GetTag", []))

	var old_handle := runtime.create_object("PlayerController")
	print("old object build = ", runtime.invoke_method(old_handle, "GetHotBuild", []))

	# C1/C2: install the hot build and unload/reload the assembly.
	if not install_file(HOT_DLL, ASSEMBLY_DLL):
		return
	install_file(HOT_PDB, ASSEMBLY_PDB)
	print("reload_assembly returned = ", runtime.reload_assembly("LeanClrGame"))
	print("reload mode = ", runtime.get_last_reload_mode())
	print("generation after reload = ", runtime.get_generation())
	print("reload last_error = ", runtime.get_last_error())

	# C2: old handle must fail with a stale type identity error.
	print("old handle Describe = ", runtime.invoke_method(old_handle, "Describe", []))
	print("old handle error = ", runtime.get_last_error())

	# C3: statics migrated by whitelist.
	print("statics after reload: counter=", runtime.invoke_static("HotState", "GetCounter", []),
		", tag=", runtime.invoke_static("HotState", "GetTag", []))

	# C1: new code is really loaded.
	var new_handle := runtime.create_object("PlayerController")
	print("new object handle = ", new_handle, " error=", runtime.get_last_error())
	print("new object build = ", runtime.invoke_method(new_handle, "GetHotBuild", []))
	print("new object Describe = ", runtime.invoke_method(new_handle, "Describe", []))

	# C4: node should rebind automatically on generation change.
	await get_tree().process_frame
	await get_tree().process_frame
	print("node generation after reload = ", player.get_bound_generation())
	print("node pending rebind = ", player.has_pending_rebind())
	player.emit_leanclr_signal_args("post-reload")
	await get_tree().process_frame

	# C5: cross-module reference from LeanClrExt.
	if not install_file(EXT_DLL, EXT_DST):
		return
	print("load LeanClrExt = ", runtime.load_assembly("LeanClrExt"), " error=", runtime.get_last_error())
	var ext_handle := runtime.create_object("ExtUser")
	print("ExtUser.Use() = ", runtime.invoke_method(ext_handle, "Use", []))

	var generation_before_reject := runtime.get_generation()
	runtime.set_hot_reload_on_unsafe("reject")
	print("reject mode = ", runtime.get_hot_reload_on_unsafe())
	print("reload_assembly (reject) returned = ", runtime.reload_assembly("LeanClrGame"))
	print("reject last_error = ", runtime.get_last_error())
	print("reject reload mode = ", runtime.get_last_reload_mode())
	print("generation unchanged = ", runtime.get_generation() == generation_before_reject)

	runtime.set_hot_reload_on_unsafe("fallback")
	print("fallback mode = ", runtime.get_hot_reload_on_unsafe())
	print("reload_assembly (fallback) returned = ", runtime.reload_assembly("LeanClrGame"))
	print("fallback reload mode = ", runtime.get_last_reload_mode())
	print("generation after fallback = ", runtime.get_generation())
	var ext_handle2 := runtime.create_object("ExtUser")
	print("ExtUser.Use() after fallback = ", runtime.invoke_method(ext_handle2, "Use", []))
	await get_tree().process_frame
	await get_tree().process_frame
	print("node generation after fallback = ", player.get_bound_generation())
	print("node pending rebind after fallback = ", player.has_pending_rebind())
	player.emit_leanclr_signal_args("post-fallback")
	await get_tree().process_frame

	# T1: 多模块依赖图热更（LeanClrGame <- LeanClrExt <- LeanClrExt2）。
	print("=== T1 multi-module dependency reload ===")
	if not install_file(EXT2_DLL, EXT2_DST):
		return
	print("load LeanClrExt2 = ", runtime.load_assembly("LeanClrExt2"), " error=", runtime.get_last_error())
	var order_before := joined_assemblies(runtime)
	print("dependents order before reload = ", order_before)
	var generation_before_dependents := runtime.get_generation()
	print("dependents reload returned = ", runtime.reload_assembly("LeanClrGame", true))
	print("dependents reload mode = ", runtime.get_last_reload_mode())
	print("dependents generation delta = ", runtime.get_generation() - generation_before_dependents)
	print("dependents loaded order = ", joined_assemblies(runtime))
	var ext2_handle := runtime.create_object("ExtUser2")
	print("ExtUser2.Use() after dependents reload = ", runtime.invoke_method(ext2_handle, "Use", []))

	# T1: 失败回滚（组内缺少镜像文件时不得改变任何状态）。
	print("=== T1 rollback on missing dependents file ===")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(EXT2_DST))
	var generation_before_abort := runtime.get_generation()
	var order_before_abort := joined_assemblies(runtime)
	print("aborted reload returned = ", runtime.reload_assembly("LeanClrGame", true))
	print("aborted reload mode = ", runtime.get_last_reload_mode())
	print("aborted reload error = ", runtime.get_last_error())
	print("aborted generation unchanged = ", runtime.get_generation() == generation_before_abort)
	print("aborted assemblies unchanged = ", joined_assemblies(runtime) == order_before_abort)
	if not install_file(EXT2_DLL, EXT2_DST):
		return

	# T1: 循环引用（LeanClrCycleA <-> LeanClrCycleB）。
	print("=== T1 circular dependency reload ===")
	if not install_file(CYCLE_A_DLL, CYCLE_A_DST):
		return
	if not install_file(CYCLE_B_DLL, CYCLE_B_DST):
		return
	print("load LeanClrCycleA = ", runtime.load_assembly("LeanClrCycleA"), " error=", runtime.get_last_error())
	print("load LeanClrCycleB = ", runtime.load_assembly("LeanClrCycleB"), " error=", runtime.get_last_error())
	print("cycle order before reload = ", joined_assemblies(runtime))
	print("cycle reload returned = ", runtime.reload_assembly("LeanClrCycleA", true))
	print("cycle reload mode = ", runtime.get_last_reload_mode())
	print("cycle loaded order = ", joined_assemblies(runtime))
	# last_module_ 是组内最后加载的 CycleB，经它调用 CycleA.Ping 验证双向引用已恢复。
	var ping_result: Variant = runtime.invoke_static("CycleB", "TouchA", [])
	print("CycleA.Ping = ", ping_result)
	print("CycleA.Ping error = ", runtime.get_last_error())

	# T2: 热更签名兼容校验，五个变体逐一验证。
	print("=== T2 signature compatibility ===")
	install_file(HOT_DLL, ASSEMBLY_DLL)
	print("sig baseline reset = ", runtime.reload_runtime())
	run_signature_variant(runtime, "SIG_PARAM_TYPE", "param type")
	run_signature_variant(runtime, "SIG_PARAM_COUNT", "param count")
	run_signature_variant(runtime, "SIG_RETURN", "return")
	run_signature_variant(runtime, "SIG_REMOVED", "removed")
	run_signature_variant(runtime, "SIG_ADDED", "added")
	install_file(HOT_DLL, ASSEMBLY_DLL)
	runtime.reload_runtime()

	# T3: 信号参数不再限制为 0..2，任意数量与引用句柄/null 均可转发。
	print("=== T3 arbitrary signal arguments ===")
	print("t3 rebind = ", player.rebind_managed_object())
	player.bind_signal("leanclr_signal", "OnSignal")
	player.bind_signal_args("leanclr_signal_args", "OnSignalArgs", 1)
	player.bind_signal_args("leanclr_signal_args2", "OnSignalArgs2", 2)
	player.bind_signal_args("leanclr_signal_mixed", "OnSignalMixed", 3)
	player.emit_leanclr_signal()
	await get_tree().process_frame
	player.emit_leanclr_signal_args("hello")
	await get_tree().process_frame
	player.emit_leanclr_signal_args2("hi", 9)
	await get_tree().process_frame
	var holder := runtime.create_object("PlayerController")
	var item_handle: Variant = runtime.invoke_method(holder, "GetItem", [])
	print("t3 item handle = ", item_handle)
	player.emit_leanclr_signal_mixed(item_handle, "sig3", 42)
	await get_tree().process_frame
	player.emit_leanclr_signal_mixed(null, "sig-null", 7)
	await get_tree().process_frame

	# T4: Godot 实例 <-> 托管对象双向映射。
	print("=== T4 Godot instance <-> managed object mapping ===")
	print("t4 node handle = ", player.get_object_handle())
	player.bind_signal("leanclr_signal_object", "OnSignalObject")
	player.emit_leanclr_signal_object(player, "sig-object")
	await get_tree().process_frame
	player.emit_leanclr_signal_object(null, "sig-null-object")
	await get_tree().process_frame

	# 显式绑定：普通 Node -> holder 的托管对象。
	var holder2 := runtime.create_object("PlayerController")
	var temp := Node.new()
	add_child(temp)
	print("t4 bind explicit = ", runtime.bind_godot_object(temp, holder2))
	print("t4 mapping count = ", runtime.get_object_mapping_count())
	player.emit_leanclr_signal_object(temp, "sig-bound")
	await get_tree().process_frame
	var self_result: Variant = runtime.invoke_method(holder2, "GetSelf", [])
	print("t4 return is object = ", typeof(self_result) == TYPE_OBJECT)
	print("t4 return same instance = ", self_result == temp)

	# 实例释放后映射自动清理，再传按 null 处理。
	var temp_ref: Variant = temp
	temp.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	print("t4 mapping count after free = ", runtime.get_object_mapping_count())
	player.emit_leanclr_signal_object(temp_ref, "sig-freed")
	await get_tree().process_frame

	# 未绑定实例必须明确报错，而不是隐式创建；错误需在同步调用后立即读取（下一帧 _process 会清空 last_error）。
	var unbound := Node.new()
	add_child(unbound)
	player.emit_leanclr_signal_object(unbound, "sig-unbound")
	print("t4 unbound error = ", runtime.get_last_error())
	await get_tree().process_frame
	unbound.queue_free()

	# 热更后显式映射失效；LeanCLRNode 自动重绑后仍可映射。
	var temp2 := Node.new()
	add_child(temp2)
	print("t4 rebind holder = ", runtime.bind_godot_object(temp2, holder2))
	print("t4 mapping count before reload = ", runtime.get_object_mapping_count())
	print("t4 unbind = ", runtime.unbind_godot_object(temp2))
	print("t4 mapping count after unbind = ", runtime.get_object_mapping_count())
	print("t4 bind again = ", runtime.bind_godot_object(temp2, holder2))
	print("t4 reload returned = ", runtime.reload_assembly("LeanClrGame", true))
	print("t4 reload mode = ", runtime.get_last_reload_mode())
	print("t4 mapping count after reload = ", runtime.get_object_mapping_count())
	await get_tree().process_frame
	await get_tree().process_frame
	print("t4 node generation after reload = ", player.get_bound_generation())
	player.emit_leanclr_signal_object(player, "sig-after-reload")
	await get_tree().process_frame
	player.emit_leanclr_signal_object(temp2, "sig-stale-instance")
	print("t4 stale instance error = ", runtime.get_last_error())
	await get_tree().process_frame
	temp2.queue_free()

	player.queue_free()
	await get_tree().process_frame
	runtime.shutdown()
	print("=== stage C hot reload test done ===")
