# Thin wrapper so `.\setup.ps1` works from PowerShell - runs setup.sh under
# Git Bash, which ships with Git for Windows. See setup.sh for the real logic.
#
# `Get-Command bash` picks whichever bash.exe is first on PATH, which on many
# machines is C:\Windows\System32\bash.exe (the WSL launcher), not Git Bash.
# Under WSL, paths become /mnt/c/..., there's no Docker socket unless WSL
# integration is on, and Windows-installed node/git aren't on PATH - so filter
# those out and prefer an actual Git for Windows bash.exe.
$bashCandidates = Get-Command bash -All -ErrorAction SilentlyContinue |
    Where-Object { $_.Source -notmatch '\\System32\\bash\.exe$' -and $_.Source -notmatch '\\WindowsApps\\bash\.exe$' }
$bashPath = ($bashCandidates | Select-Object -First 1).Source

# Git's own bash.exe often isn't on PATH even when Git for Windows is installed
# (its installer adds cmd/ for git.exe but not always bin/ for bash.exe) - fall
# back to the well-known install locations before giving up.
if (-not $bashPath) {
    $knownPaths = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LocalAppData\Programs\Git\bin\bash.exe"
    )
    $bashPath = $knownPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $bashPath) {
    Write-Error "Git Bash not found. Install Git for Windows (https://git-scm.com/download/win), or run setup.sh directly from an existing Git Bash shell."
    exit 1
}
& $bashPath -lc "./setup.sh $($args -join ' ')"
exit $LASTEXITCODE
