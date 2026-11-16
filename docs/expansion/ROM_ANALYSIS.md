# PCE-002 — ROM Reconnaissance (RomRecon)

Evidence tags as in PCE-001: **[C]** confirmed (read in this repo, or reproduced by a test run in this session) · **[S]** third-party source · **[H]** hypothesis · **[U]** unknown.

> **Status in one paragraph.** `tools/RomRecon` is a read-only inspection tool for Nintendo DS ROMs. It was built and tested **only against synthetic ROMs and against compression vectors produced by an independent library (ndspy)**. **It has never been run on a real Pokémon Conquest ROM** — none is available to the author, and none may be uploaded. Every statement below about *what a real Conquest ROM contains* is therefore a prediction that the tool will confirm or refute on your machine. Its first real run is the first real data point for the PCE-001 hypotheses.

## 1. What it does (and does not do)

| It does | It does **not** |
|---|---|
| Parse the 0x200-byte header, verify header and logo CRC-16 | Modify, patch, repack or rewrite the ROM in any way |
| List the NDS file system (FNT + FAT): path, file id, offset, size | Extract game assets (only *reports*; code images are written only with `--extract-code`, to a local folder) |
| Locate ARM9 / ARM7, hash them, report load addresses | Implement expansion patches (explicitly out of scope for PCE-002) |
| Find the NitroSDK *module params* block; decide whether ARM9 is BLZ-compressed | Disassemble code |
| Parse the ARM9/ARM7 overlay tables; flag compressed overlays | Understand the *meaning* of any code it finds |
| Decompress ARM9 / overlays in memory (BLZ) and scan them | Prove that a constant is a Pokémon limit (see §6) |
| Check the Pokémon-related data tables against the PCE-001 audit assumptions | Read save files |

### Read-only guarantees [C — each covered by a test in `tools/RomRecon.Tests`]
* The ROM is opened `FileAccess.Read` / `FileShare.Read`; there is no write API anywhere in the tool (`Nds/NdsRom.cs`).
* The ROM is SHA-256-hashed **before and after** every run; the tool exits with code 3 if they differ (`Cli.Run`).
* A read-only file works; modification time is unchanged (`Analysis_never_modifies_a_read_only_rom`).
* `--out` is refused inside any git working tree (`OutputGuard`) and always creates a **new** `recon_<hash8>_<timestamp>` folder — it never overwrites.
* Reads are bounds-checked against the real file length; malformed tables produce warnings, not crashes. The BLZ decoder is fuzzed with random garbage (`Random_garbage_never_throws_other_exceptions_or_hangs`).

## 2. Running it

Easiest (after `Setup-ConquestDev.ps1`, see WINDOWS_SETUP.md):

```powershell
.\tools\windows\Setup-ConquestDev.ps1 -Action Recon
```

Directly:

```powershell
dotnet run --project tools/RomRecon -c Release -- all "C:\...\PokemonConquestDev\original\Pokemon Conquest.nds" --out "C:\...\PokemonConquestDev\diagnostics"
```

| Command | Shows |
|---|---|
| `header` | game code/region, ARM9/ARM7 offsets, FNT/FAT, overlay table locations, CRCs, SHA-256 |
| `files` | every file in the NDS file system |
| `overlays` | overlay tables, which are compressed, whether they decoded |
| `code` | module params, compression evidence, per-region hashes |
| `tables` | Pokémon capacity checks (§4) |
| `scan` | capacity-constant candidates in ARM9/overlays (§5) |
| `all` *(default)* | everything except the file list |

Options: `--out <dir>` (writes `report.txt` + `report.json`), `--json`, `--values 200,0x25C0,…` (custom constants), `--thumb` (noisy Thumb scan), `--arm7`, `--max-hits N`, `--extract-code` (write decompressed code **locally**), `--dump-gap` (write `Pokemon.dat[0x2580..0x25C0]`, audit F‑04), `--allow-in-repo` (not recommended). Exit codes: 0 ok, 1 usage, 2 unreadable/invalid ROM, 3 ROM changed, 4 output location refused.

**What is safe to share for review.** `report.txt`/`report.json` contain only sizes, offsets, counts, aggregate statistics, hashes and RAM addresses — no game content. Skim it before sharing anyway. **Never share** the ROM, `--extract-code` output (copyrighted code) or `gap.bin` (game data). Paste report text into the review chat; do not upload any ROM or binary dumps.

## 3. Executable compression — what we know

### 3.1 Findings [C: read directly from the ndspy 4.2.0 source in this session; decoder verified against vectors from that library]
* **Module params.** The NitroSDK static-module parameter block is located by the 8-byte magic `21 06 C0 DE DE C0 06 21` within the first 0x8000 bytes of ARM9. The block starts 0x1C bytes before the magic: autoload list start/end, autoload data start, static-BSS start/end, **compressed-static-end (at magic−8)**, SDK version (magic−4). A non-zero compressed-static-end means the ARM9 static module is compressed (`Code/ModuleParams.cs`, ndspy `code.py::_searchForCodeSettingsOffs`).
* **Post-ARM9 data.** 12-byte blocks beginning `21 06 C0 DE` may follow ARM9 in the ROM (ndspy `rom.py`); RomRecon reports their size.
* **BLZ ("code compression").** Backward LZ: the stream is decoded from the *end* of the buffer towards the start. The last 8 bytes are `u32 (headerLength<<24 | compressedLength)` and `u32 extraSize`; footer padding is `0xFF`; bytes before the compressed region pass through unchanged (for ARM9, `ndspy.compress(isArm9=True)` leaves the first 0x4000 bytes untouched). Each flag byte covers 8 items MSB-first; a set bit is a 2-byte back-reference (`length = (b1>>4)+3`, `disp = ((b1&0xF)<<8 | b2)+3`) (`Code/Blz.cs`).
* **Overlays.** 32-byte entries: id, RAM address, RAM size, BSS size, static-init start/end, FAT file id, and a packed word whose low 24 bits are the compressed size and whose **high byte holds flags (bit 0 = compressed)** (`Nds/NdsRom.cs`, ndspy `code.py::loadOverlayTable`).
* **Conformance test.** `BlzTests` decodes ndspy-compressed vectors for overlay-style data, ARM9-style data (0x4000 passthrough prefix) and data with appended post-ARM9 bytes, bit-exactly (3/3), and survives 3000 garbage inputs without any non-`InvalidDataException`. No Nintendo data is involved.

### 3.2 Unknown until a real ROM is analysed
* **[U]** Whether Pokémon Conquest's ARM9 and each overlay are compressed. RomRecon decides this per region and prints its evidence; if the module-params magic is missing it says so rather than guessing.
* **[U]** Whether any Conquest overlay deviates from the standard footer (the decoder fails closed and the report says "BLZ decompression failed … scan is NOT meaningful").
* **[U]** ARM7: compression is not analysed (rarely relevant here).

### 3.3 Do we need additional tools?
| Need | Tool required? |
|---|---|
| Header, file system, overlay tables, table checks, constant scan (compressed or not) | **No** — RomRecon is self-contained (.NET 10 only). |
| Cross-checking RomRecon's decompression | Optional: `ndstool`/`ndspy` (`python -m pip install ndspy`; `ndspy.codeCompression.decompress` is the reference). Compare SHA-256 of `arm9_decompressed.bin` against ndspy's output. |
| Reading/understanding code (finding which `cmp r0,#200` is a Pokémon check) | **Yes** — a disassembler/decompiler (Ghidra with an NDS/ARM9 loader, or similar) and an emulator debugger; see EMULATOR_TESTING.md. |
| **Writing** an expanded ROM later (recompressing ARM9, fixing header CRC/size) | **Yes, a new write path** — RanseiLink has none (ARCHITECTURE.md §2). Out of scope here. |

## 4. Table checks — what `tables` verifies (against the PCE-001 audit)

| Audit finding | What RomRecon checks on the ROM |
|---|---|
| F‑01 species table | `data/Pokemon.dat` size; 200 × 0x30 = 0x2580; evolution table at 0x25C0 |
| F‑02 evolution table | length field vs file size (padded to 4); largest species id stored (entries are bytes) |
| F‑03 name-order index | 200 unique `NameOrderIndex` values, max (8-bit field) |
| F‑04 the 64-byte gap | bytes 0x2580..0x25C0: non-zero count, distinct values, short hash; `--dump-gap` to save |
| F‑05 sentinel | per scenario: count of `ScenarioPokemon` entries whose species byte is 200, largest other id, any ids > 199 |
| F‑06/F‑07 | `ScenarioPokemon.dat` entries ×8 B; `ScenarioAppearPokemon.dat` size (expect 0xC8) and flag values |
| F‑08 MaxLink | `BaseBushouMaxSyncTable.dat` size ÷ 252 warriors = per-warrior stride (expect 200) |
| F‑09 swarm | `Kuni.dat` record count/stride (NA 0x18, JP 0x14), range of the 8-bit `SwarmPokemon` field |
| F‑10 graphics | LINK entry counts of the four `POKEMON_*.ALL` archives (expect 200) and seven STL archives |

Each line is tagged `Ok`, `Info`, `Unexpected` or `Missing`. **`Unexpected` is not an error — it is a discovery**: it means an assumption in PCE-001 (or in RanseiLink's constants) is wrong for your ROM/region. Field positions come from `RanseiLink.Generation/Models.xml`; the Kingdom swarm position for JP uses `Index_VPYJ`.

## 5. Capacity-constant scan — how to read it

The scanner (`Analysis/ConstantScanner.cs`) reports **candidates**, not conclusions:

| Kind | Meaning | Noise level |
|---|---|---|
| `ArmImmediate` | An ARM data-processing instruction with an immediate equal to a watched value, decoded incl. rotated immediates (e.g. `CMP r0,#200`, `CMP r2,#9600` = 0x96 ror 26) | Medium — 200 is a common constant |
| `LiteralWord` | An aligned 32-bit word equal to a *large* watched value (≥ 0x100): 0x2580, 0x25C0, 0xC4E0 (=50 400), 1400, 1100, 0x30B | **Low** — large values are rare, so these are the best leads |
| `ThumbImmediate` (`--thumb`) | `MOV/CMP/ADD/SUB Rd,#imm8` | **High** — ARM code and data also decode as Thumb; treat as hints only |
| `AsciiString` | Occurrences of file/archive names (`Pokemon.dat`, `BaseBushou…`, `POKEMON_TEX`, …) | Low — shows where the game refers to these files |

Defaults: 200, 199, 201, 252, 251 (counts/ids), 0x2580, 0x25C0, 0xC4E0, 1400, 1100, 0x30B. RAM addresses are `load address + offset` (ARM9: header 0x28; overlays: overlay-table RAM address). The ARM9/ARM7 header order (entry at 0x24, RAM address at 0x28) follows GBATEK **[S]**; note RanseiLink's own `NdsHeader` reads those two fields in the opposite order (`RanseiLink.Core/RomFs/NdsHeader.cs:33-35`, **[C]** the code; unverified which is correct on a ROM, and nothing else in RanseiLink uses them).

**What a hit does *not* prove.** A `CMP r0,#200` may compare a Pokémon id — or a pixel count, a menu index, a timer. The scanner narrows the search from ~megabytes to dozens of addresses; **confirming** each needs a disassembler plus an emulator watchpoint on the Pokémon table (PCE-001 Experiment 0). Conversely, a *missing* hit proves little: counts can be loaded from a literal pool as `200` assembled differently, computed (`0x2580/0x30`), or stored in data.

## 6. How this feeds PCE-001's hypotheses

| Hypothesis (IMPLEMENTATION_PLAN §2) | First evidence RomRecon provides | Still needs |
|---|---|---|
| H‑A count is a compiled-in constant | `CMP/MOV #200/#199/#201` clusters in the same overlay as the `Pokemon.dat` string | Debugger: who reads the table |
| H‑B evolution table read at a constant offset | literal-pool words equal to 0x25C0 / 0x2580 | confirm the reader |
| H‑C MaxLink stride 200 | `tables` shows the 252×200 geometry; literal 0xC4E0 | confirm indexing code |
| H‑D sentinel 200 in comparisons | ARM `CMP … #200` hits; per-scenario sentinel counts | confirm context |
| H‑E archive counts | LINK entry counts of the model archives | loader inspection |
| F‑04 gap | non-zero/distinct statistics, optional dump | correlate with `Section2Index` |

## 7. Verification status of the tool itself

| Check | Result |
|---|---|
| `RomRecon.Tests` (xunit, synthetic data) | **40 passed, 0 failed** (this session, Linux, .NET 10.0.404) |
| BLZ vs ndspy 4.2.0 vectors | 3 of 3 exact |
| Windows run | `RomRecon.Tests` **passed on `windows-latest`** in the first CI run **[C]** (the author has no Windows machine; see BASELINE_REPAIR.md §5) |
| **Run on a real ROM** | **No — pending the owner** |
| Region coverage | NA (`VPYT`), JP (`VPYJ`, shorter Kingdom record), EU (`VPYP`, same data layout as NA per `ConquestGameCodeExtensions`) — only the NA/JP layouts are encoded; EU is assumed identical to NA **[H]** |

## 8. Reproducing the compression vectors
`tools/RomRecon.Tests/BlzVectors.cs` holds base64 vectors produced by ndspy 4.2.0 from deterministic synthetic data. To regenerate and compare:

```python
# python -m venv v && v/bin/pip install ndspy==4.2.0 && v/bin/python gen.py
import base64, ndspy.codeCompression as cc
def make(n, seed):                      # identical to Synthetic.Pattern in tools/RomRecon.Tests/Synthetic.cs
    x = seed; out = bytearray()
    while len(out) < n:
        x = (x * 1103515245 + 12345) & 0x7fffffff
        if len(out) >= 64 and (x >> 8) % 3 != 0:
            out += out[-64:]
        else:
            for _ in range(64):
                x = (x * 1103515245 + 12345) & 0x7fffffff
                out.append((x >> 16) & 0xFF)
    return bytes(out[:n])
print(base64.b64encode(cc.compress(make(4000, 1))).decode())            # OverlayStyle_Seed1_Len4000
print(base64.b64encode(cc.compress(make(3000, 7))).decode())            # Arm9Tail_Seed7_Len3000 (prefix make(0x4000,3) is passthrough)
print(base64.b64encode(cc.compress(make(64, 99))).decode())             # Stored_Seed99_Len64 (incompressible => "stored" marker)
```
