using System.Buffers.Binary;
using RomRecon.Nds;

namespace RomRecon.Analysis;

public enum Status { Ok, Info, Unexpected, Missing }

/// <summary>One observation about a Pokemon-related data table. Contains sizes, counts and aggregate statistics only - never game content.</summary>
public sealed record TableFinding(string Table, string Path, long Size, Status Status, string Observation);

/// <summary>
/// Checks the structural assumptions recorded in docs/expansion/POKEMON_LIMIT_AUDIT.md (F-01...F-10) against a real ROM.
/// Field positions come from RanseiLink.Generation/Models.xml. Read-only.
/// </summary>
public static class TableReport
{
    public const int PokemonStride = 0x30;
    public const int PokemonVanillaCount = 200;
    public const int EvolutionTableOffset = 0x25C0;
    public const int MaxLinkWarriors = 252;
    public const int ScenarioCount = 11;

    private static int Bits(ReadOnlySpan<byte> rec, int intIndex, int shift, int count) =>
        (int)((BinaryPrimitives.ReadUInt32LittleEndian(rec.Slice(intIndex * 4, 4)) >> shift) & ((1u << count) - 1));

    public static List<TableFinding> Build(NdsRom rom)
    {
        var list = new List<TableFinding>();
        Pokemon(rom, list);
        MaxLink(rom, list);
        ScenarioTables(rom, list);
        Kingdom(rom, list);
        Archives(rom, list);
        return list;
    }

    private static NdsFile? Need(NdsRom rom, string path, List<TableFinding> list)
    {
        var f = rom.FindFile(path);
        if (f is null) { list.Add(new TableFinding(Name(path), path, 0, Status.Missing, "File not found in the ROM file system.")); }
        return f;
    }

    private static string Name(string path) => System.IO.Path.GetFileName(path);

    private static void Pokemon(NdsRom rom, List<TableFinding> list)
    {
        const string path = "data/Pokemon.dat";
        var f = Need(rom, path, list);
        if (f is null) { return; }
        var d = rom.ReadFile(f);
        long recordsEnd = (long)PokemonVanillaCount * PokemonStride;
        list.Add(new TableFinding("Pokemon.dat", path, d.Length, d.Length >= EvolutionTableOffset + 4 ? Status.Info : Status.Unexpected,
            $"size 0x{d.Length:X}; vanilla layout = {PokemonVanillaCount} records x 0x{PokemonStride:X} = 0x{recordsEnd:X}, gap 0x{EvolutionTableOffset - recordsEnd:X} bytes, evolution table at 0x{EvolutionTableOffset:X} (RanseiLink assumes these - PokemonService.cs:9-10)."));
        if (d.Length < EvolutionTableOffset + 4) { return; }

        uint evoLen = BinaryPrimitives.ReadUInt32LittleEndian(d.AsSpan(EvolutionTableOffset, 4));
        long evoEnd = EvolutionTableOffset + 4L + evoLen;
        long padded = (evoEnd + 3) & ~3L;
        list.Add(new TableFinding("Pokemon.dat evolution table", path, evoLen,
            padded == d.Length ? Status.Ok : Status.Unexpected,
            $"length field = {evoLen} bytes; table ends at 0x{evoEnd:X} (padded 0x{padded:X}); file size 0x{d.Length:X} {(padded == d.Length ? "matches" : "DOES NOT match")}."));

        // the 64-byte gap (audit finding F-04): report only shape, never content
        var gap = d.AsSpan((int)recordsEnd, (int)(EvolutionTableOffset - recordsEnd));
        int nonZero = 0; var distinct = new HashSet<byte>();
        foreach (var b in gap) { if (b != 0) { nonZero++; } distinct.Add(b); }
        list.Add(new TableFinding("Pokemon.dat gap", path, gap.Length, Status.Info,
            $"0x{recordsEnd:X}..0x{EvolutionTableOffset:X}: {nonZero} non-zero byte(s), {distinct.Count} distinct value(s), SHA-256 {Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(gap))[..16].ToLowerInvariant()}... (audit F-04: purpose unknown; use --dump-gap to save locally)."));

        // aggregate statistics over the 200 records
        var orderIdx = new HashSet<int>(); int maxOrder = 0, minDex = int.MaxValue, maxDex = 0, evoInRange = 0, evoNone = 0, evoBad = 0;
        for (int i = 0; i < PokemonVanillaCount; i++)
        {
            var rec = d.AsSpan(i * PokemonStride, PokemonStride);
            int order = rec[44]; // NameOrderIndex, Models.xml: Index 11, shift 0, 8 bits
            orderIdx.Add(order); maxOrder = Math.Max(maxOrder, order);
            int dex = Bits(rec, 8, 22, 10); // NationalPokedexNumber
            minDex = Math.Min(minDex, dex); maxDex = Math.Max(maxDex, dex);
            int min = Bits(rec, 8, 0, 11), max = Bits(rec, 8, 11, 11);
            if (min == 1400 && max == 1400) { evoNone++; }
            else if (min <= max && max < evoLen) { evoInRange++; }
            else { evoBad++; }
        }
        list.Add(new TableFinding("Pokemon.dat records", path, PokemonVanillaCount, orderIdx.Count == PokemonVanillaCount ? Status.Ok : Status.Unexpected,
            $"NameOrderIndex: {orderIdx.Count} unique values, max {maxOrder} (8-bit field => at most 256 species); NationalPokedexNumber range {minDex}..{maxDex}; evolution ranges: {evoNone} none(1400), {evoInRange} valid, {evoBad} invalid."));

        int maxSpecies = 0; for (int i = 0; i < evoLen && EvolutionTableOffset + 4 + i < d.Length; i++) { maxSpecies = Math.Max(maxSpecies, d[EvolutionTableOffset + 4 + i]); }
        list.Add(new TableFinding("Pokemon.dat evolution entries", path, evoLen, maxSpecies < PokemonVanillaCount ? Status.Ok : Status.Unexpected,
            $"largest species id stored in the evolution table = {maxSpecies} (entries are single bytes: audit F-02)."));
    }

    private static void MaxLink(NdsRom rom, List<TableFinding> list)
    {
        const string path = "data/BaseBushouMaxSyncTable.dat";
        var f = Need(rom, path, list);
        if (f is null) { return; }
        bool divisible = f.Length % MaxLinkWarriors == 0;
        long stride = f.Length / MaxLinkWarriors;
        list.Add(new TableFinding("MaxLink (BaseBushouMaxSyncTable)", path, f.Length,
            divisible && stride == PokemonVanillaCount ? Status.Ok : Status.Unexpected,
            $"size {f.Length} = {MaxLinkWarriors} warriors x {stride} bytes{(divisible ? "" : " (NOT evenly divisible)")}; expected stride {PokemonVanillaCount} = one byte per species (audit F-08)."));
    }

    private static void ScenarioTables(NdsRom rom, List<TableFinding> list)
    {
        for (int sc = 0; sc < ScenarioCount; sc++)
        {
            string dir = $"data/Scenario/Scenario{sc:D2}/";
            var sp = rom.FindFile(dir + "ScenarioPokemon.dat");
            if (sp is null) { list.Add(new TableFinding($"ScenarioPokemon[{sc:D2}]", dir + "ScenarioPokemon.dat", 0, Status.Missing, "not found")); }
            else
            {
                var d = rom.ReadFile(sp);
                int entries = d.Length / 8, sentinel = 0, maxId = -1, over = 0;
                for (int i = 0; i < entries; i++)
                {
                    int id = d[i * 8];
                    if (id == 200) { sentinel++; } else { maxId = Math.Max(maxId, id); if (id > 199) { over++; } }
                }
                list.Add(new TableFinding($"ScenarioPokemon[{sc:D2}]", sp.Path, d.Length, entries == 200 && over == 0 ? Status.Ok : Status.Unexpected,
                    $"{entries} entries x 8 bytes; species byte 200 (the 'none' sentinel, audit F-05) in {sentinel} entries; largest other species id {maxId}; {over} entries with id > 199 other than the sentinel."));
            }

            var ap = rom.FindFile(dir + "ScenarioAppearPokemon.dat");
            if (ap is null) { list.Add(new TableFinding($"ScenarioAppearPokemon[{sc:D2}]", dir + "ScenarioAppearPokemon.dat", 0, Status.Missing, "not found")); }
            else
            {
                var d = rom.ReadFile(ap);
                var values = d.Distinct().OrderBy(v => v).Select(v => $"0x{v:X2}");
                list.Add(new TableFinding($"ScenarioAppearPokemon[{sc:D2}]", ap.Path, d.Length, d.Length == 0xC8 ? Status.Ok : Status.Unexpected,
                    $"{d.Length} bytes (expected 0xC8 = 200, one flag per species, audit F-07); distinct values: {string.Join(", ", values)}; {d.Count(b => b != 0)} flagged."));
            }
        }
    }

    private static void Kingdom(NdsRom rom, List<TableFinding> list)
    {
        const string path = "data/Kuni.dat";
        var f = Need(rom, path, list);
        if (f is null) { return; }
        bool jp = rom.Header.GameCode.Equals("VPYJ", StringComparison.OrdinalIgnoreCase);
        int stride = jp ? 0x14 : 0x18, swarmInt = jp ? 4 : 5; // Models.xml Kingdom (Index_VPYJ = 4,22,8; default 5,22,8)
        int count = (int)(f.Length / stride);
        var d = rom.ReadFile(f);
        var swarm = new List<int>();
        for (int r = 0; r < count; r++) { swarm.Add(Bits(d.AsSpan(r * stride, stride), swarmInt, 22, 8)); }
        string range = swarm.Count == 0 ? "n/a" : $"{swarm.Min()}..{swarm.Max()}";
        list.Add(new TableFinding("Kuni (Kingdom)", path, f.Length, count == 17 && f.Length % stride == 0 ? Status.Ok : Status.Unexpected,
            $"{count} records x 0x{stride:X} ({(jp ? "JP layout" : "NA/EU layout")}); SwarmPokemon is an 8-bit field (audit F-09), range {range}."));
    }

    private static void Archives(NdsRom rom, List<TableFinding> list)
    {
        string[] names =
        [
            "graphics/model_pokemon/POKEMON_TEX.ALL", "graphics/model_pokemon/POKEMON_ATX.ALL",
            "graphics/model_pokemon/POKEMON_DTX.ALL", "graphics/model_pokemon/POKEMON_PAC.ALL",
            "graphics/still/stl_pokemon_ci/stl_pokemon_ci.G2DR", "graphics/still/stl_pokemon_sr/stl_pokemon_sr.G2DR",
            "graphics/still/stl_pokemon_s/stl_pokemon_s.G2DR", "graphics/still/stl_pokemon_b/stl_pokemon_b.G2DR",
            "graphics/still/stl_pokemon_m/stl_pokemon_m.G2DR", "graphics/still/stl_pokemon_l/stl_pokemon_l.G2DR",
            "graphics/still/stl_pokemon_wu/stl_pokemon_wu.G2DR",
        ];
        foreach (var path in names)
        {
            var f = rom.FindFile(path);
            if (f is null) { list.Add(new TableFinding(Name(path), path, 0, Status.Missing, "not found")); continue; }
            var head = rom.Read(f.Start, Math.Min(16, f.Length));
            if (head.Length < 16 || head[0] != 'L' || head[1] != 'I' || head[2] != 'N' || head[3] != 'K')
            {
                list.Add(new TableFinding(Name(path), path, f.Length, Status.Unexpected, "does not start with the LINK magic."));
                continue;
            }
            uint entries = BinaryPrimitives.ReadUInt32LittleEndian(head.AsSpan(4, 4));
            uint scaler = BinaryPrimitives.ReadUInt32LittleEndian(head.AsSpan(8, 4));
            bool pokemonPerEntry = path.Contains("model_pokemon");
            list.Add(new TableFinding(Name(path), path, f.Length, pokemonPerEntry && entries != PokemonVanillaCount ? Status.Unexpected : Status.Info,
                $"LINK archive with {entries} entries (offset scaler {scaler}); {(pokemonPerEntry ? $"expected {PokemonVanillaCount} (one per species, audit F-10)" : "STL sprite archive: entries are not simply one-per-species, interpret with the matching *Info.dat")}."));
        }
    }
}
