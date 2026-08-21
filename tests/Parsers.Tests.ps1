BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '../module/LANCommander.Redistributables'
    Import-Module $script:ModulePath -Force

    $script:Fixtures = Join-Path $PSScriptRoot 'Fixtures'
    $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) "lcx-tests-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $script:Temp -Force | Out-Null

    function New-TempFile {
        param([string] $Name, [string] $Content)

        $path = Join-Path $script:Temp $Name
        Set-Content -LiteralPath $path -Value $Content -Encoding utf8
        return $path
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-OptionSchema - INI' {
    It 'promotes sections to group nodes and keys to leaves' {
        $path = New-TempFile 'basic.ini' @'
[General]
Adapter = 1
Name = hello
'@
        $schema = ConvertTo-OptionSchema -Path $path

        $schema.Options.Contains('General') | Should -BeTrue
        $schema.Options['General'].Contains('Type') | Should -BeFalse -Because 'group nodes must have no Type'
        $schema.Options['General']['Options']['Adapter']['Type'] | Should -Be 'int'
        $schema.Options['General']['Options']['Name']['Type'] | Should -Be 'string'
    }

    It 'infers bool only from textual forms, leaving 0 and 1 as int' {
        $path = New-TempFile 'bools.ini' @'
[S]
A = true
B = yes
C = off
D = 1
E = 0
'@
        $schema = ConvertTo-OptionSchema -Path $path
        $options = $schema.Options['S']['Options']

        $options['A']['Type'] | Should -Be 'bool'
        $options['B']['Type'] | Should -Be 'bool'
        $options['C']['Type'] | Should -Be 'bool'
        # 0/1 are ambiguous, and mistyping an int as bool destroys the value.
        $options['D']['Type'] | Should -Be 'int'
        $options['E']['Type'] | Should -Be 'int'
    }

    It 'normalises bool defaults to lowercase strings' {
        $path = New-TempFile 'boolcase.ini' @'
[S]
A = YES
B = Off
'@
        $schema = ConvertTo-OptionSchema -Path $path

        $schema.Options['S']['Options']['A']['Default'] | Should -BeExactly 'true'
        $schema.Options['S']['Options']['B']['Default'] | Should -BeExactly 'false'
    }

    It 'harvests choices from the comment above a key' {
        $path = New-TempFile 'choices.ini' @'
[General]
; Values: fast, accurate, best
OutputAPI = best
'@
        $schema = ConvertTo-OptionSchema -Path $path -ChoiceCommentPattern '(?i)values?\s*:\s*(?<choices>.+)'
        $option = $schema.Options['General']['Options']['OutputAPI']

        $option['Type'] | Should -Be 'choice'
        $option['Choices'] | Should -Be @('fast', 'accurate', 'best')
    }

    It 'does not attach a comment to a key separated from it by a blank line' {
        $path = New-TempFile 'detached.ini' @'
[General]
; Values: a, b

OutputAPI = a
'@
        $schema = ConvertTo-OptionSchema -Path $path -ChoiceCommentPattern '(?i)values?\s*:\s*(?<choices>.+)'

        $schema.Options['General']['Options']['OutputAPI']['Type'] | Should -Be 'string'
    }

    It 'uses an inline comment as the description and keeps it out of the value' {
        $path = New-TempFile 'inline.ini' @'
[General]
Mode = fast   ; only for testing
'@
        $schema = ConvertTo-OptionSchema -Path $path
        $option = $schema.Options['General']['Options']['Mode']

        $option['Default'] | Should -Be 'fast'
        $option['Description'] | Should -Be 'only for testing'
    }

    It 'keeps a hash that is part of a value rather than a comment' {
        $path = New-TempFile 'hashvalue.ini' @'
[General]
Colour = #ff00ff
'@
        $schema = ConvertTo-OptionSchema -Path $path

        $schema.Options['General']['Options']['Colour']['Default'] | Should -Be '#ff00ff'
    }

    It 'sanitises keys that contain spaces, dots and dashes' {
        $path = New-TempFile 'keys.ini' @'
[My Section]
some-key = 1
other.key = 2
'@
        $schema = ConvertTo-OptionSchema -Path $path

        $schema.Options.Contains('MySection') | Should -BeTrue
        $schema.Options['MySection']['Options'].Contains('Some_key') | Should -BeTrue
        $schema.Options['MySection']['Options'].Contains('Other_key') | Should -BeTrue
    }
}

Describe 'ConvertTo-OptionSchema - format detection' {
    It 'treats a leading bracket as INI rather than JSON when it is not valid JSON' {
        # ConfigToOptionSchemaService gets this wrong; an INI file almost always
        # starts with a section header.
        $path = New-TempFile 'sectionfirst.cfg' @'
[General]
A = 1
'@
        $schema = ConvertTo-OptionSchema -Path $path

        $schema.Options.Contains('General') | Should -BeTrue
    }

    It 'parses JSON objects into nested groups' {
        $path = New-TempFile 'config.json' '{ "render": { "width": 1920, "vsync": true }, "name": "x" }'
        $schema = ConvertTo-OptionSchema -Path $path

        $schema.Options['Render']['Options']['Width']['Type'] | Should -Be 'int'
        $schema.Options['Render']['Options']['Vsync']['Type'] | Should -Be 'bool'
        $schema.Options['Name']['Type'] | Should -Be 'string'
    }

    It 'maps a JSON scalar array to a list with an ItemType' {
        # The server-side converter maps arrays to 'choice', which misrepresents a
        # repeated-value setting as a single pick.
        $path = New-TempFile 'list.json' '{ "hosts": ["a", "b"] }'
        $schema = ConvertTo-OptionSchema -Path $path

        $schema.Options['Hosts']['Type'] | Should -Be 'list'
        $schema.Options['Hosts']['ItemType'] | Should -Be 'string'
        $schema.Options['Hosts']['Default'] | Should -Be @('a', 'b')
    }

    It 'maps a JSON array of objects to a composite list with Fields' {
        $path = New-TempFile 'composite.json' '{ "servers": [ { "address": "a.example", "port": 28900 } ] }'
        $schema = ConvertTo-OptionSchema -Path $path

        $schema.Options['Servers']['Type'] | Should -Be 'list'
        $schema.Options['Servers']['Fields']['Port']['Type'] | Should -Be 'int'
    }

    It 'parses XML attributes and elements' {
        $path = New-TempFile 'config.xml' '<root enabled="true"><display><width>800</width></display></root>'
        $schema = ConvertTo-OptionSchema -Path $path

        $schema.Options['Enabled']['Type'] | Should -Be 'bool'
        $schema.Options['Display']['Options']['Width']['Type'] | Should -Be 'int'
    }

    It 'collapses repeated XML siblings into a list' {
        $path = New-TempFile 'repeat.xml' '<root><host>a</host><host>b</host></root>'
        $schema = ConvertTo-OptionSchema -Path $path

        $schema.Options['Host']['Type'] | Should -Be 'list'
        $schema.Options['Host']['Default'] | Should -Be @('a', 'b')
    }

    It 'parses a .reg export, decoding dword values and dropping the hive' {
        $path = New-TempFile 'config.reg' @'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Example]
"Mode"="fast"
"Level"=dword:0000000a
"Path"="C:\\Games\\Example"
'@
        $schema = ConvertTo-OptionSchema -Path $path
        $options = $schema.Options['SOFTWARE']['Options']['Example']['Options']

        $options['Mode']['Default'] | Should -Be 'fast'
        $options['Level']['Default'] | Should -Be '10'
        $options['Path']['Default'] | Should -Be 'C:\Games\Example'
    }

    It 'parses YAML into nested groups' {
        $path = New-TempFile 'config.yml' "render:`n  width: 1024`n  vsync: true`n"
        $schema = ConvertTo-OptionSchema -Path $path

        $schema.Options['Render']['Options']['Width']['Type'] | Should -Be 'int'
        $schema.Options['Render']['Options']['Vsync']['Default'] | Should -BeExactly 'true'
    }

    It 'warns and skips a config file that does not exist' {
        $schema = ConvertTo-OptionSchema -Path (Join-Path $script:Temp 'nope.ini') -WarningAction SilentlyContinue

        $schema.Options.Count | Should -Be 0
    }
}

Describe 'ConvertTo-OptionSchema - new upstream keys' {
    It 'picks up a key added upstream without any change to the parser' {
        # The whole point of the generic parsers.
        $before = New-TempFile 'v1.ini' "[General]`nA = 1`n"
        $after = New-TempFile 'v2.ini' "[General]`nA = 1`nB = 2`n"

        $first = ConvertTo-OptionSchema -Path $before
        $second = ConvertTo-OptionSchema -Path $after

        $first.Options['General']['Options'].Contains('B') | Should -BeFalse
        $second.Options['General']['Options'].Contains('B') | Should -BeTrue
    }
}

Describe 'ConvertTo-OptionSchema - commented-out sample configs' {
    It 'finds nothing in a fully commented-out config by default' {
        # In an ordinary config a commented-out key means "deliberately not set",
        # so this has to stay opt-in.
        $path = New-TempFile 'sample.ini' "[general]`n#channels =`n#frequency = 48000`n"
        $schema = ConvertTo-OptionSchema -Path $path

        $schema.Options.Count | Should -Be 0
    }

    It 'treats commented-out keys as options when asked' {
        # OpenAL Soft's alsoftrc.sample is 88 of these; without this the file
        # yields no schema at all.
        $path = New-TempFile 'sample2.ini' "[general]`n#channels =`n#frequency = 48000`n"
        $schema = ConvertTo-OptionSchema -Path $path -IncludeCommentedKeys

        $schema.Options['General']['Options']['Frequency']['Default'] | Should -Be '48000'
        $schema.Options['General']['Options'].Contains('Channels') | Should -BeTrue
    }

    It 'still attaches the prose above a commented-out key as its description' {
        $path = New-TempFile 'sample3.ini' @'
[general]
## channels:
#  Sets the output channel configuration. The available values are: mono, stereo.
#channels = stereo
'@
        $schema = ConvertTo-OptionSchema -Path $path -IncludeCommentedKeys -ChoiceCommentPattern '(?i)values are:?\s*(?<choices>[^.]+)'
        $option = $schema.Options['General']['Options']['Channels']

        $option['Type'] | Should -Be 'choice'
        $option['Choices'] | Should -Be @('mono', 'stereo')
        $option['Description'] | Should -Match 'output channel configuration'
    }

    It 'does not mistake commented prose containing an equals sign for a key' {
        $path = New-TempFile 'sample4.ini' "[general]`n# see docs, e.g. a = b is not a setting`n#real = 1`n"
        $schema = ConvertTo-OptionSchema -Path $path -IncludeCommentedKeys

        $schema.Options['General']['Options'].Count | Should -Be 1
        $schema.Options['General']['Options'].Contains('Real') | Should -BeTrue
    }
}
