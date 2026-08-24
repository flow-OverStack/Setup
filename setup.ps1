# Thin wrapper so `.\setup.ps1` works from PowerShell - runs setup.sh under
# Git Bash, which ships with Git for Windows. See setup.sh for the real logic.
$bash = Get-Command bash -ErrorAction SilentlyContinue
if (-not $bash) {
    Write-Error "Git Bash not found on PATH. Install Git for Windows (https://git-scm.com/download/win), or run setup.sh directly from an existing Git Bash / WSL shell."
    exit 1
}
& $bash.Source -lc "./setup.sh $($args -join ' ')"
exit $LASTEXITCODE
