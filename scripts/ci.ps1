param(
    [ValidateSet('auto', 'local', 'hosted')]
    [string]$Mode = 'auto',
    [switch]$SkipGui,
    [switch]$Install,
    [string]$OutDir = 'test-results'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
if ($Mode -eq 'auto') { $Mode = if ($env:CI) { 'hosted' } else { 'local' } }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$results = @()
function Invoke-Stage {
    param([string]$Name, [scriptblock]$Body)
    $started = Get-Date
    $code = 0
    try { & $Body; $code = $LASTEXITCODE; if ($null -eq $code) { $code = 0 } }
    catch { Write-Host ("FAIL {0}: {1}" -f $Name, $_.Exception.Message); $code = 1 }
    $script:results += [ordered]@{
        name = $Name
        ok = ($code -eq 0)
        exitCode = $code
        seconds = [Math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    }
    if ($code -ne 0) { Write-Host ("FAIL {0} (exit {1})" -f $Name, $code) }
    else { Write-Host ("PASS {0}" -f $Name) }
}

Invoke-Stage 'build-json' { node scripts/make-build-json.mjs }
Invoke-Stage 'unit' { Push-Location plugin/dsh-plugin-computer-use; try { npm run test:unit } finally { Pop-Location } }

if ($Mode -eq 'local' -and -not $SkipGui) {
    Invoke-Stage 'tests' { Push-Location plugin/dsh-plugin-computer-use; try { npm test } finally { Pop-Location } }
    Invoke-Stage 'smoke' { Push-Location plugin/dsh-plugin-computer-use; try { npm run smoke } finally { Pop-Location } }
    Invoke-Stage 'matrix' { node scripts/matrix.mjs --json docs/v0.4-matrix.json }
    if (Test-Path (Join-Path $HOME '.dsh\plugins\computer-use\dsh-plugin-computer-use')) {
        Invoke-Stage 'verify' { powershell.exe -NoProfile -ExecutionPolicy Bypass -File install-plugin.ps1 -Verify }
    }
    if ($Install) {
        Invoke-Stage 'install' { powershell.exe -NoProfile -ExecutionPolicy Bypass -File install-plugin.ps1 }
    }
}

Invoke-Stage 'pack-check' { Push-Location plugin/dsh-plugin-computer-use; try { npm run pack:check } finally { Pop-Location } }

$summary = [ordered]@{
    mode = $Mode
    ok = -not ($results | Where-Object { -not $_.ok })
    at = (Get-Date).ToString('o')
    stages = $results
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $OutDir 'ci-summary.json') -Encoding UTF8
if (-not $summary.ok) { exit 1 }
Write-Host 'CI OK'
