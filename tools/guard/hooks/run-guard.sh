#!/bin/sh
# Runs the ROM-handling guard with whatever PowerShell is available. FAILS CLOSED: if no PowerShell is found the commit/push is refused.
# See AGENTS.md. Bypassing hooks (--no-verify) is a violation of the project's ROM-handling rules.
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../Test-RepoForRomData.ps1"
if command -v pwsh >/dev/null 2>&1; then PS=pwsh
elif command -v powershell.exe >/dev/null 2>&1; then PS=powershell.exe
elif command -v powershell >/dev/null 2>&1; then PS=powershell
else
    echo "ROM guard: neither pwsh nor powershell was found - refusing (fail closed). Install PowerShell or fix PATH." >&2
    exit 1
fi
case "$PS" in
    powershell.exe) SCRIPT="$(cygpath -w "$SCRIPT" 2>/dev/null || echo "$SCRIPT")" ;;
esac
exec "$PS" -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT" "$@"
