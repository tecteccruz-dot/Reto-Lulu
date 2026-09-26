[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+(\.\d+)?$')]
    [string]$Version,
    [switch]$Publish
)

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$Dist = Join-Path $Root 'dist'
$Archive = Join-Path $Dist "Reto-Lulu-$Version.zip"
$ShaPath = "$Archive.sha256"
$Repo = 'tecteccruz-dot/Reto-Lulu'

$excludedTopLevel = @(
    '.git', '.retolulu-cache', '.cache', '.fabric', '.mixin.out',
    'dist', 'saves', 'logs', 'crash-reports', 'screenshots', 'downloads', 'journeymap'
)
$excludedFiles = @(
    '.retolulu-state.json', '.retolulu-installed-manifest.json',
    '.gitignore', '.curseclient', 'RetoLulu.code-workspace',
    'Crear_Build_RetoLulu.bat', 'Crear_Build_RetoLulu.ps1',
    'README.md', 'realms_persistence.json', 'usercache.json', 'usernamecache.json'
)

function Is-Included([IO.FileInfo]$File) {
    $relative = $File.FullName.Substring($Root.Length).TrimStart('\')
    $first = ($relative -split '[\\/]')[0]
    if ($excludedTopLevel -contains $first) { return $false }
    if ($excludedFiles -contains $relative) { return $false }
    return $true
}

try {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Directory]::CreateDirectory($Dist) | Out-Null
    Remove-Item -LiteralPath $Archive -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ShaPath -Force -ErrorAction SilentlyContinue

    $files = @(Get-ChildItem -LiteralPath $Root -File -Force -Recurse | Where-Object { Is-Included $_ })
    if ($files.Count -eq 0) { throw 'No se encontraron archivos para la build.' }

    Write-Host "Creando Reto Lulu $Version con $($files.Count) archivos..." -ForegroundColor Cyan
    $stream = [IO.File]::Open($Archive, [IO.FileMode]::CreateNew)
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
    $manifestFiles = New-Object Collections.Generic.List[object]
    try {
        $index = 0
        foreach ($file in $files) {
            $index++
            $relative = $file.FullName.Substring($Root.Length).TrimStart('\').Replace('\', '/')
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifestFiles.Add([ordered]@{ path = $relative; sha256 = $hash; size = $file.Length })
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip,
                $file.FullName,
                "payload/$relative",
                [IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
            $percent = [int](($index * 100) / $files.Count)
            Write-Progress -Activity 'Empaquetando Reto Lulu' -Status "$percent% - $relative" -PercentComplete $percent
        }
        $manifest = [ordered]@{
            schemaVersion = 1
            name = 'Reto Lulu'
            version = $Version
            createdAt = (Get-Date).ToUniversalTime().ToString('o')
            files = $manifestFiles
        } | ConvertTo-Json -Depth 6
        $entry = $zip.CreateEntry('.retolulu-build.json', [IO.Compression.CompressionLevel]::Optimal)
        $entryStream = $entry.Open()
        $writer = [IO.StreamWriter]::new($entryStream, [Text.UTF8Encoding]::new($false), 4096, $true)
        try { $writer.Write($manifest) } finally { $writer.Dispose(); $entryStream.Dispose() }
    }
    finally {
        Write-Progress -Activity 'Empaquetando Reto Lulu' -Completed
        if ($zip) {
            try { $zip.Dispose() } catch { Write-Warning "No se pudo cerrar el ZIP: $($_.Exception.Message)" }
        }
        if ($stream) {
            try { $stream.Dispose() } catch { Write-Warning "No se pudo cerrar el archivo: $($_.Exception.Message)" }
        }
    }

    $archiveHash = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($ShaPath, "$archiveHash  $(Split-Path -Leaf $Archive)`n", (New-Object Text.UTF8Encoding($false)))
    Write-Host "Build creada: $Archive" -ForegroundColor Green

    if ($Publish) {
        $gh = 'C:\Program Files\GitHub CLI\gh.exe'
        if (-not (Test-Path -LiteralPath $gh -PathType Leaf)) { throw 'No se encontro GitHub CLI.' }
        & $gh release view "v$Version" --repo $Repo *> $null
        if ($LASTEXITCODE -eq 0) { throw "Ya existe la Release v$Version." }
        & $gh release create "v$Version" $Archive $ShaPath --repo $Repo --title "Reto Lulu $Version" --notes "Build $Version de Reto Lulu."
        if ($LASTEXITCODE -ne 0) { throw 'GitHub no pudo publicar la Release.' }
        Write-Host "Release v$Version publicada correctamente." -ForegroundColor Green
    }
    exit 0
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 1
}
