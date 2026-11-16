using RomRecon.Analysis;
using RomRecon.Nds;

namespace RomRecon.Tests;

public class TableReportTests
{
    private static List<TableFinding> Report(SyntheticNds nds)
    {
        var path = nds.WriteToTemp();
        try { using var rom = NdsRom.Open(path); return TableReport.Build(rom); }
        finally { File.Delete(path); }
    }

    [Fact]
    public void Vanilla_shaped_rom_passes_every_capacity_check()
    {
        var findings = Report(FakeConquest.Rom());
        Assert.DoesNotContain(findings, f => f.Status is Status.Unexpected or Status.Missing);
        Assert.Contains(findings, f => f.Table == "Pokemon.dat records" && f.Observation.Contains("200 unique values"));
        Assert.Contains(findings, f => f.Table == "MaxLink (BaseBushouMaxSyncTable)" && f.Observation.Contains("252 warriors x 200 bytes"));
        Assert.Contains(findings, f => f.Table == "Pokemon.dat gap" && f.Size == 64);
    }

    [Fact]
    public void Every_table_finding_carries_its_rom_file_offset()
    {
        var findings = Report(FakeConquest.Rom());
        var pokemon = findings.First(f => f.Table == "Pokemon.dat");
        Assert.True(pokemon.RomOffset > 0 && pokemon.RomOffset % 0x200 == 0);
        Assert.All(findings.Where(f => f.Path.Length > 0), f => Assert.True(f.RomOffset > 0, f.Table));
    }

    [Fact]
    public void Sentinel_entries_are_counted_in_every_scenario()
    {
        var findings = Report(FakeConquest.Rom()).Where(f => f.Table.StartsWith("ScenarioPokemon[")).ToList();
        Assert.Equal(11, findings.Count);
        Assert.All(findings, f => Assert.Contains("in 1 entries", f.Observation));
    }

    [Fact]
    public void Expanded_looking_tables_are_reported_as_unexpected()
    {
        var nds = FakeConquest.Rom();
        nds.Files["data/BaseBushouMaxSyncTable.dat"] = new byte[252 * 220];
        nds.Files["data/Scenario/Scenario03/ScenarioAppearPokemon.dat"] = new byte[220];
        var findings = Report(nds);
        Assert.Contains(findings, f => f.Table.StartsWith("MaxLink") && f.Status == Status.Unexpected && f.Observation.Contains("x 220 bytes"));
        Assert.Contains(findings, f => f.Table == "ScenarioAppearPokemon[03]" && f.Status == Status.Unexpected);
    }

    [Fact]
    public void Missing_files_are_reported_not_thrown()
    {
        var findings = Report(new SyntheticNds());
        Assert.Contains(findings, f => f.Table == "Pokemon.dat" && f.Status == Status.Missing);
        Assert.All(findings, f => Assert.True(f.Status == Status.Missing));
    }

    [Fact]
    public void Archive_entry_count_other_than_200_is_flagged_for_model_archives()
    {
        var findings = Report(FakeConquest.Rom(linkEntries: 201));
        Assert.Contains(findings, f => f.Table == "POKEMON_TEX.ALL" && f.Status == Status.Unexpected && f.Observation.Contains("201 entries"));
    }

    [Fact]
    public void Japanese_kingdom_layout_uses_the_short_record()
    {
        var findings = Report(FakeConquest.Rom("VPYJ"));
        Assert.Contains(findings, f => f.Table == "Kuni (Kingdom)" && f.Status == Status.Ok && f.Observation.Contains("JP layout"));
    }

    [Fact]
    public void Evolution_table_length_mismatch_is_detected()
    {
        var nds = FakeConquest.Rom();
        var dat = FakeConquest.PokemonDat();
        Array.Resize(ref dat, dat.Length + 8); // trailing bytes that the length field does not account for
        nds.Files["data/Pokemon.dat"] = dat;
        Assert.Contains(Report(nds), f => f.Table == "Pokemon.dat evolution table" && f.Status == Status.Unexpected);
    }
}
