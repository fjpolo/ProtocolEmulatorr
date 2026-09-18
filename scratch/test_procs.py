import subprocess
try:
    cmd = 'Get-CimInstance Win32_Process -Filter "name=\'powershell.exe\'" | Select-Object ProcessId, CommandLine | Format-List'
    out = subprocess.check_output(['powershell', '-NoProfile', '-Command', cmd], text=True)
    print(out)
except Exception as e:
    print('Error:', e)
