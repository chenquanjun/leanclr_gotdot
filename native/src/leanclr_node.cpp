#include "leanclr_node.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/memory.hpp>
#include <godot_cpp/core/property_info.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/callable_custom.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

namespace {

// 可变参数信号转发器：接受信号实际发出的任意数量参数，原样转交给托管方法。
class LeanCLRSignalForwarder : public CallableCustom {
public:
    LeanCLRSignalForwarder(LeanCLRNode *owner, const String &managed_method)
        : owner_(owner), managed_method_(managed_method) {}

    uint32_t hash() const override {
        uint64_t id = owner_ != nullptr ? owner_->get_instance_id() : 0;
        return static_cast<uint32_t>(managed_method_.hash() ^ static_cast<uint32_t>(id));
    }

    String get_as_text() const override {
        return "LeanCLRNode::" + managed_method_;
    }

    CompareEqualFunc get_compare_equal_func() const override {
        return &compare_equal;
    }

    CompareLessFunc get_compare_less_func() const override {
        return &compare_less;
    }

    ObjectID get_object() const override {
        return owner_ != nullptr ? ObjectID(owner_->get_instance_id()) : ObjectID();
    }

    int get_argument_count(bool &r_is_valid) const override {
        r_is_valid = false;
        return 0;
    }

    void call(const Variant **p_args, int p_argcount, Variant &r_ret, GDExtensionCallError &r_error) const override {
        Array args;
        for (int i = 0; i < p_argcount; ++i) {
            args.append(*p_args[i]);
        }
        if (owner_ != nullptr) {
            owner_->forward_signal_args(managed_method_, args);
        }
        r_ret = Variant();
        r_error.error = GDEXTENSION_CALL_OK;
        r_error.argument = 0;
        r_error.expected = 0;
    }

private:
    static bool compare_equal(const CallableCustom *a, const CallableCustom *b) {
        auto *left = static_cast<const LeanCLRSignalForwarder *>(a);
        auto *right = static_cast<const LeanCLRSignalForwarder *>(b);
        return left->owner_ == right->owner_ && left->managed_method_ == right->managed_method_;
    }

    static bool compare_less(const CallableCustom *a, const CallableCustom *b) {
        auto *left = static_cast<const LeanCLRSignalForwarder *>(a);
        auto *right = static_cast<const LeanCLRSignalForwarder *>(b);
        uint64_t left_id = left->owner_ != nullptr ? left->owner_->get_instance_id() : 0;
        uint64_t right_id = right->owner_ != nullptr ? right->owner_->get_instance_id() : 0;
        if (left_id != right_id) {
            return left_id < right_id;
        }
        return left->managed_method_ < right->managed_method_;
    }

    LeanCLRNode *owner_ = nullptr;
    String managed_method_;
};

} // namespace

void LeanCLRNode::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_managed_type", "value"), &LeanCLRNode::set_managed_type);
    ClassDB::bind_method(D_METHOD("get_managed_type"), &LeanCLRNode::get_managed_type);
    ClassDB::bind_method(D_METHOD("set_managed_assembly", "value"), &LeanCLRNode::set_managed_assembly);
    ClassDB::bind_method(D_METHOD("get_managed_assembly"), &LeanCLRNode::get_managed_assembly);
    ClassDB::bind_method(D_METHOD("set_runtime", "value"), &LeanCLRNode::set_runtime);
    ClassDB::bind_method(D_METHOD("get_runtime"), &LeanCLRNode::get_runtime);
    ClassDB::bind_method(D_METHOD("call_managed", "method_name", "args"), &LeanCLRNode::call_managed);
    ClassDB::bind_method(D_METHOD("get_managed_property", "name"), &LeanCLRNode::get_managed_property);
    ClassDB::bind_method(D_METHOD("set_managed_property", "name", "value"), &LeanCLRNode::set_managed_property);
    ClassDB::bind_method(D_METHOD("bind_signal", "signal_name", "managed_method"), &LeanCLRNode::bind_signal);
    ClassDB::bind_method(D_METHOD("bind_signal_args", "signal_name", "managed_method", "arg_count"), &LeanCLRNode::bind_signal_args);
    ClassDB::bind_method(D_METHOD("rebind_managed_object"), &LeanCLRNode::rebind_managed_object);
    ClassDB::bind_method(D_METHOD("has_pending_rebind"), &LeanCLRNode::has_pending_rebind);
    ClassDB::bind_method(D_METHOD("get_bound_generation"), &LeanCLRNode::get_bound_generation);
    ClassDB::bind_method(D_METHOD("emit_leanclr_signal"), &LeanCLRNode::emit_leanclr_signal);
    ClassDB::bind_method(D_METHOD("emit_leanclr_signal_args", "text"), &LeanCLRNode::emit_leanclr_signal_args);
    ClassDB::bind_method(D_METHOD("emit_leanclr_signal_args2", "text", "value"), &LeanCLRNode::emit_leanclr_signal_args2);
    ClassDB::bind_method(D_METHOD("emit_leanclr_signal_mixed", "handle", "text", "value"), &LeanCLRNode::emit_leanclr_signal_mixed);
    ClassDB::bind_method(D_METHOD("emit_leanclr_signal_object", "instance", "text"), &LeanCLRNode::emit_leanclr_signal_object);
    ClassDB::bind_method(D_METHOD("get_object_handle"), &LeanCLRNode::get_object_handle);
    ClassDB::bind_method(D_METHOD("_forward_signal", "managed_method"), &LeanCLRNode::_forward_signal);
    ClassDB::bind_method(D_METHOD("_forward_signal_1", "arg0", "managed_method"), &LeanCLRNode::_forward_signal_1);
    ClassDB::bind_method(D_METHOD("_forward_signal_2", "arg0", "arg1", "managed_method"), &LeanCLRNode::_forward_signal_2);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "managed_type"), "set_managed_type", "get_managed_type");
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "managed_assembly"), "set_managed_assembly", "get_managed_assembly");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "runtime", PROPERTY_HINT_RESOURCE_TYPE, "LeanCLRRuntime"), "set_runtime", "get_runtime");
    ADD_SIGNAL(MethodInfo("leanclr_signal"));
    ADD_SIGNAL(MethodInfo("leanclr_signal_args", PropertyInfo(Variant::STRING, "text")));
    ADD_SIGNAL(MethodInfo("leanclr_signal_args2", PropertyInfo(Variant::STRING, "text"), PropertyInfo(Variant::INT, "value")));
    ADD_SIGNAL(MethodInfo("leanclr_signal_mixed", PropertyInfo(Variant::INT, "handle"), PropertyInfo(Variant::STRING, "text"), PropertyInfo(Variant::INT, "value")));
    ADD_SIGNAL(MethodInfo("leanclr_signal_object", PropertyInfo(Variant::OBJECT, "instance"), PropertyInfo(Variant::STRING, "text")));
}

void LeanCLRNode::set_managed_type(const String &value) {
    managed_type_ = value;
}

String LeanCLRNode::get_managed_type() const {
    return managed_type_;
}

void LeanCLRNode::set_managed_assembly(const String &value) {
    managed_assembly_ = value;
}

String LeanCLRNode::get_managed_assembly() const {
    return managed_assembly_;
}

void LeanCLRNode::set_runtime(const Ref<LeanCLRRuntime> &value) {
    runtime_ = value;
}

Ref<LeanCLRRuntime> LeanCLRNode::get_runtime() const {
    return runtime_;
}

Variant LeanCLRNode::call_managed(const String &method_name, const Array &args) {
    if (object_handle_ == 0 || runtime_.is_null()) {
        return Variant();
    }
    return runtime_->invoke_method(object_handle_, method_name, args);
}

Variant LeanCLRNode::get_managed_property(const String &name) {
    if (object_handle_ == 0 || runtime_.is_null()) {
        return Variant();
    }
    return runtime_->get_field(object_handle_, name);
}

bool LeanCLRNode::set_managed_property(const String &name, const Variant &value) {
    if (object_handle_ == 0 || runtime_.is_null()) {
        return false;
    }
    return runtime_->set_field(object_handle_, name, value);
}

void LeanCLRNode::bind_signal(const String &signal_name, const String &managed_method) {
    bind_signal_args(signal_name, managed_method, 0);
}

void LeanCLRNode::bind_signal_args(const String &signal_name, const String &managed_method, int32_t arg_count) {
    // 参数数量不再受限：转发器按信号实际发出的参数个数动态收集。
    Callable callable(memnew(LeanCLRSignalForwarder(this, managed_method)));
    connect(StringName(signal_name), callable);

    for (const SignalBinding &binding : signal_bindings_) {
        if (binding.signal_name == signal_name && binding.managed_method == managed_method) {
            return;
        }
    }
    SignalBinding binding;
    binding.signal_name = signal_name;
    binding.managed_method = managed_method;
    binding.arg_count = arg_count;
    signal_bindings_.push_back(binding);
}

bool LeanCLRNode::rebind_managed_object() {
    if (runtime_.is_null() || managed_type_.is_empty()) {
        return false;
    }
    if (!managed_assembly_.is_empty() && runtime_->is_initialized()) {
        runtime_->load_assembly(managed_assembly_);
    }
    int64_t handle = runtime_->create_object(managed_type_);
    if (handle == 0) {
        pending_rebind_ = true;
        UtilityFunctions::push_error("[hotreload] rebind pending: " + managed_type_ + " (" + runtime_->get_last_error() + ")");
        return false;
    }
    object_handle_ = handle;
    bound_generation_ = runtime_->get_generation();
    pending_rebind_ = false;
    if (runtime_->has_method(object_handle_, "SetOwnerId")) {
        Array owner_args;
        owner_args.append(static_cast<int64_t>(get_instance_id()));
        runtime_->invoke_method(object_handle_, "SetOwnerId", owner_args);
    }
    if (runtime_->has_method(object_handle_, "OnEnterTree")) {
        runtime_->invoke_method(object_handle_, "OnEnterTree", Array());
    }
    UtilityFunctions::print("[hotreload] node rebound: type=" + managed_type_ + ", generation=" +
                            String::num_int64(bound_generation_) + ", signals=" +
                            String::num_int64(static_cast<int64_t>(signal_bindings_.size())));
    return true;
}

bool LeanCLRNode::has_pending_rebind() const {
    return pending_rebind_;
}

int64_t LeanCLRNode::get_bound_generation() const {
    return bound_generation_;
}

int64_t LeanCLRNode::get_object_handle() const {
    return object_handle_;
}

void LeanCLRNode::check_generation() {
    if (runtime_.is_null() || object_handle_ == 0) {
        return;
    }
    if (bound_generation_ < 0) {
        bound_generation_ = runtime_->get_generation();
        return;
    }
    if (runtime_->get_generation() != bound_generation_) {
        if (pending_rebind_ && rebind_attempt_generation_ == runtime_->get_generation()) {
            return;
        }
        rebind_attempt_generation_ = runtime_->get_generation();
        rebind_managed_object();
    }
}

void LeanCLRNode::emit_leanclr_signal() {
    emit_signal(StringName("leanclr_signal"));
}

void LeanCLRNode::emit_leanclr_signal_args(const String &text) {
    emit_signal(StringName("leanclr_signal_args"), text);
}

void LeanCLRNode::emit_leanclr_signal_args2(const String &text, int64_t value) {
    emit_signal(StringName("leanclr_signal_args2"), text, value);
}

void LeanCLRNode::emit_leanclr_signal_mixed(const Variant &handle, const String &text, int64_t value) {
    emit_signal(StringName("leanclr_signal_mixed"), handle, text, value);
}

void LeanCLRNode::emit_leanclr_signal_object(const Variant &instance, const String &text) {
    emit_signal(StringName("leanclr_signal_object"), instance, text);
}

void LeanCLRNode::forward_signal_args(const String &managed_method, const Array &args) {
    if (object_handle_ == 0 || runtime_.is_null()) {
        return;
    }
    if (runtime_->has_method(object_handle_, managed_method)) {
        runtime_->invoke_method(object_handle_, managed_method, args);
    }
}

void LeanCLRNode::_forward_signal(const String &managed_method) {
    if (object_handle_ == 0 || runtime_.is_null()) {
        return;
    }
    if (runtime_->has_method(object_handle_, managed_method)) {
        runtime_->invoke_method(object_handle_, managed_method, Array());
    }
}

void LeanCLRNode::_forward_signal_1(const Variant &arg0, const String &managed_method) {
    if (object_handle_ == 0 || runtime_.is_null()) {
        return;
    }
    if (runtime_->has_method(object_handle_, managed_method)) {
        Array args;
        args.append(arg0);
        runtime_->invoke_method(object_handle_, managed_method, args);
    }
}

void LeanCLRNode::_forward_signal_2(const Variant &arg0, const Variant &arg1, const String &managed_method) {
    if (object_handle_ == 0 || runtime_.is_null()) {
        return;
    }
    if (runtime_->has_method(object_handle_, managed_method)) {
        Array args;
        args.append(arg0);
        args.append(arg1);
        runtime_->invoke_method(object_handle_, managed_method, args);
    }
}

void LeanCLRNode::_enter_tree() {
    if (runtime_.is_null() || managed_type_.is_empty()) {
        return;
    }
    if (object_handle_ == 0) {
        if (!managed_assembly_.is_empty() && runtime_->is_initialized()) {
            runtime_->load_assembly(managed_assembly_);
        }
        object_handle_ = runtime_->create_object(managed_type_);
        if (object_handle_ == 0) {
            UtilityFunctions::push_error("LeanCLRNode create_object failed: " + runtime_->get_last_error());
            return;
        }
    }
    if (runtime_->has_method(object_handle_, "SetOwnerId")) {
        Array owner_args;
        owner_args.append(static_cast<int64_t>(get_instance_id()));
        runtime_->invoke_method(object_handle_, "SetOwnerId", owner_args);
    }
    bound_generation_ = runtime_->get_generation();
    if (runtime_->has_method(object_handle_, "OnEnterTree")) {
        runtime_->invoke_method(object_handle_, "OnEnterTree", Array());
    }
}

void LeanCLRNode::_ready() {
    set_process(true);
    set_physics_process(true);
    if (object_handle_ == 0 || runtime_.is_null()) {
        return;
    }
    if (runtime_->has_method(object_handle_, "OnReady")) {
        runtime_->invoke_method(object_handle_, "OnReady", Array());
    }
}

void LeanCLRNode::_process(double delta) {
    check_generation();
    if (object_handle_ == 0 || runtime_.is_null()) {
        return;
    }
    if (runtime_->has_method(object_handle_, "OnProcess")) {
        Array args;
        args.append(delta);
        runtime_->invoke_method(object_handle_, "OnProcess", args);
    }
}

void LeanCLRNode::_physics_process(double delta) {
    check_generation();
    if (object_handle_ == 0 || runtime_.is_null()) {
        return;
    }
    if (runtime_->has_method(object_handle_, "OnPhysicsProcess")) {
        Array args;
        args.append(delta);
        runtime_->invoke_method(object_handle_, "OnPhysicsProcess", args);
    }
}

void LeanCLRNode::_exit_tree() {
    if (object_handle_ == 0 || runtime_.is_null()) {
        return;
    }
    if (runtime_->has_method(object_handle_, "OnExitTree")) {
        runtime_->invoke_method(object_handle_, "OnExitTree", Array());
    }
    runtime_->destroy_object(object_handle_);
    object_handle_ = 0;
}