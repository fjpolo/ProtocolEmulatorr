param([string]$Port = "COM19", [int]$Baud = 115200)
$sp = [System.IO.Ports.SerialPort]::new($Port, $Baud, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$sp.Open()
Start-Sleep -Milliseconds 1000
$count = $sp.BytesToRead
Write-Host "BytesToRead: $count"
if ($count -gt 0) {
    $buf = New-Object byte[] $count
    $read = $sp.Read($buf, 0, $count)
    Write-Host "Data: $([System.Text.Encoding]::ASCII.GetString($buf, 0, $read))"
}
$sp.Close()
