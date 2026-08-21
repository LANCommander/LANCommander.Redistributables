<#
.SYNOPSIS
    Parses INI-style configuration into parsed option records.
.DESCRIPTION
    Generic over the file, not over the redistributable: every key present becomes
    an option, so when upstream adds a setting it appears in the schema on the next
    run with no code change.

    Section headers become group nodes; keys outside any section land at the root.

    ChoiceCommentPattern lets a redistributable harvest valid values out of the
    comments that sit above a key -- a very common convention (dgVoodoo.conf
    documents its allowed values this way). The pattern must expose a named group
    'choices'; the captured text is split on commas or pipes. This keeps odd
    conventions declarative instead of requiring a bespoke parser.
#>
function ConvertFrom-IniConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Content,
        [string] $ChoiceCommentPattern,
        [string] $Source,
        [switch] $NoSections,
        [switch] $IncludeCommentedKeys
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $commentBuffer = [System.Collections.Generic.List[string]]::new()
    $section = $null

    foreach ($rawLine in ($Content -split "`r?`n")) {
        $line = $rawLine.Trim()

        if ([string]::IsNullOrEmpty($line)) {
            # A blank line ends a comment block, so comments only ever attach to
            # the key immediately below them.
            $commentBuffer.Clear()
            continue
        }

        if ($line.StartsWith(';') -or $line.StartsWith('#')) {
            $commented = $line.TrimStart(';', '#').Trim()

            # Many projects ship a sample config with every option commented out at
            # its default value -- OpenAL Soft's alsoftrc.sample is 88 of them. Those
            # lines are the documented option set, so treating them as real keys is
            # what makes such a file yield a schema at all. Gated because in a normal
            # config a commented-out key means "deliberately not set".
            if ($IncludeCommentedKeys -and $commented -match '^(?<key>[A-Za-z0-9_.\-]+)\s*=\s*(?<value>.*)$') {
                $key = $Matches['key']
                $value = $Matches['value'].Trim().Trim('"')

                $comment = ($commentBuffer -join ' ').Trim()
                $choices = Get-ChoiceFromComment -Comment $comment -Pattern $ChoiceCommentPattern

                $segments = if ($section) {
                    @((ConvertTo-OptionKey -Key $section), (ConvertTo-OptionKey -Key $key))
                }
                else {
                    @(ConvertTo-OptionKey -Key $key)
                }

                $results.Add((New-ParsedOption -Segments $segments -Value $value -Choices $choices -Comment $comment -Source $Source))

                $commentBuffer.Clear()
                continue
            }

            $commentBuffer.Add($commented)
            continue
        }

        if (-not $NoSections -and $line.StartsWith('[') -and $line.Contains(']')) {
            $section = $line.TrimStart('[').Split(']')[0].Trim()
            $commentBuffer.Clear()
            continue
        }

        $eq = $line.IndexOf('=')
        if ($eq -le 0) { $commentBuffer.Clear(); continue }

        $key = $line.Substring(0, $eq).Trim()
        $value = $line.Substring($eq + 1).Trim()

        # Strip a trailing inline comment, but only when it is clearly one --
        # values legitimately contain '#' and ';' (paths, colour codes).
        if ($value -match '^(?<value>.*?)\s+[;#]\s*(?<comment>.*)$') {
            $inline = $Matches['comment']
            $value = $Matches['value'].Trim()
        }
        else {
            $inline = $null
        }

        $value = $value.Trim('"')

        $comment = ($commentBuffer -join ' ').Trim()
        if ($inline) { $comment = if ($comment) { "$comment $inline" } else { $inline } }

        $choices = Get-ChoiceFromComment -Comment $comment -Pattern $ChoiceCommentPattern

        $segments = if ($section) {
            @((ConvertTo-OptionKey -Key $section), (ConvertTo-OptionKey -Key $key))
        }
        else {
            @(ConvertTo-OptionKey -Key $key)
        }

        $results.Add((New-ParsedOption -Segments $segments -Value $value -Choices $choices -Comment $comment -Source $Source))

        $commentBuffer.Clear()
    }

    return $results
}

<#
.SYNOPSIS
    Extracts a choice list out of a comment using the configured pattern.
#>
function Get-ChoiceFromComment {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string] $Comment,
        [AllowNull()][AllowEmptyString()][string] $Pattern
    )

    if ([string]::IsNullOrWhiteSpace($Comment) -or [string]::IsNullOrWhiteSpace($Pattern)) {
        return @()
    }

    if ($Comment -notmatch $Pattern) { return @() }

    if (-not $Matches.ContainsKey('choices')) {
        Write-Warning "ChoiceCommentPattern matched but exposes no 'choices' named group; ignoring"
        return @()
    }

    $captured = $Matches['choices']

    return @(
        $captured -split '[,|]' |
            ForEach-Object { $_.Trim().Trim('"', "'", '.') } |
            Where-Object { $_ }
    )
}
