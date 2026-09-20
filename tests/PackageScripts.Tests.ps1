# Guards the contract between a redistributable's Package script and the SDK.
#
# LANCommander runs a Package script in a runspace built by
# RunspaceFactory.CreateRunspace(InitialSessionState) with no PSHost, then reads
# $Return back out of session state. New-Package declares -Path and -Version as
# mandatory, so calling it bare cannot bind: with no host there is nothing to
# prompt on and the binder throws instead. Every failure along that path --
# binding error, thrown script, unset $Return -- reaches the operator as the same
# opaque "the package script did not return a result", so it has to be caught here.
#
# The scripts call the live GitHub API, so they are not executed whole. Each
# New-Package call site is lifted out of the AST, its arguments replaced with
# placeholders, and re-bound against a stub carrying the real cmdlet's signature.

BeforeDiscovery {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

    # Globbed rather than listed, so a newly added redistributable is covered
    # without anyone remembering to come back here.
    $script:PackageScripts = @(
        Get-ChildItem -Path @(
            (Join-Path $script:RepoRoot 'template*/Scripts/Package.ps1')
            (Join-Path $script:RepoRoot 'LANCommander.Redistributables.*/Scripts/Package.ps1')
        ) -File -ErrorAction SilentlyContinue | ForEach-Object {
            @{
                # The directory holding Scripts/ -- 'template', 'template-vcredist',
                # or the redistributable repository's own name.
                Name = Split-Path (Split-Path $_.FullName -Parent) -Parent | Split-Path -Leaf
                Path = $_.FullName
            }
        }
    )
}

BeforeAll {
    # Mirrors LANCommander.SDK/PowerShell/Cmdlets/New-Package.cs. Deliberately does
    # not set $Return itself -- the repo convention is an explicit assignment, and
    # a stub that set it too would hide a call site that forgot to.
    $script:Stub = @'
function New-Package {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [Alias('p', 'Directory')]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [Alias('v')]
        [string] $Version,

        [Parameter(Mandatory = $false, Position = 2)]
        [Alias('c', 'Notes')]
        [string] $Changelog
    )

    [pscustomobject] @{ Path = $Path; Version = $Version; Changelog = $Changelog }
}
'@

    function Get-NewPackageCallSite {
        <#
            Returns one entry per New-Package invocation: the source text, and a
            rebuilt version of the statement with every argument swapped for a
            placeholder. Parameter names and argument positions survive the swap,
            which is all the binder looks at, and it means the call can be bound
            without standing up the real $staging / $release / $version values.
        #>
        param([string] $Path)

        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $null, [ref] $errors)

        if ($errors) {
            throw "$Path failed to parse: $(($errors | ForEach-Object { $_.Message }) -join '; ')"
        }

        $commands = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'New-Package'
            }, $true)

        foreach ($command in $commands) {
            $rebuilt = foreach ($element in $command.CommandElements) {
                if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $element.Value -eq 'New-Package') {
                    'New-Package'
                }
                elseif ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                    # -Path:$x carries its argument on the parameter itself; the
                    # separated -Path $x form arrives as a following element.
                    if ($null -ne $element.Argument) { "-$($element.ParameterName) 'placeholder'" }
                    else { "-$($element.ParameterName)" }
                }
                else {
                    "'placeholder'"
                }
            }

            # An assignment to $Return is how every script in the family hands its
            # result back, so the statement is replayed with it rather than without.
            # A command sits inside a pipeline, so the assignment is its grandparent.
            $assigns = $false
            $statement = $command.Parent

            if ($statement -is [System.Management.Automation.Language.PipelineAst]) {
                $statement = $statement.Parent
            }

            if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst]) {
                $left = $statement.Left
                $assigns = $left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $left.VariablePath.UserPath -eq 'Return'
            }

            [pscustomobject] @{
                Text    = $command.Extent.Text
                Line    = $command.Extent.StartLineNumber
                Replay  = if ($assigns) { "`$Return = $($rebuilt -join ' ')" } else { $rebuilt -join ' ' }
                Assigns = $assigns
            }
        }
    }

    function Invoke-InHostlessRunspace {
        <#
            Runs a fragment the way the SDK does -- no PSHost, so an unbound
            mandatory parameter fails to bind rather than prompting -- and reads
            $Return back through the session state proxy, as ExecuteAsync<T> does.
        #>
        param([string] $Script)

        $state = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $runspace = [runspacefactory]::CreateRunspace($state)
        $runspace.Open()

        try {
            $shell = [powershell]::Create()
            $shell.Runspace = $runspace

            try {
                $null = $shell.AddScript($Script).Invoke()

                return [pscustomobject] @{
                    Return = $runspace.SessionStateProxy.PSVariable.GetValue('Return')
                    Errors = @($shell.Streams.Error | ForEach-Object { $_.Exception.Message })
                }
            }
            finally { $shell.Dispose() }
        }
        finally { $runspace.Dispose() }
    }
}

Describe 'Package script <_.Name>' -ForEach $script:PackageScripts {
    BeforeAll {
        $script:ScriptPath = $_.Path
    }

    It 'is not empty' {
        # A declared-but-empty script is packed by no one: New-LcxPackage throws
        # "Script 'Package' at <path> is empty" and the whole build stops.
        (Get-Item -LiteralPath $script:ScriptPath).Length | Should -BeGreaterThan 0
    }

    It 'calls New-Package' {
        # Keeps the binding test below from passing vacuously if the cmdlet is
        # ever renamed or the call dropped.
        @(Get-NewPackageCallSite -Path $script:ScriptPath).Count | Should -BeGreaterThan 0
    }

    It 'assigns every New-Package result to $Return' {
        foreach ($site in Get-NewPackageCallSite -Path $script:ScriptPath) {
            # The SDK reads $Return back out of session state. New-Package also sets
            # it internally, but the explicit assignment is the family convention and
            # is what the other script types rely on, so it is required here too.
            $site.Assigns | Should -BeTrue -Because "line $($site.Line) should read `$Return = $($site.Text)"
        }
    }

    It 'binds every New-Package call site and populates $Return' {
        foreach ($site in Get-NewPackageCallSite -Path $script:ScriptPath) {
            $result = Invoke-InHostlessRunspace -Script "$script:Stub`n$($site.Replay)"

            $because = "line $($site.Line): $($site.Text)"

            $result.Errors | Should -BeNullOrEmpty -Because $because
            $result.Return | Should -Not -BeNullOrEmpty -Because $because
            $result.Return.Path | Should -Not -BeNullOrEmpty -Because $because
            $result.Return.Version | Should -Not -BeNullOrEmpty -Because $because
        }
    }
}
