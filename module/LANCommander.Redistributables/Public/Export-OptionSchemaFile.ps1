<#
.SYNOPSIS
    Renders a schema change report as markdown, for pull request bodies.
.DESCRIPTION
    Options added upstream that carry no overlay curation are called out
    explicitly, because those are the ones a human still needs to describe.
#>
function Export-OptionSchemaFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Report,
        [string] $Version
    )

    $lines = [System.Collections.Generic.List[string]]::new()

    if ($Version) { $lines.Add("Upstream version **$Version**.") ; $lines.Add('') }

    $sections = [ordered] @{
        Added          = 'Options added upstream'
        Removed        = 'Options removed upstream'
        DefaultChanged = 'Defaults changed upstream'
        Excluded       = 'Options excluded by the overlay'
        StaleCuration  = 'Overlay entries with no matching option (stale curation)'
    }

    foreach ($key in $sections.Keys) {
        $items = @($Report[$key])
        if ($items.Count -eq 0) { continue }

        $lines.Add("### $($sections[$key]) ($($items.Count))")
        $lines.Add('')
        foreach ($item in $items) { $lines.Add("- ``$item``") }
        $lines.Add('')
    }

    $uncurated = @($Report['Uncurated'])

    if ($uncurated.Count -gt 0) {
        $lines.Add("### Uncurated options ($($uncurated.Count))")
        $lines.Add('')
        $lines.Add('These have no entry in `Schema.Overlay.yml`, so they ship with whatever the parser inferred. Add a `DisplayName` and `Description` for any that an administrator would otherwise have to guess at.')
        $lines.Add('')
        foreach ($item in $uncurated) { $lines.Add("- ``$item``") }
        $lines.Add('')
    }

    if ($lines.Count -eq 0) { $lines.Add('No schema changes.') }

    return ($lines -join "`n")
}
