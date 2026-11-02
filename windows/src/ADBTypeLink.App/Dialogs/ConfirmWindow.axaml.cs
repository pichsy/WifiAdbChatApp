using Avalonia.Controls;
using Avalonia.Interactivity;

namespace ADBTypeLink.App.Dialogs;

/// <summary>通用二次确认弹窗（清空记录等）。</summary>
public partial class ConfirmWindow : Window
{
    public ConfirmWindow()
    {
        InitializeComponent();
    }

    public void Configure(string title, string message, string confirmText)
    {
        Title = title;
        TitleText.Text = title;
        MessageText.Text = message;
        ConfirmButton.Content = confirmText;
    }

    public static async Task<bool> ShowAsync(Window owner, string title, string message, string confirmText)
    {
        var dialog = new ConfirmWindow();
        dialog.Configure(title, message, confirmText);
        var result = await dialog.ShowDialog<bool?>(owner);
        return result == true;
    }

    private void OnCancel(object? sender, RoutedEventArgs e) => Close(false);

    private void OnConfirm(object? sender, RoutedEventArgs e) => Close(true);
}
