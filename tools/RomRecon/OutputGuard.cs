namespace RomRecon;

/// <summary>Refuses to write analysis output anywhere it could be committed by accident, and never overwrites anything.</summary>
public static class OutputGuard
{
    public sealed class RefusedException(string message) : Exception(message);

    /// <summary>Walks up from <paramref name="dir"/> looking for a .git entry.</summary>
    public static string? FindGitRoot(string dir)
    {
        var d = new DirectoryInfo(Path.GetFullPath(dir));
        while (d is not null)
        {
            if (Directory.Exists(Path.Combine(d.FullName, ".git")) || File.Exists(Path.Combine(d.FullName, ".git"))) { return d.FullName; }
            d = d.Parent;
        }
        return null;
    }

    /// <summary>
    /// Creates (never reuses) a brand-new directory "recon_&lt;hash8&gt;_&lt;timestamp&gt;[_n]" under <paramref name="baseDir"/>.
    /// Throws <see cref="RefusedException"/> if baseDir is inside a git working tree (unless allowed).
    /// </summary>
    public static string CreateNewOutputDirectory(string baseDir, string sha256, bool allowInRepo, DateTime? now = null)
    {
        var full = Path.GetFullPath(baseDir);
        if (!allowInRepo)
        {
            var root = FindGitRoot(full);
            if (root is not null)
            {
                throw new RefusedException(
                    $"Refusing to write analysis output inside a git working tree ('{root}'): reports and extracted code derive from a copyrighted ROM and must never be committed. " +
                    "Choose an --out directory outside the repository (e.g. <workspace>\\diagnostics), or pass --allow-in-repo if you are certain it is git-ignored.");
            }
        }
        // Cloud-synchronised folders are refused unconditionally: --allow-in-repo does NOT override this.
        var cloud = CloudSync.Detect(full);
        if (cloud is not null)
        {
            throw new RefusedException(
                $"Refusing to write analysis output to '{full}': it is in a cloud-synchronised location ({cloud}). Reports and extracted code derive from a copyrighted ROM and must stay on this computer. " +
                "Choose an --out directory outside OneDrive, Dropbox, Google Drive, iCloud, Box, MEGA, pCloud and similar (e.g. <workspace>\\diagnostics).");
        }
        Directory.CreateDirectory(full);
        string stamp = (now ?? DateTime.Now).ToString("yyyyMMdd-HHmmss");
        string name = $"recon_{sha256[..8]}_{stamp}";
        string candidate = Path.Combine(full, name);
        int n = 1;
        while (Directory.Exists(candidate) || File.Exists(candidate))
        {
            candidate = Path.Combine(full, $"{name}_{++n}");
        }
        Directory.CreateDirectory(candidate);
        return candidate;
    }
}
