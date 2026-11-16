<#
.SYNOPSIS
    Turns on the ROM-handling git hooks for THIS clone (pre-commit + pre-push). Run once per clone.

.DESCRIPTION
    Sets the clone-local git setting core.hooksPath to tools/guard/hooks. Changes nothing else, touches no files outside .git/config,
    and makes no network calls. To turn the hooks off again (not recommended): git config --local --unset core.hooksPath
    Hooks can be bypassed with --no-verify; CI re-runs the same check on every pull request. See AGENTS.md.
#>
[CmdletBinding()]
param([string]$RepoRoot)
$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = (& git rev-parse --show-toplevel).Trim() }
$hooks = [IO.Path]::Combine($RepoRoot, 'tools', 'guard', 'hooks')
if (-not (Test-Path -LiteralPath $hooks)) { throw "Hooks folder not found: $hooks" }
& git -C $RepoRoot config --local core.hooksPath 'tools/guard/hooks'
$now = (& git -C $RepoRoot config --local --get core.hooksPath)
if ($now -ne 'tools/guard/hooks') { throw "core.hooksPath is '$now', expected 'tools/guard/hooks'." }
Write-Host "ROM guard hooks enabled for this clone (core.hooksPath = $now)." -ForegroundColor Green
Write-Host 'Test it:  git stash; create a file named notes.txt that is a renamed .nds, "git add" it, "git commit" - it must be refused.'
