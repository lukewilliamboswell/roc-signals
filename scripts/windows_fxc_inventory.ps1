# Observe the actual shader compiler module, rather than assuming DLL resolution.
param([Parameter(Mandatory=$true)][string]$Fxc,
      [Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$shader = Join-Path $OutputDirectory 'inventory.hlsl'
$binary = Join-Path $OutputDirectory 'inventory.dxbc'
$source = [System.Text.StringBuilder]::new()
[void]$source.AppendLine('float4 main(float4 p : POSITION) : SV_TARGET {')
for ($i=0; $i -lt 2000; $i++) {
    [void]$source.AppendLine("p = sin(p * 1.001 + $i.0);")
}
[void]$source.AppendLine('return p; }')
[System.IO.File]::WriteAllText($shader, $source.ToString())
$observed = $null
for ($attempt=0; $attempt -lt 3 -and $null -eq $observed; $attempt++) {
    $process = Start-Process -FilePath $Fxc -ArgumentList @('/nologo', '/T', 'ps_5_0', '/E', 'main', '/Fo', "`"$binary`"", "`"$shader`"") -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $OutputDirectory 'fxc.stdout') -RedirectStandardError (Join-Path $OutputDirectory 'fxc.stderr')
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not $process.HasExited) {
        if ([DateTime]::UtcNow -gt $deadline) {
            $process.Kill()
            throw 'FXC inventory compilation exceeded 60 seconds'
        }
        try {
            $process.Refresh()
            foreach ($module in $process.Modules) {
                if ($module.ModuleName -ieq 'd3dcompiler_47.dll') {
                    $observed = $module.FileName
                }
            }
        } catch {
            # Process may exit between HasExited and module enumeration.
            if (-not $process.HasExited) { throw }
        }
    }
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "FXC probe failed: $(Get-Content (Join-Path $OutputDirectory 'fxc.stderr') -Raw)" }
}
if ($null -eq $observed) { throw 'Could not observe loaded D3DCompiler module; refusing inferred identity' }
@{path=$observed; sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $observed).Hash;
  file_version=(Get-Item -LiteralPath $observed).VersionInfo.FileVersion;
  shader_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $shader).Hash;
  output_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $binary).Hash} | ConvertTo-Json
