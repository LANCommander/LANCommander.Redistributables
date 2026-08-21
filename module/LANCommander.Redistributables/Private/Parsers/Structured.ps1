<#
.SYNOPSIS
    Parses JSON or YAML configuration into parsed option records.
.DESCRIPTION
    Both formats deserialise to the same shape (nested dictionaries, arrays,
    scalars), so they share one walker.

    Deviation from ConfigToOptionSchemaService: that converter maps every array to
    Type 'choice', which misrepresents a repeated-value setting as a single pick.
    OptionSchema has had a real 'list' type since the compatibility-options work,
    so arrays map to scalar lists (with ItemType) or composite lists (with Fields),
    which is what the admin UI and Get-RedistributableOptions actually expect.
#>
function ConvertFrom-StructuredConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Content,
        [Parameter(Mandatory)][ValidateSet('json', 'yaml')][string] $Format,
        [string] $Source
    )

    if ([string]::IsNullOrWhiteSpace($Content)) { return @() }

    $root = if ($Format -eq 'json') {
        ConvertFrom-Json -InputObject $Content -AsHashtable -Depth 64
    }
    else {
        Initialize-YamlSupport
        ConvertFrom-Yaml -Yaml $Content -Ordered
    }

    $results = [System.Collections.Generic.List[object]]::new()

    if ($root -is [System.Collections.IDictionary]) {
        Read-StructuredNode -Node $root -Prefix @() -Results $results -Source $Source
    }
    else {
        Write-Warning "Config root in $Source is not an object; no options extracted"
    }

    return $results
}

function Read-StructuredNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Node,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Prefix,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]] $Results,
        [string] $Source
    )

    foreach ($key in $Node.Keys) {
        $segments = $Prefix + (ConvertTo-OptionKey -Key ([string] $key))
        $value = $Node[$key]

        if ($value -is [System.Collections.IDictionary]) {
            Read-StructuredNode -Node $value -Prefix $segments -Results $Results -Source $Source
            continue
        }

        if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
            $Results.Add((New-ParsedListOption -Segments $segments -Items @($value) -Source $Source))
            continue
        }

        $Results.Add((New-ParsedOption -Segments $segments -Value (ConvertTo-ScalarString $value) -Source $Source))
    }
}

<#
.SYNOPSIS
    Builds a list-typed parsed option from an array value.
#>
function New-ParsedListOption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]] $Segments,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Items,
        [string] $Source
    )

    $first = $Items | Select-Object -First 1

    if ($first -is [System.Collections.IDictionary]) {
        # Composite list -- infer the per-row schema from the first row. Presence of
        # Fields is what distinguishes composite from scalar lists to the SDK.
        $fields = [ordered] @{}

        foreach ($fieldKey in $first.Keys) {
            $fieldValue = ConvertTo-ScalarString $first[$fieldKey]

            $fields[(ConvertTo-OptionKey -Key ([string] $fieldKey))] = [ordered] @{
                Type    = Get-InferredOptionType -Value $fieldValue
                Default = $fieldValue
            }
        }

        $rows = foreach ($item in $Items) {
            $row = [ordered] @{}

            if ($item -is [System.Collections.IDictionary]) {
                foreach ($fieldKey in $item.Keys) {
                    $row[(ConvertTo-OptionKey -Key ([string] $fieldKey))] = ConvertTo-ScalarString $item[$fieldKey]
                }
            }

            $row
        }

        return [pscustomobject] @{
            Path     = ($Segments -join '.')
            Segments = $Segments
            Type     = 'list'
            Default  = @($rows)
            Fields   = $fields
            Source   = $Source
        }
    }

    $values = @($Items | ForEach-Object { ConvertTo-ScalarString $_ })
    $itemType = if ($values.Count -gt 0) { Get-InferredOptionType -Value $values[0] } else { 'string' }

    return [pscustomobject] @{
        Path     = ($Segments -join '.')
        Segments = $Segments
        Type     = 'list'
        ItemType = $itemType
        Default  = $values
        Source   = $Source
    }
}

<#
.SYNOPSIS
    Renders a deserialised scalar back to the string form OptionSchema stores.
#>
function ConvertTo-ScalarString {
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowNull()] $Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }

    return [string] $Value
}
