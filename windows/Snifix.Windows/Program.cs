using Avalonia;

namespace Snifix;

static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Contains("--selftest")) return Core.SelfTest.Run().GetAwaiter().GetResult();
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        return 0;
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>().UsePlatformDetect().WithInterFont().LogToTrace();
}
