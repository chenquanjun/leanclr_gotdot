public class ExtUser
{
    public string Use()
    {
        return "ExtUser->" + new PlayerItem(42).Describe();
    }
}
