# PCE-001 — Test Strategy

Tags: **[C]** confirmed/reproduced · **[S]** third-party · **[H]** hypothesis · **[U]** unknown.

## 1. Existing test and build tooling [C]

| Item | Finding |
|---|---|
| Build tool | .NET SDK 10 (`TargetFramework net10.0` / `net10.0-windows`), solution `RanseiLink.slnx`; release script `build.cs` (`dotnet run build.cs`, needs .NET 10, `build.cs:1-14`) |
| Test projects | `RanseiLink.CoreTests` (108 `[Fact]/[Theory]` attributes), `RanseiLink.ConsoleTests` (Lua script tests), `RanseiLink.WindowsTests` (WPF, `net10.0-windows`) |
| Frameworks | xUnit 2.9.3, FluentAssertions 8.8.0, Moq 4.20.72, coverlet (`RanseiLink.CoreTests.csproj`) |
| CI | **None.** `.github/` has issue templates only. |
| Test data | `RanseiLink.CoreTests/TestData/` — 51 committed binary files (NCER/NCGR/NSBMD/… graphics) that appear to be **extracted from the commercial ROM** (upstream's choice; we must not add more, see §6) |
| ROM-derived runtime data | Many tests read an **unmodified, ROM-extracted mod folder** at `%LOCALAPPDATA%/RanseiLink/Test/TestMod` and `…/TestModJapan` (`CoreTests/TestConstants.cs:9-13`; class comment on `PokemonServiceTests`: "Model service tests require an unchanged mod at the location of the test mod folder"). Without a ROM those tests cannot pass. |
| Round-trip pattern | `IdenticalThroughLoadSaveCycle` — load a data file, `Save()`, assert bytes identical (e.g. `PokemonServiceTests.cs:68-93`). This is the single most valuable pattern for expansion and must be preserved for vanilla layouts. |

## 2. What I ran (this session, Linux x64, .NET SDK 10.0.404 installed under the scratchpad) [C]

No repository files were modified by any of these runs; test copies were made in the scratchpad.

| Command | Result |
|---|---|
| `dotnet build RanseiLink.Core` | **Succeeds** (0 errors, 12 warnings) |
| `dotnet build RanseiLink.GuiCore` / `RanseiLink.XP` | **Succeed** |
| `dotnet build RanseiLink.Windows -p:EnableWindowsTargeting=true` | **Succeeds** (cross-built on Linux; cannot be *run* here) |
| `dotnet build RanseiLink.Console` | **Fails**: `RenderExtensions/ModelRenderExtensions.cs(241,99): CS1061 'ScenarioBuilding' does not contain 'GetUnknown2'` → **`RanseiLink.ConsoleTests` cannot build either** |
| `dotnet build RanseiLink.CoreTests` | **Fails: 71 compile errors in 8 files** — `AbilityTests`, `BaseWarriorTests`, `BattleConfigTests`, `EpisodeTests`, `ItemTests`, `MoveTests`, `PokemonTests`, `WarriorSkillTests` — tests reference property names (`Effect1Chance`, `QuantityForEvolutionCondition1`, …) that were renamed by upstream commit `11e8f03` ("A lot of random changes and renaming … a lot of bugs introduced … I just wanna get this backed up", 2026‑01‑24). |
| CoreTests with those 8 files excluded (scratch copy; csproj ref pointed at the repo's `Core`) | **163 tests: 139 pass, 24 fail** |
| `RanseiLink.WindowsTests` | **Not run** (WPF test host needs Windows) |

Classification of the 24 failures:

* **22 — environmental**: `DirectoryNotFoundException … /root/.local/share/RanseiLink/Test/TestMod/…` (no ROM-extracted test mod): `EventTests` (6), `BaseWarriorServiceTests` (5), `PokemonServiceTests` (5), `ScenarioPokemonServiceTests` (2), `MapLoadTests` (1), `TextTests` (3).
* **2 — genuine, stale tests**: `ScenarioPokemonTests.AccessorsReturnCorrectValues` / `AccessorsSetCorrectValues` (`CoreTests/ModelTests/ScenarioPokemonTests.cs`). Expected `Exp == 1020` for word `0x03FC0014`; the model now returns 510 because `Models.xml:283-284` moved `Exp` to bits 17‑31 (was 16‑31). Either the tests or the new layout are wrong; **this is the same word that holds the species byte** and is directly relevant to ID‑width questions (F‑05). Flag to upstream/owner; do not "fix" silently.

Reproduce (scratch copy so the repo stays untouched):
```bash
export DOTNET_ROOT=<sdk dir>; export PATH=$DOTNET_ROOT:$PATH
cp -r RanseiLink.CoreTests /tmp/ct && cd /tmp/ct && rm obj bin -rf
rm ModelTests/{Ability,BaseWarrior,BattleConfig,Episode,Item,Move,Pokemon,WarriorSkill}Tests.cs
sed -i 's#\.\.\\RanseiLink.Core\\RanseiLink.Core.csproj#<abs path>/RanseiLink.Core/RanseiLink.Core.csproj#' RanseiLink.CoreTests.csproj
dotnet test
```

**Consequence:** at the audited commit, the project has **no trustworthy automatic regression net**. Establishing one is a prerequisite (Milestone M0 in IMPLEMENTATION_PLAN.md).

> **Update (PCE-002).** The baseline problems recorded above were repaired on branch `feature/pce-002-dev-environment`:
> Console and CoreTests now compile; CoreTests = 157 passed / 0 failed / 18 skipped (ROM fixtures skip instead of failing), ConsoleTests = 2 passed / 2 skipped;
> CI workflow added. Details, the rename table and the two judgement calls are in BASELINE_REPAIR.md. The L0 layer of §4 is therefore in place; L3 now has a first
> synthetic-NDS builder (`tools/RomRecon.Tests/Synthetic.cs`) and ROM_ANALYSIS.md covers the read-only part of L4.

## 3. Principles for the expansion test strategy

1. **Vanilla must stay byte-identical.** With the layout descriptor absent/`vanilla`, every service and patch builder must produce exactly today's bytes.
2. **No copyrighted data in tests.** Use synthetic generators; ROM-dependent tests read a user-supplied path from an environment variable and are *skipped* (not failed) when absent.
3. **Fail loudly on truncation.** The base accessors silently mask (`BaseDataWindow.SetInt`) or `(byte)`-cast; expansion code gets guarded setters and tests that assert exceptions for out-of-range IDs.
4. **Hypotheses are tested before being built on.** Each **[H]** in the audit maps to a named experiment/test below.
5. **Every claim of "works" has an emulator or byte-level oracle**, not just "it boots".

## 4. Test pyramid

| Layer | Scope | Needs ROM? | Runs in CI? | Examples |
|---|---|---|---|---|
| **L0 Build health** | All projects compile; Console/Core tests compile | No | Yes | Fix the 71 + 1 errors; add GitHub Actions: `dotnet build` Core/GuiCore/XP/Console/CoreTests on Linux |
| **L1 Pure unit** | Models, enums, layout descriptor | No | Yes | see §5 |
| **L2 Service/serialization** | Services over **synthetic** mod folders | No | Yes | `SyntheticModBuilder` writes `Pokemon.dat` (N records + evo table), `MaxLink`, `ScenarioPokemon`… with known content |
| **L3 Patcher** | `IRomFs`, ARM9/overlay injector, header/CRC, `InsertVariableLengthFile` | No | Yes | `SyntheticNds` builder: minimal valid NDS (header, FNT, FAT, arm9, overlays) generated in-test; assert FAT/offset/CRC correctness |
| **L4 ROM-in-the-loop** | Real extracted files from the user's ROM | **Yes (user-supplied)** | No | env var `RANSEILINK_TEST_ROM`; dumps → round-trip, differential patch checks |
| **L5 Emulator** | Boot/behaviour of patched ROM | **Yes** | No (local) | DeSmuME/melonDS Lua: boot → load scenario → start battle → hash screenshots/RAM |
| **L6 Manual QA** | Human playthrough | Yes | No | matrix in §7 |

## 5. Concrete test cases

### 5.1 L1/L2 (synthetic, CI-able)

| ID | Test | Targets |
|---|---|---|
| U‑01 | `PokemonService` with N ∈ {200, 201, 255} synthetic records round-trips byte-identically; evo table lands at `records*0x30 + gap` | F‑01, F‑02 |
| U‑02 | Vanilla layout (N=200) output equals the legacy offset `0x25C0` | regression guard for `PokemonService.cs:10` |
| U‑03 | Evo table entry for species 200 round-trips (and ID 256 throws) | F‑02 |
| U‑04 | `ScenarioPokemon.Pokemon` maps sentinel ↔ `PokemonId.Default`; species 200 under *expanded* layout is a real species, under *vanilla* layout is "none" | F‑05 |
| U‑05 | Setting a species ID > capacity throws (no silent masking) for `ScenarioPokemon`, `MaxLink`, `Kingdom.SwarmPokemon`, evo list | silent truncation hazard |
| U‑06 | `MaxLink` stride: `Get/SetMaxLink(warrior, species)` correct for strides 200 and N; file length == 252×N | F‑08 |
| U‑07 | `ScenarioAppearPokemon` accepts species 0..N‑1, rejects N | F‑07 |
| U‑08 | `NameOrderIndex` assigned 0..N‑1 uniquely for N up to 256 | F‑03 |
| U‑09 | Enum/UI enumeration (`EnumProvider`, `ScenarioAppearPokemonViewModel`, `MaxLinkViewModel`) yields exactly N non-default species | F‑12 |
| U‑10 | Randomizer never emits ID ≥ N and can emit N‑1 (fix `Next(200)`) | F‑11 |
| U‑11 | Descriptor parse/serialise; absent descriptor ⇒ vanilla; unknown version ⇒ refuse to patch | rollback safety |
| U‑12 | Property test: for every ID 0..N‑1, set→get is identity across every structure that stores species | all |

### 5.2 L3 patcher (synthetic NDS)
P‑01 `InsertVariableLengthFile` grows a file in the middle and every later FAT entry and the data are shifted correctly (existing code, currently untested). P‑02 ARM9 inject: payload placed, header sizes, CRC16 and secure-area CRC recomputed, original bytes outside the patch window untouched. P‑03 Overlay table (`y9.bin`) entry update. P‑04 Idempotency: patching twice == patching once. P‑05 Patch with an empty change-set produces a ROM byte-identical to input.

### 5.3 L4 ROM-in-the-loop (user's own ROM, local)
R‑01 After M0 is fixed, the existing round-trip/ROM-extraction tests pass on NA and JP. R‑02 **Differential patch**: vanilla-layout "no-op" patch ⇒ output ROM SHA‑1 equals input. R‑03 **Region diff**: list every byte differing between original and expanded ROM; each must be attributable to a documented change (allowlist). R‑04 Dump the 64‑byte gap `Pokemon.dat[0x2580..0x25C0]` and the evo-table header for NA and JP (resolves audit **[H] F‑04**). R‑05 Dump `Kuni.dat` swarm fields and `ScenarioPokemon.dat` placeholder entries across all 11 scenarios (confirms sentinel claim F‑05 beyond the single upstream assertion).

### 5.4 L5 emulator (local)
E‑01 Vanilla ROM boots → title → load a fixed save/savestate (baseline hashes). E‑02 Expanded-layout ROM with **200 species only** behaves identically to vanilla (screenshot/RAM hash set) — *the most important regression test*. E‑03 Species 200 appears as a swarm/appear-list Pokémon with correct name, stats, sprite, no crash through a full battle. E‑04 Species 200 survives: capture/recruit → gallery → save → reload. E‑05 Perfect-link check for a warrior × species 200 pair and **for 10 random existing pairs** (stride regression). E‑06 Evolve 199→200 and 200→other if configured. E‑07 Old vanilla save loads in the expanded ROM (or fails *gracefully and documentedly*). E‑08 Name-sorted list with 201 entries (menus). E‑09 Soak: 30 minutes of random scenario play script.

## 6. Test data policy [C obligations / recommendation]
* No ROMs, extracted assets, BIOS, or saves committed (task rule; also GPL/IP see FEASIBILITY.md §8).
* The existing `TestData` dir already contains ROM-derived graphics — **do not extend it**; new fixtures are generated programmatically.
* Add `.gitignore` entries for `*.nds`, `*.sav`, `*.dsv`, `arm9*.bin`, `overlay*`, `rom_dumps/` (separate housekeeping commit; **not done in this research PR**).
* ROM-dependent tests: `Skip` when `RANSEILINK_TEST_ROM` is unset, with a clear message.

## 7. Manual QA matrix (per milestone)

| Area | Check | Vanilla species | Species 200 |
|---|---|---|---|
| Save/load | create, save, reload, compare | ✔ | ✔ |
| Recruitment | appear list, scout/encounter | ✔ | ✔ |
| Warriors | link up, rank-up with `Pokemon` condition | ✔ | ✔ |
| Perfect Links | reach max-link, cap respected | ✔ | ✔ |
| Battles | stats, moves, ability, model, attack anim, faint | ✔ | ✔ |
| Menus | gallery/list, sorting, icons S/M/L/CI | ✔ | ✔ |
| Scenarios | start each of 11 scenarios; no soft-lock | ✔ | n/a |
| Evolution | all 7 Eevee branches intact | ✔ | ✔ |

## 8. Exit criteria for "test strategy ready"
M0 complete (Core/Console/CoreTests build; stale tests reconciled with owner; CI on Linux for L0–L3), plus an L4 baseline report for NA and JP, before any production expansion code is merged.
