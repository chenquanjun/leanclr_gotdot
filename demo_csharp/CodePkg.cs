using System;
using System.Runtime.InteropServices;

public static class GodotNative
{
    [DllImport("leanclr_godot.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void print(string message);
}

// 代码包热更新演示程序集：v1 与 v2 保持完全相同的公开 API，
// 只改变版本/返回值/行为，用来证明“下载新包后执行到新代码”。
public class CodePkgNode
{
#if PKG_A
    public const string PackageVersion = "A";
    public const int Answer = 7;
    public const string Feature = "triple-score-a";
#elif PKG_B
    public const string PackageVersion = "B";
    public const int Answer = 8;
    public const string Feature = "quad-score-b";
#elif PKG_V3
    public const string PackageVersion = "v3";
    public const int Answer = 33;
    public const string Feature = "triple-score";
#elif PKG_V2
    public const string PackageVersion = "v2";
    public const int Answer = 22;
    public const string Feature = "double-score";
#else
    public const string PackageVersion = "v1";
    public const int Answer = 11;
    public const string Feature = "base-score";
#endif

    public long ownerId = 0;

    public CodePkgNode()
    {
        GodotNative.print("[codepkg] CodePkgNode created version=" + PackageVersion);
    }

    public void SetOwnerId(long id)
    {
        ownerId = id;
    }

    public void OnEnterTree()
    {
        GodotNative.print("[codepkg] OnEnterTree version=" + PackageVersion +
            " feature=" + Feature + " owner=" + ownerId);
    }

    public void OnProcess(float delta)
    {
    }

    public string GetVersion()
    {
        return PackageVersion;
    }

    // 静态探测：不实例化，用于 reload 后确认新程序集里确实有此类。
    public static string Describe()
    {
        return PackageVersion;
    }

    public int GetAnswer()
    {
        return Answer;
    }

    public string GetFeature()
    {
        return Feature;
    }

    public int ComputeScore(int baseValue)
    {
#if PKG_A
        return baseValue * 3;
#elif PKG_B
        return baseValue * 4;
#elif PKG_V3
        return baseValue * 3;
#elif PKG_V2
        return baseValue * 2;
#else
        return baseValue;
#endif
    }

    public long GetOwnerId()
    {
        return ownerId;
    }
}
