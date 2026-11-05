using System;
using System.Runtime.InteropServices;
using Avalonia.Controls;

namespace ADBTypeLink.App.Helpers;

/// <summary>
/// Windows 窗口外观：优先用 DWM 圆角（Windows 11），老系统退回圆角窗口区域。
/// macOS 端窗口天然是圆角，这里让 Windows 尽量接近。
/// </summary>
public static class WindowEffects
{
    private const int DwmwaWindowCornerPreference = 33;
    private const int DwmwcpRound = 2;

    [DllImport("dwmapi.dll", PreserveSig = true)]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateRoundRectRgn(int left, int top, int right, int bottom, int width, int height);

    [DllImport("user32.dll")]
    private static extern int SetWindowRgn(IntPtr hwnd, IntPtr region, bool redraw);

    public static void ApplyRoundedCorners(Window window)
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var handle = window.TryGetPlatformHandle();
        if (handle is null || handle.Handle == IntPtr.Zero)
        {
            return;
        }

        var hwnd = handle.Handle;
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
        {
            var preference = DwmwcpRound;
            try
            {
                if (DwmSetWindowAttribute(hwnd, DwmwaWindowCornerPreference, ref preference, sizeof(int)) == 0)
                {
                    return;
                }
            }
            catch (Exception)
            {
                // DWM 不可用时走区域裁剪。
            }
        }

        ApplyRegion(window, hwnd);
        window.SizeChanged += (_, _) => ApplyRegion(window, hwnd);
    }

    private static void ApplyRegion(Window window, IntPtr hwnd)
    {
        // 圆角半径 12 DIP；SetWindowRgn 使用窗口像素坐标，这里按布局尺寸取整即可。
        var width = Math.Max(1, (int)Math.Round(window.Bounds.Width));
        var height = Math.Max(1, (int)Math.Round(window.Bounds.Height));
        var region = CreateRoundRectRgn(0, 0, width + 1, height + 1, 24, 24);
        if (region == IntPtr.Zero)
        {
            return;
        }

        // SetWindowRgn 成功后区域归窗口所有，不能再 DeleteObject。
        if (SetWindowRgn(hwnd, region, true) == 0)
        {
            DeleteObject(region);
        }
    }

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr handle);
}
