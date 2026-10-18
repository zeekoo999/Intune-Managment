<#
  Win32 app content (.intunewin)
  - Publish-IMWin32AppContent: uploads a .intunewin to an app (content version -> file -> Azure blob blocks -> commit)
    with SAS renewal, block retries and progress. Encryption info is saved per app so the content can be exported later.
  - Export-IMAppContent: downloads the encrypted content and rebuilds a .intunewin (needs the saved encryption info).
#>

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

function Read-IMIntuneWinPackage {
    <# Reads Detection.xml and locates the encrypted payload inside a .intunewin. #>
    param([Parameter(Mandatory)][string]$Path)
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $det = $zip.Entries | Where-Object { $_.FullName -match 'Metadata/Detection\.xml$' } | Select-Object -First 1
        if (-not $det) { throw "'$Path' is not a valid .intunewin (Detection.xml missing)." }
        $reader = [IO.StreamReader]::new($det.Open())
        [xml]$xml = $reader.ReadToEnd(); $reader.Dispose()
        $info = $xml.ApplicationInfo
        $payload = $zip.Entries | Where-Object { $_.FullName -match "Contents/$([regex]::Escape($info.FileName))$" } | Select-Object -First 1
        if (-not $payload) { throw "Encrypted payload '$($info.FileName)' not found in '$Path'." }
        [pscustomobject]@{
            Name = $info.Name; SetupFile = $info.SetupFile; FileName = $info.FileName
            UnencryptedSize = [long]$info.UnencryptedContentSize; EncryptedSize = $payload.Length; EntryName = $payload.FullName
            EncryptionInfo = [ordered]@{
                encryptionKey = $info.EncryptionInfo.EncryptionKey; macKey = $info.EncryptionInfo.MacKey
                initializationVector = $info.EncryptionInfo.InitializationVector; mac = $info.EncryptionInfo.Mac
                profileIdentifier = $info.EncryptionInfo.ProfileIdentifier ?? 'ProfileVersion1'
                fileDigest = $info.EncryptionInfo.FileDigest; fileDigestAlgorithm = $info.EncryptionInfo.FileDigestAlgorithm ?? 'SHA256'
            }
        }
    }
    finally { $zip.Dispose() }
}

function Find-IMAppPackage {
    <# Looks for a .intunewin for an app next to its export file or in a 'Packages' folder. #>
    param($App, [string]$File)
    if (-not $File) { return $null }
    $folder = Split-Path $File
    $base = [IO.Path]::GetFileNameWithoutExtension($File)
    $candidates = @(
        (Join-Path $folder "$base.intunewin")
        (Join-Path $folder ($App.fileName ?? '__none__'))
        (Join-Path (Join-Path $folder 'Packages') "$base.intunewin")
        (Join-Path (Join-Path $folder 'Packages') ($App.fileName ?? '__none__'))
    )
    $candidates | Where-Object { $_ -like '*.intunewin' -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

function Wait-IMContentFileState {
    param([string]$FileUri, [string]$SuccessState, [int]$TimeoutSeconds = 600)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $delay = 2
    while ((Get-Date) -lt $deadline) {
        $f = Invoke-IMGraphRequest -Uri $FileUri
        if ($f.uploadState -eq $SuccessState) { return $f }
        if ($f.uploadState -match 'Failed|TimedOut') { throw "Content upload state is '$($f.uploadState)'." }
        Start-Sleep -Seconds $delay
        $delay = [math]::Min(10, $delay + 2)
    }
    throw "Timed out waiting for content state '$SuccessState'."
}

function Publish-IMWin32AppContent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)][string]$PackagePath, $Operation, [int]$ChunkSizeMB = 6)

    $pkg = Read-IMIntuneWinPackage -Path $PackagePath
    Write-IMLog -Category 'AppContent' -Message "Uploading '$([IO.Path]::GetFileName($PackagePath))' ($([math]::Round($pkg.EncryptedSize / 1MB, 1)) MB) to app $AppId"
    $base = "/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp"
    $cv = Invoke-IMGraphRequest -Method POST -Uri "$base/contentVersions" -Body @{}
    $fileBody = [ordered]@{ '@odata.type' = '#microsoft.graph.mobileAppContentFile'; name = $pkg.FileName; size = $pkg.UnencryptedSize; sizeEncrypted = $pkg.EncryptedSize; manifest = $null; isDependency = $false }
    $cf = Invoke-IMGraphRequest -Method POST -Uri "$base/contentVersions/$($cv.id)/files" -Body $fileBody
    $fileUri = "$base/contentVersions/$($cv.id)/files/$($cf.id)"
    $cf = Wait-IMContentFileState -FileUri $fileUri -SuccessState 'azureStorageUriRequestSuccess'
    $sas = $cf.azureStorageUri
    $sasTime = Get-Date

    $zip = [IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $entry = $zip.Entries | Where-Object FullName -eq $pkg.EntryName
        $stream = $entry.Open()
        $chunk = $ChunkSizeMB * 1MB
        $buffer = [byte[]]::new($chunk)
        $ids = [Collections.Generic.List[string]]::new()
        $sent = 0L; $i = 0
        while ($true) {
            # Read a full chunk (zip streams can return partial reads)
            $read = 0
            while ($read -lt $chunk) { $n = $stream.Read($buffer, $read, $chunk - $read); if ($n -le 0) { break }; $read += $n }
            if ($read -le 0) { break }
            if (((Get-Date) - $sasTime).TotalMinutes -gt 7) {
                Invoke-IMGraphRequest -Method POST -Uri "$fileUri/renewUpload" -Body @{} | Out-Null
                $sas = (Wait-IMContentFileState -FileUri $fileUri -SuccessState 'azureStorageUriRenewalSuccess').azureStorageUri
                $sasTime = Get-Date
            }
            $blockId = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($i.ToString('0000')))
            if ($read -eq $chunk) { $data = $buffer } else { $data = [byte[]]::new($read); [Array]::Copy($buffer, $data, $read) }
            $ok = $false
            for ($attempt = 1; $attempt -le 5 -and -not $ok; $attempt++) {
                try {
                    $r = Invoke-IMHttp -Method PUT -Uri "$sas&comp=block&blockid=$([Uri]::EscapeDataString($blockId))" -BinaryBody $data -ContentType 'application/octet-stream' -Headers @{ 'x-ms-blob-type' = 'BlockBlob' } -TimeoutSeconds 300
                    if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { $ok = $true } else { throw "Blob upload returned $($r.StatusCode)" }
                }
                catch {
                    if ($attempt -eq 5) { throw "Uploading block $i failed: $($_.Exception.Message)" }
                    Write-IMLog -Level Warning -Category 'AppContent' -Message "Block $i failed (attempt $attempt): $($_.Exception.Message). Retrying."
                    Start-Sleep -Seconds ($attempt * 3)
                }
            }
            $ids.Add($blockId); $sent += $read; $i++
            if ($Operation) { Update-IMProgress -Operation $Operation -Status 'Uploading app content' -Current $sent -Total $pkg.EncryptedSize -Item "$([math]::Round($sent / 1MB, 1)) / $([math]::Round($pkg.EncryptedSize / 1MB, 1)) MB" }
        }
        $stream.Dispose()
    }
    finally { $zip.Dispose() }

    $xmlList = '<?xml version="1.0" encoding="utf-8"?><BlockList>' + (($ids | ForEach-Object { "<Latest>$_</Latest>" }) -join '') + '</BlockList>'
    $r = Invoke-IMHttp -Method PUT -Uri "$sas&comp=blocklist" -Body $xmlList -ContentType 'application/xml' -TimeoutSeconds 120
    if ($r.StatusCode -ge 300) { throw "Committing the block list failed ($($r.StatusCode))." }

    Invoke-IMGraphRequest -Method POST -Uri "$fileUri/commit" -Body @{ fileEncryptionInfo = $pkg.EncryptionInfo } | Out-Null
    Wait-IMContentFileState -FileUri $fileUri -SuccessState 'commitFileSuccess' | Out-Null
    Invoke-IMGraphRequest -Method PATCH -Uri "/deviceAppManagement/mobileApps/$AppId" -Body @{ '@odata.type' = '#microsoft.graph.win32LobApp'; committedContentVersion = $cv.id } | Out-Null

    # Keep encryption info so the content can be exported again later
    $keyFile = Join-Path (Get-IMAppDataPath 'AppKeys') "$AppId.json"
    Write-IMJsonFile $keyFile ([ordered]@{ AppId = $AppId; ContentVersion = $cv.id; FileName = $pkg.FileName; SetupFile = $pkg.SetupFile; Name = $pkg.Name; UnencryptedSize = $pkg.UnencryptedSize; EncryptionInfo = $pkg.EncryptionInfo })
    Write-IMLog -Level Success -Category 'AppContent' -Message "Content uploaded and committed for app $AppId (content version $($cv.id))"
}

function Export-IMAppContent {
    <# Downloads the encrypted content and rebuilds a re-uploadable .intunewin when the encryption info is known. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$App, [Parameter(Mandatory)][string]$Folder, [string]$BaseName)
    if (-not $BaseName) { $BaseName = Get-IMSafeFileName $App.displayName }
    $keyFile = Join-Path (Get-IMAppDataPath 'AppKeys') "$($App.id).json"
    $keys = if (Test-Path -LiteralPath $keyFile) { Read-IMJsonFile $keyFile } else { $null }
    if (-not $keys) {
        Write-IMLog -Level Warning -Category 'Export' -Message "No encryption info for '$($App.displayName)'. Intune does not return content keys, so only apps uploaded with this tool can be exported with content."
        return
    }
    $cvId = $App.committedContentVersion
    if (-not $cvId) { return }
    $base = "/deviceAppManagement/mobileApps/$($App.id)/microsoft.graph.win32LobApp/contentVersions/$cvId/files"
    $file = (Get-IMGraphCollection $base) | Where-Object isCommitted | Select-Object -Last 1
    if (-not $file.azureStorageUri) { Write-IMLog -Level Warning -Category 'Export' -Message "No download URL for '$($App.displayName)' content."; return }
    $resp = Invoke-IMHttp -Method GET -Uri $file.azureStorageUri -AsBytes -TimeoutSeconds 1800
    if ($resp.StatusCode -ne 200) { throw "Downloading content failed ($($resp.StatusCode))." }

    $target = Join-Path $Folder "$BaseName.intunewin"
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
    $zip = [IO.Compression.ZipFile]::Open($target, 'Create')
    try {
        $e = $zip.CreateEntry("IntuneWinPackage/Contents/$($keys.FileName)", 'NoCompression')
        $s = $e.Open(); $s.Write([byte[]]$resp.Content, 0, $resp.Content.Length); $s.Dispose()
        $ei = $keys.EncryptionInfo
        $xml = @"
<ApplicationInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" ToolVersion="1.8.4.0">
  <Name>$([Security.SecurityElement]::Escape($keys.Name))</Name>
  <UnencryptedContentSize>$($keys.UnencryptedSize)</UnencryptedContentSize>
  <FileName>$($keys.FileName)</FileName>
  <SetupFile>$([Security.SecurityElement]::Escape($keys.SetupFile))</SetupFile>
  <EncryptionInfo>
    <EncryptionKey>$($ei.encryptionKey)</EncryptionKey>
    <MacKey>$($ei.macKey)</MacKey>
    <InitializationVector>$($ei.initializationVector)</InitializationVector>
    <Mac>$($ei.mac)</Mac>
    <ProfileIdentifier>$($ei.profileIdentifier)</ProfileIdentifier>
    <FileDigest>$($ei.fileDigest)</FileDigest>
    <FileDigestAlgorithm>$($ei.fileDigestAlgorithm)</FileDigestAlgorithm>
  </EncryptionInfo>
</ApplicationInfo>
"@
        $m = $zip.CreateEntry('IntuneWinPackage/Metadata/Detection.xml')
        $w = [IO.StreamWriter]::new($m.Open(), [Text.UTF8Encoding]::new($false)); $w.Write($xml); $w.Dispose()
    }
    finally { $zip.Dispose() }
    Write-IMLog -Level Success -Category 'Export' -Message "Exported content for '$($App.displayName)' to $target"
}
