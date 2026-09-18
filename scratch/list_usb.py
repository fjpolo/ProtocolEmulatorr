import subprocess
out = subprocess.check_output(['powershell', '-NoProfile', '-Command', 'Get-PnpDevice -PresentOnly | Where-Object { $_.Class -in @("Ports", "USB") } | Select-Object Class, FriendlyName, InstanceId | Format-Table -AutoSize'], text=True)
print(out)
