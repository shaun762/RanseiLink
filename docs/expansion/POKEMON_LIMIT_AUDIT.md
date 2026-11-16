# PCE-001 — Pokémon Limit Audit

Audited commit `308d988`. Tags: **[C]** confirmed in repo / reproduced, **[S]** third-party source, **[H]** hypothesis, **[U]** unknown (see ARCHITECTURE.md for the legend).
"#201" = `PokemonId` **200** (zero-based).

## 0. Method (reproducible)

```bash
# every literal that could be a species count/limit
grep -rnE '\b(200|199|0xC8|0xC7|201|255|0xFF|511|1100)\b' --include=*.cs --include=*.xaml --include=*.xml .
# every consumer of the species type
grep -rln 'PokemonId' --include=*.cs .
# bit-width audit
grep -n 'PokemonId\|Pokemon' RanseiLink.Generation/Models.xml
```

Noise (colour maths, NCER/PAC offsets, XAML pixel widths) was reviewed and excluded; the survivors are below. The list is **complete for the C# source**; it is by definition **blind to ARM9/overlay code and the save format** (§6).

Quick-reference summary:

| ID | Structure | Limit | Severity for #201 |
|---|---|---|---|
| F‑01 | Species table size | 200 records, ctor constant | blocker (data+code) |
| F‑02 | Evolution table | fixed offset, 8‑bit IDs | blocker (data) |
| F‑03 | Name-order index | 8 bits (≤256) | OK up to 256 |
| F‑04 | `Pokemon.dat` unknown 64‑byte gap | unknown purpose | risk |
| F‑05 | `ScenarioPokemon` species | 8 bits, **200 = "none" sentinel** | blocker for ID 200 |
| F‑06 | `ScenarioPokemon.dat` pool | 200 entries ×11 scenarios, fixed length | unknown coupling |
| F‑07 | `ScenarioAppearPokemon.dat` | 200 bytes, indexed by species | blocker (file + code) |
| F‑08 | `MaxLink` table | 252 × 200 B, indexed by species | blocker (file + code) |
| F‑09 | `Kingdom.SwarmPokemon` | 8 bits | OK ≤255 |
| F‑10 | Graphics archives | 200 sprites per type | blocker (assets + code) |
| F‑11 | Randomizer | `random.Next(200)` | tool bug, easy |
| F‑12 | Enum / UI / tests | static enum, 200‑count tests | tool work |
| F‑13 | Save file | 8‑bit species ([S]) | unknown |
| F‑14 | Game code | hard-coded count ([S]) | **primary blocker** |

---

## 1. Species table (`Pokemon.dat`)

**F‑01 — 200 records, count baked into the service constructor. [C]**
* `RanseiLink.Core/Services/ModelServices/PokemonService.generated.cs:16` — `base(dataFile, 0, 199, () => new Pokemon(), 511)`.
* Source of truth: `RanseiLink.Generation/Models.xml:250` — `<Service MaxId="199" DefaultId="511"/>`.
* Record length `0x30` — `Models.xml:249`. 200 × 0x30 = **0x2580** (derived).
* `Reload()` reads exactly `_maxId-_minId+1` records (`Base/BaseDataModelService.cs:31-44`); the file length is never consulted.
* Test pinning the limit: `CoreTests/ServiceTests/ModelServiceTests/PokemonServiceTests.cs:98` (`Retrieve(200)` must throw) — **this test must be inverted by any expansion.**

**F‑02 — Evolution table lives at a hard-coded offset and stores 8‑bit species. [C]**
* `PokemonService.cs:9-10`: `__defaultEvoId = 1400`, `__evoTableOffset = 0x25C0`.
* Load: `stream.Position = 0x25C0; length = ReadInt32(); buffer = ReadExactly(length)` then `(PokemonId)buffer[i]` (`:15-32`). 8‑bit by construction.
* Save: `PostSave` seeks to `0x25C0`, writes `(byte)i` for each entry, pads to a multiple of 4 and truncates (`:73-87`). The offset is **not relative to the record count**: a 201st record written sequentially would land at `0x2580–0x25AF` and silently overwrite 48 of the 64 gap bytes (F‑04); a 202nd would overlap the start of the evolution table at `0x25C0`.
* Per-species evo range fields `MinEvolutionTableEntry`/`MaxEvolutionTableEntry` are 11 bits each (`Models.xml:277-278`); "none" = 1400 (`__defaultEvoId`).
* Third-party corroboration [S]: upstream author states "the pokemon ids in scenarioPokemon, and in the evolution table are only allocated 8 bits" (issue #3, see §7).
* A reported limit on evolutions per species (Eevee, 8th evolution gives a blank name) exists as open issue #80 [S]; cause **[U]** (could be a UI/game-memory limit; unrelated to species count).

**F‑03 — `NameOrderIndex` is 8 bits. [C]** `Models.xml:280` (`Index="11, 0, 8"`). Max 255 → supports **≤256 species**, no more. It is regenerated on save via a `ja-JP` string sort (`PokemonService.cs:60-68`), so the *tool* will always write a consistent value, but the *game's* use of it is **[U]**.

**F‑04 — 64 unexplained bytes between the records and the evo table. [C that the gap exists; H on its meaning]**
`0x25C0 − 0x2580 = 0x40`. Nothing in RanseiLink reads or writes it. `Section2Index` (5 bits, `Models.xml:256`) is a defined-but-never-used field; 32 entries × 2 B = 64 B fits the gap exactly. **[H]**: a "section 2" table indexed by that field. Confirm by dumping the gap from a ROM and checking whether values correlate with `Section2Index`. Relevance: if this table is indexed per species or per `Section2Index` and assumed to follow the records, appending a record shifts it.

**Other species-record bit widths that can overflow with more species [C]** (`Models.xml:249-281`): `NationalPokedexNumber` 10 bits (≤1023), `Move`/`Ability*` 9 bits (reference other tables, not species). No other field in the record references a species except via the evolution table.

## 2. Scenario data

**F‑05 — `ScenarioPokemon` species is one byte, and `200` means "no Pokémon". [C]**
* `Models/ScenarioPokemon.cs:7-19`:
  ```csharp
  byte value = GetByte(0);
  return value == 200 ? PokemonId.Default : (PokemonId)value;      // get
  byte byteVal = value == PokemonId.Default ? (byte)200 : (byte)value; // set
  ```
* The tool maps in-memory `PokemonId.Default` (511, `Enums/PokemonId.cs:208`) ↔ on-disk `200`.
* Evidence from real data: `CoreTests/ServiceTests/ModelServiceTests/ScenarioPokemonServiceTests.cs:29-30` — entry 199 of scenario 0 begins `0xC8` and is called `placeholder`. [C — as asserted by the upstream test; the ROM was not available to re-verify]
* **Therefore real species ID 200 is indistinguishable from "empty" in this structure.** Any expansion that wants ID 200 must (a) move the sentinel (e.g. to 0xFF) in the tool **and** in game code **and** in the placeholder entries of all 11 scenario files, or (b) skip ID 200 and start at 201 (see FEASIBILITY.md §5).
* UI mirrors the sentinel as 511: `Windows/ViewModels/ModelViewModels/ScenarioWarriorWorkspace/ScenarioPokemonViewModel.cs:45`.
* Bit layout of the same 32-bit word is **in flux upstream**: `Models.xml:283-284` now says `U1` = bits 8‑16 (9 bits) and `Exp` = bits 17‑31 (15 bits); before commit `11e8f03` (2026‑01‑24) it was `U1` 8 bits, `Exp` 16 bits. The existing unit tests were not updated and **fail** (see TEST_STRATEGY.md §2). Whether bit 8 of `U1` is really a species high-bit is **[U]** — a 9‑bit `U1` directly after an 8‑bit species is suspicious and is worth checking against game RAM.

**F‑06 — `ScenarioPokemon.dat`: 200 entries, 8 bytes each, per scenario, fixed length. [C]**
`ScenarioPokemonService.cs:18` (11 scenarios `0..10`), `:57` (`0, 199`), `Constants.cs:71` (`ScenarioPokemonCount = 200`), `DataPatchBuilder.cs:33,44` (patched as `None` = fixed length). *Which* 200 this is — a pool of scenario Pokémon *instances*, not species — is clear from `ScenarioWarrior` referencing them by index. Whether the **pool size** is tied to the **species count** in game code is **[U]** (probably independent; the equality is likely coincidental). Third-party save research shows the in-save equivalent holds **0x30B (779)** entries [S], suggesting the pool size is its own constant.

**F‑06b — Warrior→ScenarioPokemon slot is 16 bits with sentinel 1100. [C]**
`Models/ScenarioWarrior.cs:5-34` (8 slots at `0xE + 2i`, `DefaultScenarioPokemon = 1100`); UI: `ScenarioWarriorWorkspaceViewModel.cs:194`. Not affected by species count, but shows the sentinel style used elsewhere.

**F‑07 — `ScenarioAppearPokemon.dat` is one byte per species, exactly 0xC8 bytes. [C]**
`Models/ScenarioAppearPokemon.cs:7-31`: `DataLength = 0xC8`, `GetCanAppear(id) => GetByte(id) == 0x20`. This is the **wild-encounter/recruit eligibility list per scenario**. An out-of-range `id` ≥ 200 throws `IndexOutOfRange` inside `BaseDataWindow.GetByte`. File is patched fixed-length (`DataPatchBuilder.cs:35,44`), so growing it would currently abort patching with `DataMisalignedException` (`RomFs.cs:98-101`). The UI iterates `EnumUtil.GetValuesExceptDefaults<PokemonId>()` (`GuiCore/ViewModels/ModelViewModels/ScenarioAppearPokemonViewModel.cs:15`).

**F‑09 — `Kingdom.SwarmPokemon` is 8 bits. [C]** `Models.xml:190` (`"5, 22, 8"`, type `PokemonId`). Fits IDs ≤255. Value `Default` (511) cannot be stored here — how "no swarm" is represented **[U]**.

## 3. Link / Warrior relationships

**F‑08 — `MaxLink` is a warrior × species matrix with a 200-byte stride. [C]**
* `Models/MaxLink.cs:7-29`: `DataLength = 200`, `GetMaxLink(species) => GetByte(species)`.
* `MaxLinkService.generated.cs:15` / `Models.xml:208-210`: **252 records (`MaxId=251`, indexed by `WarriorId`)**.
* Derived file size **252 × 200 = 50,400 bytes** (not verified on a ROM). One byte per (warrior, species): the *Max Link* ("perfect link" ceiling) for that pair; the editor VM enumerates species at `GuiCore/…/MaxLinkViewModel.cs:224`.
* The in-game reader almost certainly indexes `warrior * 200 + species` or uses a row pointer **[H]**; the upstream author says "the code which loads the max link table would also need to be changed" [S, issue #3]. So adding species ⇒ new stride ⇒ **code patch, not just data**.
* Perfect Link semantics: a Perfect Link is link = 100% (`LinkCalculator.cs:3-24`: link caps at 100 via `CalculateExp`). MaxLink < 100 caps what a pair can reach. Randomizer plugin sets all to a value (`Randomizer.cs:436-444`).

**BaseWarrior.** `Models.xml:13-40`: `RankUpCondition1/2` of type `RankUpConditionId.Pokemon` (`Enums/RankUpConditionId.cs:6`) with 9-bit quantity fields (`:24,37-39`). **[H]**: for condition `Pokemon`, the quantity is a species ID; 9 bits hold ≤511, so no width problem. **[U]** whether warrior evolution compares IDs ≥200 safely.
`BaseBushouScout.dat` (`Constants.cs:39`) has a path constant but **no model** — scouting/recruitment data may reference species. **[U]**

## 4. Graphics

**F‑10 — Per-species graphics are positional archives with a hard-coded count. [C for tool; U for game]**
* `Resources/GraphicsTypes/PkmdlGraphicsInfo.cs:26` — `private const int __numPokemon = 200;`; used at `:195-200` to size four arrays and a `Parallel.For`.
* Battle model sprites are four LINK archives `POKEMON_{TEX,ATX,DTX,PAC}.ALL` (`Resources/GraphicsInfo.xml:62-70`; `<FixedAmount>true</FixedAmount>`, `:69`).
* Seven STL sprite groups (`StlPokemon{CI,SR,S,B,M,L,Wu}`, `GraphicsInfo.xml:71-128`, enum `Services/SpriteType.cs:52-80`).
* `GetFilesToPatch` only repacks **if overrides exist** (`PkmdlGraphicsInfo.cs:171-176`), and replaces entries by index; there is no "append" operation.
* Therefore a 201st species needs a 201st entry in ≥ 11 archives. Whether the game indexes by `ID` into archives with a count read from the archive header (extensible) or a compiled-in count is **[U]**. LINK archive format is documented upstream (wiki "LINK Archive") and implemented in `Archive/Link.cs` [C].

## 5. Tool-side code, UI, plugins, tests

**F‑11 — Randomizer hard-codes 200. [C]** `Plugins/RandomizerPlugin/RandomizerPlugin.cs:38`: `var pokemon = (PokemonId)random.Next(200);`. Other plugin code uses `EnumUtil.GetValuesExceptDefaults<PokemonId>()` (`Randomizer.cs:12`, `MassAction.cs:15`), which follows the enum automatically.

**F‑12 — The enum is the registry. [C]** `Enums/PokemonId.cs` lists 0‑199 then `Default = 511`. Any new species needs: a new enum member (the generator and several UI paths enumerate it: `EnumProvider.cs:17`, `ScenarioAppearPokemonViewModel.cs:15`, `MaxLinkViewModel.cs:224`, `Console/Services/LuaService.cs:62`), and sprite handling that assumes sprites exist for every enum member (`PokemonMiniViewModel.cs:50`, `SwPokemonSlotViewModel.cs:85`, `KingdomViewModel.cs:62`).

Tests that hard-code 200 and will legitimately change: `WindowsTests/ViewModelTests/WorkspaceTests.cs:53,109-122`; `CoreTests/…/PokemonServiceTests.cs:98`; `CoreTests/…/ScenarioPokemonServiceTests.cs:42` (`Retrieve(200)` on the *pool*, which may stay).

**Silent truncation hazard. [C]** `BaseDataWindow.SetInt` masks (`:46-53`); `ScenarioPokemon.Pokemon` setter casts to `byte` (`ScenarioPokemon.cs:16`); `MaxLink.SetMaxLink` casts to `byte`; `PokemonService.PostSave` casts to `(byte)` (`:79`). A species ID > 255 written through any of these **corrupts without error.**

## 6. Things the C# source cannot tell us

**F‑13 — Save file. [S]** RanseiLink has no save-file code. Third-party notes (Deijin27/conquest-hexpat `sav.hexpat`, retrieved by a delegated web fetch and a direct raw read of that file in this session):
* `struct ScenarioPokemon { u8 pokemon; u8 u1; u16 exp; SPBits field; }` and `ScenarioPokemon pokemon[0x30B]` — species is **u8** in the save (also matches the in-ROM struct).
* `struct PokemonBlock { … u16 pokemon[0x40]; }`, `SWPokemon { u8 scenarioPokemonId; bool scenarioPokemonIsDefault; }`; file padded to `0x40000`.
* MathyFurret/conquestsavefiletools: gallery species read as a 16-bit word `and 0xff`, `NUM_POKEMON 1000`, a 16-bit byte-sum checksum at the block start [S, partial; semantics unlabeled upstream].
Implications: species IDs 200‑255 would *fit* in the save's byte fields; ≥256 would not. Whether save blocks are **sized/offset by a species count** (→ layout/size/checksum changes ⇒ old saves incompatible) is **[U]**.

**F‑14 — Game code. [S]/[U]** Upstream author, issue #3 (2022‑02‑26, closed): "the number of pokemon is not stored in the files, it is hard coded, game code would need to be reverse engineered"; "I don't access the code, I only modify the files in the rom file system" (2022‑03‑03). This is consistent with everything in §1–§3 and is the **primary blocker**. No RAM/ARM9 addresses for the code that loads these tables are published; only data-structure pointers (§7).

## 7. Upstream research inventory

| Source | What it gives | Tag |
|---|---|---|
| `Deijin27/RanseiLink` issue #3 "New Pokémon/Warriors" (closed 2022‑03‑14) | Count hard-coded; 8-bit IDs in ScenarioPokemon & evo table; MaxLink loader needs change; not planned | [S] (fetched via web; the GitHub API for this repo is not enabled in the session, so not re-verified) |
| issue #80 "Evolution Limit" (open) | Eighth Eevee evolution → blank name | [S] |
| `Deijin27/conquest-memory-editing/usefulPointers.txt` | Pointer-table entries, e.g. `0x020C4D48 -> 0x0226FE58 = Pokemon`, `0x020C4D4C -> 0x022724F8 = ScenarioPokemon`, `0x020C4D54 -> 0x02277664 = BaseWarrior`; region/build **[U]** | [S] |
| `Deijin27/conquest-hexpat` (`sav.hexpat`, `nds.hexpat`) | Save layout (partial), NDS header pattern | [S] |
| `MathyFurret/conquestsavefiletools` | Gallery block constants & checksum | [S] |
| RanseiLink wiki ("NDS File System", "LINK Archive", …) | File-system and archive formats | [S] |
| Upstream git: branches `dynamic-ui`, `elevation-map-generator`, `gimmick-models`, `msg-preview`, `nickname-service`; 5 branches, last commits 2025‑03/05 | **None concern Pokémon capacity or executables** | [C] (`git log upstream/<b>`) |
| Upstream commits mentioning expansion/ARM9/overlay/decomp | Only unrelated hits ("Pokemon battle sprite editing", etc.) | [C] (`git log --grep`) |
| A decompilation/disassembly of Pokémon Conquest | **None found.** Searches for "Pokemon Conquest decompilation/disassembly" returned only other DS games (pret/pokediamond, DQIX, `pret/ds_disassembly_tools`). | [S] (web search) |
| PokéCommunity "Pokemon Conquest ROM Hacking Documentation" (thread 454568) and TCRF, pleonex blog | **Not readable in this session** (HTTP 403 / host not in network allowlist) | [U] |

Community statement that "Pokémon Conquest Ultimate" works within a **200-species cap by replacement** was seen only in search snippets of PokéCommunity pages (not fetched) [S, weak].

## 8. Verdict of the audit

* **Confirmed [C]:** every *data* structure that references species either has a 200-entry size, is indexed by species, or stores species in 8 bits; one of them uses 200 itself as a sentinel; RanseiLink cannot touch game code.
* **Primary blocker [S+H]:** the game executable almost certainly hard-codes the count and strides.
* **Not blockers [C]:** the name-order field (≤256), swarm field (≤255), save species byte (≤255), and the tool's own services (all simple to parameterise).
