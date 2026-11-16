# PCE-001 — RanseiLink Architecture (as it relates to Pokémon data)

> Research document. Nothing here changes game-editing behaviour.
> Audited commit: `308d988` (fork `master` == `upstream/master` at audit time, 2026‑11‑16).

## Evidence legend

Every claim in these documents carries one of these tags.

| Tag | Meaning |
|---|---|
| **[C]** Confirmed | Read directly in this repository at the audited commit, or reproduced by running code here. File/line cited. |
| **[S]** Secondary | Reported by a third-party web page (cited). Not independently reproducible in this session. Treat as a lead. |
| **[H]** Hypothesis | Inference that is plausible but not yet demonstrated. Says what would confirm it. |
| **[U]** Unknown | Cannot be answered from the repo or public sources audited so far. |

Terminology: "Pokémon #201" means **zero-based `PokemonId` 200**, the first ID past the current table (`PokemonId.Rayquaza` = 199 is the last). This matters because 200 is also a sentinel value in one structure (see POKEMON_LIMIT_AUDIT.md, F‑05).

## 1. Solution layout [C]

From `RanseiLink.slnx` and the `*.csproj` files:

| Project | Target | Role |
|---|---|---|
| `RanseiLink.Core` | net10.0 | All ROM/file-format logic, models, services, patch builders. **No UI.** |
| `RanseiLink.Generation` | net10.0 | Code generator. Reads `RanseiLink.Generation/Models.xml` and emits `*.generated.cs` models, services, view-models, console commands. |
| `RanseiLink.GuiCore` | net10.0 | UI-framework-agnostic view-models. |
| `RanseiLink.Windows` | net10.0-windows (WPF) | Main GUI. |
| `RanseiLink.XP` | net10.0 (Avalonia) | Cross-platform GUI (in progress). |
| `RanseiLink.Console` | net10.0 | CLI + Lua scripting (CliFx, NLua). |
| `RanseiLink.PluginModule`, `Plugins/*` | | Plugin API and 7 plugins (Randomizer, SoftlockChecker, MassAction, …). |
| `RanseiLink.View3D`, `StandaloneModelViewer` | | OpenGL model viewer. |
| `*Tests` (Core, Console, Windows) | | xUnit + FluentAssertions + Moq. |

No `.github/workflows` and no PR template exist (`.github/` holds only `ISSUE_TEMPLATE/`). [C]

## 2. The central design fact: RanseiLink edits **files**, not the executable [C]

The game is a Nintendo DS ROM. RanseiLink's data flow is:

```
Original .nds ──(RomFs.ExtractCopyOf*)──▶ mod folder (data/*.dat, msg/, graphics/…)
                                              │  edited by services/view-models
mod folder ──(ModPatchingService.Patch)──▶ copy of .nds with files re-inserted
```

* **Extract/insert layer** — `RanseiLink.Core/RomFs/RomFs.cs`. It understands only the NDS *file system* (File Name Table + File Allocation Table) and the banner. Methods: `ExtractCopyOfDirectory`, `ExtractCopyOfFile`, `InsertFixedLengthFile` (throws `DataMisalignedException` if length differs, `RomFs.cs:92-103`), `InsertVariableLengthFile` (rewrites FAT entries and shifts following file data, `RomFs.cs:105-154`).
* **NDS header** — `RomFs/NdsHeader.cs:33-48` *parses* `Arm9RomOffset`, `Arm9Size`, `Arm7…`, `Arm9OverlayOffset/Length` etc. A repo-wide grep for `arm9`/`overlay` finds **no consumer** of those fields outside `NdsHeader.cs`. [C] The header is read-only: nothing recomputes the header CRC, ROM size, or ARM9 region.
* **Patch orchestration** — `Services/Concrete/ModPatchingService.cs:43-121`. Builders implementing `IPatchBuilder` (`Services/ModPatchBuilders/*`) each add `FileToPatch(gamePath, sourcePath, options)`; the service then calls `InsertFixedLengthFile` or `InsertVariableLengthFile` per file (`:83-94`). `FilePatchOptions` = `None | DeleteSourceWhenDone | VariableLength` (`Services/IModPatchingService.cs`).
* **Which data files may change length** — only `Pokemon.dat` (`DataPatchBuilder.cs:41`), MSG, maps, gimmick models, animations and some graphics. **All other `data/*.dat` files, including every per-scenario file, are inserted as fixed length** (`DataPatchBuilder.cs:42-45`). [C]

Consequence: **there is no ARM9, ARM7, or overlay read/modify/write capability anywhere in the project.** [C] Any change that depends on game code must add that capability.

Game versions (`Enums/ConquestGameCode.cs`): `VPYT` (NA), `VPYJ` (JP), `VPYP` (EU, treated as compatible with `VPYT` for data). Tests carry hard-coded layouts for both NA and JP (`PokemonServiceTests.IdenticalThroughLoadSaveCycle_*`). [C] Code layout differences between regions are **[U]**.

## 3. How a data file becomes a model [C]

```
BaseModelService<T>            (_minId, _maxId, _defaultId, _cache)       Base/BaseModelService.cs
 └ BaseDataModelService<T>     Reload(): for id in min..max → new T().Read(stream)
                               Save():   PreSave → each Write → PostSave   Base/BaseDataModelService.cs:31-57
    └ BaseNewableDataModelService<T>
BaseDataWindow                 byte[] Data + GetInt(intIndex, shift, bits) / SetInt(...)   Models/BaseClasses/BaseDataWindow.cs:42-53
```

* **Record count is a constructor constant, not read from the file.** `PokemonService` is `base(dataFile, 0, 199, () => new Pokemon(), 511)` (`ModelServices/PokemonService.generated.cs:16`). `Reload()` loops `_minId.._maxId` reading fixed-size records sequentially (`BaseDataModelService.cs:36-41`).
* **Fields are bit-packed** into little-endian 32-bit words: `GetInt(intIndex, shift, bitCount)`. Out-of-range values are **silently masked**, never rejected (`BaseDataWindow.cs:46-53`, comment: "Maybe throw exception / warning when value is too big"). This is a hazard for expansion: writing ID 300 into an 8-bit field would silently store 44.
* **Generation.** Most models are *generated*: `Models.xml` → `*.generated.cs`. Hand-written partial classes (e.g. `Models/ScenarioPokemon.cs`) add behaviour. A service's `MaxId`/`DefaultId` come from `<Service MaxId=… DefaultId=…/>` (`Models.xml:250` for Pokémon). Changing a limit therefore means editing `Models.xml` and re-running `RanseiLink.Generation`, **not** hand-editing generated files.
* **IDs are C# enums** (`Enums/PokemonId.cs`, 0‑199 plus `Default = 511`, `[DefaultValues(Default)]`). UI combo boxes are built from the enum (`GuiCore/Constants/EnumProvider.cs:17`) or from service `ValidIds()` + `IdToName`. The Pokémon *name* is stored in `Pokemon.dat` (`Models.xml:251`), so a new species name does not need a MSG edit, but the enum member list is static. [C]

## 4. Pokémon-related data files [C unless marked]

| File (`Constants.cs`) | Model | Record | Count | How species is referenced |
|---|---|---|---|---|
| `data/Pokemon.dat` (`:55`) | `Pokemon` | 0x30 B | 200 + evolution table at fixed offset `0x25C0` | self |
| `data/BaseBushouMaxSyncTable.dat` (`:38`) | `MaxLink` | 200 B | 252 (one per warrior) | **byte index = species ID** |
| `data/Scenario/ScenarioNN/ScenarioPokemon.dat` (`:74`) | `ScenarioPokemon` | 8 B | 200 per scenario × 11 | **8-bit species at byte 0** |
| `…/ScenarioBushou.dat` (`:75`) | `ScenarioWarrior` | 0x20 B | 210 | 8 × u16 *indices into ScenarioPokemon* (0xE+2i), default `1100` |
| `…/ScenarioAppearPokemon.dat` (`:76`) | `ScenarioAppearPokemon` | 1 B flag | **0xC8 = 200 bytes per scenario** | byte index = species ID (flag `0x20`) |
| `data/Kuni.dat` (`:50`) | `Kingdom` | 0x18 B | 17 | 8-bit `SwarmPokemon` (`Models.xml:190`) |
| `data/BaseBushouScout.dat` (`:39`) | *(not modelled)* | ? | ? | **[U]** — path constant only |
| `graphics/model_pokemon/POKEMON_{TEX,ATX,DTX,PAC}.ALL` | LINK archives | | 200 | index = species ID (`PkmdlGraphicsInfo.cs:26,195-200`) |
| `graphics/still/stl_pokemon_*` (7 sprite types) | STL | | 200 (assumed) | index = species ID (`GraphicsInfo.xml:71-128`) |

Save files are **not** handled by RanseiLink at all (no `.sav` code; repo-wide grep). Save layout information comes only from third-party research ([S], see POKEMON_LIMIT_AUDIT.md §6).

## 5. Where RanseiLink *could* host expansion logic

Because RanseiLink already owns: (a) a model/service layer with explicit per-file bounds, (b) a patch-builder extension point (`IPatchBuilder`, attribute `[PatchBuilder]`), and (c) a RomFs writer, the natural architecture for an expansion feature is:

1. **Core model layer** — make species capacity a runtime property (`PokemonCapacity`) instead of a `199` literal, and replace the three hard-coded structures (evo table offset, ScenarioPokemon sentinel, MaxLink/AppearPokemon strides) with accessors that consult a *layout descriptor* (vanilla vs expanded).
2. **New `IPatchBuilder` + new `IRomFs` capability** — `ExecutablePatchBuilder` + `IRomFs.GetArm9()/SetArm9()/GetOverlay(id)/SetOverlay(id, …)`, including ARM9 compression handling, header fix-ups and CRC16.
3. **A layout descriptor stored in the mod folder** (e.g. `expansion.json`) so a mod can say "this is an expanded-layout mod", gating all new behaviour and guaranteeing that unmodified mods round-trip byte-identically.

None of this exists today. The feasibility and plan documents build on this shape.

## 6. Open architectural questions [U]

* Is the 200 in `PokemonService`/`MaxLink` etc. mirrored by a constant in ARM9/overlay code, or does the game derive counts from file sizes/headers? (Issue #3 says hard-coded — [S].)
* Does the 64‑byte gap `0x2580–0x25C0` in `Pokemon.dat` (between record 199 and the evolution table; `PokemonService.cs:10`) belong to a table indexed by `Pokemon.Section2Index` (5 bits → 32 entries × 2 B = 64 B)? **[H]**, unproven; the field is named but never used in code (`grep Section2Index`).
* Whether `RomFs.InsertVariableLengthFile` growth is safe for files the game addresses by FAT index (it is for `Pokemon.dat` today) versus any file addressed by absolute offset. **[U]**
