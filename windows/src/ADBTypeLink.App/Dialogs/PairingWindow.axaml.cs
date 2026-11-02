using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Interactivity;

namespace ADBTypeLink.App.Dialogs;

/// <summary>配对弹窗：6 位数字输入、自动过滤非数字、自动聚焦、支持粘贴。</summary>
public partial class PairingWindow : Window
{
    private bool _pairOnly = true;

    public PairingWindow()
    {
        InitializeComponent();
        KeyDown += OnWindowKeyDown;
        Opened += OnOpened;
    }

    public void Configure(string peerName, bool pairOnly, string? initialError)
    {
        _pairOnly = pairOnly;
        var title = $"与「{peerName}」配对";
        Title = title;
        TitleText.Text = title;
        HelpText.Text = pairOnly
            ? "在对方设备的 ADBType 界面左侧「本机」里可以看到 6 位配对码。输入一次后两台设备会互相信任，以后直接发送；也可以直接粘贴。"
            : $"这是第一次和「{peerName}」互传。在对方设备的 ADBType 界面左侧「本机」里找到 6 位配对码，输入后会把这次内容发过去，并记住对方。";
        ConfirmButton.Content = pairOnly ? "配对" : "配对并发送";

        if (!string.IsNullOrEmpty(initialError))
        {
            SetError(initialError);
        }
    }

    public void SetError(string message)
    {
        ErrorText.Text = message;
        ErrorText.IsVisible = !string.IsNullOrEmpty(message);
    }

    private void OnOpened(object? sender, EventArgs e)
    {
        Activate();
        CodeBox.Focus();
        CodeBox.CaretIndex = CodeBox.Text?.Length ?? 0;
    }

    private void OnCodeChanged(object? sender, TextChangedEventArgs e)
    {
        var digits = new string((CodeBox.Text ?? string.Empty).Where(char.IsAsciiDigit).Take(6).ToArray());
        if (!string.Equals(digits, CodeBox.Text, StringComparison.Ordinal))
        {
            CodeBox.Text = digits;
            CodeBox.CaretIndex = digits.Length;
        }

        ErrorText.IsVisible = false;
        ConfirmButton.IsEnabled = digits.Length == 6;
    }

    private void OnWindowKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            TryConfirm();
            e.Handled = true;
        }
        else if (e.Key == Key.Escape)
        {
            Close(null);
        }
    }

    private void OnConfirm(object? sender, RoutedEventArgs e) => TryConfirm();

    private void TryConfirm()
    {
        var code = (CodeBox.Text ?? string.Empty).Trim();
        if (code.Length != 6)
        {
            SetError("请输入对方屏幕上的 6 位数字");
            return;
        }

        Close(code);
    }

    private async void OnPaste(object? sender, RoutedEventArgs e)
    {
        try
        {
            var clipboard = GetTopLevel(this)?.Clipboard;
            if (clipboard is null)
            {
                return;
            }

            var text = await clipboard.TryGetTextAsync();
            if (!string.IsNullOrEmpty(text))
            {
                CodeBox.Text = new string(text.Where(char.IsAsciiDigit).Take(6).ToArray());
                CodeBox.CaretIndex = CodeBox.Text?.Length ?? 0;
            }
        }
        catch (Exception)
        {
            // 剪贴板不可用时忽略。
        }
    }

    private void OnCancel(object? sender, RoutedEventArgs e) => Close(null);
}
