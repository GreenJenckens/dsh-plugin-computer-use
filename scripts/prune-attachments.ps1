param(
    [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }),
    [int]$OlderThanDays = -1,
    [switch]$Apply,
    [switch]$Json,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
if ($OlderThanDays -lt 0) { $OlderThanDays = 30 }
if ($Apply -and $OlderThanDays -lt 7 -and -not $Force) {
    throw 'refusing to delete attachments younger than 7 days without -Force'
}

$homePath = [IO.Path]::GetFullPath($DshHome)
$objectsDir = Join-Path $homePath 'attachments\v1\objects'
if (-not (Test-Path $objectsDir)) {
    $report = [ordered]@{
        ok = $true; home = $homePath; dryRun = (-not $Apply); scanned = 0; sessions = 0
        referenced = 0; objects = 0; candidates = 0; deleted = 0; errors = @()
    }
    if ($Json) { $report | ConvertTo-Json -Depth 6 -Compress } else { 'no attachment objects found' }
    exit 0
}

$helper = Join-Path $PSScriptRoot '..\plugin\dsh-plugin-computer-use\lib\scripts\collect-attachment-refs.mjs'
if (-not (Test-Path $helper)) { throw "reference helper not found at $helper" }
$node = (Get-Command node -ErrorAction Stop).Source
$raw = & $node $helper --dsh-home $homePath 2>&1
if ($LASTEXITCODE -ne 0) { throw ('reference scan failed: ' + ($raw -join ' ')) }
$scan = ($raw -join "`n") | ConvertFrom-Json

$referenced = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($ref in @($scan.refs)) { if ($ref) { [void]$referenced.Add([string]$ref) } }

$scanErrors = @($scan.errors)
if ($scanErrors.Count -gt 0 -and -not $Force) {
    $detail = ($scanErrors | ForEach-Object { [string]$_.error }) -join '; '
    throw ('refusing to prune: reference scan had errors, so a referenced object could be deleted (use -Force only after inspection): ' + $detail)
}
if ($scan.files -gt 0 -and $scan.sessions -eq 0 -and -not $Force) {
    throw 'refusing to prune: files were found but no session was readable; references may be unknown (use -Force only after inspection)'
}
if ($scan.sessions -gt 0 -and $referenced.Count -eq 0 -and -not $Force) {
    throw 'refusing to prune: sessions were scanned but no attachment references were found (use -Force only after inspection)'
}

$objectsRoot = [IO.Path]::GetFullPath($objectsDir).TrimEnd('\') + '\'
$cutoff = (Get-Date).AddDays(-$OlderThanDays)
$objects = @(Get-ChildItem $objectsDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match '^[0-9a-f]{64}$' -and $_.DirectoryName -match '\\[0-9a-f]{2}$'
})
$candidates = @()
$deleted = 0
$errors = @()
foreach ($object in $objects) {
    $full = [IO.Path]::GetFullPath($object.FullName)
    if (-not $full.StartsWith($objectsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $errors += ('path escaped objects dir: ' + $full)
        continue
    }
    if ($referenced.Contains($object.Name)) { continue }
    if ($object.LastWriteTime -gt $cutoff) { continue }
    $candidates += $object
    if ($Apply) {
        try { Remove-Item $full -Force -ErrorAction Stop; $deleted++ }
        catch { $errors += ('delete failed: ' + $full + ': ' + $_.Exception.Message) }
    }
}

$report = [ordered]@{
    ok = ($errors.Count -eq 0)
    home = $homePath
    dryRun = (-not $Apply)
    olderThanDays = $OlderThanDays
    scanned = $scan.files
    sessions = $scan.sessions
    referenced = $referenced.Count
    objects = $objects.Count
    candidates = $candidates.Count
    deleted = $deleted
    errors = $errors
}

if ($Json) {
    $report | ConvertTo-Json -Depth 6 -Compress
} else {
    'attachment prune ' + $(if ($Apply) { '(applied)' } else { '(dry-run)' })
    'home=' + $homePath
    'objects=' + $objects.Count + ' referenced=' + $referenced.Count + ' candidates=' + $candidates.Count + ' deleted=' + $deleted
    if ($errors.Count -gt 0) { 'errors:'; $errors | ForEach-Object { '  ' + $_ } }
}
if (-not $report.ok) { exit 1 }
