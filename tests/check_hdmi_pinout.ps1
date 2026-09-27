$ErrorActionPreference = 'Stop'
$xdc = Join-Path (Split-Path $PSScriptRoot -Parent) 'c/p/Eink_controller_V1.0.srcs/EBAZ4205_20230529/imports/new/top_pin.xdc'
$pins = @{}
foreach ($line in Get-Content -LiteralPath $xdc) {
    if ($line -match '^set_property PACKAGE_PIN (\w+) \[get_ports (pix_clk|de_i|hs_i|vs_i)\]$') {
        $pins[$Matches[2]] = $Matches[1]
    }
    elseif ($line -match '^set_property PACKAGE_PIN (\w+) \[get_ports \{gray_i\[(\d)\]\}\]$') {
        $pins["gray_i[$($Matches[2])]" ] = $Matches[1]
    }
}
# Live one-hot ADV7611 free-run captures established the complete bus map;
# the expansion schematic is not a reliable source for this assembled board.
$expected = @{
    pix_clk = 'P19'
    de_i = 'U20'
    hs_i = 'U19'
    vs_i = 'V20'
    'gray_i[7]' = 'T20'
    'gray_i[6]' = 'R18'
    'gray_i[5]' = 'N20'
    'gray_i[4]' = 'P18'
    'gray_i[3]' = 'N17'
    'gray_i[2]' = 'P20'
    'gray_i[1]' = 'R19'
    'gray_i[0]' = 'T19'
}
foreach ($port in $expected.Keys) {
    if ($pins[$port] -ne $expected[$port]) {
        throw "$port must be on $($expected[$port]), got $($pins[$port])"
    }
}
Write-Output 'PASS HDMI input pinout'
