using System.Text.RegularExpressions;

namespace RomRecon;

/// <summary>
/// Heuristic detection of cloud-synchronised folders (OneDrive, Dropbox, Google Drive, iCloud, Box, MEGA, pCloud, ...).
/// ROM-derived output must never land in one (AGENTS.md rule 5). Returns a human-readable reason, or null when nothing suggests sync.
/// Mirrors Test-IsCloudSyncedPath in tools/windows/Setup-ConquestDev.ps1.
/// </summary>
public static partial class CloudSync
{
    [GeneratedRegex(@"^(OneDrive(\s-\s.+|\s\(.+\))?|Dropbox(\s\(.+\))?|Google\s?Drive|My\sDrive|iCloudDrive|iCloud\sDrive|Box(\sSync)?|MEGA(sync)?|pCloud(\sDrive)?|Nextcloud|ownCloud|Tresorit|Creative\sCloud\sFiles.*)$", RegexOptions.IgnoreCase)]
    private static partial Regex FolderNamePattern();

    private static readonly string[] MarkerNames = [".dropbox", ".dropbox.cache", ".owncloudsync.log", ".mega-sync"];
    private const int PlaceholderBits = 0x40000 | 0x80000 | 0x100000 | 0x400000; // RECALL_ON_OPEN, PINNED, UNPINNED, RECALL_ON_DATA_ACCESS

    public static string? Detect(string path, int depth = 0)
    {
        var full = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

        foreach (var name in new[] { "OneDrive", "OneDriveConsumer", "OneDriveCommercial" })
        {
            var root = Environment.GetEnvironmentVariable(name);
            if (string.IsNullOrWhiteSpace(root)) { continue; }
            var r = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (string.Equals(full, r, comparison) || full.StartsWith(r + Path.DirectorySeparatorChar, comparison))
            {
                return $"inside the {name} folder ({root})";
            }
        }

        string? dir = full;
        while (!string.IsNullOrEmpty(dir))
        {
            var leaf = Path.GetFileName(dir);
            if (!string.IsNullOrEmpty(leaf) && FolderNamePattern().IsMatch(leaf)) { return $"inside a folder named '{leaf}'"; }
            foreach (var marker in MarkerNames)
            {
                if (Directory.Exists(Path.Combine(dir, marker)) || File.Exists(Path.Combine(dir, marker)))
                {
                    return $"inside a folder that contains the sync marker '{marker}' ({dir})";
                }
            }
            if (Directory.Exists(dir))
            {
                var info = new DirectoryInfo(dir);
                if (((int)info.Attributes & PlaceholderBits) != 0) { return $"a cloud placeholder / pinned folder ({dir})"; }
                if (info.Attributes.HasFlag(FileAttributes.ReparsePoint) && depth < 5)
                {
                    var target = info.LinkTarget;
                    if (!string.IsNullOrEmpty(target))
                    {
                        var absolute = Path.IsPathRooted(target) ? target : Path.GetFullPath(target, Path.GetDirectoryName(dir) ?? dir);
                        var inner = Detect(absolute, depth + 1);
                        if (inner is not null) { return $"a link ({dir} -> {target}) that points {inner}"; }
                    }
                }
            }
            var parent = Path.GetDirectoryName(dir);
            if (string.IsNullOrEmpty(parent) || parent == dir) { break; }
            dir = parent;
        }
        return null;
    }
}
