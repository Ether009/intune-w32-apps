[CmdletBinding()]
param(
    # Set by the registered odteamsync:// protocol handler when a toast notification button is
    # clicked. Format: "approve|<siteId>" or "reject|<siteId>". Not used on a normal login run.
    [string]$ToastCallback
)

$ErrorActionPreference = 'Stop'

$TenantId = '46d9804e-e6e3-433c-a5fe-766016144275'
$ClientId = '7a8d6e5a-734c-44ce-8673-3f7c05c47421'
$CertThumbprint = '5ACD0E673C1D5DA72BB2497C37D74A7F67F7AF25'

$LogDir = Join-Path $env:LOCALAPPDATA 'OneDriveTeamSync'
$LogFile = Join-Path $LogDir 'sync.log'
$DecisionsFile = Join-Path $LogDir 'decisions.json'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Write-Log {
    param([string]$Message)
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

#region Cert-based Graph auth (app-only, no client secret - cert lives in LocalMachine\My,
# deployed by the Win32 app installer with its private key readable only by Authenticated Users).
function Get-GraphToken {
    $cert = Get-Item "Cert:\LocalMachine\My\$CertThumbprint" -ErrorAction SilentlyContinue
    if (-not $cert) { $cert = Get-Item "Cert:\CurrentUser\My\$CertThumbprint" -ErrorAction Stop }

    $now = [DateTimeOffset]::UtcNow
    $header = @{ alg = 'RS256'; typ = 'JWT'; x5t = [Convert]::ToBase64String($cert.GetCertHash()) -replace '\+','-' -replace '/','_' -replace '=' } | ConvertTo-Json -Compress
    $payload = @{
        aud = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        iss = $ClientId
        sub = $ClientId
        jti = [guid]::NewGuid().ToString()
        nbf = $now.ToUnixTimeSeconds()
        exp = $now.AddMinutes(10).ToUnixTimeSeconds()
    } | ConvertTo-Json -Compress

    $toBase64Url = {
        param($bytes)
        [Convert]::ToBase64String($bytes) -replace '\+','-' -replace '/','_' -replace '='
    }
    $headerB64 = & $toBase64Url ([Text.Encoding]::UTF8.GetBytes($header))
    $payloadB64 = & $toBase64Url ([Text.Encoding]::UTF8.GetBytes($payload))
    $unsigned = "$headerB64.$payloadB64"

    $rsa = $cert.PrivateKey
    $signature = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($unsigned), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $sigB64 = & $toBase64Url $signature
    $clientAssertion = "$unsigned.$sigB64"

    $body = @{
        client_id             = $ClientId
        scope                 = 'https://graph.microsoft.com/.default'
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = $clientAssertion
        grant_type            = 'client_credentials'
    }
    $resp = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $body
    return $resp.access_token
}
#endregion

#region Decision persistence (remembers a rejected channel->team swap so we don't re-prompt)
function Get-Decisions {
    if (Test-Path $DecisionsFile) {
        try { return Get-Content $DecisionsFile -Raw | ConvertFrom-Json -AsHashtable } catch { return @{} }
    }
    return @{}
}
function Set-Decision {
    param([string]$SiteId, [string]$Decision)
    $decisions = Get-Decisions
    $decisions[$SiteId] = @{ decision = $Decision; timestamp = (Get-Date -Format 'o') }
    $decisions | ConvertTo-Json | Out-File -FilePath $DecisionsFile -Encoding UTF8
}
#endregion

#region Toast notification with Approve/Reject buttons routed back through the odteamsync://
# protocol (registered once at install time), since a script-hosted toast has no direct callback.
function Show-ConflictToast {
    param([string]$TeamName, [string]$SiteId)

    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

    $xml = [xml]@"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>OneDrive: sync conflict</text>
      <text>"$TeamName" already has a specific channel synced. Replace it with the full Team library instead?</text>
    </binding>
  </visual>
  <actions>
    <action content="Yes, replace it" arguments="odteamsync://approve/$SiteId" activationType="protocol" />
    <action content="No, leave as is" arguments="odteamsync://reject/$SiteId" activationType="protocol" />
  </actions>
</toast>
"@
    $toastXml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $toastXml.LoadXml($xml.OuterXml)
    $toast = New-Object Windows.UI.Notifications.ToastNotification $toastXml
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('OneDrive Team Sync').Show($toast)
}
#endregion

#region OneDrive registry state
function Get-SyncedLibraries {
    $root = 'HKCU:\Software\SyncEngines\Providers\OneDrive'
    if (-not (Test-Path $root)) { return @() }
    Get-ChildItem $root | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath
        if ($props.UrlNamespace -match ';\{([0-9a-fA-F-]+)\};\{([0-9a-fA-F-]+)\};\{([0-9a-fA-F-]+)\}') {
            [pscustomobject]@{
                RegistryKey = $_.PSPath
                MountPoint  = $props.MountPoint
                UrlNamespace = $props.UrlNamespace
                SiteId      = $Matches[1]
                WebId       = $Matches[2]
                ListId      = $Matches[3]
            }
        }
    }
}

function Remove-SyncedLibrary {
    param($Library, [switch]$DeleteLocalFolder)
    Write-Log "Removing sync: $($Library.UrlNamespace)"
    Remove-Item -Path $Library.RegistryKey -Recurse -Force -ErrorAction SilentlyContinue
    if ($DeleteLocalFolder -and $Library.MountPoint -and (Test-Path $Library.MountPoint)) {
        Remove-Item -Path $Library.MountPoint -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Add-SyncedLibrary {
    param($SiteId, $WebId, $ListId, $UserEmail, $WebUrl, $DisplayName)
    Add-Type -AssemblyName System.Web
    $url = "odopen://sync/?siteId=$([System.Web.HttpUtility]::UrlEncode("{$SiteId}"))" +
           "&webId=$([System.Web.HttpUtility]::UrlEncode("{$WebId}"))" +
           "&listId=$([System.Web.HttpUtility]::UrlEncode($ListId))" +
           "&userEmail=$([System.Web.HttpUtility]::UrlEncode($UserEmail))" +
           "&webUrl=$([System.Web.HttpUtility]::UrlEncode($WebUrl))" +
           "&webtitle=$([System.Web.HttpUtility]::UrlEncode($DisplayName).Replace('+','%20'))"
    Write-Log "Adding sync: $DisplayName ($WebUrl)"
    Start-Process $url
}
#endregion

#region Graph lookups
function Get-CurrentUserTeams {
    param($Token)
    $upn = (whoami /upn).Trim()
    $headers = @{ Authorization = "Bearer $Token" }
    $groups = Invoke-RestMethod -Headers $headers -Uri "https://graph.microsoft.com/v1.0/users/$upn/memberOf?`$select=id,displayName,resourceProvisioningOptions"
    return @{
        UserEmail = $upn
        Teams = $groups.value | Where-Object { $_.resourceProvisioningOptions -contains 'Team' }
    }
}

function Get-TeamSiteInfo {
    param($Token, $GroupId)
    $headers = @{ Authorization = "Bearer $Token" }
    $site = Invoke-RestMethod -Headers $headers -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/sites/root"
    $lists = Invoke-RestMethod -Headers $headers -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/sites/root/lists"
    # Match by template rather than a localized display name (the original script hardcoded the
    # Swedish "Delade Dokument" name, which silently broke for any differently-configured site).
    $docLib = $lists.value | Where-Object { $_.list.template -eq 'documentLibrary' } | Select-Object -First 1
    if (-not $docLib) { return $null }

    $ids = $site.id -split ','
    return [pscustomobject]@{
        SiteId   = $ids[1]
        WebId    = $ids[2]
        ListId   = $docLib.id
        WebUrl   = $site.webUrl
    }
}
#endregion

#region Toast callback handling (protocol handler re-invokes this script with -ToastCallback)
if ($ToastCallback) {
    Write-Log "Toast callback received: $ToastCallback"
    $parts = $ToastCallback -split '/'
    $action = $parts[0]
    $siteId = $parts[1]

    if ($action -eq 'approve') {
        Set-Decision -SiteId $siteId -Decision 'approved'
    } elseif ($action -eq 'reject') {
        Set-Decision -SiteId $siteId -Decision 'rejected'
    }
    # Fall through to a normal sync pass below so an approval is acted on immediately.
}
#endregion

#region Main sync pass
try {
    Write-Log "=== Sync run starting ==="
    $token = Get-GraphToken
    $userInfo = Get-CurrentUserTeams -Token $token
    Write-Log "User: $($userInfo.UserEmail), Teams: $($userInfo.Teams.Count)"

    $synced = @(Get-SyncedLibraries)
    $decisions = Get-Decisions
    $anyRemoved = $false

    $desiredSiteIds = @{}
    foreach ($team in $userInfo.Teams) {
        $info = Get-TeamSiteInfo -Token $token -GroupId $team.id
        if (-not $info) { Write-Log "Skipping $($team.displayName) - no document library found"; continue }
        $desiredSiteIds[$info.SiteId] = $info

        $existingForSite = $synced | Where-Object { $_.SiteId -eq $info.SiteId }
        $mainAlreadySynced = $existingForSite | Where-Object { $_.ListId -eq $info.ListId }
        if ($mainAlreadySynced) { continue }

        $channelSynced = $existingForSite | Where-Object { $_.ListId -ne $info.ListId }
        if ($channelSynced) {
            $decision = $decisions[$info.SiteId]
            if ($decision -and $decision.decision -eq 'approved') {
                foreach ($c in $channelSynced) { Remove-SyncedLibrary -Library $c -DeleteLocalFolder; $anyRemoved = $true }
                Add-SyncedLibrary -SiteId $info.SiteId -WebId $info.WebId -ListId $info.ListId -UserEmail $userInfo.UserEmail -WebUrl $info.WebUrl -DisplayName $team.displayName
            } elseif ($decision -and $decision.decision -eq 'rejected') {
                Write-Log "Skipping $($team.displayName) - user previously rejected the channel->team swap"
            } else {
                Write-Log "Conflict detected for $($team.displayName) - prompting"
                Show-ConflictToast -TeamName $team.displayName -SiteId $info.SiteId
            }
            continue
        }

        Add-SyncedLibrary -SiteId $info.SiteId -WebId $info.WebId -ListId $info.ListId -UserEmail $userInfo.UserEmail -WebUrl $info.WebUrl -DisplayName $team.displayName
    }

    # Remove syncs for sites that no longer correspond to a current Team membership.
    foreach ($lib in $synced) {
        if (-not $desiredSiteIds.ContainsKey($lib.SiteId)) {
            Remove-SyncedLibrary -Library $lib -DeleteLocalFolder
            $anyRemoved = $true
        }
    }

    if ($anyRemoved) {
        Write-Log "Restarting OneDrive to apply removals."
        Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Start-Process (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe')
    }

    Write-Log "=== Sync run complete ==="
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
}
#endregion
