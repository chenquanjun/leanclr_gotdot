public static class CycleA
{
    public static string Ping()
    {
#if CYCLE_A_V2
        return "cycle-a:" + CycleB.Pong();
#else
        return "cycle-a";
#endif
    }
}
