# PCE-001 — Feasibility Assessment

Tags: **[C]** confirmed in repo/reproduced · **[S]** third-party source · **[H]** hypothesis · **[U]** unknown. Findings `F‑nn` refer to POKEMON_LIMIT_AUDIT.md. "#201" = `PokemonId` 200.

## 1. Bottom line

1. **Data-only expansion (what RanseiLink can do today) is, on current evidence, not possible** — [C] for the tool's reach, [S]+[H] for the game's behaviour (no ROM was available to test it; Experiment 1 will). RanseiLink only rewrites files in the NDS file system. Every species-indexed structure has a 200-entry size; the game's count is, per the upstream author, hard-coded in code RanseiLink never touches (issue #3 [S]). Appending data without changing code will at best be ignored by the game and at worst misalign adjacent tables.
2. **Expansion without replacing existing species is plausible only by patching the game executable** (ARM9 and/or overlays) **plus** changing several data files whose size/stride depends on the count. [H] This is a reverse-engineering project, not an editor feature. No public decompilation or disassembly of Pokémon Conquest was found. [S]
3. **A realistic ceiling without widening any ID is 255 total species (IDs 0‑254)** [C/H]: IDs are 8-bit in scenario data, the evolution table and (per third-party research) the save file; the name-order index is 8-bit; `0xFF` is a likely sentinel [H]. That is **+55 species at most**. Going beyond 255 requires widening ID fields in code, ROM data **and the save format** — a far larger, riskier project.
4. **#201 specifically collides with an existing sentinel**: `ScenarioPokemon` stores `200` for "no Pokémon" (F‑05). A first experiment must either avoid scenario slots or relocate the sentinel.
5. **Feasibility rating (judgement, not a measurement):** a *proof of concept* for ID 200 that boots and shows the species in a wild/swarm battle: **moderate**, dominated by finding code sites. A *complete* expansion (recruitment, Perfect Links, saves, menus, scenarios, all graphics): **high effort, uncertain**, because correctness cannot be established from the repo alone.

## 2. What "add a species without replacing one" actually requires

| # | Requirement | Touches | RanseiLink today |
|---|---|---|---|
| R1 | A 201st `Pokemon.dat` record and relocation of the evolution table (and the unknown 64‑byte gap) | data **and probably code** (F‑01, F‑02, F‑04) | `Pokemon.dat` is variable-length ✔, but offset `0x25C0` and `199` are constants ✘ |
| R2 | Game code reads 201 records (and any parallel RAM arrays are sized for it) | **ARM9/overlay** | no capability ✘ |
| R3 | `MaxLink` stride 200 → N and file regrown | data + **code** | fixed-length insert ✘; stride constant ✘ |
| R4 | `ScenarioAppearPokemon` 200 → N bytes per scenario | data + **code** | fixed-length insert ✘ |
| R5 | A unique ID: either move the 200 "none" sentinel or start at 201 | data + code | sentinel hard-coded in `ScenarioPokemon.cs` ✘ |
| R6 | Graphics: entry 200 in ≥ 4 model archives and 7 STL sets | data (+ code if counts compiled in) | repack by index only, `__numPokemon = 200` ✘ |
| R7 | Save compatibility: species/gallery/ownership blocks sized or indexed by species | **code + save format** | RanseiLink has no save code; layout partially known [S] |
| R8 | Tool: enum, services, UI, plugins, tests parameterised | C# | tractable ✔ |

Only R8 can be done with the repository as it is. R2–R7 each need evidence from the ROM's code.

## 3. Capacity ceiling analysis

| Constraint | Source | Max species it allows |
|---|---|---|
| `ScenarioPokemon` species byte | F‑05 [C] | 256 values, minus sentinel(s) |
| `ScenarioPokemon` "none" = 200 | F‑05 [C] | forces ID 200 unusable unless relocated |
| Evolution table entries `(byte)` | F‑02 [C] | 256 |
| `NameOrderIndex` 8 bits | F‑03 [C] | 256 |
| `Kingdom.SwarmPokemon` 8 bits | F‑09 [C] | 256 |
| Save species byte | F‑13 [S] | 256 |
| `NationalPokedexNumber` 10 bits | `Models.xml:279` [C] | 1024 (not binding) |
| Probable `0xFF` "invalid" sentinel | [H] | 255 |

**Conclusion:** IDs 0‑254 (255 species), or 0‑255 if no code treats `0xFF` specially. +55/+56 over vanilla. Widening ID fields is out of scope for the first milestone.

## 4. Approaches considered

| Approach | Adds species without replacing? | Needs code patch? | Effort | Risk | Verdict |
|---|---|---|---|---|---|
| **A. Replacement (status quo)** — repurpose slots, including the `Pokémon Conquest Ultimate`-style approach of dropping non-final evolutions [S weak] | No | No | Low | Low | Works today; not what is asked |
| **B. 8-bit count expansion** — raise compiled-in counts/strides to N ≤ 255, relocate tables, add graphics entries | **Yes** | **Yes** (ARM9 and/or overlays) | High | Medium-High | **Recommended target** |
| **C. Widen IDs to 9/16 bits** | Yes (up to 511+) | Yes, extensive; changes save layout | Very high | Very high | Defer; revisit only if B proves out and demand exists |
| **D. Relocating loader hook** — patch the Pokémon-table loader to read a count/pointer from a new header, tables live in free ROM/RAM | Yes | Yes (smaller surface, needs free space) | High | Medium | Variant of B; evaluate after code recon |
| **E. Data-only append** (extend files, leave code) | No effect | No | Low | Medium (misaligned tables) | **Rejected** — valid only as a *probe* (Experiment 1) |

## 5. Which ID should the first species use?

Two defensible choices; **recommendation: PoC targets ID 200 (#201) but does not reference it from `ScenarioPokemon`**.

* **ID 200** — what was asked. Avoids the scenario sentinel if the species is introduced through a channel that does not use `ScenarioPokemon`: e.g. `Kingdom.SwarmPokemon` (`Kuni.dat`, 8‑bit, fixed-length, F‑09) or `ScenarioAppearPokemon`. Sentinel relocation is deferred to a later milestone.
* **ID 201 (#202)** — sidesteps the sentinel entirely but obscures the 'first ID past the table' question. Use it as a *control* in Experiment 2 if ID 200 behaves oddly.

## 6. Impact by game system (what could break) — all **[H]** unless noted

| System | Expansion touches | Evidence / unknowns |
|---|---|---|
| **Save files** | Species fields in party/gallery/scenario blocks; any block sized by species count; checksums | Species is `u8` in save structs [S]; sizes/offsets-by-count **[U]**. Old saves must either load unchanged (if layout independent of count) or be declared incompatible. Needs emulator save-compat tests. |
| **Recruitment / scouting** | `ScenarioAppearPokemon` (F‑07), `BaseBushouScout.dat` (unmodelled, `Constants.cs:39`), per-kingdom encounter bits in `Pokemon.dat` (`Pokemon.cs:19-34`, 3 bits × kingdom in a 64-bit field [C]) | Encounter eligibility is already per-species data [C]; code that iterates over species to build candidate lists likely loops to 200 [H]. |
| **Warriors** | `BaseWarrior` rank-up conditions of type `Pokemon` (9-bit quantity, `Models.xml:24,37-39`); `ScenarioWarrior` → `ScenarioPokemon` indirection (16-bit, unaffected) | Rank-up checks comparing species IDs ≥200 **[U]**. |
| **Perfect Links** | `MaxLink` 252 × 200 matrix (F‑08); link% maths is species-independent (`LinkCalculator.cs`) | Stride/indexing in code **[U]**; a mis-sized row would give wrong caps for *every* species → high regression risk, so it needs the strongest tests. |
| **Battles** | Species stat load, ability/move lookup, battle model/animation lookup (archives F‑10), RAM per-battle arrays | Archive count and model lookup in code **[U]**. |
| **Menus** | Gallery/Pokédex-style lists, name-sorted lists via `NameOrderIndex` (8-bit, F‑03), 32×32/medium/large STL icons | Menu list capacity/paging constants **[U]**; likely candidates for fixed-size arrays. |
| **Scenarios** | `ScenarioPokemon` sentinel (F‑05), `ScenarioAppearPokemon` (F‑07), swarm (F‑09) | Event scripts (`.eve`, `EventTests` in repo) *may* spawn Pokémon by ID **[U]** — not audited. |
| **Evolution** | 8-bit evo table at fixed offset (F‑02), 11-bit indices | In-game reader offset **[U]** (probably same constant). |
| **Text** | Species names live in `Pokemon.dat` (10 chars) [C] — no MSG change needed | MSG-based descriptions per species: none found in `Enums`/models **[U]**. |

## 7. Tooling and information gaps that block progress

1. **A legally owned ROM for each region (NA `VPYT`, JP `VPYJ`; EU `VPYP` shares NA data)** in the *user's* environment. Not available here and **must never be committed.**
2. **ARM9/overlay access**: extractor/injector, decompression (ARM9 is often BLZ-compressed [S, general DS knowledge]), header/CRC16 fix-ups. Candidate tools: `ndstool`, `ndspy`, `pret/ds_disassembly_tools` [S], Ghidra with an NDS loader, `dsd`/`DSPRE`-style tooling — none evaluated in this session.
3. **An emulator with debugger**: DeSmuME (already used upstream via Lua scripts [S]) or melonDS; need read/write watchpoints and savestates.
4. **Region-specific RAM maps**: only three pointer-table addresses exist publicly and the region/build is not stated [S, `usefulPointers.txt`].
5. **No decompilation**: no public source of truth exists; every code finding must be generated by us.
6. **Blocked sources**: PokéCommunity documentation thread, TCRF, and pleonex's blog could not be fetched here (403 / DNS). A human with a browser should read them (see IMPLEMENTATION_PLAN.md §Open actions).
7. **GitHub API for upstream issues** is unavailable in this session; issue #3 content is second-hand [S].
8. **Test harness for CI**: none (`.github/workflows` absent); CoreTests do not compile (TEST_STRATEGY.md).

## 8. Licence and distribution obligations (not legal advice)

* **Project licence — GPL-3.0** `LICENSE` (674 lines, GNU GPL v3, 29 June 2007) [C]; README shows a GPL badge pointing at upstream. No SPDX headers exist [C]; two files carry explicit "GPLv3 **or later**" headers by Benito Palacios Sanchez (pleonex): `RanseiLink.Core/Text/PnaTextReader.cs`, `PnaTextWriter.cs` [C] — **those notices must be preserved**. Whether the project as a whole is "v3 only" or "v3 or later" is therefore **[U]** (LICENSE text only).
* **Obligations when modifying and distributing** (GPLv3 §§4–6, 10) [C on text]: keep copyright and licence notices; mark modified files with a prominent notice and date (§5a); license the whole modified work under GPLv3 (§5c); when distributing binaries (e.g. a `RanseiLink.exe` build including expansion code) **provide Corresponding Source** (§6) including build scripts (`build.cs`); add no further restrictions (§10), e.g. do not impose NDA/EULA terms on recipients. Private/internal use triggers none of these; **publishing builds or a fork's releases does.**
* **Fork hygiene:** keep the upstream remote and history; credit upstream in README/changelog; new files authored here may be added under GPLv3-compatible terms.
* **Dependencies** (`DEPENDENCIES.md`): MIT, BSD‑3, Apache‑2.0 — all GPLv3-compatible *as listed* [C]. **To verify:** SixLabors.ImageSharp 3.x is listed as "Apache 2.0", but its 3.x releases use the "Six Labors Split License" (Apache‑2.0 for qualifying open-source use, commercial terms otherwise) — I did not read the licence text in this session **[U]**. Any new ARM disassembly tooling must be checked for GPL compatibility before being bundled (e.g. GPL tools can be *invoked*, but not linked into non-GPL code).
* **Non-code obligations (Nintendo/The Pokémon Company IP).** The repository must contain no ROMs, extracted game files, BIOS/firmware or user saves — `.gitignore` currently has **no** `*.nds`, `*.sav`, `*.dsv`, `arm9*.bin`, `overlay*` rules [C]; recommend adding them in a separate housekeeping change (not done here, to avoid touching existing files). Expansion deliverables should be distributed as **patches/tools that operate on the user's own ROM**, never as pre-patched ROMs. Pre-patched or byte-for-byte test fixtures derived from the ROM are copyrighted material: tests must synthesise data or read user-supplied paths.
* **Upstream etiquette:** upstream is not modified by this work; contributions upstream would be a separate decision (issue #3 shows the author deprioritised this feature [S]).

## 9. Recommendation

1. Treat **Approach B** as the target and run a **reconnaissance experiment first** (IMPLEMENTATION_PLAN.md, Experiment 0/1) to turn the main hypotheses (count/stride constants in code, loader behaviour) into facts *before* writing any production code.
2. Keep all new capability behind an explicit **layout descriptor** so vanilla mods stay byte-identical (rollback + regression safety).
3. Do **not** start on widening IDs (Approach C) or save-format work until the 8-bit PoC succeeds.
4. Fix the repository's own test build (TEST_STRATEGY.md) before relying on it as a regression net.
