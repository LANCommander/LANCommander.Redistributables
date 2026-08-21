BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../module/LANCommander.Redistributables') -Force
    Import-Module powershell-yaml

    $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) "lcx-schema-tests-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $script:Temp -Force | Out-Null

    function New-TempFile {
        param([string] $Name, [string] $Content)

        $path = Join-Path $script:Temp $Name
        Set-Content -LiteralPath $path -Value $Content -Encoding utf8
        return $path
    }

    function Get-TestSchema {
        $path = New-TempFile "conf-$([guid]::NewGuid()).ini" @'
[General]
; Values: fast, accurate, best
OutputAPI = best
Adapter = 1
Debug = false

[DirectX]
Antialiasing = appdriven
VideoCard = geforce
'@
        return ConvertTo-OptionSchema -Path $path -ChoiceCommentPattern '(?i)values?\s*:\s*(?<choices>.+)'
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Merge-SchemaOverlay' {
    It 'passes generated options through untouched when there is no overlay' {
        $result = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay ([ordered] @{})

        $result.Schema.Options['General']['Options']['Adapter']['Type'] | Should -Be 'int'
        $result.Report.Uncurated.Count | Should -Be 5
    }

    It 'preserves hand-written curation across a full regeneration' {
        # The core guarantee: the generated half is disposable, the overlay is not.
        $overlay = ConvertFrom-Yaml -Ordered -Yaml @'
Options:
  General.OutputAPI:
    DisplayName: Output API
    Description: Direct3D backend used to present frames.
  DirectX.VideoCard:
    DisplayName: Emulated Video Card
'@
        $first = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay $overlay
        $second = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay $overlay -PreviousSchema $first.Schema

        foreach ($result in @($first, $second)) {
            $option = $result.Schema.Options['General']['Options']['OutputAPI']
            $option['DisplayName'] | Should -Be 'Output API'
            $option['Description'] | Should -Be 'Direct3D backend used to present frames.'
            $result.Schema.Options['DirectX']['Options']['VideoCard']['DisplayName'] | Should -Be 'Emulated Video Card'
        }
    }

    It 'lets the overlay override an inferred type and supply choices' {
        $overlay = ConvertFrom-Yaml -Ordered -Yaml @'
Options:
  DirectX.Antialiasing:
    Type: choice
    Choices: [appdriven, 2x, 4x]
'@
        $result = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay $overlay
        $option = $result.Schema.Options['DirectX']['Options']['Antialiasing']

        $option['Type'] | Should -Be 'choice'
        $option['Choices'] | Should -Be @('appdriven', '2x', '4x')
    }

    It 'drops options matched by an Exclude glob' {
        $overlay = ConvertFrom-Yaml -Ordered -Yaml "Exclude:`n  - General.Debug`n"
        $result = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay $overlay

        $result.Schema.Options['General']['Options'].Contains('Debug') | Should -BeFalse
        $result.Report.Excluded | Should -Contain 'General.Debug'
    }

    It 'supports wildcard Exclude globs' {
        $overlay = ConvertFrom-Yaml -Ordered -Yaml "Exclude:`n  - DirectX.*`n"
        $result = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay $overlay

        $result.Schema.Options.Contains('DirectX') | Should -BeFalse
        $result.Report.Excluded.Count | Should -Be 2
    }

    It 'regroups options under a Groups entry' {
        $overlay = ConvertFrom-Yaml -Ordered -Yaml @'
Groups:
  Rendering:
    Description: Renderer configuration
    Include: [General.OutputAPI, DirectX.Antialiasing]
'@
        $result = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay $overlay

        $result.Schema.Options['Rendering']['Description'] | Should -Be 'Renderer configuration'
        $result.Schema.Options['Rendering']['Options'].Contains('OutputAPI') | Should -BeTrue
        $result.Schema.Options['Rendering']['Options'].Contains('Antialiasing') | Should -BeTrue
        # Claimed options must not be left behind in their generated position.
        $result.Schema.Options['General']['Options'].Contains('OutputAPI') | Should -BeFalse
    }

    It 'pins a default to the previously committed value' {
        $overlay = ConvertFrom-Yaml -Ordered -Yaml "Options:`n  General.Adapter:`n    PinDefault: true`n"
        $previous = ConvertFrom-Yaml -Ordered -Yaml @'
Options:
  General:
    Options:
      Adapter:
        Type: int
        Default: "7"
'@
        $result = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay $overlay -PreviousSchema $previous

        $result.Schema.Options['General']['Options']['Adapter']['Default'] | Should -Be '7'
        $result.Report.DefaultChanged | Should -Not -Contain 'General.Adapter'
    }

    It 'reports an upstream default change when nothing is pinned' {
        $previous = ConvertFrom-Yaml -Ordered -Yaml @'
Options:
  General:
    Options:
      Adapter:
        Type: int
        Default: "7"
'@
        $result = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay ([ordered] @{}) -PreviousSchema $previous

        $result.Schema.Options['General']['Options']['Adapter']['Default'] | Should -Be '1'
        $result.Report.DefaultChanged | Should -Contain 'General.Adapter'
    }

    It 'reports a new upstream option as added and uncurated' {
        $previous = (Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay ([ordered] @{})).Schema

        $extended = New-TempFile 'extended.ini' "[General]`nOutputAPI = best`nAdapter = 1`nDebug = false`nNewOption = 5`n"
        $result = Merge-SchemaOverlay -Schema (ConvertTo-OptionSchema -Path $extended) -Overlay ([ordered] @{}) -PreviousSchema $previous

        $result.Report.Added | Should -Contain 'General.NewOption'
        $result.Report.Uncurated | Should -Contain 'General.NewOption'
    }

    It 'reports an option that disappeared upstream as removed' {
        $previous = (Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay ([ordered] @{})).Schema

        $reduced = New-TempFile 'reduced.ini' "[General]`nAdapter = 1`n"
        $result = Merge-SchemaOverlay -Schema (ConvertTo-OptionSchema -Path $reduced) -Overlay ([ordered] @{}) -PreviousSchema $previous

        $result.Report.Removed | Should -Contain 'General.OutputAPI'
    }

    It 'reports overlay entries that no longer match anything as stale' {
        # No Type, so this is curation of an option that vanished, not an option.
        $overlay = ConvertFrom-Yaml -Ordered -Yaml "Options:`n  General.LongGone:`n    Description: x`n"
        $result = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay $overlay

        $result.Report.StaleCuration | Should -Contain 'General.LongGone'
        $result.Report.Authored | Should -BeNullOrEmpty
        $result.Schema.Options['General']['Options'].Contains('LongGone') | Should -BeFalse
    }

    It 'materialises an overlay option that declares a Type' {
        $overlay = ConvertFrom-Yaml -Ordered -Yaml @'
Options:
  General.PROTONPATH:
    Type: string
    DisplayName: Proton Build
    IsEnvironmentVariable: true
'@
        $result = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay $overlay
        $option = $result.Schema.Options['General']['Options']['PROTONPATH']

        $option['Type'] | Should -Be 'string'
        $option['DisplayName'] | Should -Be 'Proton Build'
        $option['IsEnvironmentVariable'] | Should -BeTrue

        # Authored, not curation of something generated and not left uncurated.
        $result.Report.Authored | Should -Contain 'General.PROTONPATH'
        $result.Report.StaleCuration | Should -Not -Contain 'General.PROTONPATH'
        $result.Report.Uncurated | Should -Not -Contain 'General.PROTONPATH'
    }

    It 'builds an option tree from an overlay alone when no config was parsed' {
        # A shim with no config file at all: umu-launcher is configured purely
        # through environment variables, so the overlay is the entire schema.
        $overlay = ConvertFrom-Yaml -Ordered -Yaml @'
CommandTemplate: umu-run {exe} {args}
GuestPlatforms: Windows
Groups:
  Proton:
    Description: Which Proton build runs the game
    Include: [PROTONPATH, PROTON_VERB]
Options:
  PROTONPATH:
    Type: string
    IsEnvironmentVariable: true
  PROTON_VERB:
    Type: choice
    Default: waitforexitandrun
    Choices: [waitforexitandrun, run]
    IsEnvironmentVariable: true
'@
        $result = Merge-SchemaOverlay -Schema ([ordered] @{ Options = [ordered] @{} }) -Overlay $overlay

        $result.Report.Authored.Count | Should -Be 2
        $result.Schema.Options['Proton']['Options']['PROTON_VERB']['Default'] | Should -Be 'waitforexitandrun'
        (Test-OptionSchema -Schema $result.Schema).IsValid | Should -BeTrue
    }

    It 'keeps a group whose only members are overlay-authored' {
        # Build-CuratedTree omits a group that matched nothing, which would drop
        # every group in an overlay-only schema.
        $overlay = ConvertFrom-Yaml -Ordered -Yaml @'
Groups:
  Proton:
    Description: Which Proton build runs the game
    Include: [PROTONPATH]
Options:
  PROTONPATH:
    Type: string
    IsEnvironmentVariable: true
'@
        $result = Merge-SchemaOverlay -Schema ([ordered] @{ Options = [ordered] @{} }) -Overlay $overlay -WarningVariable warnings -WarningAction SilentlyContinue

        $warnings | Should -BeNullOrEmpty
        $result.Schema.Options['Proton']['Description'] | Should -Be 'Which Proton build runs the game'
    }

    It 'produces a byte-identical document for an overlay-only schema' {
        $overlay = ConvertFrom-Yaml -Ordered -Yaml @'
Options:
  GAMEID:
    Type: string
    Default: umu-default
    IsEnvironmentVariable: true
  UMU_LOG:
    Type: choice
    Default: "0"
    Choices: ["0", "1", debug]
    IsEnvironmentVariable: true
'@
        $empty = [ordered] @{ Options = [ordered] @{} }

        $first = Merge-SchemaOverlay -Schema $empty -Overlay $overlay
        $second = Merge-SchemaOverlay -Schema $empty -Overlay $overlay -PreviousSchema $first.Schema

        (ConvertTo-Yaml $second.Schema) | Should -BeExactly (ConvertTo-Yaml $first.Schema)
        $second.Report.Added | Should -BeNullOrEmpty
        $second.Report.DefaultChanged | Should -BeNullOrEmpty
    }

    It 'honours an Exclude glob against an authored option' {
        $overlay = ConvertFrom-Yaml -Ordered -Yaml @'
Options:
  UMU_NO_PROTON:
    Type: string
    IsEnvironmentVariable: true
Exclude:
  - UMU_*
'@
        $result = Merge-SchemaOverlay -Schema ([ordered] @{ Options = [ordered] @{} }) -Overlay $overlay

        $result.Report.Excluded | Should -Contain 'UMU_NO_PROTON'
        $result.Report.Authored | Should -Not -Contain 'UMU_NO_PROTON'
        $result.Schema.Options.Contains('UMU_NO_PROTON') | Should -BeFalse
    }

    It 'carries root shim properties through from the overlay' {
        $overlay = ConvertFrom-Yaml -Ordered -Yaml @'
CommandTemplate: umu-run {exe} {args}
GuestPlatforms: Windows
DisplayName: Proton
'@
        $result = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay $overlay

        $result.Schema['CommandTemplate'] | Should -Be 'umu-run {exe} {args}'
        $result.Schema['GuestPlatforms'] | Should -Be 'Windows'
        $result.Schema['DisplayName'] | Should -Be 'Proton'
    }

    It 'falls back to string when the overlay makes something a choice without choices' {
        $overlay = ConvertFrom-Yaml -Ordered -Yaml "Options:`n  General.Adapter:`n    Type: choice`n"
        $result = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay $overlay -WarningAction SilentlyContinue

        # A choice with no Choices would fail validation on the server.
        $result.Schema.Options['General']['Options']['Adapter']['Type'] | Should -Be 'string'
    }

    It 'emits bool defaults as lowercase strings' {
        # OptionDefinition.Default is object and GetDefaultAsString() calls
        # ToString(), so a YAML boolean would resolve as "False".
        $result = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay ([ordered] @{})
        $default = $result.Schema.Options['General']['Options']['Debug']['Default']

        $default | Should -BeOfType [string]
        $default | Should -BeExactly 'false'
    }
}

Describe 'Test-OptionSchema' {
    It 'accepts a well-formed schema' {
        $result = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay ([ordered] @{})
        (Test-OptionSchema -Schema $result.Schema).IsValid | Should -BeTrue
    }

    It 'rejects a key containing a dot' {
        # A dot would be indistinguishable from a nesting separator after flattening.
        $schema = ConvertFrom-Yaml -Ordered -Yaml "Options:`n  'Bad.Key':`n    Type: string`n"
        $result = Test-OptionSchema -Schema $schema

        $result.IsValid | Should -BeFalse
        $result.Errors -join ' ' | Should -Match 'Bad.Key'
    }

    It 'rejects a choice with no choices' {
        $schema = ConvertFrom-Yaml -Ordered -Yaml "Options:`n  Mode:`n    Type: choice`n"
        (Test-OptionSchema -Schema $schema).IsValid | Should -BeFalse
    }

    It 'rejects a list marked as an environment variable' {
        # ProcessExecutionContext skips these at launch, so it would silently do nothing.
        $schema = ConvertFrom-Yaml -Ordered -Yaml @'
Options:
  Hosts:
    Type: list
    ItemType: string
    IsEnvironmentVariable: true
'@
        $result = Test-OptionSchema -Schema $schema

        $result.IsValid | Should -BeFalse
        $result.Errors -join ' ' | Should -Match 'IsEnvironmentVariable'
    }

    It 'rejects two environment-variable options that share a leaf key' {
        # ProcessExecutionContext names the variable after the last dot-segment,
        # so these would both resolve to PROTONPATH and one would silently win.
        $schema = ConvertFrom-Yaml -Ordered -Yaml @'
Options:
  Proton:
    Options:
      PROTONPATH:
        Type: string
        IsEnvironmentVariable: true
  Advanced:
    Options:
      PROTONPATH:
        Type: string
        IsEnvironmentVariable: true
'@
        $result = Test-OptionSchema -Schema $schema

        $result.IsValid | Should -BeFalse
        $result.Errors -join ' ' | Should -Match 'PROTONPATH'
    }

    It 'rejects an unquoted boolean default' {
        $schema = ConvertFrom-Yaml -Ordered -Yaml "Options:`n  Flag:`n    Type: bool`n    Default: false`n"
        $result = Test-OptionSchema -Schema $schema

        $result.IsValid | Should -BeFalse
        $result.Errors -join ' ' | Should -Match 'boolean Default'
    }

    It 'rejects a node that is neither a leaf nor a group' {
        $schema = ConvertFrom-Yaml -Ordered -Yaml "Options:`n  Orphan:`n    Description: nothing`n"
        (Test-OptionSchema -Schema $schema).IsValid | Should -BeFalse
    }

    It 'rejects an unknown type' {
        $schema = ConvertFrom-Yaml -Ordered -Yaml "Options:`n  Weird:`n    Type: float`n"
        (Test-OptionSchema -Schema $schema).IsValid | Should -BeFalse
    }

    It 'rejects MinItems greater than MaxItems' {
        $schema = ConvertFrom-Yaml -Ordered -Yaml @'
Options:
  Hosts:
    Type: list
    ItemType: string
    MinItems: 5
    MaxItems: 2
'@
        (Test-OptionSchema -Schema $schema).IsValid | Should -BeFalse
    }

    It 'warns when a default is not among the declared choices' {
        $schema = ConvertFrom-Yaml -Ordered -Yaml @'
Options:
  Mode:
    Type: choice
    Choices: [a, b]
    Default: c
'@
        $result = Test-OptionSchema -Schema $schema

        $result.IsValid | Should -BeTrue
        $result.Warnings -join ' ' | Should -Match 'not among its Choices'
    }
}

Describe 'Merge-SchemaOverlay - grouped path reporting' {
    BeforeAll {
        $script:GroupOverlay = ConvertFrom-Yaml -Ordered -Yaml @'
Groups:
  Rendering:
    Description: Renderer configuration
    Include: [General.OutputAPI, DirectX.Antialiasing]
Options:
  General.Adapter:
    PinDefault: true
'@
    }

    It 'does not report a regrouped option as both added and removed on a rerun' {
        # Curation and grouping are keyed by the generated path, but Added/Removed
        # are reported in final paths. Comparing across the two spaces made every
        # grouped option churn on every scheduled run.
        $first = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay $script:GroupOverlay
        $second = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay $script:GroupOverlay -PreviousSchema $first.Schema

        $second.Report.Added | Should -BeNullOrEmpty
        $second.Report.Removed | Should -BeNullOrEmpty
        $second.Report.DefaultChanged | Should -BeNullOrEmpty
    }

    It 'reports added options using their final grouped path' {
        $first = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay $script:GroupOverlay

        $first.Report.Added | Should -Contain 'Rendering.OutputAPI'
        $first.Report.Added | Should -Not -Contain 'General.OutputAPI'
    }

    It 'pins a default for an option that a group moved' {
        # The pinned value has to be looked up by the option's final path, since
        # that is where the previous schema recorded it.
        $first = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay $script:GroupOverlay
        $first.Schema.Options['General']['Options']['Adapter']['Default'] | Should -Be '1'

        $edited = ConvertTo-Yaml -Data $first.Schema | ConvertFrom-Yaml -Ordered
        $edited['Options']['General']['Options']['Adapter']['Default'] = '9'

        $second = Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay $script:GroupOverlay -PreviousSchema $edited

        $second.Schema.Options['General']['Options']['Adapter']['Default'] | Should -Be '9'
    }

    It 'produces a byte-identical document when nothing upstream changed' {
        # The build treats OptionSchema.yml as a lockfile, so generation has to be
        # deterministic or every run would look stale.
        $first = ConvertTo-Yaml -Data (Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay $script:GroupOverlay).Schema
        $second = ConvertTo-Yaml -Data (Merge-SchemaOverlay -Schema (Get-TestSchema) -Overlay $script:GroupOverlay).Schema

        $second | Should -BeExactly $first
    }
}
