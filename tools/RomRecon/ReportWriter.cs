using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using RomRecon.Analysis;

namespace RomRecon;

public static class ReportWriter
{
    public static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
        IncludeFields = false,
    };

    public static string ToJson(ReconReport r) => JsonSerializer.Serialize(r, Json);

    public static string Section(ReconReport r, string section)
    {
        var sb = new StringBuilder();
        switch (section)
        {
            case "header": Header(sb, r); break;
            case "files": Files(sb, r); break;
            case "overlays": Overlays(sb, r); break;
            case "code": Code(sb, r); break;
            case "tables": Tables(sb, r); break;
            case "scan": Scan(sb, r); break;
            default:
                Header(sb, r); Code(sb, r); Overlays(sb, r); Tables(sb, r); Scan(sb, r);
                sb.AppendLine().AppendLine($"(file system: {r.FileCount} files; use the 'files' command to list them)");
                break;
        }
        return sb.ToString();
    }

    private static void Title(StringBuilder sb, string t) => sb.AppendLine().AppendLine($"== {t} ==");

    private static void Header(StringBuilder sb, ReconReport r)
    {
        var h = r.Header;
        Title(sb, "ROM header");
        sb.AppendLine($"File            : {r.RomFileName} ({r.RomLength} bytes)");
        sb.AppendLine($"SHA-256         : {r.Sha256}");
        sb.AppendLine($"Title / code    : '{h.GameTitle}' / {h.GameCode}  (maker {h.MakerCode}, version {h.RomVersion}, unit {h.UnitCode})");
        sb.AppendLine($"ARM9            : file 0x{h.Arm9Offset:X}  size 0x{h.Arm9Size:X}  ram 0x{h.Arm9RamAddress:X8}  entry 0x{h.Arm9Entry:X8}");
        sb.AppendLine($"ARM7            : file 0x{h.Arm7Offset:X}  size 0x{h.Arm7Size:X}  ram 0x{h.Arm7RamAddress:X8}  entry 0x{h.Arm7Entry:X8}");
        sb.AppendLine($"FNT / FAT       : 0x{h.FntOffset:X}+0x{h.FntSize:X}  /  0x{h.FatOffset:X}+0x{h.FatSize:X}");
        sb.AppendLine($"Overlay tables  : ARM9 0x{h.Arm9OverlayOffset:X}+0x{h.Arm9OverlaySize:X}   ARM7 0x{h.Arm7OverlayOffset:X}+0x{h.Arm7OverlaySize:X}");
        sb.AppendLine($"Banner / size   : 0x{h.IconBannerOffset:X} / used ROM size 0x{h.UsedRomSize:X}, header size 0x{h.HeaderSize:X}");
        sb.AppendLine($"Header CRC      : stored 0x{h.HeaderCrcStored:X4}, computed 0x{h.HeaderCrcComputed:X4} -> {(h.HeaderCrcValid ? "OK" : "MISMATCH")}");
        sb.AppendLine($"Logo CRC        : stored 0x{h.LogoCrcStored:X4}, computed 0x{h.LogoCrcComputed:X4} -> {(h.LogoCrcValid ? "OK" : "MISMATCH")}");
        if (r.Warnings.Count > 0) { sb.AppendLine("Warnings:"); foreach (var w in r.Warnings) { sb.AppendLine($"  ! {w}"); } }
    }

    private static void Files(StringBuilder sb, ReconReport r)
    {
        Title(sb, $"File system ({r.FileCount} files)");
        foreach (var f in r.Files.OrderBy(f => f.FileId)) { sb.AppendLine($"  [{f.FileId,5}] 0x{f.Start:X8}  {f.Length,9}  {f.Path}"); }
    }

    private static void Code(StringBuilder sb, ReconReport r)
    {
        Title(sb, "Executable code");
        if (r.ModuleParams is { } m)
        {
            sb.AppendLine($"ARM9 module params @ ARM9+0x{m.MagicOffset:X}: autoload 0x{m.AutoloadListStart:X8}..0x{m.AutoloadListEnd:X8}, static BSS 0x{m.StaticBssStart:X8}..0x{m.StaticBssEnd:X8}, compressed-static-end 0x{m.CompressedStaticEnd:X8}, SDK 0x{m.SdkVersion:X8}");
        }
        else { sb.AppendLine("ARM9 module params: NOT FOUND"); }
        sb.AppendLine($"ARM9 post-data (21 06 C0 DE blocks after ARM9): {r.Arm9Post.Length} bytes");
        foreach (var c in r.CodeRegions.Where(c => !c.Name.StartsWith("overlay")))
        {
            sb.AppendLine($"  {c.Name,-6} file 0x{c.FileOffset:X8}  size 0x{c.Size:X}  ram 0x{c.RamAddress:X8}  compressed: {(c.Compressed?.ToString() ?? "unknown")}  decompressed: {c.Decompressed} (0x{c.ImageSize:X})  sha256 {c.Sha256[..16]}...");
            sb.AppendLine($"         evidence: {c.CompressionEvidence}");
            if (c.Note is not null) { sb.AppendLine($"         NOTE: {c.Note}"); }
        }
    }

    private static void Overlays(StringBuilder sb, ReconReport r)
    {
        Title(sb, $"ARM9 overlays ({r.Arm9Overlays.Count}) / ARM7 overlays ({r.Arm7Overlays.Count})");
        foreach (var o in r.Arm9Overlays)
        {
            var reg = r.CodeRegions.FirstOrDefault(c => c.Name == $"overlay9_{o.Id}");
            sb.AppendLine($"  ov9 #{o.Id,-3} ram 0x{o.RamAddress:X8} size 0x{o.RamSize:X6} bss 0x{o.BssSize:X5} file-id {o.FileId,5} compressed {(o.IsCompressed ? "yes" : "no ")}{(reg is null ? "" : $" decompressed {(reg.Decompressed ? "yes" : "no")}")}{(reg?.Note is null ? "" : "  NOTE: " + reg.Note)}");
        }
        foreach (var o in r.Arm7Overlays) { sb.AppendLine($"  ov7 #{o.Id,-3} ram 0x{o.RamAddress:X8} size 0x{o.RamSize:X6} file-id {o.FileId,5} compressed {(o.IsCompressed ? "yes" : "no")}"); }
    }

    private static void Tables(StringBuilder sb, ReconReport r)
    {
        Title(sb, "Pokemon-related tables (capacity check vs. audit assumptions)");
        foreach (var t in r.Tables) { sb.AppendLine($"  [{t.Status,-10}] {t.Table}: {t.Observation}"); }
    }

    private static void Scan(StringBuilder sb, ReconReport r)
    {
        Title(sb, "Capacity-constant candidates (HEURISTIC - confirm with a disassembler/debugger)");
        sb.AppendLine($"Total candidates: {r.TotalHits}; per-region summary:");
        foreach (var s in r.ScanSummaries) { sb.AppendLine($"  {s.Region,-12} {s.Kind,-14} x{s.Count,-5} {s.Label}"); }
        sb.AppendLine("Listed hits (capped per region):");
        foreach (var h in r.Hits) { sb.AppendLine($"  {h.Region,-12} 0x{h.Address:X8}  {h.Kind,-13} {h.Detail}  <- {h.Label}"); }
    }
}
