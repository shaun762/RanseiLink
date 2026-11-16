using System;
using System.IO;
using Xunit;

namespace RanseiLink.ConsoleTests;

/// <summary>
/// Marks a test that needs a ROM-derived fixture (an unmodified extracted mod folder) which cannot be committed for
/// copyright reasons. The test is reported as *skipped* instead of failing when the fixture is absent.
/// See docs/expansion/BASELINE_REPAIR.md.
/// </summary>
[AttributeUsage(AttributeTargets.Method)]
public sealed class RomFixtureFactAttribute : FactAttribute
{
    public RomFixtureFactAttribute()
    {
        var path = ScriptTests.ScriptTests.TestModFolder;
        if (!Directory.Exists(path))
        {
            Skip = $"ROM-derived fixture not found: '{path}'. Create it locally from your own ROM (see docs/expansion/BASELINE_REPAIR.md).";
        }
    }
}
