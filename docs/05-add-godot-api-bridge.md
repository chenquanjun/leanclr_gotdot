# 05 新增 C# → Godot API 回桥（P/Invoke）

本流程用于让 C# 调用 Godot native API。实现位置：`native/src/leanclr_runtime.cpp` 中的 `register_godot_bridge()`；C# 声明在 `demo_csharp/LeanClrGame.cs` 的 `GodotNative` 类。

## 1. 注册名格式

```text
[<AssemblyName>]<Namespace>.<Class>::<Method>(<ParamType1>,<ParamType2>,...)
```

示例：

```text
[LeanClrGame]GodotNative::node_set_position(System.Int64,System.Double,System.Double)
GodotNative::node_set_position(System.Int64,System.Double,System.Double)
```

- `AssemblyName` 是 C# 程序集名（`LeanClrGame`）。
- 方法分隔符是 `::`。
- 参数类型使用内部名：`System.Int64`、`System.Int32`、`System.Boolean`、`System.Double`、`System.String`。
- 无参方法写作 `Method()`。
- 建议同时注册“带模块名”和“不带模块名”两种形式。

## 2. 标准步骤

### 2.1 写 invoker（native）

在 `register_godot_bridge()` 之前新增：

```cpp
static leanclr::RtResultVoid godot_node_set_position_invoker(
    leanclr::metadata::RtManagedMethodPointer,
    const leanclr::metadata::RtMethodInfo *,
    const leanclr::interp::RtStackObject *params,
    leanclr::interp::RtStackObject *ret) {
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
```

有返回值时使用：

```cpp
leanclr::RuntimeApi::set_return_value<bool>(ret, value);
leanclr::RuntimeApi::set_return_value<int64_t>(ret, value);
leanclr::RuntimeApi::set_return_value<double>(ret, value);
```

### 2.2 注册（native）

```cpp
leanclr::RuntimeApi::register_pinvoke_func(
    "[LeanClrGame]GodotNative::node_set_position(System.Int64,System.Double,System.Double)",
    (leanclr::vm::PInvokeFunction)&godot_bridge_native_stub,
    godot_node_set_position_invoker);
```

`godot_bridge_native_stub` 是占位 native 函数，实际调用走 invoker。

### 2.3 C# 声明

```csharp
[DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern void node_set_position(long instance_id, double x, double y);
```

库名只是占位，真正绑定由 native 注册表按方法全名匹配。

### 2.4 编译、部署、回归

1. 在 `demo_csharp` 目录编译 C#。
2. 复制 DLL 到 `godot_project/bin/assemblies`。
3. MSBuild 增量构建 native。
4. 复制 `out/build/windows/debug/Release/leanclr_godot.dll` 到 `godot_project/bin`（被占用则先删除）。
5. 运行 Godot 回归并对比基线。

## 3. 参数与返回值约定

| C# 类型 | 注册名 | invoker 读取 |
|---|---|---|
| `long` | `System.Int64` | `get_argument<int64_t>` |
| `int` | `System.Int32` | `get_argument<int32_t>` |
| `bool` | `System.Boolean` | `get_argument<bool>` |
| `double` | `System.Double` | `get_argument<double>` |
| `string`（参数） | `System.String` | `get_argument<leanclr::vm::RtString *>`，再转 UTF-8 |

### 3.1 字符串参数

C# `string` 在 eval stack 上是 `RtString*`：

```cpp
leanclr::vm::RtString *message =
    leanclr::RuntimeApi::get_argument<leanclr::vm::RtString *>(params, offset);
std::string text = utf16_to_utf8(
    reinterpret_cast<const uint16_t *>(&message->first_char),
    static_cast<size_t>(message->length));
```

### 3.2 字符串返回值

已实现（`node_get_name`）：

```cpp
leanclr::vm::RtString *result = leanclr::vm::String::create_string_from_utf8cstr(text.c_str());
leanclr::RuntimeApi::set_return_value<leanclr::vm::RtString *>(ret, result);
```

C# 声明：

```csharp
[DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern string node_get_name(long instance_id);
```

## 4. 已实现的回桥接口

| 注册名 | C# 方法 | 说明 |
|---|---|---|
| `GodotNative::print(System.String)` | `print(string)` | 输出到 Godot |
| `GodotNative::get_ticks_msec()` | `get_ticks_msec()` | Godot 运行毫秒 |
| `GodotNative::node_is_inside_tree(System.Int64)` | `node_is_inside_tree(long)` | 节点是否在树中 |
| `GodotNative::node_set_position(System.Int64,System.Double,System.Double)` | `node_set_position(long,double,double)` | 设置 Node2D 位置 |
| `GodotNative::node_set_visible(System.Int64,System.Boolean)` | `node_set_visible(long,bool)` | 设置可见性 |
| `GodotNative::node_get_visible(System.Int64)` | `node_get_visible(long)` | 读取可见性 |
| `GodotNative::node_get_position_x(System.Int64)` | `node_get_position_x(long)` | 读取 X |
| `GodotNative::node_get_position_y(System.Int64)` | `node_get_position_y(long)` | 读取 Y |
| `GodotNative::node_get_child_count(System.Int64)` | `node_get_child_count(long)` | 子节点数量 |
| `GodotNative::node_get_name(System.Int64)` | `node_get_name(long)` | 读取节点名（返回 `string`） |
| `GodotNative::node_get_parent(System.Int64)` | `node_get_parent(long)` | 父节点 `instance_id` |
| `GodotNative::node_get_child(System.Int64,System.Int32)` | `node_get_child(long,int)` | 子节点 `instance_id`（越界返回 0） |
| `GodotNative::node_emit_signal(System.Int64,System.String)` | `node_emit_signal(long,string)` | C# 主动发信号 |
| `GodotNative::node_get_node(System.Int64,System.String)` | `node_get_node(long,string)` | 按相对路径找节点 |
| `GodotNative::instantiate_scene(System.String)` | `instantiate_scene(string)` | 实例化 `PackedScene` |
| `GodotNative::node_add_child(System.Int64,System.Int64)` | `node_add_child(long,long)` | 挂载子节点 |
| `GodotNative::node_queue_free(System.Int64)` | `node_queue_free(long)` | 延迟释放节点 |
| `GodotNative::load_resource(System.String)` | `load_resource(string)` | 加载资源并持有 `Ref` |
| `GodotNative::unload_resource(System.Int64)` | `unload_resource(long)` | 释放资源引用 |
| `GodotNative::resource_get_path(System.Int64)` | `resource_get_path(long)` | 读取资源路径（返回 `string`） |
| `GodotNative::node_get_class(System.Int64)` | `node_get_class(long)` | 读取节点类名（返回 `string`） |
| `GodotNative::node_get_path(System.Int64)` | `node_get_path(long)` | 读取节点路径（返回 `string`） |

## 5. 已知坑

- **`RET_VOID_OK()` 不能直接用**：它展开为 `Unit{}`，而 `Unit` 在 `leanclr::core`。全局命名空间的 invoker 必须写 `return leanclr::core::Unit{};`。
- **float 精度**：本项目 godot-cpp 为 `float_64`，`Vector2` 组件是 `double`，C# 侧用 `double` 可直接对应。
- **P/Invoke 未匹配**：C# 调用会拿不到结果或抛异常；先检查注册名中的程序集名、`::`、参数类型是否与方法签名完全一致。
- **instance_id 来源**：C# 对象不是 Godot Object，必须由宿主注入 Godot `instance_id`（`SetOwnerId` / `SetTargetId`）。