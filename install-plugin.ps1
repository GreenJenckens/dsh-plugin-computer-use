param(
    [string]$Profile = 'desktop',
    [string]$InstallRoot = (Join-Path $HOME '.dsh\plugins\computer-use'),
    [switch]$NoPnpm,
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'plugin\dsh-plugin-computer-use'
if (-not (Test-Path (Join-Path $source 'package.json'))) { throw "plugin package not found at $source" }

$dshHome = Join-Path $HOME '.dsh'
$profileDir = Join-Path $dshHome (Join-Path 'profiles' $Profile)
$target = Join-Path $InstallRoot 'dsh-plugin-computer-use'

function Get-TreeHash {
    param([string]$Dir)
    $files = @(Get-ChildItem $Dir -Recurse -File | Where-Object {
        $rel = $_.FullName.Substring($Dir.Length).TrimStart('\').Replace('\', '/')
        $rel -notin @('build.json') -and ($rel -like 'lib/*' -or $rel -in @('package.json', 'cordis.patch.yml', 'README.md', 'CHANGELOG.md', 'SECURITY.md'))
    } | Sort-Object FullName)
    $lines = @(foreach ($file in $files) {
        $rel = $file.FullName.Substring($Dir.Length).TrimStart('\').Replace('\', '/')
        $rel + ':' + (Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    })
    [Array]::Sort($lines, [System.StringComparer]::Ordinal)
    return ($lines -join "`n")
}

function Get-BuildHash {
    param([string]$Dir)
    $tree = Get-TreeHash $Dir
    return [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($tree))).Replace('-', '').ToLowerInvariant()
}

if ($Verify) {
    if (-not (Test-Path $target)) { throw "installed plugin not found at $target" }
    $installed = Get-BuildHash $target
    $sourceHash = Get-BuildHash $source
    if ($installed -ne $sourceHash) {
        "VERIFY FAILED: installed $installed != source $sourceHash"
        exit 1
    }
    $manifestPath = Join-Path $target 'build.json'
    if (-not (Test-Path $manifestPath)) {
        "VERIFY FAILED: installed build.json is missing"
        exit 1
    }
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $installedVersion = (Get-Content (Join-Path $target 'package.json') -Raw | ConvertFrom-Json).version
    if ($manifest.buildHash -ne $installed) {
        "VERIFY FAILED: build.json hash $($manifest.buildHash) != tree $installed"
        exit 1
    }
    if ($manifest.version -ne $installedVersion) {
        "VERIFY FAILED: build.json version $($manifest.version) != package $installedVersion"
        exit 1
    }
    "VERIFY OK: $installed ($installedVersion)"
    exit 0
}

if (-not (Test-Path (Join-Path $profileDir 'package.json'))) { throw "profile '$Profile' not found at $profileDir" }

if (Test-Path $target) {
    $backup = $target + '.bak_' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Move-Item $target $backup -Force
    "previous install moved to $backup"
}
New-Item -ItemType Directory -Path $target -Force | Out-Null

Copy-Item (Join-Path $source 'package.json') $target -Force
Copy-Item (Join-Path $source 'cordis.patch.yml') $target -Force
Copy-Item (Join-Path $source 'README.md') $target -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $source 'CHANGELOG.md') $target -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $source 'SECURITY.md') $target -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $source 'LICENSE') $target -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $source 'lib') $target -Recurse -Force

$version = (Get-Content (Join-Path $target 'package.json') -Raw | ConvertFrom-Json).version
$buildHash = Get-BuildHash $target
$filesJson = @{}
foreach ($file in @(Get-ChildItem $target -Recurse -File)) {
    $rel = $file.FullName.Substring($target.Length).TrimStart('\').Replace('\', '/')
    $filesJson[$rel] = (Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
$build = [ordered]@{ version = $version; buildHash = $buildHash; installed = (Get-Date).ToString('o'); files = $filesJson }
[IO.File]::WriteAllText((Join-Path $target 'build.json'), ($build | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
"copied plugin -> $target (version $version, build $($buildHash.Substring(0, 12)))"

$manifestPath = Join-Path $profileDir 'package.json'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Copy-Item $manifestPath "$manifestPath.bak_computeruse_$stamp" -Force
foreach ($lock in 'pnpm-lock.yaml', 'pnpm-workspace.yaml') {
    $lockPath = Join-Path $profileDir $lock
    if (Test-Path $lockPath) { Copy-Item $lockPath "$lockPath.bak_computeruse_$stamp" -Force }
}
$profileJson = Get-Content $manifestPath -Raw | ConvertFrom-Json
$deps = [ordered]@{}
if ($profileJson.dependencies) { foreach ($p in $profileJson.dependencies.PSObject.Properties) { $deps[$p.Name] = $p.Value } }
$deps['dsh-plugin-computer-use'] = 'link:' + ($target -replace '\\', '/')
$profileJson.dependencies = [pscustomobject]$deps
$bundles = @()
if ($profileJson.dsh.profile.bundles) { $bundles = @($profileJson.dsh.profile.bundles) }
if (-not ($bundles -contains 'dsh-plugin-computer-use')) { $bundles += 'dsh-plugin-computer-use' }
$profileJson.dsh.profile.bundles = $bundles
[IO.File]::WriteAllText($manifestPath, ($profileJson | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
"profile '$Profile' depends on link:$target"

if (-not $NoPnpm) {
    Push-Location $profileDir
    try {
        $pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
        if ($null -eq $pnpm) { throw 'pnpm not found in PATH' }
        & $pnpm.Source install --ignore-scripts 2>&1 | ForEach-Object { "  $_" }
        if ($LASTEXITCODE -ne 0) { throw "pnpm install failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
    $linked = Join-Path $profileDir 'node_modules\dsh-plugin-computer-use'
    if (Test-Path $linked) { "linked into $linked" } else { "WARNING: link not found at $linked" }
}

""
"Run install-plugin.ps1 -Verify to compare source and installed hashes."
"Rollback: restore $manifestPath.bak_computeruse_$stamp and rerun pnpm install."


