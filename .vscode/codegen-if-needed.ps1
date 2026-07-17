$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$srcRoot = Join-Path $repoRoot "src"
$stampFile = Join-Path $PSScriptRoot ".codegen-stamp"

# Files that can change the generated FRB bindings or freezed/json_serializable output.
$watched = @(
    Get-ChildItem -Path (Join-Path $srcRoot "rust\src\api") -Recurse -Filter "*.rs" -File
    Get-Item (Join-Path $srcRoot "flutter_rust_bridge.yaml") -ErrorAction SilentlyContinue
    Get-ChildItem -Path (Join-Path $srcRoot "lib") -Recurse -Filter "*.dart" -File |
        Where-Object {
            $_.FullName -notmatch '\\src\\rust\\' -and
            $_.Name -notmatch '\.(g|freezed)\.dart$'
        }
) | Where-Object { $_ -ne $null }

$latest = ($watched | Measure-Object -Property LastWriteTimeUtc -Maximum).Maximum

$needsRun = $true
if ((Test-Path $stampFile) -and $latest) {
    $stampTime = (Get-Item $stampFile).LastWriteTimeUtc
    if ($latest -le $stampTime) {
        $needsRun = $false
    }
}

if (-not $needsRun) {
    Write-Host "codegen-if-needed: no changes under src/rust/src/api or src/lib since last run, skipping."
    exit 0
}

Write-Host "codegen-if-needed: changes detected, running flutter_rust_bridge_codegen + build_runner..."

Push-Location $srcRoot
try {
    flutter_rust_bridge_codegen generate
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    dart run build_runner build
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Pop-Location
}

New-Item -ItemType File -Path $stampFile -Force | Out-Null
