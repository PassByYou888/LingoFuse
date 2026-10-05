# clean.ps1 - Remove build artifacts from the LingoFuse Julia binding.
#
# Idempotent: missing files or directories do not cause an error.
#
# Removes, from c_ext/ and c_ext/real/:
#   *.dll, *.o, *.a, *.dll.a, *.so, *.dylib
#
# Also removes Julia precompilation caches under src/ (if any), so
# that a subsequent `using LingoFuse` recompiles from scratch.

$ErrorActionPreference = "SilentlyContinue"

$here    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$mockDir = Join-Path $here "c_ext"
$realDir = Join-Path $mockDir "real"

Write-Host "=== LingoFuse Julia Binding - Clean ===" -ForegroundColor Magenta
Write-Host ""

$patterns = @("*.dll", "*.o", "*.a", "*.dll.a", "*.so", "*.dylib")
$removed  = 0

foreach ($dir in @($mockDir, $realDir)) {
    if (-not (Test-Path $dir)) {
        continue
    }
    foreach ($pat in $patterns) {
        Get-ChildItem -Path $dir -Filter $pat -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                Write-Host "  removed: $($_.FullName)" -ForegroundColor Gray
                $script:removed++
            }
    }
}

# --- Optional: Julia precompilation caches -------------------------------

$srcDir = Join-Path $here "src"
if (Test-Path $srcDir) {
    $cacheFiles = Get-ChildItem -Path $srcDir -Filter "*.ji" -File -ErrorAction SilentlyContinue
    foreach ($f in $cacheFiles) {
        Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
        Write-Host "  removed: $($f.FullName)" -ForegroundColor Gray
        $script:removed++
    }
}

Write-Host ""
if ($removed -eq 0) {
    Write-Host "  (nothing to clean)" -ForegroundColor DarkGray
} else {
    Write-Host "  total removed: $removed file(s)" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done." -ForegroundColor Magenta