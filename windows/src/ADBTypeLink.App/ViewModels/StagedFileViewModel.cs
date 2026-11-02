namespace ADBTypeLink.App.ViewModels;

/// <summary>底部待发送文件 chips。</summary>
public sealed class StagedFileViewModel
{
    public StagedFileViewModel(string path)
    {
        Path = path;
        Name = System.IO.Path.GetFileName(path);
        SizeText = ReadSizeText(path);
    }

    /// <summary>截图 / 演示数据用：不访问磁盘。</summary>
    internal StagedFileViewModel(string path, string name, string sizeText)
    {
        Path = path;
        Name = name;
        SizeText = sizeText;
    }

    public string Path { get; }

    public string Name { get; }

    public string SizeText { get; }

    private static string ReadSizeText(string path)
    {
        try
        {
            return MessageItemViewModel.FormatSize(new FileInfo(path).Length);
        }
        catch (Exception)
        {
            return "读不到文件";
        }
    }
}
