using System;
using System.Runtime.InteropServices;

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
    public static extern long node_get_node(long instance_id, string path);
}

// 玩法逻辑全部在 C#：移动、计时、吃目标计分、超时失败、重开。
// Godot 侧只负责挂节点、读输入、显示 HUD 与触发热更。
public class GameDemo
{
    public const int StatePlaying = 0;
    public const int StateOver = 1;

    public long ownerId = 0;
    public long playerNodeId = 0;
    public long targetNodeId = 0;
    public float inputX = 0f;
    public float inputY = 0f;

    // 这些静态字段列在 hotreload.statics.json 白名单里，热更后进度继续保留。
    public static int s_score = 0;
    public static float s_timeLeft = DemoTuning.RoundSeconds;
    public static int s_state = StatePlaying;
    public static float s_playerX = 320f;
    public static float s_playerY = 180f;
    public static float s_targetX = 500f;
    public static float s_targetY = 180f;
    public static int s_hits = 0;

    public GameDemo()
    {
        GodotNative.print("[demo] GameDemo created build=" + DemoTuning.BuildTag);
    }

    public void SetOwnerId(long id)
    {
        ownerId = id;
    }

    // LeanCLRNode 首次入树与热更重绑后都会调用：按相对路径重新解析玩家/目标节点，
    // 因此实例字段丢失也不影响继续驱动现有场景节点。
    public void OnEnterTree()
    {
        playerNodeId = GodotNative.node_get_node(ownerId, "../Player");
        targetNodeId = GodotNative.node_get_node(ownerId, "../Target");
        ApplyPositions();
        GodotNative.print("[demo] OnEnterTree build=" + DemoTuning.BuildTag +
            " playerNode=" + playerNodeId + " targetNode=" + targetNodeId);
    }

    public void SetInput(float x, float y)
    {
        inputX = x;
        inputY = y;
    }

    public void OnProcess(float delta)
    {
        if (s_state == StatePlaying)
        {
            float length = (float)Math.Sqrt(inputX * inputX + inputY * inputY);
            float stepX = inputX;
            float stepY = inputY;
            if (length > 1f)
            {
                stepX /= length;
                stepY /= length;
            }
            if (stepX != 0f || stepY != 0f)
            {
                s_playerX += stepX * DemoTuning.MoveSpeed * delta;
                s_playerY += stepY * DemoTuning.MoveSpeed * delta;
                ClampPlayer();
            }

            s_timeLeft -= delta;
            if (s_timeLeft <= 0f)
            {
                s_timeLeft = 0f;
                s_state = StateOver;
                GodotNative.print("[demo] round over score=" + s_score + " build=" + DemoTuning.BuildTag);
            }
            else
            {
                float dx = s_playerX - s_targetX;
                float dy = s_playerY - s_targetY;
                if (dx * dx + dy * dy <= DemoTuning.TargetRadius * DemoTuning.TargetRadius)
                {
                    s_score += DemoTuning.PointsPerTarget;
                    s_hits += 1;
                    GodotNative.print("[demo] hit +" + DemoTuning.PointsPerTarget +
                        " score=" + s_score + " build=" + DemoTuning.BuildTag);
                    SpawnTarget();
                }
            }
        }
        ApplyPositions();
    }

    public void Restart()
    {
        s_score = 0;
        s_state = StatePlaying;
        s_timeLeft = DemoTuning.RoundSeconds;
        s_playerX = 320f;
        s_playerY = 180f;
        s_hits = 0;
        SpawnTarget();
        ApplyPositions();
        GodotNative.print("[demo] restart build=" + DemoTuning.BuildTag +
            " speed=" + DemoTuning.MoveSpeed + " round=" + DemoTuning.RoundSeconds);
    }

    public int GetScore()
    {
        return s_score;
    }

    public float GetTimeLeft()
    {
        return s_timeLeft;
    }

    public int GetState()
    {
        return s_state;
    }

    public int GetHits()
    {
        return s_hits;
    }

    public float GetSpeed()
    {
        return DemoTuning.MoveSpeed;
    }

    public int GetPointsPerTarget()
    {
        return DemoTuning.PointsPerTarget;
    }

    public float GetRoundSeconds()
    {
        return DemoTuning.RoundSeconds;
    }

    public float GetTargetRadius()
    {
        return DemoTuning.TargetRadius;
    }

    public string GetBuildTag()
    {
        return DemoTuning.BuildTag;
    }

    public float GetPlayerX()
    {
        return s_playerX;
    }

    public float GetPlayerY()
    {
        return s_playerY;
    }

    public float GetTargetX()
    {
        return s_targetX;
    }

    public float GetTargetY()
    {
        return s_targetY;
    }

    public long GetPlayerNodeId()
    {
        return playerNodeId;
    }

    public long GetTargetNodeId()
    {
        return targetNodeId;
    }

    // 供自动化测试做确定性驱动；正常游玩不会调用。
    public void SetPlayerPosition(float x, float y)
    {
        s_playerX = x;
        s_playerY = y;
        ApplyPositions();
    }

    public void SetTargetPosition(float x, float y)
    {
        s_targetX = x;
        s_targetY = y;
        ApplyPositions();
    }

    public void SetTimeLeft(float seconds)
    {
        s_timeLeft = seconds;
    }

    private void ClampPlayer()
    {
        if (s_playerX < 32f) s_playerX = 32f;
        if (s_playerX > 608f) s_playerX = 608f;
        if (s_playerY < 52f) s_playerY = 52f;
        if (s_playerY > 308f) s_playerY = 308f;
    }

    private void SpawnTarget()
    {
        long seed = GodotNative.get_ticks_msec() + (long)(s_hits + 1) * 7919L;
        int r1 = (int)(seed * 1103515245L + 12345L);
        int r2 = (int)((long)r1 * 1103515245L + 12345L);
        s_targetX = 48f + (float)((r1 & 0x7fffffff) % 544);
        s_targetY = 60f + (float)((r2 & 0x7fffffff) % 240);
    }

    private void ApplyPositions()
    {
        if (playerNodeId != 0 && GodotNative.node_is_inside_tree(playerNodeId))
        {
            GodotNative.node_set_position(playerNodeId, s_playerX, s_playerY);
        }
        if (targetNodeId != 0 && GodotNative.node_is_inside_tree(targetNodeId))
        {
            GodotNative.node_set_position(targetNodeId, s_targetX, s_targetY);
        }
    }
}
