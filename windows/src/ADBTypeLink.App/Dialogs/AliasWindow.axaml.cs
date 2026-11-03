using Avalonia.Controls;
using Avalonia.Interactivity;

namespace ADBTypeLink.App.Dialogs;

/// <summary>给已配对设备起本地别名（friends.json 的 alias）。</summary>
public partial class AliasWindow : Window
{
    public AliasWindow()
    {
        InitializeComponent();
    }

    public void Configure(string deviceName, string? alias)
    {
        Title = $"设置别名 · {deviceName}";
        HintText.Text = $"当前设备名：{deviceName}。别名只存在本机，优先显示；取消配对时一并清除。";
        AliasBox.Text = alias ?? string.Empty;
        Opened += (_, _) =>
        {
            AliasBox.Focus();
            AliasBox.SelectAll();
        };
    }

    /// <summary>返回 null 表示取消；空字符串表示清除别名。</summary>
    public static async Task<string?> ShowAsync(Window owner, string deviceName, string? alias)
    {
        var dialog = new AliasWindow();
        dialog.Configure(deviceName, alias);
        return await dialog.ShowDialog<string?>(owner);
    }

    private void OnCancel(object? sender, RoutedEventArgs e) => Close(null);

    private void OnClear(object? sender, RoutedEventArgs e) => Close(string.Empty);

    private void OnConfirm(object? sender, RoutedEventArgs e) => Close(AliasBox.Text ?? string.Empty);
}
