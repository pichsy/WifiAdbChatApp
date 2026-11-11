using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace ADBTypeLink.App.Dialogs;

/// <summary>输入名称的小弹窗（新建文件 / 文件夹）。</summary>
public sealed class TextPromptWindow : Window
{
    private readonly TextBox _input = new();
    private string? _result;

    public TextPromptWindow(string title, string message, string initial)
    {
        Title = title;
        Width = 430;
        SizeToContent = SizeToContent.Height;
        CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        Background = (IBrush?)Application.Current?.FindResource("AppBackgroundBrush");

        _input.Text = initial;
        _input.Width = 380;
        _input.Margin = new Thickness(0, 8, 0, 0);

        var panel = new StackPanel
        {
            Margin = new Thickness(24),
            Spacing = 12
        };
        panel.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 16,
            FontWeight = FontWeight.SemiBold,
            Foreground = (IBrush?)Application.Current?.FindResource("TextPrimaryBrush")
        });
        panel.Children.Add(new TextBlock
        {
            Text = message,
            FontSize = 12.5,
            TextWrapping = TextWrapping.Wrap,
            Foreground = (IBrush?)Application.Current?.FindResource("TextSecondaryBrush")
        });
        panel.Children.Add(_input);

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Spacing = 8
        };
        var cancel = new Button { Content = "取消", MinWidth = 76 };
        cancel.Click += (_, _) => Close(null);
        var create = new Button { Content = "创建", Classes = { "primary" }, MinWidth = 88 };
        create.Click += (_, _) =>
        {
            _result = _input.Text?.Trim();
            Close(_result);
        };
        buttons.Children.Add(cancel);
        buttons.Children.Add(create);
        panel.Children.Add(buttons);
        Content = panel;

        Opened += (_, _) =>
        {
            _input.Focus();
            _input.SelectAll();
        };
    }

    public static async Task<string?> ShowAsync(Window owner, string title, string message, string initial = "")
    {
        var dialog = new TextPromptWindow(title, message, initial);
        return await dialog.ShowDialog<string?>(owner);
    }
}
