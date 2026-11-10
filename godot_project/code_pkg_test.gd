extends Node
# 代码包热更新自动化验证：内置 v1 -> HTTP 下载 v2 -> user:// 覆盖 -> reload_runtime -> 新代码。
# 同时覆盖坏 SHA 拒绝与坏类型回退。

const ASSEMBLY := "LeanClrCodePkg"
const MANAGED_TYPE := "CodePkgNode"
const BASE_URL := "http://127.0.0.1:18080"
const CodePkgUpdaterScript = preload("res://code_pkg_updater.gd")

var runtime: LeanCLRRuntime
var updater
var host: LeanCLRNode
var handle := 0


func _ready() -> void:
	print("=== code pkg test ===")
	runtime = LeanCLRRuntime.new()
	updater = CodePkgUpdaterScript.new()
	updater.name = "CodePkgUpdater"
	add_child(updater)
	updater.setup(runtime, ASSEMBLY, MANAGED_TYPE)
	# 每次从“无本地覆盖”的干净状态开始。
	updater.reset_local_state()
	# manifest 使用版本号做缓存破除；留空则保持无 query 的旧行为。
	updater.manifest_query = "v={version}"
	print("pkg user dir = ", updater.user_assemblies_dir())

	var bcl_dir := ProjectSettings.globalize_path("res://bin/bcl")
	var bundled_dir := ProjectSettings.globalize_path("res://bin/assemblies")
	if not runtime.initialize(PackedStringArray([bcl_dir, updater.user_assemblies_dir(), bundled_dir])):
		push_error("initialize failed: " + runtime.get_last_error())
		return
	if not runtime.load_assembly(ASSEMBLY):
		push_error("load_assembly failed: " + runtime.get_last_error())
		return
	print("pkg loaded assemblies = ", _joined(runtime))
	print("pkg initial generation = ", runtime.get_generation())
	print("pkg initial override = ", updater.has_override())

	handle = runtime.create_object(MANAGED_TYPE)
	if handle == 0:
		push_error("create_object failed: " + runtime.get_last_error())
		return

	# 1) 内置 v1 基线。
	print("pkg v1 version = ", runtime.invoke_method(handle, "GetVersion", []))
	print("pkg v1 answer 11 = ", int(runtime.invoke_method(handle, "GetAnswer", [])) == 11)
	print("pkg v1 compute 10 = ", int(runtime.invoke_method(handle, "ComputeScore", [10])))
	print("pkg v1 feature base = ",
		str(runtime.invoke_method(handle, "GetFeature", [])) == "base-score")

	# 2) 真实 LeanCLRNode：初始绑定 v1。
	host = LeanCLRNode.new()
	host.name = "LeanCLRHost"
	host.managed_type = MANAGED_TYPE
	host.managed_assembly = ASSEMBLY
	host.runtime = runtime
	add_child(host)
	print("pkg node created = ", host.get_object_handle() != 0)
	print("pkg node v1 version = ", host.call_managed("GetVersion", []))
	print("pkg node bound generation = ", host.get_bound_generation() == runtime.get_generation())

	# 3) 下载并应用 v2。
	var v2_manifest_url: String = updater.build_manifest_url(BASE_URL + "/good")
	print("pkg v2 manifest url = ", v2_manifest_url)
	print("pkg v2 manifest url has query = ", v2_manifest_url.ends_with("/good/manifest.json?v=0"))
	var applied: Dictionary = await updater.download_and_apply(BASE_URL + "/good")
	print("pkg manifest version = ", applied["version"])
	print("pkg manifest file = ", applied["file_name"])
	print("pkg manifest file hashed = ", _is_hashed_name(str(applied["file_name"])))
	print("pkg verified files = ", applied["files"])
	print("pkg reload returned = ", applied["ok"])
	print("pkg reload stage = ", applied["stage"])
	print("pkg generation delta = ", int(applied["generation_after"]) - int(applied["generation_before"]))
	print("pkg user assembly exists = ", FileAccess.file_exists(updater.user_assemblies_dir() + "/" + ASSEMBLY + ".dll"))
	print("pkg installed names = ", _joined_array(applied["installed_names"]))
	print("pkg user dir files = ", _dir_files(updater.user_assemblies_dir()))
	print("pkg download dir empty = ", _dir_empty(ProjectSettings.globalize_path("user://code_pkg/download")))
	print("pkg installed state version = ", updater.installed_version())
	if not applied["ok"]:
		print("pkg apply error = ", applied["error"])

	# 4) 旧句柄失效，新对象执行 v2。
	var old_value: Variant = runtime.invoke_method(handle, "GetVersion", [])
	print("pkg old handle is null = ", old_value == null)
	print("pkg old handle error = ", runtime.get_last_error())
	var new_handle := runtime.create_object(MANAGED_TYPE)
	print("pkg v2 version = ", runtime.invoke_method(new_handle, "GetVersion", []))
	print("pkg v2 answer 22 = ", int(runtime.invoke_method(new_handle, "GetAnswer", [])) == 22)
	print("pkg v2 compute 10 = ", int(runtime.invoke_method(new_handle, "ComputeScore", [10])))
	print("pkg v2 feature double = ",
		str(runtime.invoke_method(new_handle, "GetFeature", [])) == "double-score")

	# 5) 节点在 generation 变化后自动重绑。
	await get_tree().process_frame
	await get_tree().process_frame
	print("pkg node rebound version = ", host.call_managed("GetVersion", []))
	print("pkg node rebound generation = ", host.get_bound_generation() == runtime.get_generation())
	print("pkg node pending rebind = ", host.has_pending_rebind())

	# 6) 下载 v3：内容变化 -> 哈希文件名变化；安装时改回固定名并清理旧包。
	var v3_manifest_url: String = updater.build_manifest_url(BASE_URL + "/good-v3")
	print("pkg v3 manifest url = ", v3_manifest_url)
	print("pkg v3 manifest url uses v2 = ", v3_manifest_url.ends_with("/good-v3/manifest.json?v=v2"))
	var applied_v3: Dictionary = await updater.download_and_apply(BASE_URL + "/good-v3")
	print("pkg v3 manifest version = ", applied_v3["version"])
	print("pkg v3 manifest file = ", applied_v3["file_name"])
	print("pkg v3 file name changed = ", str(applied_v3["file_name"]) != str(applied["file_name"]))
	print("pkg v3 manifest file hashed = ", _is_hashed_name(str(applied_v3["file_name"])))
	print("pkg v3 reload stage = ", applied_v3["stage"])
	print("pkg v3 generation delta = ", int(applied_v3["generation_after"]) - int(applied_v3["generation_before"]))
	print("pkg v3 installed state version = ", updater.installed_version())
	print("pkg v3 user dir files = ", _dir_files(updater.user_assemblies_dir()))
	print("pkg old v2 dll absent = ", not FileAccess.file_exists(updater.user_assemblies_dir() + "/" + str(applied["file_name"])))
	print("pkg old v2 download absent = ", not FileAccess.file_exists(
		ProjectSettings.globalize_path("user://code_pkg/download/v2/" + str(applied["file_name"]))))
	print("pkg download dir empty after v3 = ", _dir_empty(ProjectSettings.globalize_path("user://code_pkg/download")))
	var v3_handle := runtime.create_object(MANAGED_TYPE)
	print("pkg v3 version = ", runtime.invoke_method(v3_handle, "GetVersion", []))
	print("pkg v3 answer 33 = ", int(runtime.invoke_method(v3_handle, "GetAnswer", [])) == 33)
	print("pkg v3 compute 10 = ", int(runtime.invoke_method(v3_handle, "ComputeScore", [10])))
	print("pkg v3 feature triple = ",
		str(runtime.invoke_method(v3_handle, "GetFeature", [])) == "triple-score")
	await get_tree().process_frame
	await get_tree().process_frame
	print("pkg node v3 version = ", host.call_managed("GetVersion", []))
	print("pkg node v3 generation = ", host.get_bound_generation() == runtime.get_generation())

	# 7) 坏 SHA 包：拒绝安装，版本与 generation 不变。
	var gen_before_bad := runtime.get_generation()
	var bad: Dictionary = await updater.download_and_apply(BASE_URL + "/bad-sha")
	print("pkg bad sha rejected = ", not bad["ok"] and str(bad["stage"]) == "verify")
	print("pkg bad sha error = ", bad["error"])
	print("pkg version after bad sha = ", updater.installed_version())
	print("pkg generation after bad sha = ", runtime.get_generation() == gen_before_bad)

	# 8) 坏类型包：reload 后健康检查失败 -> 自动回退到上一份 v3。
	var gen_before_broken := runtime.get_generation()
	var broken: Dictionary = await updater.download_and_apply(BASE_URL + "/broken-type")
	print("pkg broken type rolled back = ", broken["rolled_back"])
	print("pkg broken type error = ", broken["error"])
	print("pkg version after rollback = ", broken["version_after"])
	print("pkg rolled back version matches = ", str(broken["version_after"]) == "v3")
	print("pkg rollback reloaded = ", int(broken["generation_after"]) > gen_before_broken)
	var after_rollback := runtime.create_object(MANAGED_TYPE)
	print("pkg after rollback version = ", runtime.invoke_method(after_rollback, "GetVersion", []))
	print("pkg after rollback compute 10 = ", int(runtime.invoke_method(after_rollback, "ComputeScore", [10])))

	# 9) 回退后节点再次重绑，仍执行 v3。
	await get_tree().process_frame
	await get_tree().process_frame
	print("pkg node after rollback version = ", host.call_managed("GetVersion", []))
	print("pkg node after rollback gen = ", host.get_bound_generation() == runtime.get_generation())

	host.queue_free()
	await get_tree().process_frame
	runtime.shutdown()
	print("=== code pkg test done ===")


func _joined(p_runtime: LeanCLRRuntime) -> String:
	var text := ""
	for name in p_runtime.get_loaded_assemblies():
		if text != "":
			text += ","
		text += name
	return text


func _joined_array(values: Variant) -> String:
	var text := ""
	for value in values:
		if text != "":
			text += ","
		text += str(value)
	return text


func _is_hashed_name(file_name: String) -> bool:
	var prefix := ASSEMBLY + "."
	if not file_name.begins_with(prefix) or not file_name.ends_with(".dll"):
		return false
	var middle := file_name.substr(prefix.length(), file_name.length() - prefix.length() - 4)
	if middle.length() != 16:
		return false
	for i in middle.length():
		if "0123456789abcdef".find(middle[i]) < 0:
			return false
	return true


func _dir_files(abs_path: String) -> String:
	var dir := DirAccess.open(abs_path)
	if dir == null:
		return ""
	var names := PackedStringArray()
	for name in dir.get_files():
		names.append(name)
	names.sort()
	return ",".join(names)


func _dir_empty(abs_path: String) -> bool:
	var dir := DirAccess.open(abs_path)
	if dir == null:
		return true
	return dir.get_files().is_empty() and dir.get_directories().is_empty()
