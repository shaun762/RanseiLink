# PCE-002 — Emulator Testing Strategy

Evidence tags: **[C]** confirmed by a test in this session · **[S]** third-party documentation/source (cited) · **[H]** hypothesis · **[U]** unknown / could not be verified.

> **Honesty note.** No emulator was installed or run while writing this document (the author has no Windows machine, no ROM and no GUI). What is *implemented and tested* is the **isolation logic** (Setup-ConquestDev.ps1 `LaunchIsolated`) with the emulator mocked. Everything about what each emulator *can do* comes from documentation that could be fetched, and several key pages could not (DeSmuME's site returned HTTP 500; melonDS's public docs say nothing about debugging). §7 lists exactly what you should check on your own machine before relying on any capability marked [U].

## 1. Roles

| Role | Emulator | Rule |
|---|---|---|
| **Gameplay** — your playthrough | **RetroArch + melonDS core** (as today) | **Unchanged.** Never used for experiments, never reconfigured by these scripts. |
| **Smoke/regression tests** of experimental ROMs | RetroArch + melonDS core **through the isolated profile** (separate config copy, saves, states, playlists) | Automated launcher is implemented; see §3. |
| **Debugging / code reconnaissance** (breakpoints, memory watch) | A *standalone* emulator with a debugger — **candidates in §4; choice pending a local check** | Always a different install/profile from gameplay, started with a fresh (empty) save. |
| **Cross-validation** | A second, independent emulator core | Any "works" claim must hold on two emulators (PCE-001 K2: emulators are lenient about header CRCs and secure-area details; real hardware is **[U]**). |

## 2. The safest approach for isolated experimental testing

**Principle: an experimental ROM must be physically unable to see the real save or the real configuration.** Layers (defence in depth):

1. **Different file name and folder.** Experimental ROMs live in `PokemonConquestDev\experimental\` and are named differently from the original. RetroArch names save files after the *content name*, so a different name already means a different save file.
2. **Different save/state/playlist/config directories.** `LaunchIsolated` runs RetroArch with `--config <copy of your config> --appendconfig <overrides>`; the overrides (appended last, so they win **[S: man page "appends … to the config file loaded in -c"]**) point `savefile_directory`, `savestate_directory`, `playlist_directory`, `rgui_config_directory`, `core_options_path` and `screenshot_directory` into the workspace, turn off save-on-exit/auto-save/auto-load/history, and disable "saves next to content" and per-core sorting. The config *copy* means RetroArch's `config_save_on_exit` cannot rewrite your real `retroarch.cfg`.
3. **Refusals in code [C, Pester]:** only ROMs under `experimental\`/`output\`; never the original ROM; never if the isolated folders overlap yours; never without a core.
4. **Tripwire [C, logic tested with mocks]:** snapshot (file count, bytes, newest write time) of *your* save/state/playlist folders before launch, compared after RetroArch exits; any change is printed as `CHANGED`.
5. **Back up first.** `-Action BackupRetroArchSaves` (explicit, typed `BACKUP`, copy-only, hash-verified).
6. **Fresh start.** The isolated profile begins with no save, so an experiment boots to a *new game*. Testing "does an old save load in the expanded ROM" (PCE-001 E‑07) is a later, deliberate step done by manually **copying a backup into the isolated save folder** — never by pointing the experiment at the real folder.
7. **Savestates are per-emulator-and-core**: a RetroArch state cannot be loaded in another emulator **[S: man page: "save states are bound to the libretro implementation being used"]**; don't expect to move them around. In-game saves (`.sav`/`.srm`, battery saves) are the portable artifact.

### Residual risks
* **[U]** The override key names (§WINDOWS_SETUP 6) are unverified against your RetroArch version; the tripwire and the up-front backup are the safety net.
* **[U]** RetroArch may write to `system\` (firmware/BIOS location). Not watched.
* If an experimental ROM *itself* is broken it can only corrupt the isolated save.

## 3. What the isolated launcher does today

`Setup-ConquestDev.ps1 -Action LaunchIsolated -ExperimentalRom <path> [-CorePath <dll>] [-Launch]`

Dry run prints the exact command, e.g.:
```
"C:\RetroArch\retroarch.exe" --config "…\emulator\retroarch\retroarch.cfg" --appendconfig "…\emulator\retroarch\isolated_overrides.cfg" -L "…\cores\melondsds_libretro.dll" "…\experimental\test.nds"
```
`-Launch` (after a confirmation) creates the config copy (never overwriting), writes the overrides file (never overwriting; stops if an existing one differs), starts RetroArch, waits for it to exit, and reports whether your folders changed. **[C]** plan building, refusals, no-write dry run, `-Wait` launch, tripwire, and refusal to overwrite — all with `Start-Process` mocked. **[U]** real RetroArch behaviour.

## 4. Choosing a debugging emulator

### 4.1 What RetroArch/libretro offers for automation [S: Arch man page `retroarch 1.22.2`, libretro CLI guide]
| Capability | Documented? |
|---|---|
| `--config`, `--appendconfig`, `-L core`, `--verbose`, `--menu`, `--features` | **Yes** |
| Input **replay**: `--record-replay PATH` (`-R`) / `--play-replay PATH` (`-P`) | **Yes** (man page: ".replay format"; a `.bsv` option name no longer appears) |
| `--command CMD` (UDP command to a *running* RetroArch) | **Yes** (network commands must be enabled in settings) |
| Run N frames then exit (`--max-frames`, `--max-frames-ss`) | **Not in the man page or CLI guide** — may exist in newer builds; check `retroarch --help` **[U]** |
| Headless / no-video mode | **Not documented** |
| Breakpoints / disassembly / memory viewer | **No** (RetroArch is a frontend, not a debugger) |
| Memory read/write through the network command interface (`READ_CORE_MEMORY` etc.) | Not in the pages read; whether the melonDS core exposes DS RAM is **[U]** |

**Conclusion:** RetroArch is good for *smoke tests with replayed input* and screenshots, poor for debugging. Determinism of replays on the melonDS core is **[U]**.

### 4.2 Standalone candidates
| Emulator | What the author could confirm | Unknown / unconfirmed |
|---|---|---|
| **DeSmuME** (Windows build) | Deijin27's own Conquest tooling uses it: Lua scripts and RAM pointer files for DeSmuME 0.9.11 x64 ([conquest-memory-editing](https://github.com/Deijin27/conquest-memory-editing) **[S]**; needs `lua51.dll` beside the exe). Search results/wiki text list a disassembler, memory viewer, and Lua (Windows only) **[S, weak]**. Open-source (GPL-2.0, GitHub repo page). | Official docs unreachable (desmume.org HTTP 500): CLI options (`--lua-script`?), breakpoint support, GDB stub, current version, Lua-driven breakpoints — all **[U]** |
| **melonDS** (standalone) | Stable release 1.1 listed on winstall; winget id `melonDS.melonDS` **[S]**; FAQ documents "Boot game directly", save-state slots stored beside the ROM **[S]**. README's TODO lists "debugger" as not done **[S]**. | **No documented debugger, GDB stub, portable mode, CLI or scripting** in the pages read **[U]** — treat as "no debugger" unless your build proves otherwise. Good as an accuracy cross-check. |
| **No$GBA (debug version)** | Widely known as the DS debugger **[H, from general knowledge; not researched here]** | Licensing/availability/accuracy **[U]** — not recommended without further review |
| **BizHawk** (Lua automation, headless-ish) | **[H]** has Lua scripting and a command line; NDS core(s) and version support **[U]** — not researched | Whether it is suitable is unknown; worth a 30-minute check |

### 4.3 Recommendation (pending §7)
1. **Debugging / recon:** DeSmuME (Windows), because (a) the upstream author's Conquest research already targets it, so addresses and scripts exist **[S]**, (b) it advertises memory viewer/disassembler/Lua. Run it **portable, in `PokemonConquestDev\emulator\desmume\`**, with its own saves. Do **not** use it with your playthrough.
2. **Cross-check:** melonDS standalone (and/or the isolated RetroArch profile — same core as your gameplay, different state).
3. **Static analysis:** Ghidra on the decompressed ARM9/overlays from RomRecon (`--extract-code`, kept local).
4. Evaluate BizHawk only if DeSmuME's scripting turns out unusable.

## 5. What "automated and reproducible" can mean here

| Layer | Automated now | Reproducible? |
|---|---|---|
| Static ROM facts (RomRecon) | **Yes** — one command, hash-stamped output | Yes — same ROM ⇒ same report **[C on synthetic data]** |
| Isolated profile generation & safety checks | **Yes** | Yes **[C]** |
| Boot + screenshot smoke test | **Partly** — launch is automated; exiting after N frames is **not** (no documented `--max-frames`); screenshots are redirected to `diagnostics\screenshots` and are taken by the RetroArch hotkey | Needs input replay **[U]** |
| Input-driven scenarios (start battle, recruit, evolve) | **No** — would use `--play-replay` (RetroArch) or Lua (DeSmuME/BizHawk) | **[U]** whether frame-exact on the melonDS core |
| RAM assertions (e.g. "Pokémon table has 201 records") | **No** — needs a scriptable emulator (DeSmuME Lua `memory.*` **[S weak]**) | likely **[H]** |

The PCE-001 emulator tests (E‑01…E‑09) therefore start **manual-with-checklist** and become scripted per the table once the owner's check (§7) shows which interface works.

## 6. Experiment protocol (every experimental run)

1. `Verify` — original ROM still matches its manifest.
2. Fresh `BackupRetroArchSaves` if you will touch RetroArch at all.
3. Build the experimental ROM **into `experimental\`** under a unique name (`exp_<date>_<what>.nds`), never from a modified original.
4. Record: input ROM SHA-256, patch description, emulator + version + core, date.
5. Launch isolated; run the checklist (boot, load scenario, the specific feature); capture screenshots to `diagnostics\screenshots`.
6. Read the tripwire result. Anything `CHANGED` ⇒ stop, restore from backup, report.
7. Compare against the **vanilla control** run on the same emulator (PCE-001 S1).

## 7. Local verification checklist (≈20 min, owner's machine)

Run these once and send back the text output (no ROMs, no saves):

```powershell
& "C:\RetroArch\retroarch.exe" --help | Select-String "max-frames|appendconfig|play-replay|record-replay|command"
& "C:\RetroArch\retroarch.exe" --features
# the override keys exist in your own config? (names, not values)
Select-String -Path "C:\RetroArch\retroarch.cfg" -Pattern '^(savefile_directory|savestate_directory|playlist_directory|rgui_config_directory|core_options_path|screenshot_directory|history_list_enable|savefiles_in_content_dir|savestates_in_content_dir|sort_savefiles_enable|sort_savestates_enable|sort_savefiles_by_content_enable|sort_savestates_by_content_enable|savestate_auto_save|savestate_auto_load|config_save_on_exit)\b' | ForEach-Object { ($_.Line -split '=')[0].Trim() }
```
* Missing key names ⇒ tell us which; `Get-IsolatedLaunchPlan` is a one-line edit.
* Install DeSmuME; check whether *Tools* offers a disassembler, memory viewer and breakpoints, whether *Tools ▸ Lua Scripting ▸ New Lua Script Window* exists, and whether `DeSmuME.exe --help` lists `--lua-script`.
* Check melonDS ▸ *Config ▸ Emu settings* for any "GDB"/"debug" option.
* Do the **first** isolated launch with a throwaway ROM (the vanilla original copied under a new name into `experimental\`) *after* a verified backup, and confirm the tripwire prints "unchanged" for all three of your folders.

## 8. Open questions
1. Which emulator can set a *read watchpoint on the Pokémon table* (the single most valuable capability for PCE-001 Experiment 0)?
2. Does any of them run to a frame count and exit unattended?
3. Are melonDS-core replays deterministic across runs?
4. Do hacks that grow `Pokemon.dat` boot identically on DeSmuME and melonDS (PCE-001 K2)?
