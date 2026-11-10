extends Node
# 可玩 demo 的自动化验证：确定性驱动 C# 玩法逻辑，断言热更前后参数/行为变化、
# 旧句柄失效、静态进度迁移、节点自动重绑与其余基线不变。

const ASSEMBLY := "LeanClrGameDemo"
const ASSEMBLY_RES := "res://bin/assemblies/LeanClrGameDemo.dll"
const BASE_RES := "res://game_demo_tmp/LeanClrGameDemo.base.dll"
const HOT_RES := "res://game_demo_tmp/hot/LeanClrGameDemo.dll"


func install_file(source_res: String, target_res: String) -> bool:
	var source := ProjectSettings.globalize_path(source_res)
	var target := ProjectSettings.globalize_path(target_res)
	var err := DirAccess.copy_absolute(source, target)
	if err != OK:
		push_error("copy failed: %s -> %s (%d)" % [source_res, target_res, err])
		return false
	return true


func restore_base() -> void:
	install_file(BASE_RES, ASSEMBLY_RES)


func joined_assemblies(runtime: LeanCLRRuntime) -> String:
	var text := ""
	for name in runtime.get_loaded_assemblies():
		if text != "":
			text += ","
		text += name
	return text


func _ready() -> void:
	print("=== game demo hot reload test ===")
	restore_base()

	var runtime := LeanCLRRuntime.new()
	var bcl_dir := ProjectSettings.globalize_path("res://bin/bcl")
	var assembly_dir := ProjectSettings.globalize_path("res://bin/assemblies")
	if not runtime.initialize(PackedStringArray([bcl_dir, assembly_dir])):
		push_error("initialize failed: " + runtime.get_last_error())
		return
	if not runtime.load_assembly(ASSEMBLY):
		push_error("load_assembly failed: " + runtime.get_last_error())
		return
	print("demo loaded assemblies = ", joined_assemblies(runtime))

	var handle := runtime.create_object("GameDemo")
	if handle == 0:
		push_error("create_object failed: " + runtime.get_last_error())
		return

	# 1) v1 参数基线。
	print("demo v1 build tag = ", runtime.invoke_method(handle, "GetBuildTag", []))
	print("demo v1 speed 180 = ", float(runtime.invoke_method(handle, "GetSpeed", [])) == 180.0)
	print("demo v1 points 10 = ", int(runtime.invoke_method(handle, "GetPointsPerTarget", [])) == 10)
	print("demo v1 round 30 = ", float(runtime.invoke_method(handle, "GetRoundSeconds", [])) == 30.0)
	print("demo v1 radius 16 = ", float(runtime.invoke_method(handle, "GetTargetRadius", [])) == 16.0)

	# 2) v1 确定性移动：180 * 0.5s = 90。
	runtime.invoke_method(handle, "Restart", [])
	runtime.invoke_method(handle, "SetPlayerPosition", [320.0, 180.0])
	runtime.invoke_method(handle, "SetTargetPosition", [600.0, 300.0])
	runtime.invoke_method(handle, "SetInput", [1.0, 0.0])
	runtime.invoke_method(handle, "OnProcess", [0.5])
	print("demo v1 move 0.5s at 180 = ",
		abs(float(runtime.invoke_method(handle, "GetPlayerX", [])) - 410.0) < 0.01)

	# 3) v1 计分：把目标放到玩家位置上，一帧内命中 +10。
	runtime.invoke_method(handle, "SetInput", [0.0, 0.0])
	runtime.invoke_method(handle, "SetTargetPosition", [
		float(runtime.invoke_method(handle, "GetPlayerX", [])),
		float(runtime.invoke_method(handle, "GetPlayerY", []))
	])
	runtime.invoke_method(handle, "OnProcess", [0.016])
	print("demo v1 pickup +10 = ", int(runtime.invoke_method(handle, "GetScore", [])) == 10)

	# 4) v1 超时失败：时间归零后 state=over，再推进也不再移动。
	runtime.invoke_method(handle, "SetTimeLeft", [0.2])
	runtime.invoke_method(handle, "OnProcess", [1.0])
	print("demo v1 timeout state over = ", int(runtime.invoke_method(handle, "GetState", [])) == 1)
	print("demo v1 timeout zero = ", float(runtime.invoke_method(handle, "GetTimeLeft", [])) == 0.0)

	# 5) 重开复位。
	runtime.invoke_method(handle, "Restart", [])
	print("demo v1 restart resets = ",
		int(runtime.invoke_method(handle, "GetScore", [])) == 0 and
		int(runtime.invoke_method(handle, "GetState", [])) == 0 and
		float(runtime.invoke_method(handle, "GetTimeLeft", [])) == 30.0)

	# 6) 制造热更前进度：两次命中 = 20 分、2 次命中。
	runtime.invoke_method(handle, "SetInput", [0.0, 0.0])
	for i in 2:
		runtime.invoke_method(handle, "SetTargetPosition", [
			float(runtime.invoke_method(handle, "GetPlayerX", [])),
			float(runtime.invoke_method(handle, "GetPlayerY", []))
		])
		runtime.invoke_method(handle, "OnProcess", [0.016])
	print("demo score before reload = ", int(runtime.invoke_method(handle, "GetScore", [])))
	print("demo hits before reload = ", int(runtime.invoke_method(handle, "GetHits", [])))

	# 7) 安装 v2 并热更。
	if not install_file(HOT_RES, ASSEMBLY_RES):
		return
	var generation_before := runtime.get_generation()
	var assemblies_before := joined_assemblies(runtime)
	print("demo reload returned = ", runtime.reload_assembly(ASSEMBLY, false))
	print("demo reload mode = ", runtime.get_last_reload_mode())
	print("demo generation delta = ", runtime.get_generation() - generation_before)
	print("demo assemblies unchanged = ", joined_assemblies(runtime) == assemblies_before)

	# 8) 旧句柄按既有规则失效。
	var old_value: Variant = runtime.invoke_method(handle, "GetSpeed", [])
	print("demo old handle is null = ", old_value == null)
	print("demo old handle error = ", runtime.get_last_error())

	# 9) 新代码生效 + 静态进度保留。
	var new_handle := runtime.create_object("GameDemo")
	print("demo v2 speed 320 = ", float(runtime.invoke_method(new_handle, "GetSpeed", [])) == 320.0)
	print("demo v2 points 25 = ", int(runtime.invoke_method(new_handle, "GetPointsPerTarget", [])) == 25)
	print("demo v2 round 20 = ", float(runtime.invoke_method(new_handle, "GetRoundSeconds", [])) == 20.0)
	print("demo v2 radius 22 = ", float(runtime.invoke_method(new_handle, "GetTargetRadius", [])) == 22.0)
	print("demo static score kept = ", int(runtime.invoke_method(new_handle, "GetScore", [])))
	print("demo static hits kept = ", int(runtime.invoke_method(new_handle, "GetHits", [])))

	# 10) v2 行为变化：320 * 0.5s = 160，计时 20 - 0.5 = 19.5。
	runtime.invoke_method(new_handle, "Restart", [])
	runtime.invoke_method(new_handle, "SetPlayerPosition", [320.0, 180.0])
	runtime.invoke_method(new_handle, "SetTargetPosition", [600.0, 300.0])
	runtime.invoke_method(new_handle, "SetInput", [1.0, 0.0])
	runtime.invoke_method(new_handle, "OnProcess", [0.5])
	print("demo v2 move 0.5s at 320 = ",
		abs(float(runtime.invoke_method(new_handle, "GetPlayerX", [])) - 480.0) < 0.01)
	print("demo v2 time after step = ",
		abs(float(runtime.invoke_method(new_handle, "GetTimeLeft", [])) - 19.5) < 0.01)

	runtime.invoke_method(new_handle, "SetInput", [0.0, 0.0])
	runtime.invoke_method(new_handle, "SetTargetPosition", [
		float(runtime.invoke_method(new_handle, "GetPlayerX", [])),
		float(runtime.invoke_method(new_handle, "GetPlayerY", []))
	])
	runtime.invoke_method(new_handle, "OnProcess", [0.016])
	print("demo v2 pickup +25 = ", int(runtime.invoke_method(new_handle, "GetScore", [])) == 25)

	# 11) 真实 LeanCLRNode 节点：入树解析 Player/Target，热更后自动重绑。
	print("=== game demo node rebind ===")
	var player_node := Node2D.new()
	player_node.name = "Player"
	add_child(player_node)
	var target_node := Node2D.new()
	target_node.name = "Target"
	add_child(target_node)
	var host := LeanCLRNode.new()
	host.managed_type = "GameDemo"
	host.managed_assembly = ASSEMBLY
	host.runtime = runtime
	add_child(host)
	host.set_process(false)
	print("demo node created = ", host.get_object_handle() != 0)
	print("demo node resolved player = ",
		int(host.call_managed("GetPlayerNodeId", [])) == int(player_node.get_instance_id()))
	print("demo node resolved target = ",
		int(host.call_managed("GetTargetNodeId", [])) == int(target_node.get_instance_id()))
	print("demo node initial position = ",
		abs(player_node.position.x - float(host.call_managed("GetPlayerX", []))) < 0.01)

	# 12) 再换回 v1，验证节点在 generation 变化后自动重绑并继续驱动节点。
	if not install_file(BASE_RES, ASSEMBLY_RES):
		return
	var generation_before_back := runtime.get_generation()
	print("demo node reload returned = ", runtime.reload_assembly(ASSEMBLY, false))
	print("demo node reload mode = ", runtime.get_last_reload_mode())
	print("demo node reload generation delta = ", runtime.get_generation() - generation_before_back)
	host.set_process(true)
	await get_tree().process_frame
	await get_tree().process_frame
	print("demo node bound generation = ", host.get_bound_generation() == runtime.get_generation())
	print("demo node pending rebind = ", host.has_pending_rebind())
	print("demo node back to v1 speed = ", float(host.call_managed("GetSpeed", [])) == 180.0)
	print("demo node position after rebind = ",
		abs(player_node.position.x - float(host.call_managed("GetPlayerX", []))) < 0.01)

	host.queue_free()
	await get_tree().process_frame
	restore_base()
	runtime.shutdown()
	print("=== game demo hot reload test done ===")
