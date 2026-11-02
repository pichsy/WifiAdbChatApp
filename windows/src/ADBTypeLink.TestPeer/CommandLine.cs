namespace ADBTypeLink.TestPeer;

/// <summary>极简命令行解析：支持 --key value、--key=value 和多次出现的 --file。</summary>
internal sealed class CommandLine
{
    private readonly Dictionary<string, List<string>> _values = new(StringComparer.OrdinalIgnoreCase);

    public static CommandLine Parse(IReadOnlyList<string> args)
    {
        var result = new CommandLine();
        for (var index = 0; index < args.Count; index++)
        {
            var current = args[index];
            if (!current.StartsWith("--", StringComparison.Ordinal))
            {
                continue;
            }

            var body = current[2..];
            string key;
            string value;
            var equals = body.IndexOf('=');
            if (equals >= 0)
            {
                key = body[..equals];
                value = body[(equals + 1)..];
            }
            else
            {
                key = body;
                if (index + 1 < args.Count && !args[index + 1].StartsWith("--", StringComparison.Ordinal))
                {
                    value = args[++index];
                }
                else
                {
                    value = "true";
                }
            }

            if (!result._values.TryGetValue(key, out var list))
            {
                list = new List<string>();
                result._values[key] = list;
            }

            list.Add(value);
        }

        return result;
    }

    public string? Get(string name) =>
        _values.TryGetValue(name, out var list) ? list[^1] : null;

    public IReadOnlyList<string> GetAll(string name) =>
        _values.TryGetValue(name, out var list) ? list : Array.Empty<string>();

    public bool Has(string name) => _values.ContainsKey(name);

    public int GetInt(string name, int fallback) =>
        int.TryParse(Get(name), out var value) ? value : fallback;
}
