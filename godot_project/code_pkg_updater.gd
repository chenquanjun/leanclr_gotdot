extends Node
# 代码包更新器：下载 manifest + 程序集 -> 校验 -> 落到 user:// -> reload_runtime -> 健康检查。
# 失败时回退到上一份 assemblies 并再次 reload，避免运行时停留在坏包上。

const USER_ROOT := "user://code_pkg"
const ASSEMBLIES_DIR := "user://code_pkg/assemblies"
const DOWNLOAD_DIR := "user://code_pkg/download"
const BACKUP_DIR := "user://code_pkg/backup"
const STATE_FILE := "user://code_pkg/state.json"

var runtime: LeanCLRRuntime
var assembly_name := "LeanClrCodePkg"
var managed_type := "CodePkgNode"
# manifest 的缓存破除参数：留空表示沿用旧的无 query 行为。
# 支持 {version}（当前已安装版本）与 {timestamp}（毫秒时间戳）占位符。
var manifest_query := ""
# 未显式配置 manifest_query 时，是否自动拼 ?v={timestamp}。
var manifest_query_timestamp := false


func setup(p_runtime: LeanCLRRuntime, p_assembly := "LeanClrCodePkg", p_type := "CodePkgNode") -> void:
	runtime = p_runtime
	assembly_name = p_assembly
	managed_type = p_type
	_ensure_dirs()


func user_assemblies_dir() -> String:
	return ProjectSettings.globalize_path(ASSEMBLIES_DIR)


func reset_local_state() -> void:
	_remove_tree(ProjectSettings.globalize_path(USER_ROOT))
	_ensure_dirs()


func installed_version() -> String:
	var text := _read_text(STATE_FILE)
	if text == "":
		return ""
	var data: Variant = JSON.parse_string(text)
	if typeof(data) == TYPE_DICTIONARY and data.has("version"):
		return str(data["version"])
	return ""


func has_override() -> bool:
	return FileAccess.file_exists(ASSEMBLIES_DIR + "/" + assembly_name + ".dll")


func build_manifest_url(base_url: String) -> String:
	var url := base_url
	if not url.ends_with("/"):
		url += "/"
	url += "manifest.json"
	var query := manifest_query
	if query == "" and manifest_query_timestamp:
		query = "v={timestamp}"
	if query != "":
		var version: String = installed_version()
		query = query.replace("{version}", version if version != "" else "0")
		query = query.replace("{timestamp}", str(int(Time.get_unix_time_from_system() * 1000.0)))
		url += "?" + query.trim_prefix("?")
	return url


# 返回：
# {ok, stage, version, files, generation_before, generation_after,
#  rolled_back, version_after, error}
func download_and_apply(base_url: String) -> Dictionary:
	var result := {
		"ok": false,
		"stage": "manifest",
		"version": "",
		"files": 0,
		"generation_before": runtime.get_generation() if runtime != null else -1,
		"generation_after": -1,
		"rolled_back": false,
		"version_after": installed_version(),
		"error": "",
		"manifest_url": "",
		"file_name": "",
		"file_names": [],
		"installed_names": [],
	}
	if runtime == null:
		result["error"] = "runtime not set"
		return result

	var manifest_url := build_manifest_url(base_url)
	result["manifest_url"] = manifest_url
	var manifest_response := await _http_get_url(manifest_url)
	if not manifest_response["ok"]:
		result["error"] = "manifest download failed: " + str(manifest_response["error"])
		return result
	var parsed: Variant = JSON.parse_string(manifest_response["body"].get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		result["error"] = "manifest is not a JSON object"
		return result
	var manifest: Dictionary = parsed
	var version := str(manifest.get("package_version", ""))
	var files: Variant = manifest.get("files", [])
	if version == "" or typeof(files) != TYPE_ARRAY or files.is_empty():
		result["error"] = "manifest missing package_version/files"
		return result
	var manifest_assembly := str(manifest.get("assembly", assembly_name))
	if manifest_assembly != assembly_name:
		result["error"] = "manifest assembly mismatch: " + manifest_assembly
		return result
	result["version"] = version
	result["stage"] = "download"

	var staging := ProjectSettings.globalize_path(DOWNLOAD_DIR + "/" + version)
	_remove_tree(staging)
	if DirAccess.make_dir_recursive_absolute(staging) != OK:
		result["error"] = "cannot create staging dir: " + staging
		return result

	for item in files:
		if typeof(item) != TYPE_DICTIONARY:
			result["error"] = "invalid file entry"
			return result
		var file_entry: Dictionary = item
		var file_name := str(file_entry.get("name", ""))
		if file_name == "" or file_name.contains("/") or file_name.contains("\\"):
			result["error"] = "unsafe file name: " + file_name
			return result
		var download := await _http_get_join(base_url, file_name)
		if not download["ok"]:
			result["error"] = "download %s failed: %s" % [file_name, str(download["error"])]
			return result
		var target := staging + "/" + file_name
		var file := FileAccess.open(target, FileAccess.WRITE)
		if file == null:
			result["error"] = "cannot write " + target
			return result
		file.store_buffer(download["body"])
		file.close()

		result["stage"] = "verify"
		var expected_size := int(file_entry.get("size", -1))
		var expected_sha := str(file_entry.get("sha256", "")).to_lower()
		var actual_size := _file_size(target)
		if expected_size >= 0 and actual_size != expected_size:
			result["error"] = "size mismatch for %s: expected %d got %d" % [file_name, expected_size, actual_size]
			return result
		var actual_sha := FileAccess.get_sha256(target)
		if expected_sha != "" and actual_sha != expected_sha:
			result["error"] = "sha256 mismatch for %s: expected %s got %s" % [file_name, expected_sha, actual_sha]
			return result
		result["files"] = int(result["files"]) + 1
		result["file_names"].append(file_name)
		if result["file_name"] == "":
			result["file_name"] = file_name

	# 传输层用内容哈希名（CDN 可长缓存），安装时改回运行时解析所依赖的固定程序集名。
	var installed_names: Array[String] = []
	for file_entry in files:
		var source_name := str(file_entry.get("name", ""))
		var target_name := _fixed_install_name(source_name)
		if target_name != source_name:
			var from := staging + "/" + source_name
			var to := staging + "/" + target_name
			if FileAccess.file_exists(to):
				DirAccess.remove_absolute(to)
			var rename_err := DirAccess.rename_absolute(from, to)
			if rename_err != OK:
				_remove_tree(staging)
				result["error"] = "rename %s -> %s failed: %d" % [source_name, target_name, rename_err]
				return result
		installed_names.append(target_name)
	result["installed_names"] = installed_names

	result["stage"] = "install"
	var previous_state := _read_text(STATE_FILE)
	var assemblies := ProjectSettings.globalize_path(ASSEMBLIES_DIR)
	var backup := ProjectSettings.globalize_path(BACKUP_DIR)
	_remove_tree(backup)
	if DirAccess.dir_exists_absolute(assemblies):
		var backup_err := DirAccess.rename_absolute(assemblies, backup)
		if backup_err != OK:
			result["error"] = "backup existing assemblies failed: %d" % backup_err
			return result
	var install_err := DirAccess.rename_absolute(staging, assemblies)
	if install_err != OK:
		if DirAccess.dir_exists_absolute(backup):
			DirAccess.rename_absolute(backup, assemblies)
		result["error"] = "install staging failed: %d" % install_err
		return result
	# 安装成功后清空暂存区，避免旧版本的内容哈希 DLL 继续占用 user://。
	_clean_downloads()

	result["stage"] = "reload"
	var generation_before := runtime.get_generation()
	result["generation_before"] = generation_before
	var reload_ok := runtime.reload_runtime()
	var probe: Variant = null
	if reload_ok:
		probe = runtime.invoke_static(managed_type, "Describe", [])
	var health_ok := reload_ok and probe != null
	result["generation_after"] = runtime.get_generation()
	if health_ok:
		_write_state(version, base_url)
		result["ok"] = true
		result["stage"] = "done"
		result["version_after"] = version
		print("[codepkg] applied version=", version, " files=", result["files"],
			" generation=", generation_before, "->", runtime.get_generation(),
			" installed=", result["installed_names"])
		return result

	if reload_ok:
		result["error"] = "type probe failed for " + managed_type + ": " + runtime.get_last_error()
	else:
		result["error"] = "reload_runtime failed: " + runtime.get_last_error()
	result["stage"] = "reload"
	print("[codepkg] apply failed version=", version, " error=", result["error"], " rollback...")
	var rollback_error := _rollback(assemblies, backup, previous_state)
	result["rolled_back"] = rollback_error == ""
	if rollback_error != "":
		result["error"] += "; rollback failed: " + rollback_error
	result["version_after"] = installed_version()
	result["generation_after"] = runtime.get_generation()
	print("[codepkg] rollback done=", result["rolled_back"], " version_after=", result["version_after"],
		" generation=", result["generation_after"], " error=", result["error"])
	return result


func _rollback(assemblies: String, backup: String, previous_state: String) -> String:
	if DirAccess.dir_exists_absolute(assemblies):
		_remove_tree(assemblies)
	if DirAccess.dir_exists_absolute(backup):
		var err := DirAccess.rename_absolute(backup, assemblies)
		if err != OK:
			return "restore backup failed: %d" % err
	else:
		DirAccess.make_dir_recursive_absolute(assemblies)
	if previous_state == "":
		if FileAccess.file_exists(STATE_FILE):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(STATE_FILE))
	else:
		_write_raw(STATE_FILE, previous_state)
	if not runtime.reload_runtime():
		return "reload after rollback failed: " + runtime.get_last_error()
	return ""


func _http_get_join(base_url: String, name: String) -> Dictionary:
	var url := base_url
	if not url.ends_with("/"):
		url += "/"
	url += name
	return await _http_get_url(url)


func _http_get_url(url: String) -> Dictionary:
	print("[codepkg] GET ", url)
	var http := HTTPRequest.new()
	http.timeout = 20.0
	add_child(http)
	var err := http.request(url)
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": "request error %d url=%s" % [err, url], "body": PackedByteArray()}
	var response: Array = await http.request_completed
	http.queue_free()
	var result_code := int(response[0])
	var response_code := int(response[1])
	var body: PackedByteArray = response[3]
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": "result=%d http=%d url=%s" % [result_code, response_code, url], "body": body}
	if response_code < 200 or response_code >= 300:
		return {"ok": false, "error": "http %d url=%s" % [response_code, url], "body": body}
	return {"ok": true, "error": "", "body": body}


func _fixed_install_name(file_name: String) -> String:
	var prefix := assembly_name + "."
	var suffix := ".dll"
	if file_name.begins_with(prefix) and file_name.ends_with(suffix):
		var middle := file_name.substr(prefix.length(), file_name.length() - prefix.length() - suffix.length())
		if middle != "" and _is_hex(middle):
			return assembly_name + suffix
	return file_name


func _is_hex(text: String) -> bool:
	for i in text.length():
		if "0123456789abcdefABCDEF".find(text[i]) < 0:
			return false
	return true


func _clean_downloads() -> void:
	var root := ProjectSettings.globalize_path(DOWNLOAD_DIR)
	var dir := DirAccess.open(root)
	if dir == null:
		return
	for name in dir.get_directories():
		_remove_tree(root + "/" + name)
	for name in dir.get_files():
		DirAccess.remove_absolute(root + "/" + name)


func _ensure_dirs() -> void:
	for path in [USER_ROOT, ASSEMBLIES_DIR, DOWNLOAD_DIR]:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))


func _file_size(abs_path: String) -> int:
	var file := FileAccess.open(abs_path, FileAccess.READ)
	if file == null:
		return -1
	var size := file.get_length()
	file.close()
	return size


func _read_text(res_path: String) -> String:
	if not FileAccess.file_exists(res_path):
		return ""
	var file := FileAccess.open(res_path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func _write_state(version: String, source: String) -> void:
	var data := {
		"version": version,
		"assembly": assembly_name,
		"source": source,
		"installed_at": Time.get_datetime_string_from_system(true),
	}
	_write_raw(STATE_FILE, JSON.stringify(data, "  "))


func _write_raw(res_path: String, text: String) -> void:
	var file := FileAccess.open(res_path, FileAccess.WRITE)
	if file == null:
		push_error("cannot write " + res_path)
		return
	file.store_string(text)
	file.close()


func _remove_tree(abs_path: String) -> void:
	if not DirAccess.dir_exists_absolute(abs_path):
		if FileAccess.file_exists(abs_path):
			DirAccess.remove_absolute(abs_path)
		return
	var dir := DirAccess.open(abs_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var child := abs_path + "/" + entry
			if dir.current_is_dir():
				_remove_tree(child)
			else:
				DirAccess.remove_absolute(child)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(abs_path)
