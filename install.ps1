param(
    [string]$Destination = (Join-Path $HOME '.dsh\skills\computer-use')
)

$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot

if (-not (Test-Path (Join-Path $source 'SKILL.md'))) {
    throw "SKILL.md not found next to install.ps1 ($source)"
}

New-Item -ItemType Directory -Path $Destination -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Destination 'scripts') -Force | Out-Null

Copy-Item (Join-Path $source 'SKILL.md') (Join-Path $Destination 'SKILL.md') -Force
Get-ChildItem (Join-Path $source 'scripts') -Filter '*.ps1' | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $Destination 'scripts') -Force
}

$files = Get-ChildItem $Destination -Recurse -File
"Installed computer-use skill to $Destination"
$files | ForEach-Object { "  " + $_.FullName.Replace($Destination, '').TrimStart('\') + "  ($($_.Length) bytes)" }
"Open a new DSH session (or reload the skill catalog) to pick it up."
