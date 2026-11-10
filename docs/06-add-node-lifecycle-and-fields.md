# 06 新增节点生命周期、字段与信号

## 1. LeanCLRNode 的角色

`LeanCLRNode` 是 GDExtension 下最接近“C# 脚本挂在节点上”的宿主形态。它继承 Godot `Node`，持有一个 leanclr 对象句柄，并按节点生命周期调用 C# 方法。

相关文件：

- `native/src/leanclr_node.h`
- `native/src/leanclr_node.cpp`
- `native/src/leanclr_runtime.h`
- `native/src/leanclr_runtime.cpp`

## 2. 生命周期映射

| Godot 回调 | LeanCLRNode 行为 | C# 方法 |
|---|---|---|
| `_enter_tree` | 若句柄为 0：加载 `managed_assembly`、`create_object`、注入 `SetOwnerId(instance_id)`；然后调用 `OnEnterTree` | `SetOwnerId(long)`、`OnEnterTree()` |
| `_ready` | 开启 `_process` / `_physics_process`；调用 `OnReady` | `OnReady()` |
| `_process(delta)` | 调用 `OnProcess` | `OnProcess(float delta)` |
| `_physics_process(delta)` | 调用 `OnPhysicsProcess` | `OnPhysicsProcess(float delta)` |
| `_exit_tree` | 调用 `OnExitTree`；释放对象句柄 | `OnExitTree()` |

`has_method` 会先检查 C# 实例是否存在该方法，不存在则跳过。

## 3. 新增生命周期回调的步骤

以新增 `OnNotification(int)` 为例：

1. 在 `leanclr_node.h` 增加重写的 Godot 虚函数或自定义触发方法。
2. 在 `leanclr_node.cpp` 中实现，调用 `runtime_->has_method(...)` 与 `invoke_method`。
3. 在 `demo_csharp/LeanClrGame.cs` 增加对应 C# 方法。
4. 编译 C#、构建 native、部署、回归。
5. 在 `demo.gd` 中触发该生命周期（若 Godot 不自动触发）。

## 4. 字段访问

### 4.1 接口

```gdscript
runtime.get_field(handle, "score")
runtime.set_field(handle, "score", 42)
player.get_managed_property("score")
player.set_managed_property("score", 99)
```

### 4.2 实现

`LeanCLRRuntime::get_field / set_field`：

1. `Field::find_field_by_name(klass, name)` 查找字段。
2. `Field::is_instance(field)` 校验实例字段。
3. `Field::get_field_size(field)` 获取大小。
4. `Field::get_instance_value` / `set_instance_value` 读写（内部已处理对象头偏移）。

### 4.3 字段类型支持

- 简单类型：`bool` / `int` / `float` / `double` / `string`。
- 枚举：自动按底层整数（`I1`..`U8`）读写，对外返回 `int64`。
- struct：按 `Field::get_field_size` 动态分配缓冲区，读写使用 `PackedByteArray` 原始字节；`set_field` 时字节长度必须与字段大小一致。
- 引用类型（`Class` / `Object` / `SZArray` / `Array` / `GenericInst` / `Var`）：读字段返回对象句柄（`int64`，同一对象复用同一 id），`null` 返回 `null`；写字段接受已注册句柄或 `null`。方法返回值的引用类型同样走句柄，方法参数的引用类型接受句柄或 `null`。

## 5. 信号

### 5.1 已有能力

- `bind_signal(signal_name, managed_method)`：0 参信号转发。
- `bind_signal_args(signal_name, managed_method, arg_count)`：`arg_count` 仅作元数据记录，实际由 `CallableCustom` 转发器按信号发出的参数个数动态转发，参数个数不限。
- `emit_leanclr_signal()` / `emit_leanclr_signal_args(text)` / `emit_leanclr_signal_args2(text, value)` / `emit_leanclr_signal_mixed(handle, text, value)` / `emit_leanclr_signal_object(instance, text)`：触发自定义信号。
- C# 主动发信号：`GodotNative.node_emit_signal(instance_id, signal_name)`。
- 已验证 C# → Godot `emit_signal` → LeanCLRNode 转发 → C# 回调的重入链路可行。
- 带参信号实测：`signal arg=hello-args`、`signal args2=hello-args2,7`。

### 5.2 更多参数/类型

- 已支持任意参数个数；引用类型参数可传 `create_object` 返回的 int64 句柄、`null`，或 Godot 实例。
- Godot 实例参数：`LeanCLRNode` 自动映射到当前托管对象；其他实例需先 `bind_godot_object(instance, handle)` 绑定，未绑定会报 `no managed object mapped for Godot instance '<Class>#<id>'`。已释放或 `null` 实例按托管 `null` 处理。
- 托管对象返回时若已绑定 Godot 实例，自动还原为 `Variant(Object)`；否则仍返回 int64 句柄。映射可用 `unbind_godot_object(instance)` 解除，`get_object_mapping_count()` 查看有效映射数。
- 参数类型由 `invoke_method` 按 C# 方法签名的 `RtTypeSig` 自动 marshal（`string`、`int64`、`double` 等），Godot 实例映射到的托管类型必须可赋值给参数声明的类型。

## 6. 宿主注入 ID

`LeanCLRNode` 在创建对象后会自动调用：

```cpp
runtime_->invoke_method(object_handle_, "SetOwnerId", { instance_id })
```

C# 侧：

```csharp
public void SetOwnerId(long id) { ownerId = id; }
```

业务脚本也可以注入其他对象 ID：

```gdscript
player.call_managed("SetTargetId", [marker.get_instance_id()])
```

## 7. 回归要求

任何生命周期/字段/信号改动都必须重跑 `out/logs/godot_<feature>.log`，并确认 `docs/04-run-and-regression.md` 中的基线行全部保留。