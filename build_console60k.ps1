<#
.SYNOPSIS
    Gowin build and flash launcher for Sipeed Tang Console 60K.
#>

[CmdletBinding(PositionalBinding = $false)]
param (
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ScriptPath = Join-Path $PSScriptRoot "boards\sipeed\console60k\build.ps1"
& $ScriptPath @RemainingArgs
