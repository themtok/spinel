[# PowerShell build and launch entry point.
# Runs Rebar3 tasks and manages Windows console input around the TUI.

CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('compile', 'test', 'shell', 'tui', 'release', 'package', 'clean')]
    [string]$Task = 'compile'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command erl -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'Erlang/OTP is required. Install it and add its bin directory to PATH.'
}

$rebar = Get-Command rebar3 -CommandType Application -TotalCount 1 -ErrorAction SilentlyContinue
if (-not $rebar) {
    throw 'Rebar3 is required. Install it and add it to PATH (rebar3.cmd on Windows).'
}

$taskArguments = @{
    compile = @('compile')
    test    = @('eunit')
    shell   = @('shell')
    tui     = @('compile')
    release = @('as', 'prod', 'release')
    package = @('as', 'prod', 'tar')
    clean   = @('do', 'clean', '--all')
}

Push-Location -LiteralPath $PSScriptRoot
try {
    $rebarArguments = $taskArguments[$Task]
    & $rebar.Source @rebarArguments
    if ($Task -eq 'tui' -and $LASTEXITCODE -eq 0) {
        $codePaths = @(Get-ChildItem '_build/default/lib' -Directory |
            ForEach-Object { Join-Path $_.FullName 'ebin' } |
            Where-Object { Test-Path -LiteralPath $_ })
        $launch = 'case erl_harness_tui:run() of ok -> halt(0); Error -> io:format(standard_error, "~p~n", [Error]), halt(1) end.'
        $isWindowsConsole = [Environment]::OSVersion.Platform -eq 'Win32NT'
        if ($isWindowsConsole) {
            $previousCtrlCMode = [Console]::TreatControlCAsInput
        }
        try {
            if ($isWindowsConsole) {
                [Console]::TreatControlCAsInput = $true
            }
            & erl -noshell -pa @codePaths -config 'config/sys' -eval $launch
        }
        finally {
            if ($isWindowsConsole) {
                [Console]::TreatControlCAsInput = $previousCtrlCMode
            }
        }
    }
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
