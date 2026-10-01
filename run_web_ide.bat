@echo off
echo Starting OmniBus Web IDE Server on http://localhost:8000 ...
start http://localhost:8000
python -m http.server 8000 --directory web_ide
