<#
.SYNOPSIS
    Parses XML configuration into parsed option records.
.DESCRIPTION
    Follows ConfigToOptionSchemaService.ParseXmlElement: attributes become options
    on their owning element, elements with children or attributes become groups,
    and leaf elements become options carrying their text content. Namespace
    declarations are skipped.

    Repeated sibling elements with the same name collapse into a scalar list
    rather than silently overwriting one another, which the server-side converter
    does not handle.
#>
function ConvertFrom-XmlConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Content,
        [string] $Source
    )

    if ([string]::IsNullOrWhiteSpace($Content)) { return @() }

    $doc = [System.Xml.Linq.XDocument]::Parse($Content)

    $results = [System.Collections.Generic.List[object]]::new()

    if ($doc.Root) {
        Read-XmlElement -Element $doc.Root -Prefix @() -Results $results -Source $Source
    }

    return $results
}

function Read-XmlElement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Xml.Linq.XElement] $Element,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Prefix,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]] $Results,
        [string] $Source
    )

    foreach ($attr in $Element.Attributes()) {
        if ($attr.Name.LocalName -like 'xmlns*' -or $attr.IsNamespaceDeclaration) { continue }

        $segments = $Prefix + (ConvertTo-OptionKey -Key $attr.Name.LocalName)
        $Results.Add((New-ParsedOption -Segments $segments -Value $attr.Value -Source $Source))
    }

    # Group siblings by name so repeated elements become a list instead of the
    # last one winning.
    $childGroups = $Element.Elements() | Group-Object { $_.Name.LocalName }

    foreach ($group in $childGroups) {
        $segments = $Prefix + (ConvertTo-OptionKey -Key $group.Name)

        if ($group.Count -gt 1 -and -not ($group.Group | Where-Object { $_.HasElements -or $_.HasAttributes })) {
            $values = @($group.Group | ForEach-Object { $_.Value.Trim() })
            $Results.Add((New-ParsedListOption -Segments $segments -Items $values -Source $Source))
            continue
        }

        foreach ($child in $group.Group) {
            if ($child.HasElements -or $child.HasAttributes) {
                Read-XmlElement -Element $child -Prefix $segments -Results $Results -Source $Source
            }
            else {
                $Results.Add((New-ParsedOption -Segments $segments -Value $child.Value.Trim() -Source $Source))
            }
        }
    }
}
