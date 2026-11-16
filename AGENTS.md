# Project rules for every contributor and AI assistant (Pokémon Conquest Expanded)

These rules are **permanent**. They apply to humans, Claude, ChatGPT/Codex and any other tool or agent working on this repository.
Wherever practical they are enforced by **code**, not just by this text (see the table at the end). Changing them needs a pull request and
independent review, like any other change.

## ROM and game-data handling

1. **The ROM stays on the owner's computer.** Never upload, transmit, attach, commit or push a `.nds` file (or any other copy of the game) to
   GitHub, Claude, ChatGPT, cloud storage, e-mail, chat, an issue/PR, a gist, a paste site or any other external service.
2. **Everything derived from the ROM stays local too:** extracted assets, dumped tables, `gap.bin`, decompressed ARM9/overlay code
   (`*_decompressed.bin`, `arm9*.bin`, `overlay*.bin`), saves, save states, screenshots of copyrighted assets and RomRecon output folders.
3. **ROM processing runs on the owner's computer, never in a remote AI environment.** Scripts and tools may be *developed* anywhere, but anything that
   opens the real ROM is run by the owner locally (PowerShell on their laptop). AI assistants do not operate the owner's machine, do not
   request access to the ROM folder, and do not attach a computer/folder to a session without the owner explicitly asking.
4. **`PokemonConquestDev\original\` is read-only.** Experimental changes use *copies* in `experimental\` or `output\`. Originals are never edited,
   renamed, moved or deleted; tools open them with read access only and verify the SHA-256 before and after.
5. **The workspace lives outside the git repository and outside cloud-synchronised folders** (OneDrive, Dropbox, Google Drive, iCloud, Box, MEGA,
   pCloud, Nextcloud, ...). Default: `%USERPROFILE%\PokemonConquestDev`.
6. **Technical safeguards come first.** Rules are enforced with git ignore rules, content-based commit/push/CI checks, workspace-location checks,
   tools that are provably network-free, and a text-only exporter. If a rule can be checked by code, add the check.
7. **Only text-based diagnostics leave the machine**, and only after `tools/windows/Export-ShareableText.ps1` (or equivalent redaction and review).
   Sharing sizes, counts, offsets, hashes, addresses and `[PASS]/[FAIL]` lines is fine. Sharing bytes, dumps or assets is not.
8. **If a tool's execution location or network behaviour is uncertain, stop and verify before using it with the ROM.** Prefer tools with no network
   code (RomRecon has a test that proves it references no networking assembly). A command whose output flows to an AI session transmits that
   output: it must therefore print text diagnostics only, never ROM content.
9. **Preserve the existing gameplay setup.** Playnite → RetroArch → melonDS and its saves, states, configuration and game entries are never modified
   by development work. Development uses its own isolated RetroArch profile and save directories. A "Pokémon Conquest — Development" Playnite entry is
   an optional later step that needs the owner's approval.

## How AI assistants should work here

* Discover before changing; prefer read-only commands first; never assume a command succeeded without reading its output.
* Guide the owner **one local command at a time** and wait for the output. Provide complete scripts, not fragments, when something must be replaced.
* Check what is actually installed and configured (paths, versions, core, save locations); do not assume.
* Never merge or deploy. Use branches and pull requests; wait for the independent review.
* Mark every claim as confirmed, third-party, hypothesis or unknown (see `docs/expansion/`).
* Mandatory safety gates (backup verified, isolation verified) are pass/fail: if one fails, stop.

## Where each rule is enforced

| Rule | Enforcement in the repository |
|---|---|
| 1, 2 | `.gitignore` (ROM, save, state, dump, recon names); `tools/guard/Test-RepoForRomData.ps1` inspects **content** (an NDS header renamed `notes.txt` is still caught), run by the `pre-commit` and `pre-push` hooks (`tools/guard/Install-Guards.ps1` turns them on per clone) and by CI on every pull request; `tools/guard/binary-allowlist.txt` makes any new binary a reviewed decision |
| 3 | No tool in this repository sends data anywhere; ROM tools read local files and write local files. AI sessions have no machine attached unless the owner explicitly grants it |
| 4 | `Setup-ConquestDev.ps1` marks the original read-only, never overwrites or deletes (`FileMode.CreateNew`), `-Action Verify` re-hashes; `LaunchIsolated` refuses the original ROM; RomRecon opens ROMs read-only and fails if the hash changes |
| 5 | `Setup-ConquestDev.ps1` and RomRecon refuse git working trees and cloud-synchronised locations (names, sync markers, OneDrive variables and placeholder attributes, junctions/symlinks) |
| 6, 8 | Tests assert there are no network primitives in the scripts and no networking assembly or package in RomRecon; hooks fail closed |
| 7 | `Export-ShareableText.ps1` refuses binary/ROM-like files and redacts user names, paths, computer name, e-mail, credentials, tokens, IP/MAC |
| 9 | `LaunchIsolated` uses a copy of the RetroArch config plus overrides, refuses overlap with the real save/state folders and verifies the real folders were unchanged afterwards |

**Limits (be honest about them):** git hooks can be bypassed with `--no-verify` (CI will still flag it, but only after a push); heuristics for cloud folders
and redaction can miss things; nothing here can stop a person from uploading a file by hand. These rules are therefore also a commitment.
