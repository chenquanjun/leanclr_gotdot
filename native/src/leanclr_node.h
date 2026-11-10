#pragma once

#include <godot_cpp/classes/node.hpp>

#include "leanclr_runtime.h"

namespace godot {

class LeanCLRNode : public Node {
    GDCLASS(LeanCLRNode, Node)

    struct SignalBinding {
        String signal_name;
        String managed_method;
        int32_t arg_count = 0;
    };

    String managed_type_;
    String managed_assembly_;
    Ref<LeanCLRRuntime> runtime_;
    int64_t object_handle_ = 0;
    int64_t bound_generation_ = -1;
    int64_t rebind_attempt_generation_ = -1;
    bool pending_rebind_ = false;
    std::vector<SignalBinding> signal_bindings_;

    void check_generation();

protected:
    static void _bind_methods();

public:
    void set_managed_type(const String &value);
    String get_managed_type() const;
    void set_managed_assembly(const String &value);
    String get_managed_assembly() const;
    void set_runtime(const Ref<LeanCLRRuntime> &value);
    Ref<LeanCLRRuntime> get_runtime() const;
    Variant call_managed(const String &method_name, const Array &args);
    Variant get_managed_property(const String &name);
    bool set_managed_property(const String &name, const Variant &value);
    void bind_signal(const String &signal_name, const String &managed_method);
    void bind_signal_args(const String &signal_name, const String &managed_method, int32_t arg_count);
    // 运行时换代后按类名+信号名重新绑定托管对象；失败时保持 pending 状态。
    bool rebind_managed_object();
    bool has_pending_rebind() const;
    int64_t get_bound_generation() const;
    // 当前托管对象句柄；0 表示尚未创建。
    int64_t get_object_handle() const;
    void emit_leanclr_signal();
    void emit_leanclr_signal_args(const String &text);
    void emit_leanclr_signal_args2(const String &text, int64_t value);
    void emit_leanclr_signal_mixed(const Variant &handle, const String &text, int64_t value);
    void emit_leanclr_signal_object(const Variant &instance, const String &text);
    // 把任意数量的信号参数原样转发给托管方法（引用类型用 int64 句柄或 null 表达）。
    void forward_signal_args(const String &managed_method, const Array &args);
    void _forward_signal(const String &managed_method);
    void _forward_signal_1(const Variant &arg0, const String &managed_method);
    void _forward_signal_2(const Variant &arg0, const Variant &arg1, const String &managed_method);
    void _enter_tree() override;
    void _ready() override;
    void _process(double delta) override;
    void _physics_process(double delta) override;
    void _exit_tree() override;
};

}