using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;

namespace Snifix;

public partial class App : Application
{
    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            AppState.Shared.Start();
            desktop.MainWindow = new MainWindow();
            desktop.ShutdownRequested += (_, _) => AppState.Shared.Shutdown();
            Snapshot.Schedule(desktop);
        }
        base.OnFrameworkInitializationCompleted();
    }
}
