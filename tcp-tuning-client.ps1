param(
    [Parameter(Mandatory = $true)][string]$Control,
    [Parameter(Mandatory = $true)][string]$Token,
    [int]$MaxGiB = 4
)

$ErrorActionPreference = 'Stop'
$iperf = $env:DAIMON_IPERF3
if (-not $iperf) { $iperf = (Get-Command iperf3 -ErrorAction SilentlyContinue).Source }
if (-not $iperf) {
    $iperf = Read-Host 'iperf3.exe full path'
    if (-not (Test-Path -LiteralPath $iperf)) { throw 'iperf3.exe was not found' }
}

$base = $Control.TrimEnd('/')
$tokenQuery = [Uri]::EscapeDataString($Token)
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false
$http = New-Object System.Net.Http.HttpClient($handler)
$lastId = -1
$totalBytes = [long]0
$deadline = (Get-Date).AddMinutes(35)
try {
  while ((Get-Date) -lt $deadline) {
    $stage = $http.GetStringAsync("$base/stage?token=$tokenQuery").GetAwaiter().GetResult() | ConvertFrom-Json
    if ($stage.state -eq 'done') { Write-Host $stage.message; exit 0 }
    if ($stage.state -eq 'error') { throw $stage.message }
    if ($stage.state -ne 'ready' -or [int]$stage.id -le $lastId) {
        Start-Sleep -Milliseconds 700
        continue
    }

    $family = [int]$stage.family
    $server = [string]$stage.host
    $port = [int]$stage.port
    $duration = [int]$stage.duration
    $omit = [int]$stage.omit
    Write-Host ("Round {0}: IPv{1} {2}:{3}" -f $stage.id, $family, $server, $port)
    $attempt = 0
    do {
        $attempt++
        $raw = & $iperf -c $server -p $port "-$family" -R -t $duration -O $omit -i 1 -J 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { break }
        if ($attempt -ge 8) { throw "iperf3 failed after $attempt attempts: $raw" }
        Start-Sleep -Seconds 2
    } while ($true)

    $measurement = $raw | ConvertFrom-Json
    $received = $measurement.end.sum_received
    if (-not $received -or [double]$received.bits_per_second -le 0 -or [long]$received.bytes -le 0) {
        throw "Round $($stage.id) has no valid receiver throughput"
    }
    $totalBytes += [long]$received.bytes
    if ($totalBytes -gt [long]$MaxGiB * 1GB) {
        throw "Traffic budget exceeded: $MaxGiB GiB"
    }

    $sender = $measurement.end.sum_sent
    $result = @{
        id = [int]$stage.id
        family = $family
        receiver_mbps = [Math]::Round([double]$received.bits_per_second / 1000000, 2)
        bytes = [long]$received.bytes
        retrans = if ($sender.retransmits) { [int]$sender.retransmits } else { 0 }
    }
    $json = $result | ConvertTo-Json -Compress
    $body = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')
    $response = $http.PostAsync("$base/result?token=$tokenQuery", $body).GetAwaiter().GetResult()
    $response.EnsureSuccessStatusCode() | Out-Null
    $response.Dispose()
    $body.Dispose()
    Write-Host ("  receiver: {0} Mbps, retrans: {1}, traffic: {2:N2} GiB" -f $result.receiver_mbps, $result.retrans, ($totalBytes / 1GB))
    $lastId = [int]$stage.id
  }
  throw 'Benchmark session timed out'
} finally {
  $http.Dispose()
  $handler.Dispose()
}
