<#
.SYNOPSIS
    Parses a Windows .reg export into parsed option records.
.DESCRIPTION
    Registry-configured redistributables are common enough to be worth a first
    class parser. Key paths become groups (the hive prefix is dropped, since it
    is constant across the file and adds a useless nesting level), value names
    become options.

    dword: values are decoded to their decimal form so type inference sees an int;
    hex: byte blobs are surfaced as strings, since OptionSchema has no binary type.
#>
function ConvertFrom-RegistryConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Content,
        [string] $Source
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $prefix = @()

    foreach ($rawLine in ($Content -split "`r?`n")) {
        $line = $rawLine.Trim()

        if ([string]::IsNullOrEmpty($line) -or $line.StartsWith(';') -or $line -like 'Windows Registry Editor*' -or $line -eq 'REGEDIT4') {
            continue
        }

        if ($line.StartsWith('[') -and $line.EndsWith(']')) {
            $path = $line.Trim('[', ']').TrimStart('-')

            # Drop the hive -- it is the same for every key in a given export.
            $parts = @($path.Split([char] 0x5C) | Where-Object { $_ }) | Select-Object -Skip 1

            $prefix = @($parts | ForEach-Object { ConvertTo-OptionKey -Key $_ })
            continue
        }

        if ($line -notmatch '^(?<name>"[^"]*"|@)\s*=\s*(?<value>.*)$') { continue }

        $name = $Matches['name'].Trim('"')
        $raw = $Matches['value'].Trim()

        if ($name -eq '@' -or [string]::IsNullOrEmpty($name)) { $name = 'Default' }

        $value = switch -Regex ($raw) {
            '^dword:(?<hex>[0-9a-fA-F]+)$' { [string] [Convert]::ToInt64($Matches['hex'], 16); break }
            # Literal .Replace rather than -replace: a .reg string escapes a
            # backslash as '\\' and a quote as '\"', and expressing those as regex
            # patterns needs four levels of escaping for no benefit.
            '^"(?<str>.*)"$'               { $Matches['str'].Replace('\"', '"').Replace('\\', '\'); break }
            '^hex'                         { $raw; break }
            '^-$'                          { ''; break }
            default                        { $raw }
        }

        $segments = $prefix + (ConvertTo-OptionKey -Key $name)
        $results.Add((New-ParsedOption -Segments $segments -Value $value -Source $Source))
    }

    return $results
}
