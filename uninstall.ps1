$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$claudeRoot = Join-Path $env:USERPROFILE '.claude'
$skillsRoot = Join-Path $claudeRoot 'skills'
# Remove the current skill and any installed copy of the retired second skill.
# Moving each folder preserves a backup for recovery.
foreach ($name in @('orchestra', 'orchestra-claude')) {
    $path = Join-Path $skillsRoot $name
    if (Test-Path -LiteralPath $path) {
        $backup = $path + '.bak-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff')
        Move-Item -LiteralPath $path -Destination $backup
        Write-Output "Removed active skill; backup: $backup"
    } else { Write-Output "Already absent: $name" }
}
foreach ($name in @('AGENTS.md', 'CLAUDE.md')) {
    $path = Join-Path $claudeRoot $name
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $current = [IO.File]::ReadAllText($path, $utf8)
    $updated = [regex]::Replace($current, '(?ms)^<!-- orchestra:start -->\r?\n.*?^<!-- orchestra:end -->[^\S\r\n]*(?:\r?\n|\z)', '')
    $updated = [regex]::Replace($updated, '(?ms)^<!-- orchestra:git:start -->\r?\n.*?^<!-- orchestra:git:end -->[^\S\r\n]*(?:\r?\n|\z)', '')
    if ($updated -ne $current) {
        Copy-Item -LiteralPath $path -Destination ($path + '.bak-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff'))
        [IO.File]::WriteAllText($path, $updated, $utf8)
        Write-Output "Rule removed: $path"
    }
}
Write-Output 'Uninstalled. Backups remain beside the original folders and rule files.'
