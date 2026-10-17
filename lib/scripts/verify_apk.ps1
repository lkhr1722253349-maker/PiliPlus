param(
    [Parameter(Mandatory = $true)]
    [string]$ApkPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ApkPath).Path)
try {
    $entries = @($archive.Entries | ForEach-Object { $_.FullName })
    $abis = @($entries | ForEach-Object {
        if ($_ -match '^lib/([^/]+)/libflutter\.so$') { $matches[1] }
    })
    if ($abis.Count -eq 0) { throw 'APK contains no Flutter engine.' }
    foreach ($abi in $abis) {
        if ($entries -notcontains "lib/$abi/libmpv.so") {
            throw "APK is missing libmpv.so for $abi; playback initialization would fail."
        }
        Write-Output "Verified Flutter engine and media_kit native library: $abi"
    }
}
finally {
    $archive.Dispose()
}
