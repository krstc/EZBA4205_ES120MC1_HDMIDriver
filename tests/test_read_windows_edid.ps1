$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$reader = Join-Path $repo 'diagnostics/read_windows_edid.ps1'
$out = Join-Path $repo 'build/tests/read_windows_edid'
New-Item -ItemType Directory -Force $out | Out-Null
$expected = Join-Path $repo 'build/tests/es120_edid_tb/edid.bin'
$script:mockEdid = [IO.File]::ReadAllBytes($expected)
$script:mockActive = $true
$script:failExtension = $false
function Get-CimInstance {
    param($Namespace,$ClassName)
    [pscustomobject]@{Active=$mockActive; InstanceName='DISPLAY\MOCKEPD\TEST_0'}
}
function Invoke-CimMethod {
    param($InputObject,$MethodName,$Arguments)
    $block = [int]$Arguments.BlockId
    [pscustomobject]@{
        ReturnValue = !($failExtension -and $block -gt 0)
        BlockContent = [byte[]]$mockEdid[($block*128)..($block*128+127)]
    }
}
function Read-Mock($file) {
    $json = Join-Path $out 'result.json'
    & $reader -ExpectedFile $file -OutputFile $json | Out-Null
    Get-Content $json -Raw | ConvertFrom-Json
}
$r = Read-Mock $expected
if (!$r.MatchesExpected -or $r.ProductCode -ne '0133' -or $r.Resolution -ne '2560x1600' -or
    $r.PreferredHz -lt 24.99 -or $r.PreferredHz -gt 25.01 -or $r.Blocks.Count -ne 1) {
    throw 'Candidate decode or equality check failed'
}
# Replay the observed rewritten EDID, not a fabricated driver claim.
$saved = Get-Content (Join-Path $repo 'build/edid_registry_comparison_20260911.json') -Raw | ConvertFrom-Json
$hex = ($saved | Where-Object Instance -Match 'EPD0131').Hex
$script:mockEdid = [byte[]]@($hex.Split('-') | ForEach-Object { [Convert]::ToByte($_,16) })
$previous = Join-Path $repo 'build/releases/20260910_white_hdmi25/edid.bin'
$r = Read-Mock $previous
if ($r.MatchesExpected -or $r.Resolution -ne '2560x1600' -or $r.PixelClockMHz -ne 268.5 -or
    $r.ObservedLength -ne 256 -or $r.ExpectedLength -ne 128 -or $r.Blocks.Count -ne 2 -or
    ($r.Blocks | Where-Object {!$_.ChecksumValid}) -or
    ($r.DifferentOffsets -join ',') -ne '10,54,55,126,127') {
    throw 'Rewritten EDID or extension diff detection failed'
}
$script:mockEdid[255] = $script:mockEdid[255] -bxor 1
$r = Read-Mock $previous
if ($r.Blocks[1].ChecksumValid) { throw 'Bad extension checksum accepted' }
$script:failExtension = $true
$failed = $false
try { Read-Mock $previous | Out-Null } catch { $failed = $_.Exception.Message -like 'EDID extension 1 read failed*' }
if (!$failed) { throw 'Extension read failure ignored' }
$script:mockActive = $false
$failed = $false
try { Read-Mock $previous | Out-Null } catch { $failed = $_.Exception.Message -like 'No active monitor*' }
if (!$failed) { throw 'Disconnected monitor accepted' }
'PASS EDID reader: candidate, observed 59.97Hz rewrite, all extensions, byte diffs, bad checksum, failed read, inactive monitor'
