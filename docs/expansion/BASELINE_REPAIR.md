# PCE-002 — Development Baseline Repair

Evidence tags: **[C]** confirmed by a build/test run in this session · **[H]** hypothesis · **[U]** unknown.
Starting point: audited upstream commit `308d988` (see TEST_STRATEGY.md §2 for the original failures).

## 1. Diagnosis

Upstream commit `11e8f03` (2026-01-24, *"A lot of random changes and renaming based on new findings, a lot of bugs introduced and binding errors need fixing, I just wanna get this backed up"*) regenerated the models from `RanseiLink.Generation/Models.xml` with new names and some new bit layouts, and `64d6bdf` renamed `ScenarioBuilding`'s accessor. The *production* projects were updated; two *consumers* were not. **[C]**

| Failure | Cause | Class |
|---|---|---|
| `RanseiLink.Console` — `ScenarioBuilding does not contain GetUnknown2` (`RenderExtensions/ModelRenderExtensions.cs:241`) | accessor renamed to `GetIsUnlocked` (same byte: `GetByte(offset+1) != 0`, `Models/ScenarioBuilding.cs:25-28`) | stale caller |
| `RanseiLink.CoreTests` — 71 compile errors in 8 files | property renames (table below) | stale tests |
| `ScenarioPokemonTests` ×2 fail at runtime | `Models.xml` moved `Exp` to bits 17‑31 (was 16‑31) | stale expectation |
| 18 tests fail with `DirectoryNotFoundException` | need an unmodified ROM-extracted mod at `%LOCALAPPDATA%\RanseiLink\Test\TestMod` (and `TestModJapan`, `*_MSG.DAT`) | environmental, **copyrighted fixtures** |

### Renames at identical bit positions (verified against `git diff 75194b2b HEAD -- Models.xml`)
| Old (tests) | New (model) | Bits |
|---|---|---|
| `Ability.Effect{1,2}Amount` | `Effect{1,2}_Quantity` | same start; width 2 → 8 bits |
| `WarriorSkill.Effect{1,2,3}Amount` | `Effect{1,2,3}_Quantity` | same |
| `Move.Effect{1,2}Chance` | `Effect{1,2}_Quantity` | same |
| `Move.Effect3`/`Effect3Chance` | `Rank5Effect1`/`Rank5Effect1_Quantity` | same (6,14,7)/(6,21,7) |
| `Move.Effect4`/`Effect4Chance` | `Rank5Effect2`/`Rank5Effect2_Quantity` | same (7,0,7)/(7,7,7) |
| `Item.QuantityForEffect` | `Effect_Quantity` | same (7,18,9) |
| `Pokemon.QuantityForEvolutionCondition{1,2}` | `EvolutionCondition{1,2}_Quantity1` | same (7,0,9)/(7,18,9) |
| `Episode.Order` | `ScenarioWarrior` | same (0,0,9) |
| `BattleConfig.{Upper,Middle,Lower}AtmosphereColor` | `…SkyColor` | same |
| `BaseWarrior.RankUp` | `RankUpWarrior` | same (2,15,9) |
| `BaseWarrior.Quantity{1,2}ForRankUpCondition` | `RankUpCondition2_Quantity{1,2}` | same (4,9,9)/(4,18,9) |
| `BaseWarrior.RankUpPokemon{1,2}` (typed `PokemonId`) | `RankUpCondition1_Quantity{1,2}` (int) | same (1,20,9)/(4,0,9) |

The last row is useful for the expansion work: the test's real ROM bytes show that when `RankUpCondition1 == Pokemon`, those 9-bit quantity fields **hold Pokémon ids** (`((PokemonId)a.RankUpCondition1_Quantity1) == Golbat`) — a **[C]** confirmation (from upstream's own test data) of PCE-001's hypothesis that warrior rank-up conditions reference species (9 bits, so no width problem up to 511).

### Layout changes that needed judgement
* **`BattleConfig` victory/defeat conditions.** The old test asserted `DefeatAllEnemies` (value 0). That enum member no longer exists and the fields moved from bits (0,5)/(5,5) to (3,5)/(8,5) with the flag values re-based (`ClaimAllBanners` 0b10000 → 0b10 at a +3 shift — the *same physical bit*). The test's real bytes decode to 0 under either layout, so the assertion became `(BattleVictoryConditionFlags)0` with a comment. The set/round-trip assertions are unchanged and pass.
* **`ScenarioPokemon.Exp`.** Under the new layout the test word `0x03FC0014` decodes to `Exp = 510` (it was 1020 at bits 16‑31). The test now asserts 510 and the *identical* bytes `14 00 FC 03 …` on write, and says why. **[U] — which layout is correct is not settled**: the new `U1` is 9 bits (8–16) and `Exp` 15 bits (17–31). If upstream's 9-bit `U1` is wrong, odd exp values would be misread. This is flagged for the owner/upstream; it is also the word that holds the species byte (PCE-001 F‑05), so it matters for expansion.

## 2. What was changed — and what was not

* **Changed:** one display string in the Console renderer (`Unknown2:` → `IsUnlocked:`, same data); the expectations/names in 9 test files; new test-only attribute files.
* **Not changed [C]:** no file under `RanseiLink.Core/`, `RanseiLink.GuiCore/`, `RanseiLink.Windows/`, `RanseiLink.XP/`, `Plugins/` or `RanseiLink.Generation/`; no production behaviour. (`git diff cc9d466^..cc9d466 --stat` lists only Console, CoreTests, ConsoleTests.)

## 3. ROM-fixture tests (copyrighted data stays local)

`[RomFixtureFact]` / `[RomFixtureTheory]` (new, in `RanseiLink.CoreTests/RomFixtureAttributes.cs` and `RanseiLink.ConsoleTests/RomFixtureAttributes.cs`) mark tests that need ROM-extracted fixtures. They are **skipped, with the missing path in the message** (a skipped theory counts once, so 18 skips = 5+5+2+3+1+1+1 across the fixtures below), when the fixture is absent, and run normally when present.

| Fixture (under `%LOCALAPPDATA%\RanseiLink\Test\`) | Tests that use it |
|---|---|
| `TestMod\` (an *unmodified* mod folder created from your NA ROM: `data\`, `msg\`, `event\`, `data\map`…) | `PokemonServiceTests` (4), `BaseWarriorServiceTests` (4), `ScenarioPokemonServiceTests` (2), `EventTests` (3 theories), `MapLoadTests`, `TextTests.IdenticalThroughLoadSaveCycle`, `ScriptTests` ×2 |
| `TestModJapan\` (same, from your JP ROM) | the two `*_Japan` round-trip tests |
| `VPYT_MSG.DAT`, `VPYJ_MSG.DAT` (the ROM's `data/MSG.DAT`) | `TextTests.MsgDatIdenticalThroughUnpackPack` (1 theory) |

**How to create them locally [U — exact layout not re-verified without a ROM]:** in RanseiLink choose *Create Mod* from your unmodified ROM and copy that mod's folder to `…\Test\TestMod`; repeat with the Japanese ROM for `TestModJapan`. These folders live outside the repository and are covered by the new `.gitignore` rules if ever copied into it. **Never commit or upload them.**

(The 51 committed files in `RanseiLink.CoreTests/TestData/` are graphics that appear to be ROM-derived and predate this work; they were not touched or extended.)

## 4. Results

| Suite | Before | After |
|---|---|---|
| `RanseiLink.Core`, `GuiCore`, `XP`, `Windows` (cross-build) | build | build |
| `RanseiLink.Console` | **does not compile** | builds |
| `RanseiLink.CoreTests` | **does not compile** (71 errors) | **157 passed, 0 failed, 18 skipped (ROM fixtures)** |
| `RanseiLink.ConsoleTests` | does not build | **2 passed, 0 failed, 2 skipped** |
| `tools/RomRecon.Tests` (new) | — | **40 passed** |
| `tools/windows/tests` Pester (new) | — | **51 passed** (PowerShell 7.6, Linux) |
| `RanseiLink.WindowsTests` (WPF) | not run | not run here; CI job added, non-blocking until proven **[U]** |

## 5. Automated checks (`.github/workflows/ci.yml`)

| Job | Runs |
|---|---|
| `dotnet` (ubuntu) | build Core/GuiCore/Console/RomRecon; CoreTests, ConsoleTests, RomRecon.Tests |
| `windows` | build the WPF app; RomRecon.Tests on Windows; PSScriptAnalyzer on the setup script; Pester under **Windows PowerShell 5.1** and under PowerShell 7 |
| `windows-wpf-tests` (non-blocking) | `RanseiLink.WindowsTests` |

**[U] The workflow has never run when this was written.** The repository had no workflows and the fork's Actions may need enabling; results appear on the PR once it runs. Nothing in CI needs a ROM; ROM-fixture tests simply show as skipped.

## 6. Remaining known issues
* `ScenarioPokemon` bit layout disagreement (above).
* The WPF test project has not been run by anyone in this effort.
* Upstream is mid-refactor ("binding errors need fixing"): GUI runtime behaviour was not exercised.
* `RanseiLink.Core/RomFs/NdsHeader.cs:33-35` appears to read the ARM9 entry and RAM addresses in swapped order relative to GBATEK **[S]** — unused elsewhere, left untouched (production code).
