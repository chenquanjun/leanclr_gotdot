using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public enum MyMode
{
    A = 0,
    B = 1,
    C = 2
}

public struct MyData
{
    public int x;
    public int y;
}

public static class GodotNative
{
    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void print(string message);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern long get_ticks_msec();

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern bool node_is_inside_tree(long instance_id);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void node_set_position(long instance_id, double x, double y);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void node_set_visible(long instance_id, bool visible);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern bool node_get_visible(long instance_id);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern double node_get_position_x(long instance_id);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern double node_get_position_y(long instance_id);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern long node_get_child_count(long instance_id);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern string node_get_name(long instance_id);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern long node_get_parent(long instance_id);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern long node_get_child(long instance_id, int index);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void node_emit_signal(long instance_id, string signal_name);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern long node_get_node(long instance_id, string path);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern long instantiate_scene(string path);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void node_add_child(long parent_id, long child_id);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void node_queue_free(long instance_id);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern long load_resource(string path);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern bool unload_resource(long instance_id);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern string resource_get_path(long instance_id);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern string node_get_class(long instance_id);

    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern string node_get_path(long instance_id);
}

public static class HotState
{
    public static int counter = 0;
    public static string tag = "initial";

    public static void SetCounter(int value)
    {
        counter = value;
    }

    public static int GetCounter()
    {
        return counter;
    }

    public static void SetTag(string value)
    {
        tag = value;
    }

    public static string GetTag()
    {
        return tag;
    }
}

public class PlayerItem
{
    public int value;

    public PlayerItem(int value)
    {
        this.value = value;
    }

    public string Describe()
    {
        return "PlayerItem=" + value;
    }
}

public class PlayerController
{
#if HOT_V2
    public const string HotBuild = "v2";
#else
    public const string HotBuild = "v1";
#endif
    public int score = 7;
    public string title = "Player";
    public int physicsTicks = 0;
    public long ownerId = 0;
    public MyMode mode = MyMode.B;
    public MyData data = new MyData { x = 3, y = 4 };
    public long targetId = 0;
    public PlayerItem item = new PlayerItem(5);
    public PlayerItem spare = new PlayerItem(9);
    public int[] numbers = new int[] { 3, 4, 5 };

    private int health = 100;

    public PlayerController()
    {
        Debugger.Log(0, "info", "PlayerController created");
    }

    public void OnReady()
    {
        Debugger.Log(0, "info", "PlayerController.OnReady");
        GodotNative.print("C# -> Godot print via P/Invoke");
        Debugger.Log(0, "info", "godot ticks=" + GodotNative.get_ticks_msec());
        Debugger.Log(0, "info", "node inside_tree=" + GodotNative.node_is_inside_tree(ownerId));
    }

    public void OnProcess(float delta)
    {
        health += 1;
    }

    public void OnExitTree()
    {
        Debugger.Log(0, "info", "PlayerController.OnExitTree health=" + health);
    }

    public void OnSignal()
    {
        Debugger.Log(0, "info", "PlayerController.OnSignal");
    }

    public int GetItemValue()
    {
        return item == null ? -1 : item.value;
    }

    public PlayerItem GetItem()
    {
        return item;
    }

    public PlayerItem GetNullItem()
    {
        return null;
    }

    public int[] GetNumbers()
    {
        return numbers;
    }

    public string DescribeItem(PlayerItem target)
    {
        return target == null ? "null" : target.Describe();
    }

    public int SumNumbers(int[] values)
    {
        if (values == null)
        {
            return -1;
        }
        int sum = 0;
        for (int i = 0; i < values.Length; ++i)
        {
            sum += values[i];
        }
        return sum;
    }

    public int GetNumbersSum()
    {
        if (numbers == null)
        {
            return -1;
        }
        int sum = 0;
        for (int i = 0; i < numbers.Length; ++i)
        {
            sum += numbers[i];
        }
        return sum;
    }

    public void OnSignalArgs(string text)
    {
        Debugger.Log(0, "info", "signal arg=" + text);
    }

    public void OnSignalArgs2(string text, long value)
    {
        Debugger.Log(0, "info", "signal args2=" + text + "," + value);
    }

    public PlayerController GetSelf()
    {
        return this;
    }

    public void OnSignalObject(PlayerController target, string text)
    {
        Debugger.Log(0, "info", "OnSignalObject target=" + (target == null ? "null" : "PlayerController") +
            " same=" + (ReferenceEquals(target, this) ? "true" : "false") + " text=" + text);
    }

    public void OnEnterTree()
    {
        Debugger.Log(0, "info", "PlayerController.OnEnterTree");
    }

    public void SetOwnerId(long id)
    {
        ownerId = id;
    }

    public void SetTargetId(long id)
    {
        targetId = id;
    }

    public void EmitTestSignal()
    {
        Debugger.Log(0, "info", "emit leanclr_signal from C#");
        GodotNative.node_emit_signal(ownerId, "leanclr_signal");
    }

    public void TestSceneApi()
    {
        long sceneId = GodotNative.instantiate_scene("res://demo_node.tscn");
        Debugger.Log(0, "info", "instantiate scene id=" + sceneId);
        if (sceneId != 0)
        {
            GodotNative.node_add_child(ownerId, sceneId);
            Debugger.Log(0, "info", "scene name=" + GodotNative.node_get_name(sceneId));
            Debugger.Log(0, "info", "owner child count=" + GodotNative.node_get_child_count(ownerId));
            long byPath = GodotNative.node_get_node(ownerId, "DemoNode");
            Debugger.Log(0, "info", "get_node by path=" + byPath);
            GodotNative.node_queue_free(sceneId);
        }
    }

    public void TestResourceApi()
    {
        long resourceId = GodotNative.load_resource("res://demo_resource.tres");
        Debugger.Log(0, "info", "load resource id=" + resourceId);
        if (resourceId != 0)
        {
            Debugger.Log(0, "info", "resource path=" + GodotNative.resource_get_path(resourceId));
            Debugger.Log(0, "info", "unload=" + GodotNative.unload_resource(resourceId));
        }
    }

    public void TestNodeApi()
    {
        GodotNative.node_set_position(targetId, 12.5, 34.5);
        GodotNative.node_set_visible(targetId, false);
        Debugger.Log(0, "info", "target visible=" + GodotNative.node_get_visible(targetId));
        Debugger.Log(0, "info", "target pos=" + GodotNative.node_get_position_x(targetId) + "," + GodotNative.node_get_position_y(targetId));
        Debugger.Log(0, "info", "target child count=" + GodotNative.node_get_child_count(targetId));
        Debugger.Log(0, "info", "target name=" + GodotNative.node_get_name(targetId));
        Debugger.Log(0, "info", "target parent=" + GodotNative.node_get_parent(targetId));
        Debugger.Log(0, "info", "target child0=" + GodotNative.node_get_child(targetId, 0));
        Debugger.Log(0, "info", "target class=" + GodotNative.node_get_class(targetId));
        Debugger.Log(0, "info", "owner path=" + GodotNative.node_get_path(ownerId));
    }

    public void OnPhysicsProcess(float delta)
    {
        physicsTicks += 1;
    }

    public int GetPhysicsTicks()
    {
        return physicsTicks;
    }

    public int GetDataX()
    {
        return data.x;
    }

    public int GetDataY()
    {
        return data.y;
    }

#if SIG_PARAM_TYPE
    public int Add(string a, int b)
    {
        return a.Length + b;
    }
#elif SIG_PARAM_COUNT
    public int Add(int a, int b, int c)
    {
        return a + b + c;
    }
#else
    public int Add(int a, int b)
    {
        return a + b;
    }
#endif

    public string Describe()
    {
        return "PlayerController health=" + health;
    }

    public void OnHotSignal(string text)
    {
        Debugger.Log(0, "info", "OnHotSignal build=" + HotBuild + " text=" + text);
    }

    public void OnSignalMixed(PlayerItem target, string text, int value)
    {
        Debugger.Log(0, "info", "OnSignalMixed target=" +
            (target == null ? "null" : target.Describe()) + " text=" + text + " value=" + value);
    }

#if SIG_RETURN
    public string SignatureProbe(int value)
    {
        return "probe:" + value;
    }
#else
    public int SignatureProbe(int value)
    {
        return value;
    }
#endif

#if !SIG_REMOVED
    public string GetHotBuild()
    {
        return HotBuild;
    }
#endif

#if SIG_ADDED
    public string ExtraMethod()
    {
        return "extra";
    }
#endif
}