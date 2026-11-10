#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include "alloc/general_allocation.h"
#include "metadata/module_def.h"
#include "metadata/rt_metadata.h"
#include "vm/assembly.h"
#include "vm/class.h"
#include "vm/method.h"
#include "vm/rt_string.h"
#include "vm/runtime.h"
#include "vm/settings.h"

using namespace leanclr;

static std::vector<std::string> g_lib_dirs;

static bool file_loader(const char *assembly_name, const char *extension, vm::FileData &file_data) {
    for (const auto &dir : g_lib_dirs) {
        std::string path = dir + "/" + assembly_name + "." + extension;
        std::ifstream file(path, std::ios::binary | std::ios::ate);
        if (!file.is_open()) {
            continue;
        }
        std::streamsize size = file.tellg();
        if (size <= 0) {
            continue;
        }
        file.seekg(0, std::ios::beg);
        auto *data = static_cast<uint8_t *>(alloc::GeneralAllocation::malloc(static_cast<size_t>(size)));
        if (data == nullptr) {
            return false;
        }
        if (!file.read(reinterpret_cast<char *>(data), size)) {
            alloc::GeneralAllocation::free(data);
            continue;
        }
        file_data.data = data;
        file_data.length = static_cast<size_t>(size);
        file_data.shared = false;
        return true;
    }
    return false;
}

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

static const metadata::RtMethodInfo *find_method(metadata::RtModuleDef *mod, const char *class_name, const char *method_name) {
    auto class_result = mod->get_class_by_nested_full_name(class_name, false, true);
    if (class_result.is_err()) {
        std::cerr << "class not found: " << class_name << std::endl;
        return nullptr;
    }
    auto *klass = class_result.unwrap();
    auto init_result = vm::Class::initialize_all(klass);
    if (init_result.is_err()) {
        std::cerr << "class init failed: " << static_cast<int>(init_result.unwrap_err()) << std::endl;
        return nullptr;
    }
    const metadata::RtMethodInfo *method = vm::Method::find_matched_method_in_class_by_name(klass, method_name);
    if (method == nullptr) {
        std::cerr << "method not found: " << method_name << std::endl;
    }
    return method;
}

static bool invoke_method(const metadata::RtMethodInfo *method, const std::vector<uint64_t> &args, std::vector<uint64_t> &ret) {
    ret.assign(method->ret_stack_object_size == 0 ? 1 : method->ret_stack_object_size, 0);
    auto result = vm::Runtime::invoke_stackobject_arguments_with_run_cctor(
        method,
        args.empty() ? nullptr : reinterpret_cast<const interp::RtStackObject *>(args.data()),
        reinterpret_cast<interp::RtStackObject *>(ret.data()));
    if (result.is_err()) {
        std::cerr << "invoke failed: " << static_cast<int>(result.unwrap_err()) << std::endl;
        return false;
    }
    return true;
}

static bool run_suite(metadata::RtModuleDef *mod, int32_t &run_value) {
    const metadata::RtMethodInfo *run_method = find_method(mod, "test.App", "Run");
    if (run_method == nullptr) {
        return false;
    }
    std::vector<uint64_t> run_args{1, 2};
    std::vector<uint64_t> run_ret;
    if (!invoke_method(run_method, run_args, run_ret)) {
        return false;
    }
    std::memcpy(&run_value, run_ret.data(), sizeof(run_value));
    std::cout << "test.App::Run(1, 2) = " << run_value << std::endl;

    const metadata::RtMethodInfo *test1_method = find_method(mod, "test.App", "Test1");
    if (test1_method == nullptr) {
        return false;
    }
    std::vector<uint64_t> test1_args;
    std::vector<uint64_t> test1_ret;
    if (!invoke_method(test1_method, test1_args, test1_ret)) {
        return false;
    }
    vm::RtString *text = nullptr;
    std::memcpy(&text, test1_ret.data(), sizeof(text));
    if (text != nullptr) {
        std::cout << "test.App::Test1() = " << utf16_to_utf8(reinterpret_cast<const uint16_t *>(&text->first_char), static_cast<size_t>(text->length)) << std::endl;
    }

    const metadata::RtMethodInfo *main_method = find_method(mod, "test.App", "Main");
    if (main_method == nullptr) {
        return false;
    }
    std::vector<uint64_t> main_args;
    std::vector<uint64_t> main_ret;
    return invoke_method(main_method, main_args, main_ret);
}

int main(int argc, char **argv) {
    if (argc >= 3) {
        g_lib_dirs.push_back(argv[1]);
        g_lib_dirs.push_back(argv[2]);
    } else {
        g_lib_dirs.push_back("godot_project/bin/bcl");
        g_lib_dirs.push_back("godot_project/bin/assemblies");
    }

    vm::Settings::set_file_loader(file_loader);
    auto init_result = vm::Runtime::initialize();
    if (init_result.is_err()) {
        std::cerr << "Runtime::initialize failed: " << static_cast<int>(init_result.unwrap_err()) << std::endl;
        return 1;
    }

    auto assembly_result = vm::Assembly::load_by_name("CoreTests");
    if (assembly_result.is_err()) {
        std::cerr << "Assembly::load_by_name failed: " << static_cast<int>(assembly_result.unwrap_err()) << std::endl;
        return 1;
    }
    metadata::RtModuleDef *mod = assembly_result.unwrap()->mod;

    int32_t run_value = 0;
    if (!run_suite(mod, run_value)) {
        return 1;
    }

    // 第一轮结束后完整清理，再重新初始化并重跑，验证 shutdown/initialize 可循环。
    vm::Runtime::shutdown();

    auto reload_init_result = vm::Runtime::initialize();
    if (reload_init_result.is_err()) {
        std::cerr << "Runtime::initialize (reload) failed: " << static_cast<int>(reload_init_result.unwrap_err()) << std::endl;
        return 1;
    }
    auto reload_assembly_result = vm::Assembly::load_by_name("CoreTests");
    if (reload_assembly_result.is_err()) {
        std::cerr << "Assembly::load_by_name (reload) failed: " << static_cast<int>(reload_assembly_result.unwrap_err()) << std::endl;
        return 1;
    }
    mod = reload_assembly_result.unwrap()->mod;
    int32_t reload_run_value = 0;
    if (!run_suite(mod, reload_run_value)) {
        return 1;
    }

    bool ok = run_value == 3 && reload_run_value == 3;
    if (ok) {
        std::cout << "SMOKE_OK" << std::endl;
    } else {
        std::cout << "SMOKE_FAILED" << std::endl;
    }

    vm::Runtime::shutdown();
    return ok ? 0 : 1;
}
