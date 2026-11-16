using System.Text.RegularExpressions;

namespace RomRecon.Tests;

/// <summary>
/// AGENTS.md rule 6/8: ROM-processing tools must not be able to transmit data. These tests fail if RomRecon ever gains a
/// dependency that could reach the network.
/// </summary>
public class NoNetworkTests
{
    [Fact]
    public void RomRecon_references_no_networking_assemblies()
    {
        var referenced = typeof(Cli).Assembly.GetReferencedAssemblies().Select(a => a.Name!).ToList();
        Assert.DoesNotContain(referenced, n => Regex.IsMatch(n, @"^System\.Net(\..*)?$|^System\.Web|^Microsoft\.AspNetCore|^Azure|^AWSSDK|^Google\.", RegexOptions.IgnoreCase));
    }

    [Fact]
    public void RomRecon_project_has_no_package_references()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "tools", "RomRecon", "RomRecon.csproj"))) { dir = dir.Parent; }
        Assert.NotNull(dir);
        var csproj = File.ReadAllText(Path.Combine(dir!.FullName, "tools", "RomRecon", "RomRecon.csproj"));
        Assert.DoesNotContain("PackageReference", csproj);
        Assert.DoesNotContain("ProjectReference", csproj);
    }

    [Fact]
    public void RomRecon_sources_contain_no_network_apis()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "tools", "RomRecon"))) { dir = dir.Parent; }
        Assert.NotNull(dir);
        foreach (var file in Directory.EnumerateFiles(Path.Combine(dir!.FullName, "tools", "RomRecon"), "*.cs", SearchOption.AllDirectories))
        {
            if (file.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}") || file.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}")) { continue; }
            var text = File.ReadAllText(file);
            Assert.DoesNotMatch(@"System\.Net|HttpClient|WebClient|Socket|TcpClient|UdpClient|WebRequest|Process\.Start|ProcessStartInfo", text);
        }
    }
}
