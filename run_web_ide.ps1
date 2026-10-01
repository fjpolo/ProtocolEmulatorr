# OmniBus Web IDE Launcher
Write-Host "Starting OmniBus Web IDE Server on http://localhost:8000 ..." -ForegroundColor Cyan
Start-Process "http://localhost:8000"
python -m http.server 8000 --directory web_ide
