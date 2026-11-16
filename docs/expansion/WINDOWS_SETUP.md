# PCE-002 — Windows Development & ROM-Analysis Setup

Evidence tags: **[C]** confirmed by a test run in this session · **[S]** third-party source · **[H]** hypothesis · **[U]** unknown / not verifiable here.

> **You never upload your ROM anywhere.** Everything below runs on your laptop. The ROM is only *read* from where it already lives and *copied* inside your own computer. Nothing in this setup contacts the internet except `winget` (only if you pass `-InstallMissing` and confirm), and nothing is sent to GitHub or any AI service.

## 0. ROM-handling rules (permanent; see `AGENTS.md`)

The ROM, anything derived from it (dumps, decompressed code, `gap.bin`, extracted assets), saves and save states **never leave your computer**: not to GitHub, not to Claude/ChatGPT, not to cloud storage. Only *text* diagnostics are shared, and only after redaction. These rules are enforced in code where possible:

| Safeguard | What it does | How to use it |
|---|---|---|
| `.gitignore` | ignores ROM/save/state/dump/recon names | automatic |
| `tools/guard/Test-RepoForRomData.ps1` | inspects file **content** (a renamed ROM is still caught), unexplained binaries, archives, oversize files | `.\tools\guard\Install-Guards.ps1` once per clone enables the `pre-commit` and `pre-push` hooks; CI runs it on every PR |
| Workspace location checks | setup and RomRecon refuse git working trees **and** OneDrive/Dropbox/Google Drive/iCloud/Box/MEGA/pCloud/Nextcloud locations | automatic |
| No-network tests | prove the scripts and RomRecon contain no network code or networking assembly | automatic (CI) |
| `tools/windows/Export-ShareableText.ps1` | refuses binary/ROM-like files, redacts user name, paths, computer name, e-mail, credentials, tokens, IP/MAC; writes a new file | `.\tools\windows\Export-ShareableText.ps1 <report.txt> -Show`, read it, then share |

Limits: hooks can be bypassed with `--no-verify` (CI still flags it afterwards) and redaction is pattern-based. Always read what you are about to share.

## 1. The one command

1. Get the repository onto your laptop (pick one):
   * `git clone https://github.com/shaun762/RanseiLink` then `git checkout feature/pce-002-dev-environment`, **or**
   * GitHub → branch `feature/pce-002-dev-environment` → *Code ▸ Download ZIP*, extract it, and run `Get-ChildItem -Recurse <folder> | Unblock-File` once (ZIP downloads are marked "from the internet").
2. Open **Windows PowerShell** (the blue one that ships with Windows — 5.1 is fully supported) in the repository folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\windows\Setup-ConquestDev.ps1
```

`-ExecutionPolicy Bypass` applies to this one process only; it does not change your system policy.

3. Follow the prompts. The script will:
   1. list which tools are installed and which are missing;
   2. offer detected Pokémon Conquest ROMs (from your RetroArch playlists), or let you **browse** or **paste** a path;
   3. validate the ROM (game code VPYT/VPYJ/VPYP, header CRC) and show its region;
   4. create `PokemonConquestDev` and its folders (asks first);
   5. **copy** the ROM into `PokemonConquestDev\original`, verify the SHA-256 of the copy, mark it read-only, and write a manifest;
   6. offer to run the read-only analysis (needs the .NET SDK).

Re-running it is safe: it reports "already present and identical" and changes nothing **[C: end-to-end Pester test runs setup twice and compares the whole tree]**.

Unattended form (no prompts; anything needing a "yes" is skipped):
```powershell
.\tools\windows\Setup-ConquestDev.ps1 -RomPath "C:\Games\Pokemon Conquest.nds" -NonInteractive -AssumeYes
```

## 2. What gets created

Default location: `%USERPROFILE%\PokemonConquestDev` (`-WorkspaceRoot` to change; must be **outside any git repository**, the RetroArch folder, and your RetroArch save/state folders — the script refuses otherwise **[C]**).

```
PokemonConquestDev\
  original\       verified READ-ONLY copy of your ROM. Never edit.
  experimental\   scratch ROMs/mods. Only ROMs here or in output\ can be launched by the isolated profile.
  output\         patched ROMs / build products (disposable)
  diagnostics\    RomRecon reports (new sub-folder per run) and emulator screenshots from isolated runs
  backups\        copies of RetroArch saves/states you explicitly back up
  manifests\      original_<rom>.json  (SHA-256, size, game code, region)
  logs\           setup transcripts
  emulator\retroarch\   the ISOLATED RetroArch profile (config copy, saves, states, playlists)
  workspace.json  remembered paths
```

## 3. Safety guarantees — and how each is enforced

| Guarantee | Enforcement | Tested |
|---|---|---|
| Nothing is ever **deleted** | The script contains no delete/move primitive | Pester scans the script text for `Remove-Item`, `Move-Item`, `Set-Content`, `Out-File`, `Copy-Item`, `FileMode.Create/Truncate`, `File.Delete` **[C]** |
| Nothing is ever **overwritten** | All writes use `FileMode.CreateNew` (throws if the file exists); conflicts get a new name (`_2`) or are skipped | existing-file tests keep bytes identical **[C]** |
| Your ROM is **never modified** | Opened `FileAccess.Read`/`FileShare.Read` only; hash and timestamp unchanged | read-only + mtime tests **[C]** |
| Copy is **verified** | SHA-256 of source vs copy; mismatch aborts (and leaves the bad copy for you to inspect — it is not deleted) | **[C]** |
| Your **saves/states/config** are never modified | Read-only parsing of `retroarch.cfg`; saves only ever *copied* by the backup action | owner-tree-unchanged assertions **[C]** |
| **Backups need explicit consent** | A separate action; you must type `BACKUP` (capitals). `-AssumeYes` cannot answer it | **[C]** |
| An **experimental ROM never uses your save directory** | `LaunchIsolated` always passes `--config <copy>` + `--appendconfig <overrides>` that redirect saves, states, playlists, core options, history; refuses if the isolated folders overlap yours; refuses ROMs outside `experimental\`/`output\`; refuses the original ROM; then compares your save/state/playlist folders before and after as a tripwire | plan, refusal and tripwire tests **[C]**; the real RetroArch behaviour of these keys is **[U]**, see §6 |
| Workspace can't be **committed by accident** | Refuses locations inside a git working tree | **[C]** |

What is **not** guaranteed: if Windows, antivirus or a crash interrupts a copy, a partial file can remain (the script never deletes it — you delete it). Hash verification will flag it on the next run.

## 4. Actions

`.\tools\windows\Setup-ConquestDev.ps1 -Action <name> [options]`

| Action | Purpose | Modifies anything? |
|---|---|---|
| `Setup` *(default)* | tools report, workspace, ROM copy + manifest | creates new files/folders in the workspace only |
| `Check` | tool detection only (`-InstallMissing` offers winget installs, one confirmation each) | no (except winget if you confirm) |
| `Status` | prints workspace/RetroArch paths | no |
| `Verify` | re-hashes `original\` against its manifest; checks read-only flag | no (exit code 1 on mismatch) |
| `Recon` | runs RomRecon on the original ROM → `diagnostics\` (new folder) | writes reports only |
| `SelfTest` | runs RomRecon's synthetic tests (no ROM) | build output only |
| `BackupRetroArchSaves` | copies your save/state files for `-RomPath`'s game into `backups\retroarch_<time>\` | creates a new backup folder; **sources untouched** |
| `LaunchIsolated` | prints the isolated launch plan; with `-Launch` starts RetroArch | creates files under `emulator\retroarch\`; waits for RetroArch to exit and reports whether your folders changed |

Parameters: `-WorkspaceRoot`, `-RomPath`, `-RetroArchPath` (folder or `retroarch.exe`), `-RetroArchConfig`, `-RomSearchPath` (extra folders to scan), `-ExperimentalRom`, `-CorePath`, `-Launch`, `-InstallMissing`, `-NonInteractive`, `-AssumeYes`. Full help: `Get-Help .\tools\windows\Setup-ConquestDev.ps1 -Full`.

## 5. Recommended routine

```powershell
# 0. one-time setup (copies the ROM, verifies it)
.\tools\windows\Setup-ConquestDev.ps1

# 1. BEFORE any experiment: back up your real playthrough (close RetroArch first)
.\tools\windows\Setup-ConquestDev.ps1 -Action BackupRetroArchSaves -RomPath "C:\Games\Pokemon Conquest.nds"

# 2. read-only analysis of the verified copy
.\tools\windows\Setup-ConquestDev.ps1 -Action Recon

# 3. later: run an experimental ROM in a fully separate profile (dry run first)
.\tools\windows\Setup-ConquestDev.ps1 -Action LaunchIsolated -ExperimentalRom "$HOME\PokemonConquestDev\experimental\test.nds"
.\tools\windows\Setup-ConquestDev.ps1 -Action LaunchIsolated -ExperimentalRom "$HOME\PokemonConquestDev\experimental\test.nds" -Launch
```

**Restoring a backup** is deliberately manual: close RetroArch and copy files back yourself. The script never restores or overwrites.

**Your playthrough itself** keeps using your normal RetroArch exactly as today. The setup never edits your `retroarch.cfg`, saves, states, playlists or cores.

## 6. Where RetroArch keeps things, and what is unverified

The script reads `retroarch.cfg` (next to `retroarch.exe` for portable installs, else `%APPDATA%\RetroArch\retroarch.cfg`) and resolves `savefile_directory`, `savestate_directory`, `libretro_directory`, `playlist_directory` (`:\saves` means "relative to the RetroArch folder"; `default` means the stock sub-folder). Per-core sub-folders (`sort_savefiles_enable`) are searched recursively, and saves "next to the content" (`savefiles_in_content_dir`) are looked up only when the config enables that.

* **[S]** The `--config`, `--appendconfig` (applied *after* the main config, so it wins) and `-L` command-line options are documented in the RetroArch man page (Arch `retroarch 1.22.2`) and libretro CLI guide.
* **[U] — verify on your install:** the exact *config key names* used in the override file (`savefile_directory`, `savestate_directory`, `playlist_directory`, `rgui_config_directory`, `core_options_path`, `screenshot_directory`, `history_list_enable`, `savefiles_in_content_dir`, `savestates_in_content_dir`, `sort_*`, `savestate_auto_save/load`, `config_save_on_exit`) were written from memory of RetroArch's config format and could not be checked against your RetroArch version here. The tripwire protects you: after an isolated run the script reports whether your save/state/playlist folders changed, and **you should do the first isolated run only after a verified backup**. If a key is wrong, the tripwire will tell you; the fix is a one-line edit to `Get-IsolatedLaunchPlan`.
* **[U]** The libretro core file name — "melonDS DS" (`melondsds_libretro.dll`) versus the older "melonDS" (`melonds_libretro.dll`) — is matched with `melonds*_libretro.dll`; both are accepted **[S: docs.libretro.com lists both cores]**.
* **[U]** Whether the melonDS core writes anything outside the save/state folders (e.g. under RetroArch's `system\` folder in DSi mode). The tripwire does not watch `system\` (BIOS/firmware live there); NDS cartridge play is expected not to write there **[H]**.

## 7. Tools

| Tool | Need | How to get | Status |
|---|---|---|---|
| Windows PowerShell 5.1 or PowerShell 7 | required | built in / `winget install --id Microsoft.PowerShell -e` | 7.6 **[C]** tested locally; **Windows PowerShell 5.1.26100 [C]**: 51/51 tests pass on a Windows CI runner (first run 49/51; the 2 failures were a test-helper issue, now fixed) |
| git | required to fetch updates | `winget install --id Git.Git -e` | winget id seen on winstall.app **[S]** |
| .NET SDK 10 | required for RomRecon/tests | `winget install --id Microsoft.DotNet.SDK.10 -e` | id seen **[S]** |
| RetroArch + melonDS core | you already have it | — | detected, never modified |
| melonDS (standalone) | recommended, isolated testing | `winget install --id melonDS.melonDS -e` | id seen **[S]** |
| DeSmuME | optional (debugger / Lua) | download from desmume.org | no verified winget id; site was unreachable to the author **[U]** |
| ndstool / Python+ndspy | optional cross-checks | devkitPro / `pip install ndspy` | — |
| Ghidra | later (disassembly) | ghidra-sre.org; set `GHIDRA_INSTALL_DIR` | — |

`-InstallMissing` only installs tools whose winget id was actually seen (git, .NET 10, melonDS, Python 3.12) and asks for each. Re-open PowerShell afterwards so `PATH` updates apply.

## 8. Troubleshooting

| Symptom | Fix |
|---|---|
| "running scripts is disabled" | use the `-ExecutionPolicy Bypass -File` form above |
| "is not digitally signed" after ZIP download | `Get-ChildItem -Recurse . \| Unblock-File` |
| RetroArch not found | `-RetroArchPath "D:\Emu\RetroArch"` (folder or exe) and, if portable config elsewhere, `-RetroArchConfig` |
| ROM is a `.zip`/`.7z` | extract the `.nds` first; the script rejects archives |
| Game code warning | only VPYT (NA), VPYJ (JP), VPYP (EU) are recognised Conquest codes |
| "header CRC mismatch" | the dump may be modified, trimmed or damaged; analysis still works but treat results with care |
| "workspace is inside a git working tree" | choose a different `-WorkspaceRoot` |
| `dotnet` not found right after installing | open a new PowerShell window |

To remove everything: close all programs and delete the `PokemonConquestDev` folder yourself (Explorer will ask to confirm for the read-only ROM copy). The script never deletes.

## 9. What is automated vs. what you run

See the PR description for the owner-facing summary. In short: **fully automated** — tool detection, folder creation, ROM validation/copy/verification/manifest, reports, isolated-profile generation, safety checks, 51 Pester tests, 40 RomRecon tests, CI. **Needs you at the keyboard** — choosing the ROM, confirming prompts, typing `BACKUP`, closing RetroArch before a backup, installing tools, the first real run of RomRecon and the first isolated emulator run (the script's tests have run on a Windows CI runner but not on your laptop, and nothing has run against a real ROM or real RetroArch).
