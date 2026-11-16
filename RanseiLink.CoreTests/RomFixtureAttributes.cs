using System;
using System.IO;
using Xunit;

namespace RanseiLink.CoreTests;

/// <summary>
/// Marks a test that needs ROM-derived fixture data (an unmodified extracted mod folder) that cannot be committed
/// to the repository for copyright reasons. The test is reported as *skipped* - instead of failing - when the fixture
/// folder is not present on this machine.
/// See docs/expansion/BASELINE_REPAIR.md for how to provide the fixtures locally.
/// </summary>
[AttributeUsage(AttributeTargets.Method)]
public sealed class RomFixtureFactAttribute : FactAttribute
{
    public RomFixtureFactAttribute(params string[] fixturePaths)
    {
        Skip = RomFixture.SkipReason(fixturePaths);
    }
}

/// <inheritdoc cref="RomFixtureFactAttribute"/>
[AttributeUsage(AttributeTargets.Method)]
public sealed class RomFixtureTheoryAttribute : TheoryAttribute
{
    public RomFixtureTheoryAttribute(params string[] fixturePaths)
    {
        Skip = RomFixture.SkipReason(fixturePaths);
    }
}

internal static class RomFixture
{
    /// <param name="fixturePaths">Folders or files, relative to <see cref="TestConstants.TestFolder"/>. Defaults to the "TestMod" folder.</param>
    /// <returns>null when every fixture exists (run the test), otherwise the skip reason.</returns>
    public static string? SkipReason(string[] fixturePaths)
    {
        if (fixturePaths.Length == 0)
        {
            fixturePaths = ["TestMod"];
        }
        foreach (var relative in fixturePaths)
        {
            var path = Path.Combine(TestConstants.TestFolder, relative);
            if (!Directory.Exists(path) && !File.Exists(path))
            {
                return $"ROM-derived fixture not found: '{path}'. These fixtures are copyrighted and must be created locally from your own ROM (see docs/expansion/BASELINE_REPAIR.md).";
            }
        }
        return null;
    }
}
