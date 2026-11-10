#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace leanclr {
namespace metadata {
struct RtModuleDef;
struct RtTypeSig;
}
namespace vm {
struct FileData;
struct RtObject;
}
}

namespace godot {

class LeanCLRRuntime : public RefCounted {
    GDCLASS(LeanCLRRuntime, RefCounted)

public:
    struct HandleEntry {
        void *gc_handle = nullptr;
        std::string module_name;
        int64_t generation = 0;
    };

    struct StaleHandleInfo {
        std::string module_name;
        int64_t generation = 0;
    };

    // Godot 实例与托管对象 1:1 映射；句柄复用 object_handles_，映射存在期间托管对象保持存活。
    struct ObjectMappingEntry {
        int64_t handle = 0;
        std::string module_name;
        int64_t generation = 0;
    };

    struct StaticSnapshotEntry {
        std::string assembly_name;
        std::string type_name;
        std::string field_name;
        std::vector<uint8_t> bytes;
        bool valid = false;
        bool reference = false;
        void *keep_alive_handle = nullptr;
    };

    struct MethodSignature {
        std::string type_name;
        std::string method_name;
        std::string signature;
        int param_count = 0;
        bool is_static = false;
    };

    struct SignatureSnapshot {
        std::string assembly_name;
        std::vector<MethodSignature> methods;
    };

private:
    bool initialized_ = false;
    std::vector<std::string> lib_dirs_;
    std::vector<std::string> loaded_assemblies_;
    leanclr::metadata::RtModuleDef *last_module_ = nullptr;
    std::string last_error_;
    std::unordered_map<int64_t, HandleEntry> object_handles_;
    std::unordered_map<int64_t, StaleHandleInfo> stale_handles_;
    // key: ObjectID（uint64_t）；handle_mappings_ 为反向索引，用于把托管对象还原成 Godot 实例。
    std::unordered_map<uint64_t, ObjectMappingEntry> instance_mappings_;
    std::unordered_map<int64_t, uint64_t> handle_mappings_;
    std::vector<StaticSnapshotEntry> static_snapshots_;
    std::vector<SignatureSnapshot> signature_snapshots_;
    std::vector<void *> static_keepalive_handles_;
    int64_t next_handle_id_ = 1;
    int64_t generation_ = 0;
    std::string last_reload_mode_;
    std::string on_unsafe_mode_;

    void apply_settings();
    std::string get_on_unsafe_mode() const;
    leanclr::vm::RtObject *resolve_handle(int64_t handle_id, std::string &error);
    void invalidate_module_handles(const std::string &module_name);
    std::vector<std::pair<std::string, std::string>> load_static_whitelist(const std::string &assembly_name) const;
    void capture_static_snapshot(leanclr::metadata::RtModuleDef *module, const std::string &assembly_name);
    bool restore_static_snapshot(leanclr::metadata::RtModuleDef *module, const std::string &assembly_name, std::string &error);
    // 热更前快照方法签名，重载后比对；参数类型/数量、返回值或方法删除视为不兼容。
    void capture_signature_snapshot(leanclr::metadata::RtModuleDef *module, const std::string &assembly_name);
    void collect_signatures(leanclr::metadata::RtModuleDef *module, SignatureSnapshot &snapshot) const;
    bool compare_signature_snapshot(leanclr::metadata::RtModuleDef *module, const std::string &assembly_name, std::string &error) const;
    static std::string signature_type_name(const leanclr::metadata::RtTypeSig *sig);
    bool assembly_file_exists(const std::string &assembly_name) const;
    std::vector<std::string> collect_reload_group(const std::string &assembly_name) const;
    bool unload_group(const std::vector<std::string> &group, std::string &error);
    bool load_group(const std::vector<std::string> &group, std::string &error);
    bool reload_group(const std::string &assembly_name, std::vector<std::string> &unload_order, bool &recovered);
    // Godot 实例参数解析：LeanCLRNode 取当前句柄，其余查显式绑定表；未映射时报错而不是隐式创建。
    bool normalize_object_argument(const Variant &value, const leanclr::metadata::RtTypeSig *type, Variant &out, std::string &error);
    bool check_managed_argument_type(leanclr::vm::RtObject *object, const leanclr::metadata::RtTypeSig *type, std::string &error) const;
    // 已绑定映射且实例仍有效时把 int64 句柄还原成 Godot 实例，否则原样返回。
    Variant map_handle_to_godot_object(const Variant &value) const;
    // 清掉实例已释放或句柄已失效的映射。
    void sweep_object_mappings();

    static std::vector<std::string> *s_lib_dirs;
    static bool file_loader(const char *assembly_name, const char *extension, leanclr::vm::FileData &file_data);
    static void debugger_log(int32_t level, const uint16_t *category, size_t category_len, const uint16_t *message, size_t message_len);

protected:
    static void _bind_methods();

public:
    bool initialize(const PackedStringArray &lib_dirs);
    bool reload_runtime();
    // 单程序集热更：安全时卸载并重新加载，不安全时按 on_unsafe 策略回退或拒绝。
    // include_dependents=true 时先卸载所有引用方（及传递引用方），再按原加载顺序整体重载。
    bool reload_assembly(const String &name, bool include_dependents = false);
    PackedStringArray get_loaded_assemblies() const;
    String get_last_reload_mode() const;
    String get_hot_reload_on_unsafe() const;
    void set_hot_reload_on_unsafe(const String &mode);
    void shutdown();
    bool is_initialized() const;
    int64_t get_generation() const;
    bool load_assembly(const String &name);
    Variant invoke_static(const String &class_full_name, const String &method_name, const Array &args);
    int64_t create_object(const String &class_full_name);
    Variant invoke_method(int64_t handle, const String &method_name, const Array &args);
    bool has_method(int64_t handle, const String &method_name);
    Variant get_field(int64_t handle, const String &field_name);
    bool set_field(int64_t handle, const String &field_name, const Variant &value);
    void destroy_object(int64_t handle);
    // Godot 实例 <-> 托管对象显式绑定（1:1）；LeanCLRNode 无需绑定，转换时按当前句柄动态解析。
    bool bind_godot_object(const Variant &instance, int64_t handle);
    bool unbind_godot_object(const Variant &instance);
    int64_t get_object_mapping_count();
    String get_last_error() const;
};

}