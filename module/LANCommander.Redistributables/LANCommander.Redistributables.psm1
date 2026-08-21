# Dot-sources every Private and Public script, then exports the Public surface.
# Private helpers stay module-scoped but remain visible to Pester via InModuleScope.

$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)
$public = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in ($private + $public)) {
    try {
        . $file.FullName
    }
    catch {
        throw "Failed to load $($file.FullName): $_"
    }
}

Export-ModuleMember -Function $public.BaseName
