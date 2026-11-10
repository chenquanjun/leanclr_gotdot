public static class CycleB
{
    public static string Pong()
    {
        return "cycle-b";
    }

    public static string TouchA()
    {
        return CycleA.Ping();
    }
}
