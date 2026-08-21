<#
.SYNOPSIS
    Converts one or more upstream config files into a nested OptionSchema structure.
.DESCRIPTION
    Dispatches each file to a generic, format-level parser and assembles the flat
    dot-path results into the nested shape the SDK's OptionSchema model expects.

    Nothing here is specific to any redistributable: the parsers enumerate whatever
    keys are present, so when upstream adds a config setting it appears in the
    generated schema on the next run without any script change. Curation that a
    parser cannot infer -- friendly names, real descriptions, choice lists,
    regrouping -- is layered on afterwards by Merge-SchemaOverlay.

    Descriptions are taken from the comments surrounding each key where the format
    has them. That is deliberately different from ConfigToOptionSchemaService, which
    sets Description to the key name itself; echoing the key adds no information and
    makes it impossible to tell curated options from uncurated ones.
.PARAMETER Path
    Config files to parse. Missing files are skipped with a warning so a partial
    upstream layout change does not break the whole build.
.PARAMETER Format
    Force a parser. Defaults to auto-detection by extension, then by content.
.PARAMETER ChoiceCommentPattern
    Regex with a named 'choices' group, applied to the comment above each key to
    harvest valid values. Only meaningful for INI and key/value formats.
.PARAMETER CustomParserPath
    A redistributable-supplied Parse-Config.ps1 for formats nothing else handles.
    It receives -Content and -Source and must return parsed option records.
.EXAMPLE
    ConvertTo-OptionSchema -Path ./dgVoodoo.conf -ChoiceCommentPattern '(?i)values?\s*:\s*(?<choices>.+)'
#>
function ConvertTo-OptionSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][string[]] $Path,
        [ValidateSet('auto', 'ini', 'keyvalue', 'json', 'yaml', 'xml', 'reg', 'custom')]
        [string] $Format = 'auto',
        [string] $ChoiceCommentPattern,
        [string] $CustomParserPath
    )

    begin {
        $parsed = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($file in $Path) {
            if (-not (Test-Path -LiteralPath $file)) {
                Write-Warning "Config file not found, skipping: $file"
                continue
            }

            $content = Get-Content -LiteralPath $file -Raw -Encoding UTF8
            $source = Split-Path -Leaf $file

            $resolved = if ($Format -eq 'auto') {
                Get-ConfigFormat -Path $file -Content $content
            }
            else {
                $Format
            }

            Write-Verbose "Parsing $source as '$resolved'"

            $records = switch ($resolved) {
                'ini'      { ConvertFrom-IniConfig -Content $content -ChoiceCommentPattern $ChoiceCommentPattern -Source $source }
                'keyvalue' { ConvertFrom-IniConfig -Content $content -ChoiceCommentPattern $ChoiceCommentPattern -Source $source -NoSections }
                'json'     { ConvertFrom-StructuredConfig -Content $content -Format json -Source $source }
                'yaml'     { ConvertFrom-StructuredConfig -Content $content -Format yaml -Source $source }
                'xml'      { ConvertFrom-XmlConfig -Content $content -Source $source }
                'reg'      { ConvertFrom-RegistryConfig -Content $content -Source $source }
                'custom'   {
                    if (-not $CustomParserPath -or -not (Test-Path -LiteralPath $CustomParserPath)) {
                        throw "Format 'custom' requires -CustomParserPath pointing at a Parse-Config.ps1"
                    }
                    & $CustomParserPath -Content $content -Source $source
                }
                default    { throw "No parser for format '$resolved'" }
            }

            foreach ($record in $records) { $parsed.Add($record) }
        }
    }

    end {
        return ConvertTo-NestedSchema -ParsedOptions $parsed.ToArray()
    }
}

<#
.SYNOPSIS
    Determines which parser to use for a config file.
.DESCRIPTION
    Extension first, then content. The content sniff deliberately does not use the
    naive "starts with [ means JSON" rule from ConfigToOptionSchemaService -- INI
    files routinely start with a section header. A '[' only means JSON if the whole
    document actually parses as JSON.
#>
function Get-ConfigFormat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Content
    )

    switch -Regex ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '^\.(json|jsonc)$'            { return 'json' }
        '^\.(yml|yaml)$'              { return 'yaml' }
        '^\.(xml|config|xaml|plist)$' { return 'xml' }
        '^\.reg$'                     { return 'reg' }
        '^\.(ini|conf|cfg)$'          { return 'ini' }
    }

    $trimmed = $Content.TrimStart()

    if ($trimmed.StartsWith('<')) { return 'xml' }

    if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
        try {
            $null = ConvertFrom-Json -InputObject $Content -Depth 64 -ErrorAction Stop
            return 'json'
        }
        catch {
            # Almost certainly an INI section header rather than a JSON array.
            Write-Verbose "Content starts with a bracket but is not valid JSON; treating as INI: $($_.Exception.Message)"
        }
    }

    if ($Content -match '(?m)^\s*\[[^\]]+\]\s*$') { return 'ini' }

    return 'keyvalue'
}

<#
.SYNOPSIS
    Folds flat dot-path records into the nested Options tree OptionSchema uses.
#>
function ConvertTo-NestedSchema {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $ParsedOptions)

    $root = [ordered] @{}

    foreach ($option in $ParsedOptions) {
        $cursor = $root
        $segments = @($option.Segments)

        # Walk the group nodes, creating them as needed. Group nodes carry Options
        # and no Type, which is exactly how the SDK's flattener tells them apart
        # from leaves.
        for ($i = 0; $i -lt $segments.Count - 1; $i++) {
            $segment = $segments[$i]

            if (-not $cursor.Contains($segment)) {
                $cursor[$segment] = [ordered] @{ Options = [ordered] @{} }
            }
            elseif (-not $cursor[$segment].Contains('Options')) {
                # A leaf and a group collided on the same path. Keep the group --
                # dropping it would silently discard every option beneath it.
                Write-Warning "Option '$($option.Path)' collides with a leaf at '$segment'; promoting to a group"
                $cursor[$segment]['Options'] = [ordered] @{}
            }

            $cursor = $cursor[$segment]['Options']
        }

        $leafKey = $segments[-1]
        $leaf = [ordered] @{ Type = $option.Type }

        if ($option.PSObject.Properties['ItemType'] -and $option.ItemType) {
            $leaf['ItemType'] = $option.ItemType
        }

        if ($option.PSObject.Properties['Fields'] -and $option.Fields) {
            $leaf['Fields'] = $option.Fields
        }

        if ($null -ne $option.Default -and $option.Default -ne '') {
            $leaf['Default'] = $option.Default
        }

        if ($option.PSObject.Properties['Comment'] -and $option.Comment) {
            $leaf['Description'] = $option.Comment
        }

        if ($option.PSObject.Properties['Choices'] -and $option.Choices -and $option.Choices.Count -gt 0) {
            $leaf['Choices'] = @($option.Choices)
        }

        if ($cursor.Contains($leafKey) -and $cursor[$leafKey].Contains('Options')) {
            Write-Warning "Option '$($option.Path)' collides with an existing group; skipping the leaf"
            continue
        }

        $cursor[$leafKey] = $leaf
    }

    return [ordered] @{ Options = $root }
}
