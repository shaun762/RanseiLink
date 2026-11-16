using System.Globalization;
using RomRecon;
using RomRecon.Analysis;
using RomRecon.Nds;

return Cli.Run(args, Console.Out, Console.Error);

namespace RomRecon
{
    public static class Cli
    {
        public const int Ok = 0, Usage = 1, BadInput = 2, IntegrityFailure = 3, OutputRefused = 4;

        private const string UsageText = """
            RomRecon - READ-ONLY Nintendo DS ROM reconnaissance for Pokemon Conquest

            Usage:
              RomRecon <command> <rom.nds> [options]

            Commands:   all (default) | header | files | overlays | code | tables | scan
            Options:
              --out <dir>        write report.txt, report.json (and any extracted files) into a NEW sub-directory of <dir>
              --json             print the full JSON report to stdout instead of text
              --values <list>    comma-separated constants to look for (decimal or 0x..); default: capacity-related values
              --thumb            also scan for Thumb immediates (noisy)
              --arm7             also scan ARM7
              --max-hits <n>     hits listed per region (default 100)
              --extract-code     with --out: write decompressed ARM9/overlay images (COPYRIGHTED CODE: keep local, never commit)
              --dump-gap         with --out: write Pokemon.dat bytes 0x2580..0x25C0 (audit finding F-04) to gap.bin
              --allow-in-repo    allow --out inside a git working tree (not recommended)

            The ROM is opened read-only and is hashed before and after the run; the tool exits with code 3 if it changed.
            Exit codes: 0 ok, 1 usage, 2 unreadable/invalid ROM, 3 ROM changed during analysis, 4 output location refused.
            """;

        public static int Run(string[] args, TextWriter stdout, TextWriter stderr)
        {
            string[] commands = ["all", "header", "files", "overlays", "code", "tables", "scan"];
            string command = "all"; string? romPath = null; string? outDir = null;
            bool json = false, thumb = false, arm7 = false, extract = false, dumpGap = false, allowInRepo = false;
            int maxHits = 100; Dictionary<uint, string>? values = null;

            try
            {
                for (int i = 0; i < args.Length; i++)
                {
                    string a = args[i];
                    string Next() => i + 1 < args.Length ? args[++i] : throw new ArgumentException($"Option {a} needs a value.");
                    switch (a)
                    {
                        case "-h": case "--help": stdout.WriteLine(UsageText); return Ok;
                        case "--out": outDir = Next(); break;
                        case "--json": json = true; break;
                        case "--thumb": thumb = true; break;
                        case "--arm7": arm7 = true; break;
                        case "--extract-code": extract = true; break;
                        case "--dump-gap": dumpGap = true; break;
                        case "--allow-in-repo": allowInRepo = true; break;
                        case "--max-hits": maxHits = int.Parse(Next(), CultureInfo.InvariantCulture); break;
                        case "--values":
                            values = [];
                            foreach (var tok in Next().Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                            {
                                uint v = tok.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? uint.Parse(tok[2..], NumberStyles.HexNumber, CultureInfo.InvariantCulture) : uint.Parse(tok, CultureInfo.InvariantCulture);
                                values[v] = ScanOptions.DefaultValues.TryGetValue(v, out var l) ? l : "user-specified value";
                            }
                            break;
                        default:
                            if (a.StartsWith('-')) { throw new ArgumentException($"Unknown option '{a}'."); }
                            if (romPath is null && Array.IndexOf(commands, a) >= 0 && command == "all" && !args.Take(i).Any(x => Array.IndexOf(commands, x) >= 0)) { command = a; }
                            else if (romPath is null) { romPath = a; }
                            else { throw new ArgumentException($"Unexpected argument '{a}'."); }
                            break;
                    }
                }
                if (romPath is null) { throw new ArgumentException("No ROM path given."); }
            }
            catch (Exception e) when (e is ArgumentException or FormatException or OverflowException)
            {
                stderr.WriteLine($"error: {e.Message}\n"); stderr.WriteLine(UsageText);
                return Usage;
            }

            // Fail before doing any work if the output location is not acceptable.
            string? reportDir = null;
            string sha;
            try { sha = NdsRom.Sha256Hex(romPath); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                stderr.WriteLine($"error: cannot read '{romPath}': {e.Message}");
                return BadInput;
            }
            try
            {
                if (outDir is not null) { reportDir = OutputGuard.CreateNewOutputDirectory(outDir, sha, allowInRepo); }
            }
            catch (OutputGuard.RefusedException e)
            {
                stderr.WriteLine($"error: {e.Message}");
                return OutputRefused;
            }

            ReconReport report; List<ExtractedImage> images; NdsRom? rom = null;
            try
            {
                rom = NdsRom.Open(romPath);
                var options = new ReconOptions
                {
                    Scan = new ScanOptions { IncludeThumb = thumb, Values = values ?? ScanOptions.DefaultValues },
                    ScanArm7 = arm7,
                    MaxHitsPerRegion = maxHits,
                };
                (report, images) = Recon.Run(rom, sha, options);

                if (dumpGap && reportDir is not null)
                {
                    var f = rom.FindFile("data/Pokemon.dat");
                    if (f is not null && f.Length >= TableReport.EvolutionTableOffset)
                    {
                        var d = rom.ReadFile(f);
                        File.WriteAllBytes(Path.Combine(reportDir, "gap.bin"), d[(TableReport.PokemonVanillaCount * TableReport.PokemonStride)..TableReport.EvolutionTableOffset]);
                    }
                }
            }
            catch (Exception e) when (e is InvalidDataException or EndOfStreamException or IOException)
            {
                stderr.WriteLine($"error: '{romPath}' could not be analysed: {e.Message}");
                return BadInput;
            }
            finally { rom?.Dispose(); }

            // Prove the ROM is untouched.
            string after = NdsRom.Sha256Hex(romPath);
            if (!string.Equals(sha, after, StringComparison.Ordinal))
            {
                stderr.WriteLine($"FATAL: the ROM's SHA-256 changed during analysis ({sha} -> {after}). Something other than this tool modified it.");
                return IntegrityFailure;
            }

            string text = json ? ReportWriter.ToJson(report) : ReportWriter.Section(report, command);
            stdout.WriteLine(text);
            stdout.WriteLine($"[integrity] ROM SHA-256 unchanged after analysis: {after}");

            if (reportDir is not null)
            {
                File.WriteAllText(Path.Combine(reportDir, "report.txt"), ReportWriter.Section(report, "all"));
                File.WriteAllText(Path.Combine(reportDir, "report.json"), ReportWriter.ToJson(report));
                if (extract)
                {
                    foreach (var img in images) { File.WriteAllBytes(Path.Combine(reportDir, img.Name), img.Data); }
                    stdout.WriteLine($"[extract] wrote {images.Count} decompressed code image(s). They are copyrighted: keep them local, never commit or upload them.");
                }
                stdout.WriteLine($"[out] {reportDir}");
            }
            return Ok;
        }
    }
}
