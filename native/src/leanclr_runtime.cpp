#include "leanclr_runtime.h"

#include "leanclr_node.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "vm/settings.h"
#include "vm/runtime.h"
#include "vm/assembly.h"
#include "vm/class.h"
#include "vm/method.h"
#include "vm/object.h"
#include "vm/gchandle.h"
#include "vm/field.h"
#include "vm/rt_string.h"
#include "metadata/module_def.h"
#include "metadata/rt_metadata.h"
#include "alloc/general_allocation.h"
#include "vm/pinvoke.h"
#include "metadata/metadata_cache.h"
#include "utils/rt_vector.h"
#include "public/leanclr.hpp"

#include <godot_cpp/classes/canvas_item.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/classes/packed_scene.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <cstring>
#include <algorithm>
#include <fstream>
#include <set>
#include <string>
#include <vector>

using namespace godot;

std::vector<std::string> *LeanCLRRuntime::s_lib_dirs = nullptr;

// res:// 在真实文件系统中的根目录，用于把绝对路径反查成虚拟路径。
static std::string g_res_root;
static bool g_logged_virtual_load = false;
static bool g_logged_fs_load = false;

static std::string utf16_to_utf8(const uint16_t *data, size_t length) {
    std::string out;
    out.reserve(length);
    for (size_t i = 0; i < length; ++i) {
        uint32_t cp = data[i];
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < length) {
            uint32_t lo = data[i + 1];
            if (lo >= 0xDC00 && lo <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                ++i;
            }
        }
        if (cp < 0x80) {
            out.push_back(static_cast<char>(cp));
        } else if (cp < 0x800) {
            out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }
    return out;
}

static std::string normalize_dir_path(const std::string &path) {
    std::string out = path;
    for (char &c : out) {
        if (c == '\\') {
            c = '/';
        }
    }
    while (!out.empty() && out.back() == '/') {
        out.pop_back();
    }
    return out;
}

static bool starts_with_ignore_case(const std::string &text, const std::string &prefix) {
    if (text.size() < prefix.size()) {
        return false;
    }
    for (size_t i = 0; i < prefix.size(); ++i) {
        char a = text[i];
        char b = prefix[i];
        if (a >= 'A' && a <= 'Z') {
            a = static_cast<char>(a - 'A' + 'a');
        }
        if (b >= 'A' && b <= 'Z') {
            b = static_cast<char>(b - 'A' + 'a');
        }
        if (a != b) {
            return false;
        }
    }
    return true;
}

static bool is_absolute_path(const std::string &path) {
    if (path.empty()) {
        return false;
    }
    if (path.front() == '/' || path.front() == '\\') {
        return true;
    }
    return path.size() >= 2 && path[1] == ':';
}

// 将文件系统目录映射到 res:// 虚拟路径；无法映射时返回空串。
static std::string map_to_res_dir(const std::string &dir) {
    std::string normalized = normalize_dir_path(dir);
    if (normalized.rfind("res://", 0) == 0) {
        return normalized;
    }
    if (!g_res_root.empty() && starts_with_ignore_case(normalized, g_res_root)) {
        std::string relative = normalized.substr(g_res_root.size());
        while (!relative.empty() && relative.front() == '/') {
            relative.erase(relative.begin());
        }
        return relative.empty() ? std::string("res://") : ("res://" + relative);
    }
    // 导出后的工程里 globalize_path("res://xxx") 只返回相对路径，此处按 res:// 处理。
    if (!is_absolute_path(normalized)) {
        return "res://" + normalized;
    }
    return std::string();
}

static bool read_file_via_godot(const std::string &res_path, leanclr::vm::FileData &file_data) {
    godot::Ref<godot::FileAccess> file = godot::FileAccess::open(godot::String(res_path.c_str()), godot::FileAccess::READ);
    if (file.is_null()) {
        return false;
    }
    uint64_t size = file->get_length();
    if (size == 0) {
        return false;
    }
    auto *data = static_cast<uint8_t *>(leanclr::alloc::GeneralAllocation::malloc(static_cast<size_t>(size)));
    if (data == nullptr) {
        return false;
    }
    if (file->get_buffer(data, size) != size) {
        leanclr::alloc::GeneralAllocation::free(data);
        return false;
    }
    file_data.data = data;
    file_data.length = static_cast<size_t>(size);
    file_data.shared = false;
    return true;
}

bool LeanCLRRuntime::file_loader(const char *assembly_name, const char *extension, leanclr::vm::FileData &file_data) {
    if (s_lib_dirs == nullptr) {
        return false;
    }
    for (const auto &dir : *s_lib_dirs) {
        // 1. 优先走 Godot 虚拟文件系统，导出为 PCK 后仍可读取 BCL 与程序集。
        std::string res_dir = map_to_res_dir(dir);
        if (!res_dir.empty()) {
            std::string res_path = res_dir + "/" + assembly_name + "." + extension;
            if (read_file_via_godot(res_path, file_data)) {
                if (!g_logged_virtual_load) {
                    g_logged_virtual_load = true;
                    godot::UtilityFunctions::print("[LeanCLR] resolve assembly via Godot VFS: ", godot::String(res_path.c_str()));
                }
                return true;
            }
        }
        // 2. 回退到真实文件系统（编辑器内运行或非 res:// 目录）。
        std::string path = normalize_dir_path(dir) + "/" + assembly_name + "." + extension;
        std::ifstream file(path, std::ios::binary | std::ios::ate);
        if (!file.is_open()) {
            continue;
        }
        std::streamsize size = file.tellg();
        if (size <= 0) {
            continue;
        }
        file.seekg(0, std::ios::beg);
        auto *data = static_cast<uint8_t *>(leanclr::alloc::GeneralAllocation::malloc(static_cast<size_t>(size)));
        if (data == nullptr) {
            return false;
        }
        if (!file.read(reinterpret_cast<char *>(data), size)) {
            leanclr::alloc::GeneralAllocation::free(data);
            continue;
        }
        file_data.data = data;
        file_data.length = static_cast<size_t>(size);
        file_data.shared = false;
        if (!g_logged_fs_load) {
            g_logged_fs_load = true;
            godot::UtilityFunctions::print("[LeanCLR] resolve assembly via filesystem: ", godot::String(path.c_str()));
        }
        return true;
    }
    return false;
}

void LeanCLRRuntime::debugger_log(int32_t level, const uint16_t *category, size_t category_len, const uint16_t *message, size_t message_len) {
    std::string cat = utf16_to_utf8(category, category_len);
    std::string msg = utf16_to_utf8(message, message_len);
    godot::UtilityFunctions::print("[LeanCLR][", level, "][", godot::String(cat.c_str()), "] ", godot::String(msg.c_str()));
}

static void godot_bridge_native_stub() {}

static leanclr::RtResultVoid godot_print_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    leanclr::vm::RtString *message = leanclr::RuntimeApi::get_argument<leanclr::vm::RtString *>(params, offset);
    if (message != nullptr) {
        std::string text = utf16_to_utf8(reinterpret_cast<const uint16_t *>(&message->first_char), static_cast<size_t>(message->length));
        godot::UtilityFunctions::print(godot::String(text.c_str()));
    }
    (void)ret;
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_get_ticks_msec_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    (void)params;
    leanclr::RuntimeApi::set_return_value<int64_t>(ret, static_cast<int64_t>(godot::Time::get_singleton()->get_ticks_msec()));
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_node_is_inside_tree_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    int64_t instance_id = leanclr::RuntimeApi::get_argument<int64_t>(params, offset);
    godot::Object *object = godot::ObjectDB::get_instance(static_cast<uint64_t>(instance_id));
    godot::Node *node = godot::Object::cast_to<godot::Node>(object);
    bool inside = node != nullptr && node->is_inside_tree();
    leanclr::RuntimeApi::set_return_value<bool>(ret, inside);
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_node_set_position_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    int64_t instance_id = leanclr::RuntimeApi::get_argument<int64_t>(params, offset);
    double x = leanclr::RuntimeApi::get_argument<double>(params, offset);
    double y = leanclr::RuntimeApi::get_argument<double>(params, offset);
    godot::Object *object = godot::ObjectDB::get_instance(static_cast<uint64_t>(instance_id));
    godot::Node2D *node = godot::Object::cast_to<godot::Node2D>(object);
    if (node != nullptr) {
        node->set_position(godot::Vector2(x, y));
    }
    (void)ret;
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_node_set_visible_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    int64_t instance_id = leanclr::RuntimeApi::get_argument<int64_t>(params, offset);
    bool visible = leanclr::RuntimeApi::get_argument<bool>(params, offset);
    godot::Object *object = godot::ObjectDB::get_instance(static_cast<uint64_t>(instance_id));
    godot::CanvasItem *item = godot::Object::cast_to<godot::CanvasItem>(object);
    if (item != nullptr) {
        item->set_visible(visible);
    }
    (void)ret;
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_node_get_visible_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    int64_t instance_id = leanclr::RuntimeApi::get_argument<int64_t>(params, offset);
    godot::Object *object = godot::ObjectDB::get_instance(static_cast<uint64_t>(instance_id));
    godot::CanvasItem *item = godot::Object::cast_to<godot::CanvasItem>(object);
    leanclr::RuntimeApi::set_return_value<bool>(ret, item != nullptr && item->is_visible());
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_node_get_position_x_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    int64_t instance_id = leanclr::RuntimeApi::get_argument<int64_t>(params, offset);
    godot::Object *object = godot::ObjectDB::get_instance(static_cast<uint64_t>(instance_id));
    godot::Node2D *node = godot::Object::cast_to<godot::Node2D>(object);
    leanclr::RuntimeApi::set_return_value<double>(ret, node != nullptr ? node->get_position().x : 0.0);
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_node_get_position_y_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    int64_t instance_id = leanclr::RuntimeApi::get_argument<int64_t>(params, offset);
    godot::Object *object = godot::ObjectDB::get_instance(static_cast<uint64_t>(instance_id));
    godot::Node2D *node = godot::Object::cast_to<godot::Node2D>(object);
    leanclr::RuntimeApi::set_return_value<double>(ret, node != nullptr ? node->get_position().y : 0.0);
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_node_get_child_count_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    int64_t instance_id = leanclr::RuntimeApi::get_argument<int64_t>(params, offset);
    godot::Object *object = godot::ObjectDB::get_instance(static_cast<uint64_t>(instance_id));
    godot::Node *node = godot::Object::cast_to<godot::Node>(object);
    leanclr::RuntimeApi::set_return_value<int64_t>(ret, node != nullptr ? static_cast<int64_t>(node->get_child_count()) : 0);
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_node_get_name_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    int64_t instance_id = leanclr::RuntimeApi::get_argument<int64_t>(params, offset);
    godot::Object *object = godot::ObjectDB::get_instance(static_cast<uint64_t>(instance_id));
    godot::Node *node = godot::Object::cast_to<godot::Node>(object);
    std::string text;
    if (node != nullptr) {
        godot::String name = node->get_name();
        godot::CharString name_u8 = name.utf8();
        text = name_u8.get_data();
    }
    leanclr::vm::RtString *result = leanclr::vm::String::create_string_from_utf8cstr(text.c_str());
    leanclr::RuntimeApi::set_return_value<leanclr::vm::RtString *>(ret, result);
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_node_get_parent_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    int64_t instance_id = leanclr::RuntimeApi::get_argument<int64_t>(params, offset);
    godot::Object *object = godot::ObjectDB::get_instance(static_cast<uint64_t>(instance_id));
    godot::Node *node = godot::Object::cast_to<godot::Node>(object);
    godot::Node *parent = node != nullptr ? node->get_parent() : nullptr;
    leanclr::RuntimeApi::set_return_value<int64_t>(ret, parent != nullptr ? static_cast<int64_t>(parent->get_instance_id()) : 0);
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_node_get_child_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    int64_t instance_id = leanclr::RuntimeApi::get_argument<int64_t>(params, offset);
    int32_t index = leanclr::RuntimeApi::get_argument<int32_t>(params, offset);
    godot::Object *object = godot::ObjectDB::get_instance(static_cast<uint64_t>(instance_id));
    godot::Node *node = godot::Object::cast_to<godot::Node>(object);
    godot::Node *child = nullptr;
    if (node != nullptr && index >= 0 && index < static_cast<int32_t>(node->get_child_count())) {
        child = node->get_child(index);
    }
    leanclr::RuntimeApi::set_return_value<int64_t>(ret, child != nullptr ? static_cast<int64_t>(child->get_instance_id()) : 0);
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_node_emit_signal_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    int64_t instance_id = leanclr::RuntimeApi::get_argument<int64_t>(params, offset);
    leanclr::vm::RtString *signal_name = leanclr::RuntimeApi::get_argument<leanclr::vm::RtString *>(params, offset);
    godot::Object *object = godot::ObjectDB::get_instance(static_cast<uint64_t>(instance_id));
    if (object != nullptr && signal_name != nullptr) {
        std::string name = utf16_to_utf8(reinterpret_cast<const uint16_t *>(&signal_name->first_char), static_cast<size_t>(signal_name->length));
        object->emit_signal(godot::StringName(name.c_str()));
    }
    (void)ret;
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_node_get_node_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    int64_t instance_id = leanclr::RuntimeApi::get_argument<int64_t>(params, offset);
    leanclr::vm::RtString *path = leanclr::RuntimeApi::get_argument<leanclr::vm::RtString *>(params, offset);
    godot::Object *object = godot::ObjectDB::get_instance(static_cast<uint64_t>(instance_id));
    godot::Node *node = godot::Object::cast_to<godot::Node>(object);
    godot::Node *target = nullptr;
    if (node != nullptr && path != nullptr) {
        std::string path_text = utf16_to_utf8(reinterpret_cast<const uint16_t *>(&path->first_char), static_cast<size_t>(path->length));
        target = node->get_node<godot::Node>(godot::NodePath(godot::String(path_text.c_str())));
    }
    leanclr::RuntimeApi::set_return_value<int64_t>(ret, target != nullptr ? static_cast<int64_t>(target->get_instance_id()) : 0);
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_instantiate_scene_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    leanclr::vm::RtString *path = leanclr::RuntimeApi::get_argument<leanclr::vm::RtString *>(params, offset);
    int64_t instance_id = 0;
    if (path != nullptr) {
        std::string path_text = utf16_to_utf8(reinterpret_cast<const uint16_t *>(&path->first_char), static_cast<size_t>(path->length));
        godot::Ref<godot::PackedScene> scene = godot::ResourceLoader::get_singleton()->load(godot::String(path_text.c_str()), "PackedScene");
        if (scene.is_valid()) {
            godot::Node *node = scene->instantiate();
            if (node != nullptr) {
                instance_id = static_cast<int64_t>(node->get_instance_id());
            }
        }
    }
    leanclr::RuntimeApi::set_return_value<int64_t>(ret, instance_id);
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_node_add_child_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    int64_t parent_id = leanclr::RuntimeApi::get_argument<int64_t>(params, offset);
    int64_t child_id = leanclr::RuntimeApi::get_argument<int64_t>(params, offset);
    godot::Node *parent = godot::Object::cast_to<godot::Node>(godot::ObjectDB::get_instance(static_cast<uint64_t>(parent_id)));
    godot::Node *child = godot::Object::cast_to<godot::Node>(godot::ObjectDB::get_instance(static_cast<uint64_t>(child_id)));
    if (parent != nullptr && child != nullptr) {
        parent->add_child(child);
    }
    (void)ret;
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_node_queue_free_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    int64_t instance_id = leanclr::RuntimeApi::get_argument<int64_t>(params, offset);
    godot::Node *node = godot::Object::cast_to<godot::Node>(godot::ObjectDB::get_instance(static_cast<uint64_t>(instance_id)));
    if (node != nullptr) {
        node->queue_free();
    }
    (void)ret;
    return leanclr::core::Unit{};
}

static std::unordered_map<int64_t, godot::Ref<godot::Resource>> g_resource_refs;

static leanclr::RtResultVoid godot_load_resource_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    leanclr::vm::RtString *path = leanclr::RuntimeApi::get_argument<leanclr::vm::RtString *>(params, offset);
    int64_t instance_id = 0;
    if (path != nullptr) {
        std::string path_text = utf16_to_utf8(reinterpret_cast<const uint16_t *>(&path->first_char), static_cast<size_t>(path->length));
        godot::Ref<godot::Resource> resource = godot::ResourceLoader::get_singleton()->load(godot::String(path_text.c_str()));
        if (resource.is_valid()) {
            instance_id = static_cast<int64_t>(resource->get_instance_id());
            g_resource_refs[instance_id] = resource;
        }
    }
    leanclr::RuntimeApi::set_return_value<int64_t>(ret, instance_id);
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_unload_resource_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    int64_t instance_id = leanclr::RuntimeApi::get_argument<int64_t>(params, offset);
    bool removed = g_resource_refs.erase(instance_id) > 0;
    leanclr::RuntimeApi::set_return_value<bool>(ret, removed);
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_resource_get_path_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    int64_t instance_id = leanclr::RuntimeApi::get_argument<int64_t>(params, offset);
    std::string text;
    auto it = g_resource_refs.find(instance_id);
    if (it != g_resource_refs.end()) {
        godot::String path = it->second->get_path();
        godot::CharString path_u8 = path.utf8();
        text = path_u8.get_data();
    }
    leanclr::vm::RtString *result = leanclr::vm::String::create_string_from_utf8cstr(text.c_str());
    leanclr::RuntimeApi::set_return_value<leanclr::vm::RtString *>(ret, result);
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_node_get_class_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    int64_t instance_id = leanclr::RuntimeApi::get_argument<int64_t>(params, offset);
    godot::Object *object = godot::ObjectDB::get_instance(static_cast<uint64_t>(instance_id));
    std::string text;
    if (object != nullptr) {
        godot::String class_name = object->get_class();
        godot::CharString class_u8 = class_name.utf8();
        text = class_u8.get_data();
    }
    leanclr::vm::RtString *result = leanclr::vm::String::create_string_from_utf8cstr(text.c_str());
    leanclr::RuntimeApi::set_return_value<leanclr::vm::RtString *>(ret, result);
    return leanclr::core::Unit{};
}

static leanclr::RtResultVoid godot_node_get_path_invoker(leanclr::metadata::RtManagedMethodPointer, const leanclr::metadata::RtMethodInfo *, const leanclr::interp::RtStackObject *params, leanclr::interp::RtStackObject *ret) {
    size_t offset = 0;
    int64_t instance_id = leanclr::RuntimeApi::get_argument<int64_t>(params, offset);
    godot::Node *node = godot::Object::cast_to<godot::Node>(godot::ObjectDB::get_instance(static_cast<uint64_t>(instance_id)));
    std::string text;
    if (node != nullptr) {
        godot::String path = node->get_path();
        godot::CharString path_u8 = path.utf8();
        text = path_u8.get_data();
    }
    leanclr::vm::RtString *result = leanclr::vm::String::create_string_from_utf8cstr(text.c_str());
    leanclr::RuntimeApi::set_return_value<leanclr::vm::RtString *>(ret, result);
    return leanclr::core::Unit{};
}

static void register_godot_bridge() {
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::print(System.String)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_print_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::print(System.String)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_print_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::get_ticks_msec()", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_get_ticks_msec_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::get_ticks_msec()", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_get_ticks_msec_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::node_is_inside_tree(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_is_inside_tree_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::node_is_inside_tree(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_is_inside_tree_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::node_set_position(System.Int64,System.Double,System.Double)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_set_position_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::node_set_position(System.Int64,System.Double,System.Double)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_set_position_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::node_set_visible(System.Int64,System.Boolean)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_set_visible_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::node_set_visible(System.Int64,System.Boolean)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_set_visible_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::node_get_visible(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_visible_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::node_get_visible(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_visible_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::node_get_position_x(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_position_x_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::node_get_position_x(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_position_x_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::node_get_position_y(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_position_y_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::node_get_position_y(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_position_y_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::node_get_child_count(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_child_count_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::node_get_child_count(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_child_count_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::node_get_name(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_name_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::node_get_name(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_name_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::node_get_parent(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_parent_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::node_get_parent(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_parent_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::node_get_child(System.Int64,System.Int32)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_child_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::node_get_child(System.Int64,System.Int32)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_child_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::node_emit_signal(System.Int64,System.String)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_emit_signal_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::node_emit_signal(System.Int64,System.String)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_emit_signal_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::node_get_node(System.Int64,System.String)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_node_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::node_get_node(System.Int64,System.String)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_node_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::instantiate_scene(System.String)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_instantiate_scene_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::instantiate_scene(System.String)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_instantiate_scene_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::node_add_child(System.Int64,System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_add_child_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::node_add_child(System.Int64,System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_add_child_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::node_queue_free(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_queue_free_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::node_queue_free(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_queue_free_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::load_resource(System.String)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_load_resource_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::load_resource(System.String)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_load_resource_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::unload_resource(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_unload_resource_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::unload_resource(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_unload_resource_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::resource_get_path(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_resource_get_path_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::resource_get_path(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_resource_get_path_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::node_get_class(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_class_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::node_get_class(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_class_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("[LeanClrGame]GodotNative::node_get_path(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_path_invoker);
    leanclr::RuntimeApi::register_pinvoke_func("GodotNative::node_get_path(System.Int64)", (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub, godot_node_get_path_invoker);
}

void LeanCLRRuntime::_bind_methods() {
    ClassDB::bind_method(D_METHOD("initialize", "lib_dirs"), &LeanCLRRuntime::initialize);
    ClassDB::bind_method(D_METHOD("shutdown"), &LeanCLRRuntime::shutdown);
    ClassDB::bind_method(D_METHOD("reload_runtime"), &LeanCLRRuntime::reload_runtime);
    ClassDB::bind_method(D_METHOD("reload_assembly", "name", "include_dependents"), &LeanCLRRuntime::reload_assembly, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("get_loaded_assemblies"), &LeanCLRRuntime::get_loaded_assemblies);
    ClassDB::bind_method(D_METHOD("get_last_reload_mode"), &LeanCLRRuntime::get_last_reload_mode);
    ClassDB::bind_method(D_METHOD("get_hot_reload_on_unsafe"), &LeanCLRRuntime::get_hot_reload_on_unsafe);
    ClassDB::bind_method(D_METHOD("set_hot_reload_on_unsafe", "mode"), &LeanCLRRuntime::set_hot_reload_on_unsafe);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "hot_reload_on_unsafe", PROPERTY_HINT_ENUM, "fallback,reject"),
                 "set_hot_reload_on_unsafe", "get_hot_reload_on_unsafe");
    ClassDB::bind_method(D_METHOD("get_generation"), &LeanCLRRuntime::get_generation);
    ClassDB::bind_method(D_METHOD("is_initialized"), &LeanCLRRuntime::is_initialized);
    ClassDB::bind_method(D_METHOD("load_assembly", "name"), &LeanCLRRuntime::load_assembly);
    ClassDB::bind_method(D_METHOD("invoke_static", "class_full_name", "method_name", "args"), &LeanCLRRuntime::invoke_static);
    ClassDB::bind_method(D_METHOD("create_object", "class_full_name"), &LeanCLRRuntime::create_object);
    ClassDB::bind_method(D_METHOD("invoke_method", "handle", "method_name", "args"), &LeanCLRRuntime::invoke_method);
    ClassDB::bind_method(D_METHOD("has_method", "handle", "method_name"), &LeanCLRRuntime::has_method);
    ClassDB::bind_method(D_METHOD("get_field", "handle", "field_name"), &LeanCLRRuntime::get_field);
    ClassDB::bind_method(D_METHOD("set_field", "handle", "field_name", "value"), &LeanCLRRuntime::set_field);
    ClassDB::bind_method(D_METHOD("destroy_object", "handle"), &LeanCLRRuntime::destroy_object);
    ClassDB::bind_method(D_METHOD("bind_godot_object", "instance", "handle"), &LeanCLRRuntime::bind_godot_object);
    ClassDB::bind_method(D_METHOD("unbind_godot_object", "instance"), &LeanCLRRuntime::unbind_godot_object);
    ClassDB::bind_method(D_METHOD("get_object_mapping_count"), &LeanCLRRuntime::get_object_mapping_count);
    ClassDB::bind_method(D_METHOD("get_last_error"), &LeanCLRRuntime::get_last_error);
}

void LeanCLRRuntime::apply_settings() {
    s_lib_dirs = &lib_dirs_;
    g_res_root.clear();
    g_logged_virtual_load = false;
    g_logged_fs_load = false;
    if (godot::ProjectSettings::get_singleton() != nullptr) {
        godot::String res_root = godot::ProjectSettings::get_singleton()->globalize_path("res://");
        godot::CharString res_root_u8 = res_root.utf8();
        g_res_root = normalize_dir_path(res_root_u8.get_data());
    }
    leanclr::vm::Settings::set_file_loader(&LeanCLRRuntime::file_loader);
    leanclr::vm::Settings::set_debugger_log_function(&LeanCLRRuntime::debugger_log);
    leanclr::vm::Settings::set_domain_name("leanclr-godot");
    if (!lib_dirs_.empty()) {
        leanclr::vm::Settings::set_data_dir(lib_dirs_.front().c_str());
        leanclr::vm::Settings::set_config_dir(lib_dirs_.front().c_str());
    }
}

bool LeanCLRRuntime::initialize(const PackedStringArray &lib_dirs) {
    last_error_.clear();
    if (initialized_) {
        return true;
    }
    lib_dirs_.clear();
    for (int i = 0; i < lib_dirs.size(); ++i) {
        godot::CharString path = lib_dirs[i].utf8();
        lib_dirs_.push_back(std::string(path.get_data()));
    }
    apply_settings();
    godot::UtilityFunctions::print("[LeanCLR] res root=", godot::String(g_res_root.c_str()));
    for (const auto &dir : lib_dirs_) {
        godot::UtilityFunctions::print("[LeanCLR] lib dir=", godot::String(dir.c_str()));
    }
    auto result = leanclr::vm::Runtime::initialize();
    if (result.is_err()) {
        last_error_ = "Runtime::initialize failed: " + std::to_string(static_cast<int>(result.unwrap_err()));
        return false;
    }
    initialized_ = true;
    generation_ = 0;
    loaded_assemblies_.clear();
    register_godot_bridge();
    return true;
}

bool LeanCLRRuntime::reload_runtime() {
    last_error_.clear();
    if (!initialized_) {
        last_error_ = "runtime not initialized";
        return false;
    }
    for (auto &pair : object_handles_) {
        leanclr::vm::GCHandle::free_handle(pair.second.gc_handle);
    }
    object_handles_.clear();
    stale_handles_.clear();
    instance_mappings_.clear();
    handle_mappings_.clear();
    for (void *keepalive : static_keepalive_handles_) {
        leanclr::vm::GCHandle::free_handle(keepalive);
    }
    static_keepalive_handles_.clear();
    static_snapshots_.clear();
    g_resource_refs.clear();
    last_module_ = nullptr;

    leanclr::vm::Runtime::shutdown();
    initialized_ = false;

    apply_settings();
    auto result = leanclr::vm::Runtime::initialize();
    if (result.is_err()) {
        last_error_ = "Runtime::initialize failed on reload: " + std::to_string(static_cast<int>(result.unwrap_err()));
        return false;
    }
    initialized_ = true;
    // Runtime::shutdown() 会清空 P/Invoke 注册表；reload 后必须重新注册桥接函数，
    // 否则新一轮程序集里的 [DllImport] 调用会命中未注册的 pinvoke。
    register_godot_bridge();

    for (const std::string &name : loaded_assemblies_) {
        auto loaded = leanclr::vm::Assembly::load_by_name(name.c_str());
        if (loaded.is_err()) {
            last_error_ = "Assembly::load_by_name failed on reload: " + name + " err=" + std::to_string(static_cast<int>(loaded.unwrap_err()));
            return false;
        }
        last_module_ = loaded.unwrap()->mod;
    }
    ++generation_;
    return true;
}

void LeanCLRRuntime::shutdown() {
    if (!initialized_) {
        return;
    }
    for (auto &pair : object_handles_) {
        leanclr::vm::GCHandle::free_handle(pair.second.gc_handle);
    }
    object_handles_.clear();
    stale_handles_.clear();
    instance_mappings_.clear();
    handle_mappings_.clear();
    for (void *keepalive : static_keepalive_handles_) {
        leanclr::vm::GCHandle::free_handle(keepalive);
    }
    static_keepalive_handles_.clear();
    static_snapshots_.clear();
    g_resource_refs.clear();
    leanclr::vm::Runtime::shutdown();
    initialized_ = false;
    generation_ = 0;
    loaded_assemblies_.clear();
    last_module_ = nullptr;
    s_lib_dirs = nullptr;
    g_res_root.clear();
    g_logged_virtual_load = false;
    g_logged_fs_load = false;
}

bool LeanCLRRuntime::is_initialized() const {
    return initialized_;
}

int64_t LeanCLRRuntime::get_generation() const {
    return generation_;
}

std::string LeanCLRRuntime::get_on_unsafe_mode() const {
    std::string mode = on_unsafe_mode_;
    if (mode.empty()) {
        if (ProjectSettings::get_singleton() != nullptr) {
            String setting = ProjectSettings::get_singleton()->get_setting("leanclr/hot_reload/on_unsafe", "fallback");
            mode = setting.utf8().get_data();
        }
    }
    if (mode != "reject") {
        mode = "fallback";
    }
    return mode;
}

String LeanCLRRuntime::get_hot_reload_on_unsafe() const {
    return String(get_on_unsafe_mode().c_str());
}

void LeanCLRRuntime::set_hot_reload_on_unsafe(const String &mode) {
    godot::CharString mode_u8 = mode.utf8();
    std::string value(mode_u8.get_data());
    if (value != "fallback" && value != "reject") {
        last_error_ = "invalid on_unsafe mode: " + value + " (expected fallback|reject)";
        return;
    }
    on_unsafe_mode_ = value;
}

leanclr::vm::RtObject *LeanCLRRuntime::resolve_handle(int64_t handle_id, std::string &error) {
    auto stale = stale_handles_.find(handle_id);
    if (stale != stale_handles_.end()) {
        error = "stale type identity: handle " + std::to_string(handle_id) + " belongs to unloaded assembly '" +
                stale->second.module_name + "' (generation " + std::to_string(stale->second.generation) + ")";
        return nullptr;
    }
    auto it = object_handles_.find(handle_id);
    if (it == object_handles_.end()) {
        error = "invalid object handle: " + std::to_string(handle_id);
        return nullptr;
    }
    leanclr::vm::RtObject *object = leanclr::vm::GCHandle::get_target(it->second.gc_handle);
    if (object == nullptr) {
        error = "object handle target is null: " + std::to_string(handle_id);
    }
    return object;
}

void LeanCLRRuntime::invalidate_module_handles(const std::string &module_name) {
    std::vector<int64_t> stale_ids;
    for (const auto &pair : object_handles_) {
        if (pair.second.module_name == module_name) {
            stale_ids.push_back(pair.first);
        }
    }
    for (int64_t id : stale_ids) {
        auto it = object_handles_.find(id);
        if (it == object_handles_.end()) {
            continue;
        }
        leanclr::vm::GCHandle::free_handle(it->second.gc_handle);
        StaleHandleInfo info;
        info.module_name = module_name;
        info.generation = it->second.generation;
        stale_handles_[id] = info;
        object_handles_.erase(it);
    }
    // 句柄已失效，对应实例映射同步删除，避免留下悬空映射。
    for (auto it = instance_mappings_.begin(); it != instance_mappings_.end();) {
        if (it->second.module_name == module_name) {
            handle_mappings_.erase(it->second.handle);
            it = instance_mappings_.erase(it);
        } else {
            ++it;
        }
    }
}

static bool is_reference_element_type(leanclr::metadata::RtElementType ele_type);

std::vector<std::pair<std::string, std::string>> LeanCLRRuntime::load_static_whitelist(const std::string &assembly_name) const {
    std::vector<std::pair<std::string, std::string>> result;
    std::string config_path;
    if (!g_res_root.empty()) {
        std::string candidate = g_res_root + "/hotreload.statics.json";
        if (FileAccess::file_exists(candidate.c_str())) {
            config_path = candidate;
        }
    }
    if (config_path.empty() && !lib_dirs_.empty()) {
        std::string candidate = lib_dirs_.back() + "/hotreload.statics.json";
        if (FileAccess::file_exists(candidate.c_str())) {
            config_path = candidate;
        }
    }
    if (config_path.empty()) {
        return result;
    }
    String text = FileAccess::get_file_as_string(config_path.c_str());
    if (text.is_empty()) {
        return result;
    }
    Variant parsed = JSON::parse_string(text);
    if (parsed.get_type() != Variant::DICTIONARY) {
        UtilityFunctions::push_warning("[hotreload] invalid hotreload.statics.json");
        return result;
    }
    Dictionary root = parsed;
    Array entries = root.get("statics", Array());
    for (int i = 0; i < entries.size(); ++i) {
        String entry = entries[i];
        std::string line(entry.utf8().get_data());
        size_t bang = line.find('!');
        size_t sep = line.find("::");
        if (bang == std::string::npos || sep == std::string::npos || sep <= bang) {
            continue;
        }
        std::string owner = line.substr(0, bang);
        if (owner != assembly_name) {
            continue;
        }
        result.emplace_back(line.substr(bang + 1, sep - bang - 1), line.substr(sep + 2));
    }
    return result;
}

void LeanCLRRuntime::capture_static_snapshot(leanclr::metadata::RtModuleDef *module, const std::string &assembly_name) {
    auto entries = load_static_whitelist(assembly_name);
    if (entries.empty()) {
        UtilityFunctions::print("[hotreload] statics: no entries for " + String(assembly_name.c_str()));
        return;
    }
    for (const auto &entry : entries) {
        StaticSnapshotEntry snapshot;
        snapshot.assembly_name = assembly_name;
        snapshot.type_name = entry.first;
        snapshot.field_name = entry.second;
        auto class_result = module->get_class_by_nested_full_name(entry.first.c_str(), false, false);
        if (class_result.is_err()) {
            UtilityFunctions::print("[hotreload] statics: type not found " + String(entry.first.c_str()));
            continue;
        }
        leanclr::metadata::RtClass *klass = class_result.unwrap();
        leanclr::vm::Class::initialize_all(klass);
        auto field_result = leanclr::vm::Field::find_field_by_name(klass, entry.second.c_str());
        if (field_result.is_err()) {
            UtilityFunctions::print("[hotreload] statics: field not found " + String(entry.first.c_str()) + "::" + String(entry.second.c_str()));
            continue;
        }
        const leanclr::metadata::RtFieldInfo *field = field_result.unwrap();
        if (!leanclr::vm::Field::is_static_excluded_literal_and_rva(field)) {
            UtilityFunctions::print("[hotreload] statics: not a static field " + String(entry.first.c_str()) + "::" + String(entry.second.c_str()));
            continue;
        }
        auto size_result = leanclr::vm::Field::get_field_size(field);
        if (size_result.is_err()) {
            continue;
        }
        size_t size = size_result.unwrap();
        snapshot.bytes.assign(size == 0 ? 1 : size, 0);
        if (leanclr::vm::Field::get_static_value(field, snapshot.bytes.data()).is_err()) {
            continue;
        }
        snapshot.reference = is_reference_element_type(field->type_sig->ele_type);
        if (snapshot.reference) {
            void *target = nullptr;
            std::memcpy(&target, snapshot.bytes.data(), sizeof(void *));
            if (target != nullptr) {
                auto *object = reinterpret_cast<leanclr::vm::RtObject *>(target);
                if (object->klass != nullptr && object->klass->image == module) {
                    UtilityFunctions::print("[hotreload] statics: skip reference to unloaded module " + String(entry.first.c_str()) + "::" + String(entry.second.c_str()));
                    continue;
                }
                snapshot.keep_alive_handle = leanclr::vm::GCHandle::new_handle(object, false);
            }
        }
        snapshot.valid = true;
        static_snapshots_.push_back(snapshot);
    }
}

bool LeanCLRRuntime::restore_static_snapshot(leanclr::metadata::RtModuleDef *module, const std::string &assembly_name, std::string &error) {
    bool ok = true;
    for (StaticSnapshotEntry &snapshot : static_snapshots_) {
        if (!snapshot.valid || snapshot.assembly_name != assembly_name) {
            continue;
        }
        std::string label = snapshot.type_name + "::" + snapshot.field_name;
        auto class_result = module->get_class_by_nested_full_name(snapshot.type_name.c_str(), false, false);
        if (class_result.is_err()) {
            UtilityFunctions::print("[hotreload] statics: restore skip missing type " + String(label.c_str()));
            ok = false;
            continue;
        }
        leanclr::metadata::RtClass *klass = class_result.unwrap();
        leanclr::vm::Class::initialize_all(klass);
        auto cctor_result = leanclr::vm::Runtime::run_class_static_constructor(klass);
        if (cctor_result.is_err()) {
            UtilityFunctions::print("[hotreload] statics: static constructor failed " + String(label.c_str()) + " err=" +
                                    String::num_int64(static_cast<int64_t>(cctor_result.unwrap_err())));
        }
        auto field_result = leanclr::vm::Field::find_field_by_name(klass, snapshot.field_name.c_str());
        if (field_result.is_err()) {
            UtilityFunctions::print("[hotreload] statics: restore skip missing field " + String(label.c_str()));
            ok = false;
            continue;
        }
        const leanclr::metadata::RtFieldInfo *field = field_result.unwrap();
        auto size_result = leanclr::vm::Field::get_field_size(field);
        if (size_result.is_err() || size_result.unwrap() != snapshot.bytes.size()) {
            UtilityFunctions::print("[hotreload] statics: restore skip size mismatch " + String(label.c_str()));
            ok = false;
            continue;
        }
        if (leanclr::vm::Field::set_static_value(field, snapshot.bytes.data()).is_err()) {
            UtilityFunctions::print("[hotreload] statics: restore failed " + String(label.c_str()));
            ok = false;
            continue;
        }
        UtilityFunctions::print("[hotreload] statics: restored " + String(label.c_str()) + " (" +
                                String::num_int64(static_cast<int64_t>(snapshot.bytes.size())) + " bytes)");
    }
    for (size_t i = 0; i < static_snapshots_.size();) {
        StaticSnapshotEntry &snapshot = static_snapshots_[i];
        if (snapshot.assembly_name != assembly_name) {
            ++i;
            continue;
        }
        if (snapshot.keep_alive_handle != nullptr) {
            // Keep reference-type static values alive across lazy GC passes until the next full reload.
            static_keepalive_handles_.push_back(snapshot.keep_alive_handle);
            snapshot.keep_alive_handle = nullptr;
        }
        static_snapshots_.erase(static_snapshots_.begin() + static_cast<std::ptrdiff_t>(i));
    }
    if (!ok) {
        error = "some static fields were not restored";
    }
    return ok;
}

std::string LeanCLRRuntime::signature_type_name(const leanclr::metadata::RtTypeSig *sig) {
    if (sig == nullptr) {
        return "?";
    }
    using ET = leanclr::metadata::RtElementType;
    std::string result;
    switch (sig->ele_type) {
        case ET::Void: result = "void"; break;
        case ET::Boolean: result = "bool"; break;
        case ET::Char: result = "char"; break;
        case ET::I1: result = "i1"; break;
        case ET::U1: result = "u1"; break;
        case ET::I2: result = "i2"; break;
        case ET::U2: result = "u2"; break;
        case ET::I4: result = "i4"; break;
        case ET::U4: result = "u4"; break;
        case ET::I8: result = "i8"; break;
        case ET::U8: result = "u8"; break;
        case ET::R4: result = "r4"; break;
        case ET::R8: result = "r8"; break;
        case ET::String: result = "string"; break;
        case ET::Object: result = "object"; break;
        case ET::I: result = "i"; break;
        case ET::U: result = "u"; break;
        case ET::Class:
        case ET::ValueType: {
            auto class_result = leanclr::vm::Class::get_class_by_type_def_gid(sig->data.type_def_gid);
            if (class_result.is_err() || class_result.unwrap() == nullptr) {
                result = "gid:" + std::to_string(sig->data.type_def_gid);
            } else {
                const leanclr::metadata::RtClass *klass = class_result.unwrap();
                std::string ns = klass->namespaze != nullptr ? klass->namespaze : "";
                std::string name = klass->name != nullptr ? klass->name : "";
                result = "class:" + (ns.empty() ? name : ns + "." + name);
            }
            break;
        }
        case ET::SZArray:
            result = signature_type_name(sig->data.element_type) + "[]";
            break;
        case ET::Ptr:
            result = signature_type_name(sig->data.element_type) + "*";
            break;
        case ET::ByRef:
            result = signature_type_name(sig->data.element_type) + "&";
            break;
        default:
            result = "elem:" + std::to_string(static_cast<int>(sig->ele_type));
            break;
    }
    if (sig->by_ref && !result.empty() && result.back() != '&') {
        result += "&";
    }
    return result;
}

void LeanCLRRuntime::collect_signatures(leanclr::metadata::RtModuleDef *module, SignatureSnapshot &snapshot) const {
    if (module == nullptr) {
        return;
    }
    uint32_t class_count = module->get_class_count();
    for (uint32_t rid = 1; rid <= class_count; ++rid) {
        auto class_result = module->get_class_by_type_def_rid(rid);
        if (class_result.is_err() || class_result.unwrap() == nullptr) {
            continue;
        }
        // init_class_of_type_def 只建骨架，方法表要 initialize_all 后才可枚举。
        if (leanclr::vm::Class::initialize_all(class_result.unwrap()).is_err()) {
            continue;
        }
        const leanclr::metadata::RtClass *klass = class_result.unwrap();
        std::string ns = klass->namespaze != nullptr ? klass->namespaze : "";
        std::string type_name = (ns.empty() ? "" : ns + ".") + (klass->name != nullptr ? klass->name : "");
        for (uint16_t i = 0; i < klass->method_count; ++i) {
            const leanclr::metadata::RtMethodInfo *method = klass->methods[i];
            if (method == nullptr || method->name == nullptr) {
                continue;
            }
            MethodSignature signature;
            signature.type_name = type_name;
            signature.method_name = method->name;
            signature.param_count = method->parameter_count;
            signature.is_static = (method->flags & 0x0010) != 0;
            std::string text = "(";
            for (uint16_t p = 0; p < method->parameter_count; ++p) {
                if (p > 0) {
                    text += ",";
                }
                text += signature_type_name(method->parameters[p]);
            }
            text += ")->" + signature_type_name(method->return_type);
            if (signature.is_static) {
                text += " static";
            }
            signature.signature = text;
            snapshot.methods.push_back(signature);
        }
    }
}

void LeanCLRRuntime::capture_signature_snapshot(leanclr::metadata::RtModuleDef *module, const std::string &assembly_name) {
    SignatureSnapshot snapshot;
    snapshot.assembly_name = assembly_name;
    collect_signatures(module, snapshot);
    signature_snapshots_.push_back(snapshot);
    UtilityFunctions::print("[hotreload] signature snapshot: " + String(assembly_name.c_str()) + ", methods=" +
                            String::num_int64(static_cast<int64_t>(snapshot.methods.size())));
}

bool LeanCLRRuntime::compare_signature_snapshot(leanclr::metadata::RtModuleDef *module, const std::string &assembly_name, std::string &error) const {
    const SignatureSnapshot *previous = nullptr;
    for (const SignatureSnapshot &snapshot : signature_snapshots_) {
        if (snapshot.assembly_name == assembly_name) {
            previous = &snapshot;
            break;
        }
    }
    if (previous == nullptr) {
        return true;
    }
    SignatureSnapshot current;
    current.assembly_name = assembly_name;
    collect_signatures(module, current);

    auto display = [](const MethodSignature &method) {
        return method.type_name + "." + method.method_name + method.signature;
    };
    auto full_key = [](const MethodSignature &method) {
        return method.type_name + "." + method.method_name + method.signature;
    };
    auto arity_key = [](const MethodSignature &method) {
        return method.type_name + "." + method.method_name + "|" + std::to_string(method.param_count);
    };

    std::set<std::string> new_full;
    std::unordered_map<std::string, const MethodSignature *> new_by_arity;
    for (const MethodSignature &method : current.methods) {
        new_full.insert(full_key(method));
        new_by_arity.emplace(arity_key(method), &method);
    }

    std::vector<std::string> issues;
    for (const MethodSignature &method : previous->methods) {
        if (new_full.find(full_key(method)) != new_full.end()) {
            continue;
        }
        auto same_arity = new_by_arity.find(arity_key(method));
        if (same_arity != new_by_arity.end()) {
            issues.push_back("changed signature: " + display(method) + " -> " + display(*same_arity->second));
        } else {
            issues.push_back("removed method: " + display(method));
        }
        if (issues.size() >= 5) {
            break;
        }
    }
    if (issues.empty()) {
        return true;
    }
    error = "signature mismatch in '" + assembly_name + "': ";
    for (size_t i = 0; i < issues.size(); ++i) {
        if (i > 0) {
            error += "; ";
        }
        error += issues[i];
    }
    return false;
}

bool LeanCLRRuntime::assembly_file_exists(const std::string &assembly_name) const {
    for (const auto &dir : lib_dirs_) {
        std::string res_dir = map_to_res_dir(dir);
        if (!res_dir.empty()) {
            std::string res_path = res_dir + "/" + assembly_name + ".dll";
            if (godot::FileAccess::file_exists(godot::String(res_path.c_str()))) {
                return true;
            }
        }
        std::string path = normalize_dir_path(dir) + "/" + assembly_name + ".dll";
        std::ifstream file(path, std::ios::binary);
        if (file.is_open()) {
            return true;
        }
    }
    return false;
}

std::vector<std::string> LeanCLRRuntime::collect_reload_group(const std::string &assembly_name) const {
    std::vector<std::string> group;
    group.push_back(assembly_name);
    bool changed = true;
    while (changed) {
        changed = false;
        leanclr::utils::Vector<leanclr::metadata::RtModuleDef *> modules;
        leanclr::metadata::RtModuleDef::get_registered_modules(modules);
        for (leanclr::metadata::RtModuleDef *mod : modules) {
            if (mod == nullptr || mod->is_corlib()) {
                continue;
            }
            const char *raw_name = mod->get_name_no_ext();
            if (raw_name == nullptr) {
                continue;
            }
            std::string name(raw_name);
            if (std::find(group.begin(), group.end(), name) != group.end()) {
                continue;
            }
            // 只处理已被 runtime 记录的模块，保证重载顺序与 loaded_assemblies_ 一致。
            if (std::find(loaded_assemblies_.begin(), loaded_assemblies_.end(), name) == loaded_assemblies_.end()) {
                continue;
            }
            for (const std::string &member : group) {
                if (mod->references_assembly(member.c_str())) {
                    group.push_back(name);
                    changed = true;
                    break;
                }
            }
        }
    }
    return group;
}

bool LeanCLRRuntime::unload_group(const std::vector<std::string> &group, std::string &error) {
    for (const std::string &name : group) {
        auto unload_result = leanclr::vm::Assembly::unload_module_unchecked(name.c_str());
        if (unload_result.is_err()) {
            error = "Assembly::unload_module_unchecked failed for '" + name +
                    "': " + std::to_string(static_cast<int>(unload_result.unwrap_err()));
            return false;
        }
    }
    return true;
}

bool LeanCLRRuntime::load_group(const std::vector<std::string> &group, std::string &error) {
    for (const std::string &name : group) {
        auto load_result = leanclr::vm::Assembly::load_by_name(name.c_str());
        if (load_result.is_err()) {
            error = "Assembly::load_by_name failed for '" + name +
                    "': " + std::to_string(static_cast<int>(load_result.unwrap_err()));
            return false;
        }
        last_module_ = load_result.unwrap()->mod;
        std::string restore_error;
        restore_static_snapshot(last_module_, name, restore_error);
        if (!restore_error.empty() && !last_error_.empty()) {
            last_error_ += "; ";
        }
        if (!restore_error.empty()) {
            last_error_ += restore_error;
        }
    }
    return true;
}

bool LeanCLRRuntime::reload_group(const std::string &assembly_name, std::vector<std::string> &unload_order, bool &recovered) {
    recovered = false;
    std::vector<std::string> group = collect_reload_group(assembly_name);
    // 按原加载顺序排列；未出现在 loaded_assemblies_ 的成员不应存在（collect 已过滤）。
    std::vector<std::string> load_order;
    for (const std::string &name : loaded_assemblies_) {
        if (std::find(group.begin(), group.end(), name) != group.end()) {
            load_order.push_back(name);
        }
    }

    // 失败回滚：先确认组内所有镜像文件都存在，避免卸载到一半才发现缺文件。
    for (const std::string &name : load_order) {
        if (!assembly_file_exists(name)) {
            last_error_ = "hot reload aborted: missing assembly file '" + name + "'";
            last_reload_mode_ = "aborted";
            UtilityFunctions::print("[hotreload] " + String(last_error_.c_str()));
            return false;
        }
    }

    unload_order.assign(load_order.rbegin(), load_order.rend());
    std::string order_text;
    for (const std::string &name : unload_order) {
        if (!order_text.empty()) {
            order_text += ",";
        }
        order_text += name;
    }
    UtilityFunctions::print("[hotreload] dependents unload order: " + String(order_text.c_str()));

    static_snapshots_.clear();
    signature_snapshots_.clear();
    for (const std::string &name : unload_order) {
        leanclr::metadata::RtModuleDef *module = leanclr::metadata::RtModuleDef::find_module(name.c_str());
        if (module != nullptr) {
            capture_static_snapshot(module, name);
            capture_signature_snapshot(module, name);
        }
        invalidate_module_handles(name);
    }

    std::string group_error;
    if (!unload_group(unload_order, group_error)) {
        last_error_ = group_error;
        last_reload_mode_ = "failed";
        return false;
    }
    if (!load_group(load_order, group_error)) {
        last_error_ = group_error;
        recovered = reload_runtime();
        last_reload_mode_ = recovered ? "dependents-failed" : "dependents-failed-unrecovered";
        return false;
    }

    // 签名兼容校验：所有模块加载完成后、执行任何托管代码前逐个比对。
    std::string mismatch;
    for (const std::string &name : load_order) {
        leanclr::metadata::RtModuleDef *module = leanclr::metadata::RtModuleDef::find_module(name.c_str());
        if (module == nullptr) {
            continue;
        }
        std::string module_mismatch;
        if (!compare_signature_snapshot(module, name, module_mismatch)) {
            if (!mismatch.empty()) {
                mismatch += "; ";
            }
            mismatch += module_mismatch;
        }
    }
    if (!mismatch.empty()) {
        last_error_ = mismatch;
        recovered = reload_runtime();
        last_reload_mode_ = "signature-mismatch";
        UtilityFunctions::print("[hotreload] " + String(mismatch.c_str()));
        return false;
    }

    ++generation_;
    std::string loaded_text;
    for (const std::string &name : load_order) {
        if (!loaded_text.empty()) {
            loaded_text += ",";
        }
        loaded_text += name;
    }
    UtilityFunctions::print("[hotreload] dependents loaded order: " + String(loaded_text.c_str()));
    last_reload_mode_ = "assembly+dependents";
    UtilityFunctions::print("[hotreload] assembly group reloaded: " + String(assembly_name.c_str()) + ", generation=" +
                            String::num_int64(generation_) + ", mode=assembly+dependents");
    return true;
}

bool LeanCLRRuntime::reload_assembly(const String &name, bool include_dependents) {
    last_error_.clear();
    last_reload_mode_.clear();
    if (!initialized_) {
        last_error_ = "runtime not initialized";
        return false;
    }
    std::string assembly_name(name.utf8().get_data());
    std::string unsafe_reason;

    leanclr::metadata::RtModuleDef *module = leanclr::metadata::RtModuleDef::find_module(assembly_name.c_str());
    if (module == nullptr) {
        unsafe_reason = "assembly not loaded: " + assembly_name;
    } else if (module->is_corlib()) {
        unsafe_reason = "corlib cannot be unloaded";
    } else if (!include_dependents) {
        leanclr::utils::Vector<leanclr::metadata::RtModuleDef *> modules;
        leanclr::metadata::RtModuleDef::get_registered_modules(modules);
        for (leanclr::metadata::RtModuleDef *other : modules) {
            if (other != nullptr && other != module && other->references_assembly(assembly_name.c_str())) {
                unsafe_reason = "assembly '" + assembly_name + "' is referenced by '" + other->get_name_no_ext() + "'";
                break;
            }
        }
    } else if (std::find(loaded_assemblies_.begin(), loaded_assemblies_.end(), assembly_name) == loaded_assemblies_.end()) {
        unsafe_reason = "assembly not tracked by runtime: " + assembly_name;
    } else {
        // 组外模块仍引用组内成员时，整组卸载不安全。
        std::vector<std::string> group = collect_reload_group(assembly_name);
        leanclr::utils::Vector<leanclr::metadata::RtModuleDef *> modules;
        leanclr::metadata::RtModuleDef::get_registered_modules(modules);
        for (leanclr::metadata::RtModuleDef *other : modules) {
            if (other == nullptr || other->is_corlib()) {
                continue;
            }
            const char *raw_name = other->get_name_no_ext();
            if (raw_name == nullptr || std::find(group.begin(), group.end(), std::string(raw_name)) != group.end()) {
                continue;
            }
            for (const std::string &member : group) {
                if (other->references_assembly(member.c_str())) {
                    unsafe_reason = "assembly group of '" + assembly_name + "' is referenced by external '" +
                                    std::string(raw_name) + "'";
                    break;
                }
            }
            if (!unsafe_reason.empty()) {
                break;
            }
        }
    }

    if (!unsafe_reason.empty()) {
        if (get_on_unsafe_mode() == "reject") {
            last_error_ = "unsafe to unload: " + unsafe_reason;
            last_reload_mode_ = "rejected";
            UtilityFunctions::print("[hotreload] " + String(last_error_.c_str()));
            return false;
        }
        UtilityFunctions::print("[hotreload] unsafe to unload: " + String(unsafe_reason.c_str()) + ", fallback to full runtime reload");
        if (!reload_runtime()) {
            last_reload_mode_ = "fallback-failed";
            return false;
        }
        last_reload_mode_ = "fallback";
        return true;
    }

    if (include_dependents) {
        std::vector<std::string> unload_order;
        bool recovered = false;
        return reload_group(assembly_name, unload_order, recovered);
    }

    static_snapshots_.clear();
    signature_snapshots_.clear();
    capture_static_snapshot(module, assembly_name);
    capture_signature_snapshot(module, assembly_name);
    invalidate_module_handles(assembly_name);

    auto unload_result = leanclr::vm::Assembly::unload_module(assembly_name.c_str());
    if (unload_result.is_err()) {
        last_error_ = "Assembly::unload_module failed: " + std::to_string(static_cast<int>(unload_result.unwrap_err()));
        last_reload_mode_ = "failed";
        return false;
    }

    auto load_result = leanclr::vm::Assembly::load_by_name(assembly_name.c_str());
    if (load_result.is_err()) {
        last_error_ = "Assembly::load_by_name failed after unload: " + std::to_string(static_cast<int>(load_result.unwrap_err()));
        last_reload_mode_ = "failed";
        return false;
    }
    last_module_ = load_result.unwrap()->mod;

    std::string restore_error;
    restore_static_snapshot(last_module_, assembly_name, restore_error);
    if (!restore_error.empty()) {
        last_error_ = restore_error;
    }

    // 签名兼容校验：执行任何托管代码前比对；不兼容时恢复一致状态并明确报错。
    std::string mismatch;
    if (!compare_signature_snapshot(last_module_, assembly_name, mismatch)) {
        last_error_ = mismatch;
        reload_runtime();
        last_reload_mode_ = "signature-mismatch";
        UtilityFunctions::print("[hotreload] " + String(mismatch.c_str()));
        return false;
    }

    ++generation_;
    last_reload_mode_ = "assembly";
    UtilityFunctions::print("[hotreload] assembly reloaded: " + String(assembly_name.c_str()) + ", generation=" +
                            String::num_int64(generation_) + ", mode=assembly");
    return true;
}

PackedStringArray LeanCLRRuntime::get_loaded_assemblies() const {
    PackedStringArray result;
    for (const std::string &name : loaded_assemblies_) {
        result.append(String(name.c_str()));
    }
    return result;
}

String LeanCLRRuntime::get_last_reload_mode() const {
    return String(last_reload_mode_.c_str());
}

bool LeanCLRRuntime::load_assembly(const String &name) {
    last_error_.clear();
    if (!initialized_) {
        last_error_ = "runtime not initialized";
        return false;
    }
    godot::CharString name_u8 = name.utf8();
    auto result = leanclr::vm::Assembly::load_by_name(name_u8.get_data());
    if (result.is_err()) {
        last_error_ = "Assembly::load_by_name failed: " + std::to_string(static_cast<int>(result.unwrap_err()));
        return false;
    }
    last_module_ = result.unwrap()->mod;
    std::string assembly_name(name_u8.get_data());
    bool tracked = false;
    for (const std::string &existing : loaded_assemblies_) {
        if (existing == assembly_name) {
            tracked = true;
            break;
        }
    }
    if (!tracked) {
        loaded_assemblies_.push_back(assembly_name);
    }
    return true;
}

static bool push_integer_arg(uint8_t *buffer, size_t &offset, int64_t value, leanclr::metadata::RtElementType type) {
    switch (type) {
        case leanclr::metadata::RtElementType::Boolean: {
            uint8_t v = value != 0 ? 1 : 0;
            std::memcpy(buffer + offset, &v, sizeof(v));
            break;
        }
        case leanclr::metadata::RtElementType::I1: {
            int8_t v = static_cast<int8_t>(value);
            std::memcpy(buffer + offset, &v, sizeof(v));
            break;
        }
        case leanclr::metadata::RtElementType::U1: {
            uint8_t v = static_cast<uint8_t>(value);
            std::memcpy(buffer + offset, &v, sizeof(v));
            break;
        }
        case leanclr::metadata::RtElementType::Char:
        case leanclr::metadata::RtElementType::U2: {
            uint16_t v = static_cast<uint16_t>(value);
            std::memcpy(buffer + offset, &v, sizeof(v));
            break;
        }
        case leanclr::metadata::RtElementType::I2: {
            int16_t v = static_cast<int16_t>(value);
            std::memcpy(buffer + offset, &v, sizeof(v));
            break;
        }
        case leanclr::metadata::RtElementType::I4: {
            int32_t v = static_cast<int32_t>(value);
            std::memcpy(buffer + offset, &v, sizeof(v));
            break;
        }
        case leanclr::metadata::RtElementType::U4: {
            uint32_t v = static_cast<uint32_t>(value);
            std::memcpy(buffer + offset, &v, sizeof(v));
            break;
        }
        case leanclr::metadata::RtElementType::I8:
        case leanclr::metadata::RtElementType::U8: {
            std::memcpy(buffer + offset, &value, sizeof(value));
            break;
        }
        default:
            return false;
    }
    offset += 8;
    return true;
}

static int64_t register_object_handle(leanclr::vm::RtObject *object,
                                      std::unordered_map<int64_t, LeanCLRRuntime::HandleEntry> &handles,
                                      int64_t &next_handle_id, int64_t generation);
static bool is_reference_element_type(leanclr::metadata::RtElementType ele_type);

static bool push_argument_value(uint8_t *buffer, size_t &offset, const Variant &value,
                                const leanclr::metadata::RtTypeSig *type,
                                const std::unordered_map<int64_t, LeanCLRRuntime::HandleEntry> &handles) {
    switch (type->ele_type) {
        case leanclr::metadata::RtElementType::String: {
            godot::String text = value;
            godot::CharString text_u8 = text.utf8();
            leanclr::vm::RtString *managed = leanclr::vm::String::create_string_from_utf8cstr(text_u8.get_data());
            std::memcpy(buffer + offset, &managed, sizeof(managed));
            offset += 8;
            return true;
        }
        case leanclr::metadata::RtElementType::R4: {
            float v = static_cast<float>(static_cast<double>(value));
            std::memcpy(buffer + offset, &v, sizeof(v));
            offset += 8;
            return true;
        }
        case leanclr::metadata::RtElementType::R8: {
            double v = static_cast<double>(value);
            std::memcpy(buffer + offset, &v, sizeof(v));
            offset += 8;
            return true;
        }
        default:
            if (is_reference_element_type(type->ele_type)) {
                if (value.get_type() == godot::Variant::NIL) {
                    leanclr::vm::RtObject *null_reference = nullptr;
                    std::memcpy(buffer + offset, &null_reference, sizeof(null_reference));
                    offset += 8;
                    return true;
                }
                if (value.get_type() != godot::Variant::INT) {
                    return false;
                }
                auto it = handles.find(static_cast<int64_t>(value));
                if (it == handles.end()) {
                    return false;
                }
                leanclr::vm::RtObject *reference = leanclr::vm::GCHandle::get_target(it->second.gc_handle);
                if (reference == nullptr) {
                    return false;
                }
                std::memcpy(buffer + offset, &reference, sizeof(reference));
                offset += 8;
                return true;
            }
            return push_integer_arg(buffer, offset, static_cast<int64_t>(value), type->ele_type);
    }
}

static Variant read_return_value(const uint8_t *ret, const leanclr::metadata::RtTypeSig *type,
                                 std::unordered_map<int64_t, LeanCLRRuntime::HandleEntry> &handles, int64_t &next_handle_id,
                                 int64_t generation) {
    switch (type->ele_type) {
        case leanclr::metadata::RtElementType::Void:
            return Variant();
        case leanclr::metadata::RtElementType::Boolean: {
            uint8_t v = 0;
            std::memcpy(&v, ret, sizeof(v));
            return Variant(v != 0);
        }
        case leanclr::metadata::RtElementType::I1: {
            int8_t v = 0;
            std::memcpy(&v, ret, sizeof(v));
            return Variant(static_cast<int64_t>(v));
        }
        case leanclr::metadata::RtElementType::U1: {
            uint8_t v = 0;
            std::memcpy(&v, ret, sizeof(v));
            return Variant(static_cast<int64_t>(v));
        }
        case leanclr::metadata::RtElementType::I2: {
            int16_t v = 0;
            std::memcpy(&v, ret, sizeof(v));
            return Variant(static_cast<int64_t>(v));
        }
        case leanclr::metadata::RtElementType::Char:
        case leanclr::metadata::RtElementType::U2: {
            uint16_t v = 0;
            std::memcpy(&v, ret, sizeof(v));
            return Variant(static_cast<int64_t>(v));
        }
        case leanclr::metadata::RtElementType::I4: {
            int32_t v = 0;
            std::memcpy(&v, ret, sizeof(v));
            return Variant(static_cast<int64_t>(v));
        }
        case leanclr::metadata::RtElementType::U4: {
            uint32_t v = 0;
            std::memcpy(&v, ret, sizeof(v));
            return Variant(static_cast<int64_t>(v));
        }
        case leanclr::metadata::RtElementType::I8:
        case leanclr::metadata::RtElementType::U8: {
            int64_t v = 0;
            std::memcpy(&v, ret, sizeof(v));
            return Variant(v);
        }
        case leanclr::metadata::RtElementType::R4: {
            float v = 0;
            std::memcpy(&v, ret, sizeof(v));
            return Variant(static_cast<double>(v));
        }
        case leanclr::metadata::RtElementType::R8: {
            double v = 0;
            std::memcpy(&v, ret, sizeof(v));
            return Variant(v);
        }
        case leanclr::metadata::RtElementType::String: {
            leanclr::vm::RtString *managed = nullptr;
            std::memcpy(&managed, ret, sizeof(managed));
            if (managed == nullptr) {
                return Variant();
            }
            std::string text = utf16_to_utf8(reinterpret_cast<const uint16_t *>(&managed->first_char), static_cast<size_t>(managed->length));
            return Variant(godot::String(text.c_str()));
        }
        default: {
            if (is_reference_element_type(type->ele_type)) {
                leanclr::vm::RtObject *reference = nullptr;
                std::memcpy(&reference, ret, sizeof(reference));
                if (reference == nullptr) {
                    return Variant();
                }
                int64_t handle_id = register_object_handle(reference, handles, next_handle_id, generation);
                if (handle_id == 0) {
                    return Variant();
                }
                return Variant(handle_id);
            }
            int64_t v = 0;
            std::memcpy(&v, ret, sizeof(v));
            return Variant(v);
        }
    }
}

static Variant read_enum_value(const uint8_t *data, leanclr::metadata::RtElementType ele_type) {
    switch (ele_type) {
        case leanclr::metadata::RtElementType::I1: {
            int8_t v = 0;
            std::memcpy(&v, data, 1);
            return Variant(static_cast<int64_t>(v));
        }
        case leanclr::metadata::RtElementType::U1: {
            uint8_t v = 0;
            std::memcpy(&v, data, 1);
            return Variant(static_cast<int64_t>(v));
        }
        case leanclr::metadata::RtElementType::I2: {
            int16_t v = 0;
            std::memcpy(&v, data, 2);
            return Variant(static_cast<int64_t>(v));
        }
        case leanclr::metadata::RtElementType::Char:
        case leanclr::metadata::RtElementType::U2: {
            uint16_t v = 0;
            std::memcpy(&v, data, 2);
            return Variant(static_cast<int64_t>(v));
        }
        case leanclr::metadata::RtElementType::I4: {
            int32_t v = 0;
            std::memcpy(&v, data, 4);
            return Variant(static_cast<int64_t>(v));
        }
        case leanclr::metadata::RtElementType::U4: {
            uint32_t v = 0;
            std::memcpy(&v, data, 4);
            return Variant(static_cast<int64_t>(v));
        }
        case leanclr::metadata::RtElementType::I8: {
            int64_t v = 0;
            std::memcpy(&v, data, 8);
            return Variant(v);
        }
        case leanclr::metadata::RtElementType::U8: {
            uint64_t v = 0;
            std::memcpy(&v, data, 8);
            return Variant(static_cast<int64_t>(v));
        }
        default: {
            int64_t v = 0;
            std::memcpy(&v, data, sizeof(v));
            return Variant(v);
        }
    }
}

static void write_enum_value(uint8_t *data, int64_t value, leanclr::metadata::RtElementType ele_type) {
    switch (ele_type) {
        case leanclr::metadata::RtElementType::I1: {
            int8_t v = static_cast<int8_t>(value);
            std::memcpy(data, &v, 1);
            break;
        }
        case leanclr::metadata::RtElementType::U1: {
            uint8_t v = static_cast<uint8_t>(value);
            std::memcpy(data, &v, 1);
            break;
        }
        case leanclr::metadata::RtElementType::I2: {
            int16_t v = static_cast<int16_t>(value);
            std::memcpy(data, &v, 2);
            break;
        }
        case leanclr::metadata::RtElementType::Char:
        case leanclr::metadata::RtElementType::U2: {
            uint16_t v = static_cast<uint16_t>(value);
            std::memcpy(data, &v, 2);
            break;
        }
        case leanclr::metadata::RtElementType::I4: {
            int32_t v = static_cast<int32_t>(value);
            std::memcpy(data, &v, 4);
            break;
        }
        case leanclr::metadata::RtElementType::U4: {
            uint32_t v = static_cast<uint32_t>(value);
            std::memcpy(data, &v, 4);
            break;
        }
        default: {
            std::memcpy(data, &value, sizeof(value));
            break;
        }
    }
}

static bool is_reference_element_type(leanclr::metadata::RtElementType ele_type) {
    switch (ele_type) {
        case leanclr::metadata::RtElementType::String:
        case leanclr::metadata::RtElementType::Class:
        case leanclr::metadata::RtElementType::Object:
        case leanclr::metadata::RtElementType::Array:
        case leanclr::metadata::RtElementType::SZArray:
        case leanclr::metadata::RtElementType::GenericInst:
        case leanclr::metadata::RtElementType::Var:
            return true;
        default:
            return false;
    }
}

static std::string class_display_name(const leanclr::metadata::RtClass *klass) {
    if (klass == nullptr) {
        return "?";
    }
    std::string ns = klass->namespaze != nullptr ? klass->namespaze : "";
    std::string name = klass->name != nullptr ? klass->name : "";
    return ns.empty() ? name : ns + "." + name;
}

bool LeanCLRRuntime::check_managed_argument_type(leanclr::vm::RtObject *object, const leanclr::metadata::RtTypeSig *type,
                                                 std::string &error) const {
    if (object == nullptr || object->klass == nullptr || type == nullptr) {
        return true;
    }
    auto param_result = leanclr::vm::Class::get_class_from_typesig(type);
    if (param_result.is_err() || param_result.unwrap() == nullptr) {
        return true;
    }
    auto *param_class = const_cast<leanclr::metadata::RtClass *>(param_result.unwrap());
    leanclr::vm::Class::initialize_all(const_cast<leanclr::metadata::RtClass *>(object->klass));
    leanclr::vm::Class::initialize_all(param_class);
    if (leanclr::vm::Class::is_assignable_from(object->klass, param_class)) {
        return true;
    }
    error = "managed type mismatch: Godot instance maps to '" + class_display_name(object->klass) +
            "' but parameter expects '" + class_display_name(param_class) + "'";
    return false;
}

bool LeanCLRRuntime::normalize_object_argument(const Variant &value, const leanclr::metadata::RtTypeSig *type,
                                               Variant &out, std::string &error) {
    out = value;
    if (type == nullptr || !is_reference_element_type(type->ele_type)) {
        return true;
    }
    if (value.get_type() != godot::Variant::OBJECT) {
        return true;
    }
    godot::Object *instance = value.get_validated_object();
    if (instance == nullptr) {
        // 已释放或 null 实例按托管 null 处理。
        out = Variant();
        return true;
    }
    int64_t handle_id = 0;
    if (auto *node = godot::Object::cast_to<LeanCLRNode>(instance)) {
        handle_id = node->get_object_handle();
        if (handle_id == 0) {
            error = "Godot instance '" + std::string(instance->get_class().utf8().get_data()) + "#" +
                    std::to_string(static_cast<uint64_t>(instance->get_instance_id())) + "' has no managed object";
            return false;
        }
    } else {
        uint64_t instance_id = static_cast<uint64_t>(instance->get_instance_id());
        auto it = instance_mappings_.find(instance_id);
        if (it == instance_mappings_.end()) {
            error = "no managed object mapped for Godot instance '" + std::string(instance->get_class().utf8().get_data()) +
                    "#" + std::to_string(instance_id) + "'";
            return false;
        }
        handle_id = it->second.handle;
    }
    std::string handle_error;
    leanclr::vm::RtObject *target = resolve_handle(handle_id, handle_error);
    if (target == nullptr) {
        // 句柄已随模块卸载失效时同步删除映射，避免反复命中悬空条目。
        auto reverse = handle_mappings_.find(handle_id);
        if (reverse != handle_mappings_.end()) {
            instance_mappings_.erase(reverse->second);
            handle_mappings_.erase(reverse);
        }
        error = handle_error;
        return false;
    }
    if (!check_managed_argument_type(target, type, error)) {
        return false;
    }
    out = Variant(handle_id);
    return true;
}

Variant LeanCLRRuntime::map_handle_to_godot_object(const Variant &value) const {
    if (value.get_type() != godot::Variant::INT) {
        return value;
    }
    auto it = handle_mappings_.find(static_cast<int64_t>(value));
    if (it == handle_mappings_.end()) {
        return value;
    }
    godot::Object *instance = godot::ObjectDB::get_instance(it->second);
    if (instance == nullptr) {
        return value;
    }
    return Variant(instance);
}

void LeanCLRRuntime::sweep_object_mappings() {
    for (auto it = instance_mappings_.begin(); it != instance_mappings_.end();) {
        bool instance_alive = godot::ObjectDB::get_instance(it->first) != nullptr;
        bool handle_alive = object_handles_.find(it->second.handle) != object_handles_.end();
        if (!instance_alive || !handle_alive) {
            handle_mappings_.erase(it->second.handle);
            it = instance_mappings_.erase(it);
        } else {
            ++it;
        }
    }
}

bool LeanCLRRuntime::bind_godot_object(const Variant &instance, int64_t handle) {
    last_error_.clear();
    if (!initialized_) {
        last_error_ = "runtime not initialized";
        return false;
    }
    godot::Object *object = instance.get_validated_object();
    if (object == nullptr) {
        last_error_ = "bind_godot_object expects a valid Godot instance";
        return false;
    }
    std::string handle_error;
    if (resolve_handle(handle, handle_error) == nullptr) {
        last_error_ = handle_error;
        return false;
    }
    uint64_t instance_id = static_cast<uint64_t>(object->get_instance_id());
    auto existing = instance_mappings_.find(instance_id);
    if (existing != instance_mappings_.end()) {
        if (existing->second.handle == handle) {
            return true;
        }
        last_error_ = "Godot instance already bound to handle " + std::to_string(existing->second.handle);
        return false;
    }
    auto reverse = handle_mappings_.find(handle);
    if (reverse != handle_mappings_.end() && reverse->second != instance_id) {
        if (godot::ObjectDB::get_instance(reverse->second) != nullptr) {
            last_error_ = "handle " + std::to_string(handle) + " already bound to another Godot instance";
            return false;
        }
        instance_mappings_.erase(reverse->second);
        handle_mappings_.erase(reverse);
    }
    ObjectMappingEntry entry;
    entry.handle = handle;
    entry.generation = generation_;
    auto handle_it = object_handles_.find(handle);
    if (handle_it != object_handles_.end()) {
        entry.module_name = handle_it->second.module_name;
    }
    instance_mappings_[instance_id] = entry;
    handle_mappings_[handle] = instance_id;
    return true;
}

bool LeanCLRRuntime::unbind_godot_object(const Variant &instance) {
    last_error_.clear();
    godot::Object *object = instance.get_validated_object();
    if (object == nullptr) {
        last_error_ = "unbind_godot_object expects a valid Godot instance";
        return false;
    }
    uint64_t instance_id = static_cast<uint64_t>(object->get_instance_id());
    auto it = instance_mappings_.find(instance_id);
    if (it == instance_mappings_.end()) {
        last_error_ = "no managed object mapped for Godot instance";
        return false;
    }
    handle_mappings_.erase(it->second.handle);
    instance_mappings_.erase(it);
    return true;
}

int64_t LeanCLRRuntime::get_object_mapping_count() {
    last_error_.clear();
    sweep_object_mappings();
    return static_cast<int64_t>(instance_mappings_.size());
}

// 为对象分配可复用的句柄：同一对象始终返回同一个 id，避免每帧读字段都新建 GCHandle。
static int64_t register_object_handle(leanclr::vm::RtObject *object,
                                      std::unordered_map<int64_t, LeanCLRRuntime::HandleEntry> &handles,
                                      int64_t &next_handle_id, int64_t generation) {
    if (object == nullptr) {
        return 0;
    }
    for (const auto &pair : handles) {
        if (leanclr::vm::GCHandle::get_target(pair.second.gc_handle) == object) {
            return pair.first;
        }
    }
    void *handle = leanclr::vm::GCHandle::new_handle(object, false);
    if (handle == nullptr) {
        return 0;
    }
    int64_t id = next_handle_id++;
    LeanCLRRuntime::HandleEntry entry;
    entry.gc_handle = handle;
    entry.generation = generation;
    if (object->klass != nullptr && object->klass->image != nullptr && object->klass->image->get_name_no_ext() != nullptr) {
        entry.module_name = object->klass->image->get_name_no_ext();
    }
    handles[id] = entry;
    return id;
}

static Variant read_field_value(const leanclr::metadata::RtFieldInfo *field, const uint8_t *data, size_t size,
                                std::unordered_map<int64_t, LeanCLRRuntime::HandleEntry> &handles, int64_t &next_handle_id,
                                int64_t generation, std::string &error) {
    const leanclr::metadata::RtTypeSig *type = field->type_sig;
    if (type->ele_type == leanclr::metadata::RtElementType::ValueType) {
        auto class_result = leanclr::vm::Class::get_class_from_typesig(type);
        if (class_result.is_ok() && leanclr::vm::Class::is_enum_type(class_result.unwrap())) {
            return read_enum_value(data, leanclr::vm::Class::get_enum_element_type(class_result.unwrap()));
        }
        godot::PackedByteArray bytes;
        bytes.resize(static_cast<int64_t>(size));
        std::memcpy(bytes.ptrw(), data, size);
        return Variant(bytes);
    }
    switch (type->ele_type) {
        case leanclr::metadata::RtElementType::Boolean:
        case leanclr::metadata::RtElementType::Char:
        case leanclr::metadata::RtElementType::I1:
        case leanclr::metadata::RtElementType::U1:
        case leanclr::metadata::RtElementType::I2:
        case leanclr::metadata::RtElementType::U2:
        case leanclr::metadata::RtElementType::I4:
        case leanclr::metadata::RtElementType::U4:
        case leanclr::metadata::RtElementType::I8:
        case leanclr::metadata::RtElementType::U8:
        case leanclr::metadata::RtElementType::R4:
        case leanclr::metadata::RtElementType::R8:
        case leanclr::metadata::RtElementType::String:
            return read_return_value(data, type, handles, next_handle_id, generation);
        default:
            if (is_reference_element_type(type->ele_type)) {
                leanclr::vm::RtObject *reference = nullptr;
                std::memcpy(&reference, data, sizeof(reference));
                if (reference == nullptr) {
                    return Variant();
                }
                int64_t handle_id = register_object_handle(reference, handles, next_handle_id, generation);
                if (handle_id == 0) {
                    error = "GCHandle::new_handle failed";
                    return Variant();
                }
                return Variant(handle_id);
            }
            error = "reference field is not supported";
            return Variant();
    }
}

static bool write_field_value(const leanclr::metadata::RtFieldInfo *field, uint8_t *data, size_t size, const Variant &value,
                              const std::unordered_map<int64_t, LeanCLRRuntime::HandleEntry> &handles, std::string &error) {
    const leanclr::metadata::RtTypeSig *type = field->type_sig;
    if (type->ele_type == leanclr::metadata::RtElementType::ValueType) {
        auto class_result = leanclr::vm::Class::get_class_from_typesig(type);
        if (class_result.is_ok() && leanclr::vm::Class::is_enum_type(class_result.unwrap())) {
            write_enum_value(data, static_cast<int64_t>(value), leanclr::vm::Class::get_enum_element_type(class_result.unwrap()));
            return true;
        }
        if (value.get_type() == Variant::PACKED_BYTE_ARRAY) {
            godot::PackedByteArray bytes = value;
            if (static_cast<size_t>(bytes.size()) != size) {
                error = "struct field size mismatch";
                return false;
            }
            std::memcpy(data, bytes.ptr(), size);
            return true;
        }
        error = "struct field requires PackedByteArray";
        return false;
    }
    switch (type->ele_type) {
        case leanclr::metadata::RtElementType::Boolean:
        case leanclr::metadata::RtElementType::Char:
        case leanclr::metadata::RtElementType::I1:
        case leanclr::metadata::RtElementType::U1:
        case leanclr::metadata::RtElementType::I2:
        case leanclr::metadata::RtElementType::U2:
        case leanclr::metadata::RtElementType::I4:
        case leanclr::metadata::RtElementType::U4:
        case leanclr::metadata::RtElementType::I8:
        case leanclr::metadata::RtElementType::U8:
        case leanclr::metadata::RtElementType::R4:
        case leanclr::metadata::RtElementType::R8:
        case leanclr::metadata::RtElementType::String: {
            size_t offset = 0;
            if (!push_argument_value(data, offset, value, type, handles)) {
                error = "unsupported field type: " + std::to_string(static_cast<int>(type->ele_type));
                return false;
            }
            return true;
        }
        default:
            if (is_reference_element_type(type->ele_type)) {
                if (value.get_type() == godot::Variant::NIL) {
                    leanclr::vm::RtObject *null_reference = nullptr;
                    std::memcpy(data, &null_reference, sizeof(null_reference));
                    return true;
                }
                if (value.get_type() != godot::Variant::INT) {
                    error = "reference field expects an object handle or null";
                    return false;
                }
                int64_t handle_id = static_cast<int64_t>(value);
                auto it = handles.find(handle_id);
                if (it == handles.end()) {
                    error = "invalid object handle";
                    return false;
                }
                leanclr::vm::RtObject *reference = leanclr::vm::GCHandle::get_target(it->second.gc_handle);
                if (reference == nullptr) {
                    error = "object handle target is null";
                    return false;
                }
                std::memcpy(data, &reference, sizeof(reference));
                return true;
            }
            error = "reference field is not supported";
            return false;
    }
}

Variant LeanCLRRuntime::invoke_static(const String &class_full_name, const String &method_name, const Array &args) {
    last_error_.clear();
    if (!initialized_ || last_module_ == nullptr) {
        last_error_ = "runtime not initialized or no assembly loaded";
        return Variant();
    }
    godot::CharString class_u8 = class_full_name.utf8();
    godot::CharString method_u8 = method_name.utf8();
    auto class_result = last_module_->get_class_by_nested_full_name(class_u8.get_data(), false, true);
    if (class_result.is_err()) {
        last_error_ = "class not found: " + std::string(class_u8.get_data());
        return Variant();
    }
    auto *klass = class_result.unwrap();
    auto init_result = leanclr::vm::Class::initialize_all(klass);
    if (init_result.is_err()) {
        last_error_ = "Class::initialize_all failed: " + std::to_string(static_cast<int>(init_result.unwrap_err()));
        return Variant();
    }
    const leanclr::metadata::RtMethodInfo *method = leanclr::vm::Method::find_matched_method_in_class_by_name(klass, method_u8.get_data());
    if (method == nullptr) {
        last_error_ = "method not found: " + std::string(method_u8.get_data());
        return Variant();
    }
    if (!leanclr::vm::Method::is_static(method)) {
        last_error_ = "method is not static";
        return Variant();
    }
    size_t param_count = leanclr::vm::Method::get_param_count_exclude_this(method);
    if (param_count != static_cast<size_t>(args.size())) {
        last_error_ = "argument count mismatch: expected " + std::to_string(param_count) + ", got " + std::to_string(args.size());
        return Variant();
    }

    std::vector<uint64_t> arg_storage(method->total_arg_stack_object_size == 0 ? 1 : method->total_arg_stack_object_size, 0);
    std::vector<uint64_t> ret_storage(method->ret_stack_object_size == 0 ? 1 : method->ret_stack_object_size, 0);
    uint8_t *arg_buffer = reinterpret_cast<uint8_t *>(arg_storage.data());
    size_t offset = 0;
    for (size_t i = 0; i < param_count; ++i) {
        Variant normalized;
        if (!normalize_object_argument(args[static_cast<int>(i)], method->parameters[i], normalized, last_error_)) {
            return Variant();
        }
        if (!push_argument_value(arg_buffer, offset, normalized, method->parameters[i], object_handles_)) {
            last_error_ = "unsupported parameter type or invalid object handle: " + std::to_string(static_cast<int>(method->parameters[i]->ele_type));
            return Variant();
        }
    }

    auto invoke_result = leanclr::vm::Runtime::invoke_stackobject_arguments_with_run_cctor(
        method,
        reinterpret_cast<const leanclr::interp::RtStackObject *>(arg_buffer),
        reinterpret_cast<leanclr::interp::RtStackObject *>(ret_storage.data()));
    if (invoke_result.is_err()) {
        last_error_ = "invoke failed: " + std::to_string(static_cast<int>(invoke_result.unwrap_err()));
        return Variant();
    }
    return map_handle_to_godot_object(read_return_value(reinterpret_cast<const uint8_t *>(ret_storage.data()), method->return_type,
                                                       object_handles_, next_handle_id_, generation_));
}

int64_t LeanCLRRuntime::create_object(const String &class_full_name) {
    last_error_.clear();
    if (!initialized_ || last_module_ == nullptr) {
        last_error_ = "runtime not initialized or no assembly loaded";
        return 0;
    }
    godot::CharString class_u8 = class_full_name.utf8();
    auto class_result = last_module_->get_class_by_nested_full_name(class_u8.get_data(), false, true);
    if (class_result.is_err()) {
        last_error_ = "class not found: " + std::string(class_u8.get_data());
        return 0;
    }
    auto *klass = class_result.unwrap();
    auto init_result = leanclr::vm::Class::initialize_all(klass);
    if (init_result.is_err()) {
        last_error_ = "Class::initialize_all failed: " + std::to_string(static_cast<int>(init_result.unwrap_err()));
        return 0;
    }
    auto object_result = LEANCLR_NEWOBJ_INTERNAL(klass, "LeanCLRRuntime::create_object");
    if (object_result.is_err()) {
        last_error_ = "new object failed: " + std::to_string(static_cast<int>(object_result.unwrap_err()));
        return 0;
    }
    leanclr::vm::RtObject *object = object_result.unwrap();

    const leanclr::metadata::RtMethodInfo *ctor =
        leanclr::vm::Method::find_matched_method_in_class_by_name_and_signature(klass, ".ctor", nullptr, 0);
    if (ctor != nullptr) {
        std::vector<uint64_t> ctor_args(ctor->total_arg_stack_object_size == 0 ? 1 : ctor->total_arg_stack_object_size, 0);
        std::vector<uint64_t> ctor_ret(ctor->ret_stack_object_size == 0 ? 1 : ctor->ret_stack_object_size, 0);
        void *this_ptr = object;
        std::memcpy(ctor_args.data(), &this_ptr, sizeof(this_ptr));
        auto ctor_result = leanclr::vm::Runtime::invoke_stackobject_arguments_with_run_cctor(
            ctor,
            reinterpret_cast<const leanclr::interp::RtStackObject *>(ctor_args.data()),
            reinterpret_cast<leanclr::interp::RtStackObject *>(ctor_ret.data()));
        if (ctor_result.is_err()) {
            last_error_ = "constructor failed: " + std::to_string(static_cast<int>(ctor_result.unwrap_err()));
            return 0;
        }
    }

    int64_t id = register_object_handle(object, object_handles_, next_handle_id_, generation_);
    if (id == 0) {
        last_error_ = "GCHandle::new_handle failed";
    }
    return id;
}

Variant LeanCLRRuntime::invoke_method(int64_t handle_id, const String &method_name, const Array &args) {
    last_error_.clear();
    if (!initialized_) {
        last_error_ = "runtime not initialized";
        return Variant();
    }
    std::string handle_error;
    leanclr::vm::RtObject *object = resolve_handle(handle_id, handle_error);
    if (object == nullptr) {
        last_error_ = handle_error;
        return Variant();
    }
    godot::CharString method_u8 = method_name.utf8();
    const leanclr::metadata::RtMethodInfo *method =
        leanclr::vm::Method::find_matched_method_in_class_by_name(object->klass, method_u8.get_data());
    if (method == nullptr) {
        last_error_ = "method not found: " + std::string(method_u8.get_data());
        return Variant();
    }
    if (!leanclr::vm::Method::is_instance(method)) {
        last_error_ = "method is not an instance method";
        return Variant();
    }
    size_t param_count = leanclr::vm::Method::get_param_count_exclude_this(method);
    if (param_count != static_cast<size_t>(args.size())) {
        last_error_ = "argument count mismatch: expected " + std::to_string(param_count) + ", got " + std::to_string(args.size());
        return Variant();
    }

    std::vector<uint64_t> arg_storage(method->total_arg_stack_object_size == 0 ? 1 : method->total_arg_stack_object_size, 0);
    std::vector<uint64_t> ret_storage(method->ret_stack_object_size == 0 ? 1 : method->ret_stack_object_size, 0);
    uint8_t *arg_buffer = reinterpret_cast<uint8_t *>(arg_storage.data());
    void *this_ptr = object;
    // 参数按 RtStackObject（固定 8 字节）槽位排布；32 位平台 sizeof(void*) 只有 4，
    // 用 sizeof(void*) 推进会错位，导致后续 int 参数读到 0。
    const size_t stack_slot_size = sizeof(leanclr::interp::RtStackObject);
    std::memcpy(arg_buffer, &this_ptr, sizeof(this_ptr));
    size_t offset = stack_slot_size;
    for (size_t i = 0; i < param_count; ++i) {
        Variant normalized;
        if (!normalize_object_argument(args[static_cast<int>(i)], method->parameters[i], normalized, last_error_)) {
            return Variant();
        }
        if (!push_argument_value(arg_buffer, offset, normalized, method->parameters[i], object_handles_)) {
            last_error_ = "unsupported parameter type or invalid object handle: " + std::to_string(static_cast<int>(method->parameters[i]->ele_type));
            return Variant();
        }
    }

    auto invoke_result = leanclr::vm::Runtime::invoke_stackobject_arguments_with_run_cctor(
        method,
        reinterpret_cast<const leanclr::interp::RtStackObject *>(arg_buffer),
        reinterpret_cast<leanclr::interp::RtStackObject *>(ret_storage.data()));
    if (invoke_result.is_err()) {
        last_error_ = "invoke failed: " + std::to_string(static_cast<int>(invoke_result.unwrap_err()));
        return Variant();
    }
    return map_handle_to_godot_object(read_return_value(reinterpret_cast<const uint8_t *>(ret_storage.data()), method->return_type,
                                                       object_handles_, next_handle_id_, generation_));
}

bool LeanCLRRuntime::has_method(int64_t handle_id, const String &method_name) {
    if (stale_handles_.find(handle_id) != stale_handles_.end()) {
        return false;
    }
    auto it = object_handles_.find(handle_id);
    if (it == object_handles_.end()) {
        return false;
    }
    leanclr::vm::RtObject *object = leanclr::vm::GCHandle::get_target(it->second.gc_handle);
    if (object == nullptr || object->klass == nullptr) {
        return false;
    }
    godot::CharString method_u8 = method_name.utf8();
    const leanclr::metadata::RtMethodInfo *method =
        leanclr::vm::Method::find_matched_method_in_class_by_name(object->klass, method_u8.get_data());
    return method != nullptr && leanclr::vm::Method::is_instance(method);
}

Variant LeanCLRRuntime::get_field(int64_t handle_id, const String &field_name) {
    last_error_.clear();
    if (!initialized_) {
        last_error_ = "runtime not initialized";
        return Variant();
    }
    std::string handle_error;
    leanclr::vm::RtObject *object = resolve_handle(handle_id, handle_error);
    if (object == nullptr) {
        last_error_ = handle_error;
        return Variant();
    }
    godot::CharString field_u8 = field_name.utf8();
    auto field_result = leanclr::vm::Field::find_field_by_name(const_cast<leanclr::metadata::RtClass *>(object->klass), field_u8.get_data());
    if (field_result.is_err()) {
        last_error_ = "field not found: " + std::string(field_u8.get_data());
        return Variant();
    }
    const leanclr::metadata::RtFieldInfo *field = field_result.unwrap();
    if (!leanclr::vm::Field::is_instance(field)) {
        last_error_ = "field is not an instance field";
        return Variant();
    }
    auto size_result = leanclr::vm::Field::get_field_size(field);
    if (size_result.is_err()) {
        last_error_ = "get field size failed";
        return Variant();
    }
    size_t field_size = size_result.unwrap();
    std::vector<uint8_t> field_buffer(field_size == 0 ? 1 : field_size, 0);
    auto read_result = leanclr::vm::Field::get_instance_value(field, object, field_buffer.data());
    if (read_result.is_err()) {
        last_error_ = "get field failed: " + std::to_string(static_cast<int>(read_result.unwrap_err()));
        return Variant();
    }
    return map_handle_to_godot_object(
        read_field_value(field, field_buffer.data(), field_size, object_handles_, next_handle_id_, generation_, last_error_));
}

bool LeanCLRRuntime::set_field(int64_t handle_id, const String &field_name, const Variant &value) {
    last_error_.clear();
    if (!initialized_) {
        last_error_ = "runtime not initialized";
        return false;
    }
    std::string handle_error;
    leanclr::vm::RtObject *object = resolve_handle(handle_id, handle_error);
    if (object == nullptr) {
        last_error_ = handle_error;
        return false;
    }
    godot::CharString field_u8 = field_name.utf8();
    auto field_result = leanclr::vm::Field::find_field_by_name(const_cast<leanclr::metadata::RtClass *>(object->klass), field_u8.get_data());
    if (field_result.is_err()) {
        last_error_ = "field not found: " + std::string(field_u8.get_data());
        return false;
    }
    const leanclr::metadata::RtFieldInfo *field = field_result.unwrap();
    if (!leanclr::vm::Field::is_instance(field)) {
        last_error_ = "field is not an instance field";
        return false;
    }
    auto size_result = leanclr::vm::Field::get_field_size(field);
    if (size_result.is_err()) {
        last_error_ = "get field size failed";
        return false;
    }
    size_t field_size = size_result.unwrap();
    std::vector<uint8_t> field_buffer(field_size < 8 ? 8 : field_size, 0);
    Variant normalized;
    if (!normalize_object_argument(value, field->type_sig, normalized, last_error_)) {
        return false;
    }
    if (!write_field_value(field, field_buffer.data(), field_size, normalized, object_handles_, last_error_)) {
        return false;
    }
    auto write_result = leanclr::vm::Field::set_instance_value(field, object, field_buffer.data());
    if (write_result.is_err()) {
        last_error_ = "set field failed: " + std::to_string(static_cast<int>(write_result.unwrap_err()));
        return false;
    }
    return true;
}

void LeanCLRRuntime::destroy_object(int64_t handle_id) {
    auto it = object_handles_.find(handle_id);
    if (it == object_handles_.end()) {
        return;
    }
    leanclr::vm::GCHandle::free_handle(it->second.gc_handle);
    object_handles_.erase(it);
    auto reverse = handle_mappings_.find(handle_id);
    if (reverse != handle_mappings_.end()) {
        instance_mappings_.erase(reverse->second);
        handle_mappings_.erase(reverse);
    }
}

String LeanCLRRuntime::get_last_error() const {
    return godot::String(last_error_.c_str());
}