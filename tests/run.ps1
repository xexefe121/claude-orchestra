$ErrorActionPreference = 'Stop'
try {
    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'codex-run-tests.ps1') 2>&1)
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        Write-Output 'PASS codex-run-tests.ps1'
        exit 0
    }
    $detail = @($output | Select-Object -Last 1) -join ' '
    Write-Output "FAIL codex-run-tests.ps1: exit=$code $detail"
} catch {
    Write-Output "FAIL codex-run-tests.ps1: $($_.Exception.Message)"
}
exit 1
