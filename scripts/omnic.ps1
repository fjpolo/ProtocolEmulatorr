$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
python "$scriptDir\..\python\omnic.py" $args
exit $LASTEXITCODE
