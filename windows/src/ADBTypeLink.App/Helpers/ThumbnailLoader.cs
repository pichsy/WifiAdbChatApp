using System.Collections.Concurrent;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using ADBTypeLink.Core;
using Avalonia;
using Avalonia.Media.Imaging;
using Avalonia.Platform;

namespace ADBTypeLink.App.ViewModels;

/// <summary>图片 / GIF / 视频缩略图：先 adb pull 到临时目录，再解码。</summary>
public static class ThumbnailLoader
{
    private static readonly ConcurrentDictionary<string, Bitmap?> MemoryCache = new();
    private static readonly ConcurrentDictionary<string, Task<Bitmap?>> InFlight = new();
    private static readonly string CacheDirectory = Path.Combine(Path.GetTempPath(), "ADBTypeLink", "thumbs");

    private static readonly HashSet<string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "avif", "ico"
    };

    private static readonly HashSet<string> VideoExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "mp4", "mov", "m4v", "3gp", "3g2", "mkv", "avi", "webm", "flv", "wmv", "ts", "m2ts"
    };

    public static bool IsImage(DeviceFileEntry entry) =>
        ImageExtensions.Contains(Path.GetExtension(entry.Name).TrimStart('.'));

    public static bool IsVideo(DeviceFileEntry entry) =>
        VideoExtensions.Contains(Path.GetExtension(entry.Name).TrimStart('.'));

    public static bool Supports(DeviceFileEntry entry) =>
        !entry.IsDirectory && (IsImage(entry) || IsVideo(entry));

    public static Task<Bitmap?> LoadAsync(DeviceFileService service, string serial, DeviceFileEntry entry,
        CancellationToken cancellationToken = default)
    {
        var key = CacheKey(serial, entry.Path);
        if (MemoryCache.TryGetValue(key, out var cached))
        {
            return Task.FromResult(cached);
        }

        return InFlight.GetOrAdd(key, _ => CreateAsync(service, serial, entry, cancellationToken));
    }

    private static async Task<Bitmap?> CreateAsync(DeviceFileService service, string serial, DeviceFileEntry entry,
        CancellationToken cancellationToken)
    {
        try
        {
            Directory.CreateDirectory(CacheDirectory);
            var ext = Path.GetExtension(entry.Name).TrimStart('.');
            if (ext.Length == 0) ext = "dat";
            var key = CacheKey(serial, entry.Path);
            var localPath = Path.Combine(CacheDirectory, key + "." + ext);

            if (!File.Exists(localPath))
            {
                var timeout = IsVideo(entry) ? TimeSpan.FromMinutes(5) : TimeSpan.FromSeconds(90);
                var result = await service.PullAsync(serial, entry.Path, localPath, timeout: timeout,
                    cancellationToken: cancellationToken).ConfigureAwait(false);
                if (!result.Ok)
                {
                    try { File.Delete(localPath); } catch { }
                    return null;
                }
            }

            if (IsImage(entry))
            {
                try
                {
                    return new Bitmap(localPath);
                }
                catch
                {
                    return await Task.Run(() => WindowsShellThumbnail.TryCreate(localPath), cancellationToken).ConfigureAwait(false);
                }
            }

            return await Task.Run(() => WindowsShellThumbnail.TryCreate(localPath), cancellationToken).ConfigureAwait(false);
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static string CacheKey(string serial, string path)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(serial + "|" + path));
        return Convert.ToHexString(hash)[..24].ToLowerInvariant();
    }
}

/// <summary>Windows 资源管理器缩略图：视频、GIF、HEIC 等交给系统解码。</summary>
internal static class WindowsShellThumbnail
{
    public static Bitmap? TryCreate(string path)
    {
        if (!OperatingSystem.IsWindows()) return null;
        IntPtr hBitmap = IntPtr.Zero;
        try
        {
            var iid = typeof(IShellItemImageFactory).GUID;
            SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out var factory);
            if (factory is null) return null;
            var size = new SIZE { cx = 320, cy = 240 };
            if (factory.GetImage(size, SIIGBF.ResizeToFit | SIIGBF.BiggerSizeOk, out hBitmap) != 0)
            {
                return null;
            }
            return ConvertBitmap(hBitmap);
        }
        catch
        {
            return null;
        }
        finally
        {
            if (hBitmap != IntPtr.Zero) DeleteObject(hBitmap);
        }
    }

    private static Bitmap? ConvertBitmap(IntPtr hBitmap)
    {
        if (GetObject(hBitmap, System.Runtime.InteropServices.Marshal.SizeOf<BITMAP>(), out var bmp) == 0) return null;
        var width = bmp.bmWidth;
        var height = bmp.bmHeight;
        if (width <= 0 || height <= 0 || width > 4096 || height > 4096) return null;

        var info = new BITMAPINFO
        {
            bmiHeader = new BITMAPINFOHEADER
            {
                biSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<BITMAPINFOHEADER>(),
                biWidth = width,
                biHeight = -height,
                biPlanes = 1,
                biBitCount = 32,
                biCompression = 0
            }
        };
        var pixels = new byte[width * height * 4];
        var dc = CreateCompatibleDC(IntPtr.Zero);
        try
        {
            if (GetDIBits(dc, hBitmap, 0, (uint)height, pixels, ref info, 0) == 0) return null;
        }
        finally
        {
            DeleteDC(dc);
        }

        // Shell 缩略图 alpha 经常是 0，直接当作不透明 BGRA 使用。
        for (var i = 3; i < pixels.Length; i += 4) pixels[i] = 255;

        var bitmap = new WriteableBitmap(new PixelSize(width, height), new Vector(96, 96),
            PixelFormat.Bgra8888, AlphaFormat.Premul);
        using (var fb = bitmap.Lock())
        {
            var rowBytes = width * 4;
            for (var y = 0; y < height; y++)
            {
                System.Runtime.InteropServices.Marshal.Copy(pixels, y * rowBytes,
                    fb.Address + y * fb.RowBytes, rowBytes);
            }
        }
        return bitmap;
    }

    private const uint SIIGBFResizeToFit = 0x00000000;
    private const uint SIIGBFBiggerSizeOk = 0x00000001;

    [Flags]
    private enum SIIGBF : uint
    {
        ResizeToFit = SIIGBFResizeToFit,
        BiggerSizeOk = SIIGBFBiggerSizeOk
    }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct SIZE
    {
        public int cx;
        public int cy;
    }

    [System.Runtime.InteropServices.ComImport]
    [System.Runtime.InteropServices.Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b")]
    [System.Runtime.InteropServices.InterfaceType(System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItemImageFactory
    {
        [System.Runtime.InteropServices.PreserveSig]
        int GetImage(SIZE size, SIIGBF flags, out IntPtr phbm);
    }

    [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, PreserveSig = false)]
    private static extern void SHCreateItemFromParsingName(
        string path,
        IntPtr pbc,
        ref Guid riid,
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Interface)]
        out IShellItemImageFactory shellItem);

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct BITMAP
    {
        public int bmType;
        public int bmWidth;
        public int bmHeight;
        public int bmWidthBytes;
        public ushort bmPlanes;
        public ushort bmBitsPixel;
        public IntPtr bmBits;
    }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct BITMAPINFOHEADER
    {
        public uint biSize;
        public int biWidth;
        public int biHeight;
        public ushort biPlanes;
        public ushort biBitCount;
        public uint biCompression;
        public uint biSizeImage;
        public int biXPelsPerMeter;
        public int biYPelsPerMeter;
        public uint biClrUsed;
        public uint biClrImportant;
    }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct BITMAPINFO
    {
        public BITMAPINFOHEADER bmiHeader;
        public uint bmiColors;
    }

    [System.Runtime.InteropServices.DllImport("gdi32.dll")]
    private static extern int GetObject(IntPtr hgdiobj, int cbBuffer, out BITMAP lpvObject);

    [System.Runtime.InteropServices.DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleDC(IntPtr hdc);

    [System.Runtime.InteropServices.DllImport("gdi32.dll")]
    private static extern bool DeleteDC(IntPtr hdc);

    [System.Runtime.InteropServices.DllImport("gdi32.dll")]
    private static extern int GetDIBits(IntPtr hdc, IntPtr hbm, uint start, uint cLines,
        byte[] lpvBits, ref BITMAPINFO lpbmi, uint usage);

    [System.Runtime.InteropServices.DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr ho);
}
