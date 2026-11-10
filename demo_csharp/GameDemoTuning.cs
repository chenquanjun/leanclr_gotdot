// 这个文件就是「改这里看效果」的位置：改完保存，运行中的游戏热更后立即生效。
// v1 是基线手感；带 DEMO_V2 的构建用于自动化验证热更前后的差异。
public static class DemoTuning
{
#if DEMO_V2
    public const string BuildTag = "v2";
    public const float MoveSpeed = 320f;        // 玩家移动速度（像素/秒）
    public const int PointsPerTarget = 25;      // 每次吃到目标得分
    public const float RoundSeconds = 20f;      // 单局时长（秒）
    public const float TargetRadius = 22f;      // 判定为吃到的距离（像素）
#else
    public const string BuildTag = "v1";
    public const float MoveSpeed = 180f;        // 玩家移动速度（像素/秒）
    public const int PointsPerTarget = 10;      // 每次吃到目标得分
    public const float RoundSeconds = 30f;      // 单局时长（秒）
    public const float TargetRadius = 16f;      // 判定为吃到的距离（像素）
#endif
}
