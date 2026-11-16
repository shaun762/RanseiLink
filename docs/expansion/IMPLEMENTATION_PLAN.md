# PCE-001 — Implementation Plan (research stage — nothing here is implemented)

Tags: **[C]** confirmed · **[S]** third-party · **[H]** hypothesis · **[U]** unknown. `F‑nn` = POKEMON_LIMIT_AUDIT.md; `R1…R8` = FEASIBILITY.md §2; `U‑/P‑/R‑/E‑nn` = TEST_STRATEGY.md.
"#201" = `PokemonId` **200**.

## 0. Guardrails (apply to every step)

1. Never commit ROMs, extracted game files, BIOS/firmware, disassembly dumps, or save files. Commit **addresses, hashes, descriptions and synthetic fixtures only**.
2. Do not modify existing game-editing behaviour until Milestone M4; new work is **additive** (new projects, new descriptor) with vanilla as the default.
3. Never write to a user's original ROM, mod folder or save. All experiments operate on copies; every artifact is hashed.
4. Upstream (`Deijin27/RanseiLink`) is not modified. All work lands in the fork.
5. Each milestone ends with a **go / no-go gate**; a failed gate stops the programme and triggers a re-plan, not "try harder".

## 1. Milestones

| M | Name | Output | Gate (go if…) |
|---|---|---|---|
| **M0** *(done in PCE-002, pending review)* | Restore a regression net | Console + CoreTests compile; stale tests reconciled with the owner; Linux CI for L0–L3; user-run L4 baseline on NA/JP | `dotnet test` green on synthetic tests; L4 baseline report exists |
| **M1** | Reconnaissance (Experiment 0) | `findings/` report: where the game loads `Pokemon.dat` & friends; list of code sites referencing 200 / 0xC8 / 0x30 / 0x25C0 / strides | Every table in F‑01…F‑10 classified *file-derived* vs *code-constant*; ARM9 compression/overlay layout known |
| **M2** | Data-layout probe (Experiment 1) | Observed behaviour of the game with a 201-record `Pokemon.dat` | Outcome matrix (§3.2) resolved for NA at minimum |
| **M3** | **Proof of concept: species #201** (§4) | Patched ROM + patch tool + report | All PoC success criteria met on NA; JP recon documented |
| **M4** | Productionise core primitives | `IRomFs` ARM9/overlay API, layout descriptor, parameterised services, UI/plugin/test updates | U‑/P‑ suites green; vanilla byte-identical (R‑02) |
| **M5** | Full feature set | Recruitment, Perfect Links, saves, menus, scenarios, graphics pipeline, sentinel relocation, up to 255 species | Full QA matrix (TEST_STRATEGY §7) |
| **M6** | Optional: ID widening | Only if demanded after M5 | Separate proposal |

## 2. Experiment 0 — Reconnaissance (analysis only; no repo changes)

**Purpose:** convert hypotheses H‑A…H‑E into facts.

| Hyp. | Statement | How to settle |
|---|---|---|
| H‑A | The species count (200) is a compiled-in constant, not derived from file size | Static: find loader of `Pokemon.dat` (string/FAT-id reference), inspect size/count arithmetic; Dynamic: breakpoint on the table's RAM (pointer chain from `usefulPointers.txt` [S]: `0x020C4D48 → 0x0226FE58 = Pokemon`, region unverified) |
| H‑B | Evolution table is read at a constant offset `0x25C0` (mirrors `PokemonService.cs:10`) | Search ARM9/overlays for `0x25C0` literal-pool entries / `0x2580+0x40` arithmetic |
| H‑C | `MaxLink` is indexed as `warrior*200 + species` | Search for `0xC8` multipliers around the table load; breakpoint on first read when opening a link screen |
| H‑D | 8-bit species and a `0xC8`/`0xFF` sentinel are used by comparisons (`cmp r,#0xC8`) | Pattern search for `cmp`/`mov` with `#0xC8`, `#0xC7`, `#0xFF` near species handling |
| H‑E | Graphics archive counts are read from archive headers (extensible) or are compiled in | Static inspection of loader for `POKEMON_*.ALL` plus a dynamic test in Experiment 1 variant with a longer archive |

**Procedure (user's machine, own ROM):**
1. Record ROM SHA‑1/game code. Extract `arm9.bin`, `arm7.bin`, overlays, `y9.bin` with `ndstool` (or `ndspy`) into a **gitignored** `rom_dumps/` dir. Determine whether ARM9 is compressed (BLZ footer) [S general DS knowledge → verify].
2. Load ARM9 + overlays at their load addresses (from `NdsHeader` fields RanseiLink already parses, `NdsHeader.cs:33-48`; and the overlay table) into Ghidra/IDA.
3. Run the pattern searches in the table; for each hit record `{file, address, instruction class, role guess, confidence}`.
4. In DeSmuME, set write/read watchpoints on the Pokémon table, scenario-pokemon table and max-link table; drive UI paths (open gallery, start battle, open link screen) and record callers.
5. Produce `docs/expansion/findings/code_sites_<VPYT|VPYJ>.md` (addresses + roles only).

**Abort/redirect:** if more than ~30 independent code sites per table need change, or the loader is table-driven in a way that makes counts implicit in data layout, escalate to Approach D (loader hook) or stop.

## 3. Experiment 1 — "Append-and-relocate" probe (**recommended first implementation experiment**)

A throwaway console tool (new project `RanseiLink.Expansion.Probe`, not referenced by anything) reads an **unmodified mod folder**'s `Pokemon.dat` and writes variants into a scratch mod; the *existing* `ModPatchingService` patches them into a **copy** of the user's ROM (Pokemon.dat is already `VariableLength`, `DataPatchBuilder.cs:41`).

Variants:
* **V0 control** — re-pack unchanged (must be byte-identical; validates the pipeline; same as the `IdenticalThroughLoadSaveCycle` idea).
* **V1 relocate** — insert a 201st record (clone of record 199 with name `PoC201`) at `0x2580`; shift the 64-byte gap and the evolution table by `0x30` so the evo table starts at `0x25F0`.
* **V2 append-after** — leave layout untouched; append the 201st record **after** the evolution table (file grows by 0x30).
* **V3 gap-zeroed** — V1 with the 64-byte gap bytes zeroed. If behaviour differs from V1, the gap is live data the game needs (resolves audit F‑04).

Observation checklist per variant: boots? title → load scenario OK? Pokémon list/gallery shows normal entries? Eevee's 7 evolutions intact? RAM snapshot of the loaded table: size copied, bytes after record 199, evo table contents.

### 3.2 Outcome matrix (written *before* running — to avoid post-hoc rationalisation)

| Observed | Interpretation | Next step |
|---|---|---|
| V1: evolutions garbled/missing, record 200 not visible | Fixed offsets and fixed count (**expected**, H‑A+H‑B) | Proceed to PoC with ARM9 patch of those constants |
| V1: evolutions intact, record 200 visible in RAM | Count and offsets derived from file (**best case**) → PoC may need no code patch for R1 | Test R3/R4/R6 next; reduces scope sharply |
| V1: crash/hang at boot or load | Loader validates size/hash | Locate validation in Exp 0, patch or bypass |
| V2 identical to V0 | Trailing data ignored (consistent with fixed count) | none |
| V2 differs from V0 | Game reads to EOF or size-derived | investigate |
| Gap zeroing (V3) changes behaviour | Gap is live data (probably `Section2` table, F‑04 [H]) | model it; keep it relocatable |

Effort: small (days). Risk to repository: none. **Requires the user's ROM and an emulator** (not available in this research environment).

## 4. Minimal Proof of Concept — Pokémon #201 (ID 200)

### 4.1 Goal
Demonstrate, on **NA (`VPYT`) in an emulator**, that the game can load and use a **201st species without replacing any of the original 200**, with **all original species unaffected**, using only an 8-bit ID.

### 4.2 Scope
**In:** one new species record; evolution-table relocation; clone of an existing species' graphics into slot 200 (no new art); one observation channel (below); ARM9/overlay constants discovered in Experiment 0; a patch tool operating on the user's ROM; documentation of every changed byte.
**Out:** recruitment/scouting UX, Perfect Link tables for #201 beyond not-crashing, saves of other regions (JP/EU), new art, ID widening, UI of the editor, plugins, Randomizer.

### 4.3 Design decisions
* **ID 200, sentinel untouched.** Because `ScenarioPokemon` uses `200` as "none" (F‑05), the PoC species is **not** referenced from `ScenarioPokemon`. Observation channel: **`Kingdom.SwarmPokemon = 200`** for one kingdom (`Kuni.dat`, 8-bit field, fixed-length, no growth — F‑09) so the species appears as a wild swarm Pokémon in battle. If the game treats 200 specially there (**[U]**), fall back to **ID 201** as a control (adds a second record).
* **Clone, don't create:** stats/moves/abilities = copy of an existing simple species; name `PoC201`; graphics entries cloned from the same species so any visual difference proves the *slot* was used.
* **Layout descriptor** `expansion.json` in the mod folder (`{ "version": 1, "pokemonCount": 201, "evoTableOffset": "0x25F0", … }`); absent ⇒ vanilla. All new code paths are gated by it.
* **Patch primitive:** in-place constant patching of ARM9/overlay (preferred); trampolines/free-space only if the constants are not patchable in place. Fix ARM9 header size/CRC if the file length changes.
* **Delivery:** the patch tool + a patch description (offsets & bytes) — **no pre-patched ROM is ever distributed**.

### 4.4 Work breakdown

| # | Task | Depends on | Size |
|---|---|---|---|
| T1 | M0: fix CoreTests/Console compile; reconcile `ScenarioPokemonTests` with owner | — | S |
| T2 | Experiment 0 report (NA) | user ROM | M |
| T3 | Experiment 1 probe tool + results | T2 (interpretation) | S |
| T4 | `LayoutDescriptor` type + loader (Core, additive, default vanilla) + U‑11 | T1 | S |
| T5 | `PokemonService` accepts descriptor (count, evo offset) + U‑01/02/03/08 | T4 | M |
| T6 | `IRomFs` ARM9/overlay read/write + `SyntheticNds` + P‑01…P‑05 | T1 | L |
| T7 | `ExecutablePatchBuilder` applying the byte-patch list from Exp 0 | T2, T6 | M |
| T8 | Graphics: append cloned entry 200 to POKEMON_{TEX,ATX,DTX,PAC}.ALL + STL sets (cloned) | T2/H‑E | M |
| T9 | Kingdom swarm set to 200 for one kingdom | T5 | S |
| T10 | E‑01…E‑03 emulator scripts; R‑02/R‑03 byte allowlist | T7–T9 | M |
| T11 | PoC report + go/no-go for M4 | T10 | S |

### 4.5 Success criteria (all required unless marked stretch)

| # | Criterion | Measured by |
|---|---|---|
| S1 | **Vanilla regression:** expanded-layout ROM with only the original 200 species behaves identically to the vanilla ROM (screenshots + RAM hash set over the E‑01/E‑02 script) | E‑02 |
| S2 | **No-op patch is a no-op:** patching with an empty change set ⇒ ROM SHA‑1 unchanged | R‑02/P‑05 |
| S3 | **Boots and loads** a scenario with the 201-record table; no crash/freeze in 30 min soak | E‑01, E‑09 |
| S4 | **Species 200 live:** in a swarm battle it appears with name `PoC201`, the cloned model/sprite, correct stats, and completes a full battle (attack, faint, victory) | E‑03 |
| S5 | **Evolutions intact:** all 7 Eevee branches and one multi-stage line unchanged | manual/E‑06 |
| S6 | **Byte provenance:** every differing byte vs original ROM is on a documented allowlist (Pokemon.dat, archives, Kuni.dat, listed ARM9/overlay sites, header size/CRC) | R‑03 |
| S7 | **Max-link regression:** 10 random existing warrior×species links show identical caps | E‑05 |
| S8 | **Reproducible:** a second person can rebuild the ROM from a clean checkout + their own ROM using documented steps and get the same SHA‑1 | independent |
| S9 | **Save sanity (stretch):** save in the patched ROM, reload; a vanilla-ROM save loads without corruption or fails with an explicit, documented behaviour | E‑04/E‑07 |
| S10 | **Documented findings:** each audit hypothesis H‑A…H‑E marked confirmed/refuted with evidence | report |

### 4.6 Decision gate after the PoC
* **Go (→ M4)** if S1–S8 pass and the number of code sites per structure is bounded and understood.
* **Re-plan** if S4 passes only with a species-specific workaround, or S1 fails intermittently.
* **No-go** if the code sites are not enumerable (e.g., counts implicit in compressed/self-modifying code) or S1 cannot be achieved — conclude that replacement (Approach A) is the practical limit and document why.

## 5. Risk register

| ID | Risk | Likelihood | Impact | Mitigation / detection |
|---|---|---|---|---|
| K1 | Count/stride constants spread across many sites or overlays; missed site causes rare crash | High | High | Exp 0 exhaustive pattern search + dynamic breakpoints; S1 soak; allowlist diff (R‑03) |
| K2 | ARM9 compressed/encrypted; secure-area CRC; header CRC mishandled → ROM won't boot on hardware (emulator may be lenient) | Medium | High | P‑02 synthetic tests; validate in melonDS *and* DeSmuME; document hardware untested |
| K3 | ID 200 sentinel conflicts in code paths beyond `ScenarioPokemon` (e.g., `cmp #0xC8` ⇒ invalid) | Medium | Medium | H‑D search; PoC fallback to ID 201 |
| K4 | Silent truncation writes wrong IDs (>255) | Medium | High | U‑05/U‑12 guarded setters; throw on overflow |
| K5 | Save incompatibility / corruption of user saves | Medium | High | Never touch real saves in dev; E‑07; ship a clear "expanded ROMs need new saves" notice unless proven otherwise |
| K6 | Fixed-length growth: `InsertVariableLengthFile` assumes game addresses files by FAT index, not offset; header ROM size/CRC not updated (`RomFs.cs:105-154`) | Medium | Medium | P‑01 tests; check header fields; verify on both emulators |
| K7 | Region differences (NA/JP/EU) — different code offsets | High | Medium | Per-region patch lists keyed by game code + ROM hash; refuse unknown hashes |
| K8 | Graphics archive count compiled in | Medium | Medium | Exp 1 variant + H‑E |
| K9 | Legal: distributing patched ROMs or extracted data | Low (process) | Very high | Guardrails §0; patch-only distribution; GPLv3 obligations (FEASIBILITY §8) |
| K10 | Upstream layout churn (`Models.xml` mid-refactor; `ScenarioPokemon` bit layout changed 2026‑01‑24) conflicts with our work | Medium | Medium | Rebase cadence; pin audited commit; coordinate with upstream owner before editing generated models |
| K11 | Test net unreliable (CoreTests do not compile) | Certain today | Medium | M0 first |
| K12 | Research sources unreachable (PokéCommunity, TCRF, pleonex blog) leave knowledge gaps | Certain | Low-Med | Human reads them and pastes relevant text; see §7 |
| K13 | Scope creep into ID widening | Medium | Medium | M6 separate proposal |

## 6. Rollback procedures

| Level | What can go wrong | Rollback |
|---|---|---|
| **ROM artifact** | Patched ROM misbehaves | Originals are never modified (guardrail 3). Delete the output; every run records input SHA‑1 + patch-list hash in a manifest. Provide `--verify` (re-hash) and `--unpatch` (apply the stored reverse byte-diff to the patched copy and confirm original SHA‑1). |
| **Mod folder** | Corrupted/expanded mod | Descriptor absent ⇒ vanilla; the tool refuses expanded descriptors for unsupported versions; mods are snapshotted to `*.rlmod.bak` before any expansion operation (use existing mod export, `ModManager`). |
| **Saves** | Expanded ROM damages a save | Development uses **copies** of saves and emulator savestates only; documentation warns users to back up `.sav` first; E‑07 gates release. |
| **Repository** | A change regresses vanilla editing | Work on branches off `master`; additive code; descriptor-gated; each PR must pass R‑02 (vanilla byte-identical) and U‑02; revert is a single `git revert` because primitives (`IRomFs` additions, descriptor) don't alter existing code paths; generated files regenerated only via `RanseiLink.Generation`. |
| **Programme** | PoC fails its gate | §4.6: stop, document the limit, retain Approach A as the supported path. |
| **This research PR** | Unwanted | Docs-only; delete the branch. |

## 7. Open actions / external requirements (things I could not do here)

1. **ROMs** — a legally owned NA (`VPYT`) and JP (`VPYJ`) ROM on the maintainer's machine; none exist in this environment (and none may be committed).
2. **Tools** — `ndstool`/`ndspy`, Ghidra (or IDA) with an NDS/ARM9 loader, DeSmuME (Lua) and/or melonDS with debugger, a hex diff tool. None installed/evaluated here. (.NET 10 SDK was installed locally in the sandbox for builds; no emulator.)
3. **Unreachable references** — read by a human and summarised into the PR: PokéCommunity *Pokémon Conquest ROM Hacking Documentation* (thread 454568, 403 from this environment), TCRF *Pokémon Conquest*, pleonex's blog `pokemon-names` (host not in network allowlist), upstream wiki bodies (only titles loaded), Google Drive "Rom Documentation" linked from the wiki, and the Discussions pages beyond the first page.
4. **GitHub API access to upstream issues/discussions** — only git read access was available; issue #3's content is second-hand. Either enable access or paste the thread.
5. **Upstream owner input** — ask whether `Models.xml`'s new `ScenarioPokemon` layout (`U1` 9 bits, `Exp` 15 bits) is final and whether the 8 stale test files are being repaired (K10/K11); ask for any private ARM9 notes behind the issue #3 statement ("hard coded").
6. **CI** — permission to add a GitHub Actions workflow (none today).
7. **Executable samples** — none available; any prior ARM9 patch examples from other Conquest hacks (e.g. PokéCommunity projects) would shorten Experiment 0.

## 8. Checklist for the independent reviewer

* Are the [C] findings reproducible from the cited `file:line` at commit `308d988`?
* Is the tag discipline honest — are any [H]/[S] claims phrased as facts?
* Is ID 200 vs 201 handling sound (sentinel, 0xFF)?
* Do the Experiment 1 outcome predictions distinguish "fixed count" from "file-derived count"?
* Are the PoC success criteria sufficient to catch the high-impact regressions (S1, S7)?
* Is the legal/IP section appropriately cautious?
