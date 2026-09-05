[CmdletBinding()]
param(
    # Set by the registered odteamsync:// protocol handler when a toast notification button is
    # clicked. Format: "approve/<siteId>" or "reject/<siteId>". Not used on a normal login run.
    [string]$ToastCallback
)

$ErrorActionPreference = 'Stop'

$TenantId = '46d9804e-e6e3-433c-a5fe-766016144275'
$ClientId = '7a8d6e5a-734c-44ce-8673-3f7c05c47421'
$CertThumbprint = '5ACD0E673C1D5DA72BB2497C37D74A7F67F7AF25'

# How long a run with pending disconnect work waits for OneDrive to be closed before giving up and
# leaving it for the next run. Deliberately short: the run repeats hourly, so a close that happens
# outside this window is simply picked up by the next run, and there is no reason to hold a SYSTEM
# PowerShell process open for half of every hour waiting for something that usually will not happen
# during the wait anyway. It only needs to be long enough to catch someone acting on the toast.
$DisconnectWaitMinutes = 5

# How often to re-tell the user about disconnect work that is still waiting on them. Without this
# the notification fired once per *change* of the pending set, which in practice meant exactly one
# notification ever: a real day's log showed one at 15:23 and then six hourly runs that said
# nothing, because the pending set never changed. Since nothing can proceed until the user closes
# OneDrive, a reminder they missed once is a flow that never completes.
$RenotifyHours = 4

# AppUserModelID the toasts are shown under. This MUST be an AUMID Windows already has registered,
# and it is not free-form: an unregistered string makes CreateToastNotifier(...).Show() succeed with
# no error at all while the notification platform silently discards the toast - which is exactly why
# no toast from this script had ever appeared. Verified on a real device: with the old
# 'OneDrive Team Sync' nothing rendered and no key existed under
# HKCU\...\Notifications\Settings, while this one rendered immediately.
#
# Borrowing OneDrive's own identity is deliberate rather than lazy: every toast here is about
# OneDrive needing to be closed or restarted, so "OneDrive" is the honest sender from the user's
# point of view. Registering a distinct AUMID of our own would need a Start Menu shortcut carrying
# the System.AppUserModel.ID property (the registry key alone is not enough for a plain Win32
# process), so if a separate identity is ever wanted, that shortcut has to be installed and tested
# first - do not simply change this string and assume it works.
$ToastAppId = 'Microsoft.SkyDrive.Desktop'

# This script runs as SYSTEM (the AutoMountTeamSites registry path is writable only by
# SYSTEM/Administrators - a standard user, even the one this script is acting on behalf of,
# cannot write it - confirmed via a real ACL check on a real device). SYSTEM has no "current
# user" of its own, so almost everything below has to explicitly resolve and act on the actual
# interactively logged-on user instead of relying on $env:LOCALAPPDATA / HKCU / whoami, none of
# which mean anything useful under SYSTEM.

#region Resolve the interactive user (SYSTEM has none of its own)
# Native P/Invoke to launch a process inside another user's session - required because SYSTEM
# cannot interact with a user's desktop directly (restarting OneDrive so it releases file
# handles, and showing a toast notification, both need to happen IN that user's session).
$runAsUserSource = @'
using System;
using System.Runtime.InteropServices;

public static class RunAsUser
{
    [DllImport("wtsapi32.dll", SetLastError = true)]
    static extern bool WTSQueryUserToken(uint sessionId, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool DuplicateTokenEx(IntPtr hExistingToken, uint dwDesiredAccess, IntPtr lpTokenAttributes,
        int impersonationLevel, int tokenType, out IntPtr phNewToken);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges,
        ref TOKEN_PRIVILEGES NewState, uint BufferLengthInBytes, IntPtr PreviousState, IntPtr ReturnLengthInBytes);

    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();

    [StructLayout(LayoutKind.Sequential)]
    struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID Luid; public uint Attributes; }

    // WTSQueryUserToken requires SeTcbPrivilege to be actively enabled on the calling token, not
    // merely present - confirmed for real that a SYSTEM token launched via a raw PsExec -s child
    // has it present but disabled, which makes WTSQueryUserToken fail silently (a real Scheduled
    // Task launch of this same script may or may not already have it enabled depending on how
    // it's invoked, so enabling it explicitly here removes the ambiguity rather than relying on
    // the launch method to have gotten it right).
    public static void EnableTcbPrivilege()
    {
        IntPtr hToken;
        if (!OpenProcessToken(GetCurrentProcess(), 0x0020 /* TOKEN_ADJUST_PRIVILEGES */ | 0x0008 /* TOKEN_QUERY */, out hToken))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "OpenProcessToken failed");
        try
        {
            LUID luid;
            if (!LookupPrivilegeValue(null, "SeTcbPrivilege", out luid))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "LookupPrivilegeValue(SeTcbPrivilege) failed");
            var tp = new TOKEN_PRIVILEGES { PrivilegeCount = 1, Luid = luid, Attributes = 0x00000002 /* SE_PRIVILEGE_ENABLED */ };
            if (!AdjustTokenPrivileges(hToken, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "AdjustTokenPrivileges(SeTcbPrivilege) failed");
        }
        finally { CloseHandle(hToken); }
    }

    [DllImport("userenv.dll", SetLastError = true)]
    static extern bool CreateEnvironmentBlock(out IntPtr lpEnvironment, IntPtr hToken, bool bInherit);

    [DllImport("userenv.dll", SetLastError = true)]
    static extern bool DestroyEnvironmentBlock(IntPtr lpEnvironment);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFO
    {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX; public int dwY; public int dwXSize; public int dwYSize;
        public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute; public int dwFlags;
        public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
        public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION
    {
        public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId;
    }

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessAsUser(IntPtr hToken, string lpApplicationName, string lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags,
        IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    public static int Start(uint sessionId, string commandLine)
    {
        // Every failure below throws with GetLastError rather than returning bool - a prior
        // version swallowed all of this via "| Out-Null" on the PowerShell side, which let a
        // silently-failed OneDrive /shutdown look identical to a successful one until the code
        // that waited for the process to actually exit timed out with no clue why.
        IntPtr userToken;
        if (!WTSQueryUserToken(sessionId, out userToken))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "WTSQueryUserToken failed for session " + sessionId);

        IntPtr dupToken;
        // SecurityImpersonation = 2, TokenPrimary = 1, TOKEN_ALL_ACCESS-ish via 0xF01FF
        if (!DuplicateTokenEx(userToken, 0xF01FF, IntPtr.Zero, 2, 1, out dupToken))
        {
            int err = Marshal.GetLastWin32Error();
            CloseHandle(userToken);
            throw new System.ComponentModel.Win32Exception(err, "DuplicateTokenEx failed");
        }

        IntPtr env;
        if (!CreateEnvironmentBlock(out env, dupToken, false))
        {
            // Not fatal on its own, but worth being loud about: with a null block the new process
            // inherits SYSTEM's environment, so %LOCALAPPDATA% and friends point at
            // config\systemprofile instead of the user's profile.
            env = IntPtr.Zero;
        }

        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        // MUST be the empty string, not "winsta0\\default" and not null. Measured on a real
        // machine: with "winsta0\\default" every launch - OneDrive, notepad, anything - was
        // created successfully (CreateProcessAsUser returns TRUE with a real PID) and was then
        // killed during startup with exit code 0xC0000142 STATUS_DLL_INIT_FAILED, because a
        // session-0 caller has that name resolved against session 0's window station, which the
        // user's session token cannot attach to, so user32's DllMain fails before Main runs. That
        // is the whole reason "restart OneDrive" used to report success while leaving OneDrive
        // stopped. null behaved the same way but intermittently; "" is the documented way to say
        // "give me the default desktop of the token's own session" and was the only value that
        // worked every time.
        si.lpDesktop = "";

        PROCESS_INFORMATION pi;
        // CREATE_UNICODE_ENVIRONMENT (0x400) | CREATE_NO_WINDOW (0x08000000). The 0x400 is not
        // optional while an environment block is passed - without it CreateProcessAsUser rejects
        // the Unicode block with ERROR_INVALID_PARAMETER (87).
        //
        // lpCurrentDirectory must also be a real, explicitly named directory. Passing null makes
        // the child inherit the *caller's* current directory, which is then resolved against the
        // *user's* token; when SYSTEM's working directory is not something that user can resolve,
        // CreateProcessAsUser fails outright with ERROR_INVALID_NAME (123) before the image is
        // ever loaded. The Windows directory is always present and always readable.
        string workingDir = Environment.GetEnvironmentVariable("SystemRoot");
        if (string.IsNullOrEmpty(workingDir)) workingDir = "C:\\Windows";

        bool ok = CreateProcessAsUser(dupToken, null, commandLine, IntPtr.Zero, IntPtr.Zero, false,
            0x08000400, env, workingDir, ref si, out pi);
        int createErr = ok ? 0 : Marshal.GetLastWin32Error();
        int newPid = ok ? pi.dwProcessId : 0;

        if (env != IntPtr.Zero) DestroyEnvironmentBlock(env);
        CloseHandle(dupToken);
        CloseHandle(userToken);
        if (ok) { CloseHandle(pi.hProcess); CloseHandle(pi.hThread); }
        if (!ok) throw new System.ComponentModel.Win32Exception(createErr, "CreateProcessAsUser failed for: " + commandLine);
        return newPid;
    }
}
'@
Add-Type -TypeDefinition $runAsUserSource -ErrorAction SilentlyContinue

function Get-InteractiveUserContext {
    # explorer.exe only runs in an interactive user's own session, never SYSTEM's or a service
    # session - its owner and session ID reliably identify "the person actually sitting here."
    $proc = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1
    if (-not $proc) { throw "No interactive user session found (explorer.exe not running)." }
    $ownerSid = (Invoke-CimMethod -InputObject $proc -MethodName GetOwnerSid).Sid

    $profilePath = (Get-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$ownerSid").ProfileImagePath

    return [pscustomobject]@{
        Sid           = $ownerSid
        SessionId     = [uint32]$proc.SessionId
        ProfilePath   = $profilePath
        LocalAppData  = Join-Path $profilePath 'AppData\Local'
        HkuRoot       = "Registry::HKEY_USERS\$ownerSid"
    }
}

function Start-ProcessInUserSession {
    # Logs the PID rather than returning it, so callers stay side-effect free. The PID matters:
    # a process that is created and then dies during startup looks exactly like a process that
    # was never created unless you can go back and ask what happened to that specific PID.
    param([Parameter(Mandatory)][uint32]$SessionId, [Parameter(Mandatory)][string]$CommandLine)
    $newPid = [RunAsUser]::Start($SessionId, $CommandLine)
    Write-Log "Launched PID $newPid in session ${SessionId}: $CommandLine"
}
#endregion

[RunAsUser]::EnableTcbPrivilege()
$UserContext = Get-InteractiveUserContext
$LogDir = Join-Path $UserContext.LocalAppData 'OneDriveTeamSync'
$LogFile = Join-Path $LogDir 'sync.log'
$DecisionsFile = Join-Path $LogDir 'decisions.json'
$SiteCacheFile = Join-Path $LogDir 'sitecache.json'
$PendingFile = Join-Path $LogDir 'pending.json'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Write-Log {
    param([string]$Message)
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

#region Cert-based Graph auth (app-only, no client secret). Running as SYSTEM, the cert's
# private key is accessible without any special ACL grant - LocalMachine\My is
# SYSTEM/Administrators-only by default, which is exactly what we want now.
function Get-GraphToken {
    $cert = Get-Item "Cert:\LocalMachine\My\$CertThumbprint" -ErrorAction Stop

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

    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
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

#region Local JSON state (decisions, site-info cache, pending-disconnect bookkeeping)
function Read-JsonHashtable {
    # ConvertFrom-Json -AsHashtable is PowerShell 6+ only, and this runs under Windows PowerShell
    # 5.1 - the previous code used it inside a try/catch that swallowed the resulting error, so
    # every read silently returned an empty hashtable and no decision was ever actually remembered.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @{} }
    try {
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        return @{}
    }
    $result = @{}
    if ($json) {
        foreach ($p in $json.PSObject.Properties) { $result[$p.Name] = $p.Value }
    }
    return $result
}

function Write-JsonHashtable {
    param([string]$Path, $Value)
    $Value | ConvertTo-Json -Depth 5 | Out-File -FilePath $Path -Encoding UTF8
}

function Get-Decisions { Read-JsonHashtable -Path $DecisionsFile }

function Set-Decision {
    param([string]$SiteId, [string]$Decision)
    $decisions = Get-Decisions
    $decisions[$SiteId] = @{ decision = $Decision; timestamp = (Get-Date -Format 'o') }
    Write-JsonHashtable -Path $DecisionsFile -Value $decisions
}

# A group's SharePoint site and document-library ids never change once provisioned, but resolving
# them costs two Graph calls per group on every single run - by far the bulk of this script's Graph
# traffic (1 + 2N calls for N groups). Caching them locally reduces a steady-state run to just the
# token request plus the one /memberOf call that genuinely has to be fresh, which is what makes
# running this on a repeating schedule rather than only at logon reasonable.
function Get-SiteCache { Read-JsonHashtable -Path $SiteCacheFile }
function Save-SiteCache { param($Cache) Write-JsonHashtable -Path $SiteCacheFile -Value $Cache }

# Tracks disconnect work that can't be completed right now because OneDrive is running: used to
# rate-limit the notification so it isn't re-shown on every repeat run, and to carry the "the user
# asked us to restart OneDrive" flag set by the toast's button (see the ToastCallback region).
function Get-PendingState { Read-JsonHashtable -Path $PendingFile }
function Save-PendingState { param($State) Write-JsonHashtable -Path $PendingFile -Value $State }
#endregion

#region Toast notification with Approve/Reject buttons, shown inside the user's own session
# (a toast raised directly from SYSTEM would never reach their desktop at all) via the
# odteamsync:// protocol handler routing the button click back into this same script.
function ConvertTo-XmlText {
    # Library and group names here are real user-facing names and can legitimately contain & or
    # quotes, which would otherwise produce malformed toast XML and no notification at all.
    param([string]$Text)
    return [System.Security.SecurityElement]::Escape($Text)
}

function Show-Toast {
    param([string]$ToastXml)

    $toastScript = @"
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
`$xml = [xml]@'
$ToastXml
'@
`$toastXml = New-Object Windows.Data.Xml.Dom.XmlDocument
`$toastXml.LoadXml(`$xml.OuterXml)
`$toast = New-Object Windows.UI.Notifications.ToastNotification `$toastXml
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('$ToastAppId').Show(`$toast)
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($toastScript))
    Start-ProcessInUserSession -SessionId $UserContext.SessionId -CommandLine "powershell.exe -NoProfile -WindowStyle Hidden -EncodedCommand $encoded"
}

function Show-ConflictToast {
    param([string]$TeamName, [string]$SiteId)
    $safeName = ConvertTo-XmlText $TeamName
    Show-Toast -ToastXml @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>OneDrive: sync conflict</text>
      <text>"$safeName" already has a specific channel synced. Replace it with the full Team library instead?</text>
    </binding>
  </visual>
  <actions>
    <action content="Yes, replace it" arguments="odteamsync://approve/$SiteId" activationType="protocol" />
    <action content="No, leave as is" arguments="odteamsync://reject/$SiteId" activationType="protocol" />
  </actions>
</toast>
"@
}

function Show-DisconnectPendingToast {
    # Disconnecting a library can only be done while OneDrive is stopped (its own sync engine holds
    # the sync root open - CfUnregisterSyncRoot fails outright otherwise), and force-stopping it
    # underneath someone mid-work isn't acceptable on a repeating schedule. So tell them what
    # happened and let them stop OneDrive when it suits, rather than doing it to them.
    #
    # No action buttons, deliberately. Measured on a real device: toasts from this script render
    # reliably, but their <actions> are silently dropped - no buttons appeared for a custom
    # protocol, for a known-good system protocol (ms-settings:), or under three different
    # AppUserModelIDs. Interactive toasts from a classic Win32 process need an AUMID backed by the
    # calling app's own Start Menu shortcut (and, for activation, a registered COM activator);
    # borrowing someone else's registered AUMID gets the toast shown but not its buttons. Rather
    # than ship a button that silently does not exist, the instruction lives in the text. The
    # user quitting OneDrive from the tray is what actually completes the disconnect, and that
    # path is watched for and proven to work end to end.
    param([string[]]$Names)
    $what = if ($Names.Count -eq 1) { "`"$(ConvertTo-XmlText $Names[0])`" is no longer shared with you" }
            else { "$($Names.Count) SharePoint libraries are no longer shared with you" }
    Show-Toast -ToastXml @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>OneDrive sync needs to finish an update</text>
      <text>$what and will be removed from your synced folders. To finish, right-click the OneDrive cloud icon in the taskbar and choose "Quit OneDrive" when convenient - it will restart on its own.</text>
    </binding>
  </visual>
</toast>
"@
}
#endregion

#region OneDrive registry state - actual live syncs (under the target user's own hive, not HKCU)
function Get-SyncedLibraries {
    $root = "$($UserContext.HkuRoot)\Software\SyncEngines\Providers\OneDrive"
    if (-not (Test-Path $root)) { return @() }
    Get-ChildItem $root | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath
        # UrlNamespace is a plain URL with no embedded ids in real data ("https://tenant.sharepoint.com
        # /sites/xxx/Delade dokument/") - SiteId/WebId/ListId below are left null and resolved
        # separately (see Get-LibrarySiteIdentifiers) only for the libraries actually being
        # disconnected, rather than guessed here from a pattern that doesn't match reality.
        [pscustomobject]@{
            RegistryKey  = $_.PSPath
            SyncId       = $_.PSChildName
            MountPoint   = $props.MountPoint
            UrlNamespace = $props.UrlNamespace
            SiteId       = $null
            WebId        = $null
            ListId       = $null
        }
    }
}

function Get-SitePathFromUrl {
    param($Url)
    if ($Url -match '^https://[^/]+/sites/([^/]+)/?') { return $Matches[1] }
    return $null
}

function Get-LibrarySiteIdentifiers {
    # A library being disconnected needs its real SiteId/WebId/ListId to build the ClientPolicy
    # ini filename (see Remove-OneDriveDeepSyncState) - UrlNamespace alone doesn't carry them.
    # Prefer the TenantAutoMount entry this tool itself wrote when it added the library (no extra
    # Graph call, and the ListId embedded there beats re-deriving one via template-matching);
    # fall back to a live Graph lookup by site path for anything that arrived without one (a
    # manually-added library, or a prior partial run that already cleared its entry).
    param($Token, $Library, $AutoMounted)
    if ($Library.UrlNamespace -match '^https://([^/]+)/sites/([^/]+)/') {
        $sitePath = $Matches[2]
        $match = $AutoMounted | Where-Object { $_.Data -match [regex]::Escape("/sites/$sitePath") } | Select-Object -First 1
        if ($match -and $match.Data -match 'webId=\{?([0-9a-fA-F-]+)\}?.*listId=([0-9a-fA-F-]+).*webUrl=([^&]+)') {
            return [pscustomobject]@{ SiteId = $match.SiteId; WebId = $Matches[1]; ListId = $Matches[2]; WebUrl = $Matches[3] }
        }
    }
    return Resolve-SiteInfoFromUrl -Token $Token -UrlNamespace $Library.UrlNamespace
}

function Get-OneDriveExePath {
    # OneDrive can be installed per-machine (Program Files) or per-user (LocalAppData) depending
    # on how it was deployed - confirmed for real that this fleet uses the per-machine install,
    # not the per-user one this originally assumed. Check both rather than hardcode either.
    $candidates = @(
        'C:\Program Files\Microsoft OneDrive\OneDrive.exe',
        (Join-Path $UserContext.LocalAppData 'Microsoft\OneDrive\OneDrive.exe')
    )
    $found = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $found) { throw "Could not locate OneDrive.exe in any known install location." }
    return $found
}

function Get-OneDriveProcess {
    Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $UserContext.SessionId } | Select-Object -First 1
}

function Wait-ForOneDriveToExit {
    # Returns $true once OneDrive is no longer running. This script never stops OneDrive itself
    # anymore: a disconnect needs it stopped, but forcing that on a repeating schedule would kill
    # it under someone mid-work, and asking it to stop gracefully proved unreliable anyway (a
    # OneDrive busy retrying a library whose access was just revoked never processes /shutdown).
    # Instead the user is told what's pending and stops it when convenient - via the toast's
    # button, or just by quitting OneDrive themselves, which this also picks up.
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-OneDriveProcess)) { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Start-OneDriveProcess {
    # The reason a launch could "succeed" and leave OneDrive stopped is fixed at its source now
    # (see the lpDesktop note in RunAsUser::Start - the process really was being created and then
    # killed at DLL init). This verify-and-retry stays anyway: it costs nothing on the happy path,
    # it is the only thing that turned that failure from silent into visible in the first place,
    # and OneDrive can still legitimately decline to start while it is tearing down a previous
    # instance. What it must never go back to being is a substitute for an explanation.
    param([int]$MaxAttempts = 5, [int]$CheckDelaySeconds = 5)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Log "Restarting OneDrive (attempt $attempt of $MaxAttempts)."
        Start-ProcessInUserSession -SessionId $UserContext.SessionId -CommandLine "`"$(Get-OneDriveExePath)`" /background"
        Start-Sleep -Seconds $CheckDelaySeconds
        if (Get-OneDriveProcess) { return }
    }
    Write-Log "ERROR: OneDrive did not start after $MaxAttempts attempts - it is left stopped."
}

# Cloud Filter API (cldapi.dll) - the public Win32 API any cloud-sync provider (OneDrive included)
# registers/unregisters a synced folder ("sync root") through at the OS level. Confirmed for real,
# against a live tenant, that this - not any of the registry surfaces below - is the actual
# authoritative switch: CfGetSyncRootInfoByPath succeeding means Windows still considers the path
# a live cloud sync root regardless of what OneDrive's own registry mirrors say.
if (-not ("CloudFilter.Api" -as [type])) {
    Add-Type -Namespace CloudFilter -Name Api -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("cldapi.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int CfUnregisterSyncRoot(string syncRootPath);
[System.Runtime.InteropServices.DllImport("cldapi.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int CfGetSyncRootInfoByPath(string filePath, int infoClass, System.IntPtr syncRootInfo, uint syncRootInfoLength, out uint returnedLength);
"@
}

# HRESULT for the underlying Win32 error "not a cloud file" (ERROR_NOT_A_CLOUD_FILE) - what
# CfGetSyncRootInfoByPath returns for a path that is confirmed NOT registered as a sync root.
$script:CF_NOT_A_CLOUD_FILE_HRESULT = 0x80070186

function Test-SyncRootRegistered {
    # $true = still a live sync root. $false = confirmed unregistered. Throws on anything else,
    # since an unrecognized error here means we don't actually know the state - and per the
    # incidents that got us here, an unknown state must never be treated as "safe to delete."
    param($Path)
    $buf = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(8200)
    try {
        [uint32]$outLen = 0
        $hr = [CloudFilter.Api]::CfGetSyncRootInfoByPath($Path, 0, $buf, 8200, [ref]$outLen)
        if ($hr -eq 0) { return $true }
        if ($hr -eq $script:CF_NOT_A_CLOUD_FILE_HRESULT) { return $false }
        throw "CfGetSyncRootInfoByPath returned unexpected HRESULT 0x{0:X8} for $Path" -f $hr
    } finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
    }
}

function Invoke-UnregisterSyncRoot {
    param($Path)
    $hr = [CloudFilter.Api]::CfUnregisterSyncRoot($Path)
    if ($hr -ne 0) { throw "CfUnregisterSyncRoot failed for $Path with HRESULT 0x{0:X8}" -f $hr }
}

function Remove-OneDriveDeepSyncState {
    # OneDrive rebuilds SyncEngines\Providers\OneDrive and its Cloud Filter sync-root registration
    # FROM this state on every start - confirmed for real that removing only those two downstream
    # copies (plus even the TenantAutoMount policy entry) is not durable: OneDrive fully
    # re-registered a stale sync from this ini state alone on its next restart. This must run
    # while OneDrive is stopped (it owns these files while running).
    param($SyncId, $SiteId, $ListId)
    $settingsDir = "$($UserContext.LocalAppData)\Microsoft\OneDrive\settings\$($script:OneDriveAccountName)"
    $siteIdRaw = $SiteId -replace '[{}-]', ''
    $listIdRaw = $ListId -replace '[{}-]', ''

    $clientPolicyFile = Join-Path $settingsDir "ClientPolicy_${listIdRaw}_${siteIdRaw}.ini"
    if (Test-Path -LiteralPath $clientPolicyFile) {
        Remove-Item -LiteralPath $clientPolicyFile -Force
    }

    Remove-ItemProperty -LiteralPath "$($UserContext.HkuRoot)\Software\Microsoft\OneDrive\Accounts\$($script:OneDriveAccountName)\ScopeIdToMountPointPathCache" -Name $SyncId -ErrorAction SilentlyContinue

    # The account-scoped ini is named after the account's own GUID (OneAuthAccountId), not the
    # "Business1"-style key name - resolved once and stashed alongside the other account details.
    $accountIniFile = Join-Path $settingsDir "$($script:OneDriveOneAuthAccountId).ini"
    if (Test-Path -LiteralPath $accountIniFile) {
        $syncIdEscaped = [regex]::Escape($SyncId)
        $tmp = "$accountIniFile.tmp"
        Get-Content -LiteralPath $accountIniFile -Encoding Unicode | Where-Object { $_ -notmatch $syncIdEscaped } | Set-Content -LiteralPath $tmp -Encoding Unicode
        Remove-Item -LiteralPath $accountIniFile -Force
        Rename-Item -LiteralPath $tmp -NewName (Split-Path $accountIniFile -Leaf)
    }

    Remove-Item -Path "$($UserContext.HkuRoot)\Software\SyncEngines\Providers\OneDrive\$SyncId" -Recurse -Force -ErrorAction SilentlyContinue
}

function Remove-StaleLocalFolders {
    param($Libraries)
    foreach ($lib in $Libraries) {
        if ($lib.MountPoint -and (Test-Path $lib.MountPoint)) {
            Write-Log "Deleting local folder (verified unsynced): $($lib.MountPoint)"
            Remove-Item -Path $lib.MountPoint -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
#endregion

#region OneDrive AutoMountTeamSites policy state - silent add mechanism
# Verified directly against the real OneDrive.admx on this machine (not documentation alone):
#   policy AutoMountTeamSites -> list key "Software\Policies\Microsoft\OneDrive\TenantAutoMount",
#   additive, explicitValue. Each list entry is one REG_SZ value under that key: the value NAME
# is an arbitrary label (used here as the site's own GUID, so re-runs can match existing entries
# deterministically), and the value DATA is
# "tenantId={..}&siteId={..}&webId={..}&listId=..&webUrl=https://..&version=1".
# OneDrive itself picks these up on its own (next OneDrive.exe start / within its own window) -
# no window, no user interaction, unlike odopen://. Confirmed via Microsoft's own documentation
# that REMOVING an entry does NOT automatically unsync an already-synced library - this only
# replaces the add path; removal still goes through Remove-OneDriveDeepSyncState/Invoke-
# UnregisterSyncRoot in the main pass's Disconnect region.
#
# Confirmed via a real ACL check that this key is writable only by SYSTEM/Administrators, even
# for the user it's acting on behalf of - this is why this whole script runs as SYSTEM and
# operates on the target user's hive under HKEY_USERS rather than as that user directly.
function Get-AutoMountRegPath { "$($UserContext.HkuRoot)\SOFTWARE\Policies\Microsoft\OneDrive\TenantAutoMount" }

function Get-AutoMountEntries {
    $path = Get-AutoMountRegPath
    if (-not (Test-Path $path)) { return @() }
    $props = Get-ItemProperty -LiteralPath $path
    $props.PSObject.Properties |
        Where-Object { $_.Name -notmatch '^PS' } |
        ForEach-Object {
            if ($_.Value -match 'siteId=\{?([0-9a-fA-F-]+)\}?') {
                [pscustomobject]@{ ValueName = $_.Name; SiteId = $Matches[1]; Data = $_.Value }
            }
        }
}

function Set-AutoMountEntry {
    param($SiteId, $WebId, $ListId, $WebUrl, $DisplayName)
    $path = Get-AutoMountRegPath
    if (-not (Test-Path $path)) {
        New-Item -Path $path -Force | Out-Null
    }
    $data = "tenantId={$TenantId}&siteId={$SiteId}&webId={$WebId}&listId=$ListId&webUrl=$WebUrl&version=1"
    Write-Log "Setting auto-mount entry for $DisplayName (site $SiteId)"
    Set-ItemProperty -LiteralPath $path -Name $SiteId -Value $data -Type String
}

function Remove-AutoMountEntry {
    param($SiteId)
    Write-Log "Removing auto-mount entry for site $SiteId"
    Remove-ItemProperty -LiteralPath (Get-AutoMountRegPath) -Name $SiteId -ErrorAction SilentlyContinue
}
#endregion

#region Graph lookups
function Get-CurrentUserUpn {
    # whoami /upn only reflects the process's own identity (SYSTEM has none) - read it straight
    # out of the target user's own OneDrive account registration instead, matched by tenant ID
    # in case they have multiple OneDrive accounts configured. This is the same technique the
    # old tool used, which was actually the right call for a SYSTEM-context script - it just
    # wasn't SYSTEM-context before.
    $accountsPath = "$($UserContext.HkuRoot)\Software\Microsoft\OneDrive\Accounts"
    if (-not (Test-Path $accountsPath)) { throw "No OneDrive accounts found under the user's hive." }
    foreach ($account in Get-ChildItem $accountsPath) {
        $props = Get-ItemProperty $account.PSPath -ErrorAction SilentlyContinue
        if ($props.ConfiguredTenantId -eq $TenantId -and $props.UserEmail) {
            # Stashed for Remove-OneDriveDeepSyncState below - avoids re-deriving which
            # Accounts sub-key belongs to this tenant a second time.
            $script:OneDriveAccountName = $account.PSChildName
            $script:OneDriveOneAuthAccountId = $props.OneAuthAccountId
            return $props.UserEmail
        }
    }
    throw "No OneDrive account configured for tenant $TenantId under the user's hive."
}

function Get-CurrentUserTeams {
    # Any Microsoft 365 Group the user belongs to, not just ones that have gone through Teams
    # provisioning - the tool was never meant to require that. Filtering on
    # resourceProvisioningOptions -contains 'Team' excluded a real group the user created and
    # was a member of, because Teams-specific provisioning is a separate, sometimes-delayed step
    # from the group (and its SharePoint site) actually existing - groupTypes -contains 'Unified'
    # is what actually distinguishes an M365 Group (has a SharePoint site) from a plain security
    # group (doesn't), independent of whether it's also been made into a Team.
    param($Token, $Upn)
    $headers = @{ Authorization = "Bearer $Token" }
    $groups = Invoke-RestMethod -Headers $headers -Uri "https://graph.microsoft.com/v1.0/users/$Upn/memberOf?`$select=id,displayName,groupTypes"
    return $groups.value | Where-Object { $_.groupTypes -contains 'Unified' }
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

function Resolve-SiteInfoFromUrl {
    # Fallback for a stale library being disconnected whose site's Team the user is no longer a
    # member of (so Get-TeamSiteInfo's group-scoped lookup isn't usable) and that has no matching
    # TenantAutoMount entry to read the ids from either (e.g. a prior partial run already cleared
    # it). UrlNamespace only gives us the site's path, not its ids - resolve the rest from Graph
    # directly by that path instead of guessing.
    param($Token, $UrlNamespace)
    if ($UrlNamespace -notmatch '^https://([^/]+)/sites/([^/]+)/') { return $null }
    $hostname = $Matches[1]; $sitePath = $Matches[2]
    $headers = @{ Authorization = "Bearer $Token" }
    $site = Invoke-RestMethod -Headers $headers -Uri "https://graph.microsoft.com/v1.0/sites/${hostname}:/sites/${sitePath}"
    $lists = Invoke-RestMethod -Headers $headers -Uri "https://graph.microsoft.com/v1.0/sites/$($site.id)/lists"
    $docLib = $lists.value | Where-Object { $_.list.template -eq 'documentLibrary' } | Select-Object -First 1
    if (-not $docLib) { return $null }
    $ids = $site.id -split ','
    return [pscustomobject]@{ SiteId = $ids[1]; WebId = $ids[2]; ListId = $docLib.id; WebUrl = $site.webUrl }
}
#endregion

#region Toast callback handling (protocol handler re-invokes this script with -ToastCallback)
# Clicking a toast button re-invokes this script AS THE USER who clicked it (that's their own
# session, not SYSTEM), unlike the normal logon-triggered run. Rather than have two different
# security contexts both needing to authenticate to Graph, just record the decision here (a
# plain per-user JSON file, no elevated access needed) and stop - the next SYSTEM-context logon
# run picks up the decision and acts on it. That means an approval takes effect at the user's
# next login rather than instantly, which is an acceptable tradeoff for not needing the
# certificate's private key to be readable outside SYSTEM/Administrators at all.
if ($ToastCallback) {
    Write-Log "Toast callback received: $ToastCallback"
    # The protocol handler hands us the whole URL ("odteamsync://approve/<siteId>"), so the scheme
    # has to come off first - splitting the raw string on "/" put "odteamsync:" in the action slot
    # and silently matched nothing at all, which is why no toast button has ever done anything.
    $parts = ($ToastCallback -replace '^\s*odteamsync:/*', '').TrimEnd('/') -split '/'
    $action = $parts[0]
    $siteId = if ($parts.Count -gt 1) { $parts[1] } else { $null }

    switch ($action) {
        'approve' {
            Set-Decision -SiteId $siteId -Decision 'approved'
            Write-Log "Decision recorded - will be applied on the next sync run."
        }
        'reject' {
            Set-Decision -SiteId $siteId -Decision 'rejected'
            Write-Log "Decision recorded - will be applied on the next sync run."
        }
        'restart-onedrive' {
            # Runs as the user who clicked, not SYSTEM, so it can simply stop their own OneDrive.
            # The flag tells the SYSTEM-context run that this shutdown was asked for, so OneDrive
            # gets started again once the pending disconnect work has actually been completed -
            # whether that's the run already waiting for this, or the next scheduled one.
            $pending = Get-PendingState
            $pending['restartRequested'] = $true
            Save-PendingState -State $pending
            Write-Log "User asked for the OneDrive restart - stopping OneDrive."
            Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        'dismiss' { Write-Log "User dismissed the pending-disconnect notification." }
        default { Write-Log "Unrecognized toast callback action: $action" }
    }
    exit 0
}
#endregion

#region Main sync pass
try {
    Write-Log "=== Sync run starting ==="
    $token = Get-GraphToken
    $upn = Get-CurrentUserUpn
    $teams = @(Get-CurrentUserTeams -Token $token -Upn $upn)
    Write-Log "User: $upn, Teams: $($teams.Count)"

    $synced = @(Get-SyncedLibraries)
    $autoMounted = @(Get-AutoMountEntries)
    $decisions = Get-Decisions

    # Resolve desired state first - removals have to happen before additions so a channel/team
    # conflict on the same site is actually clear by the time we try to add the replacement.
    # Site/list ids come from the local cache where possible: they're fixed for the life of the
    # group, so re-fetching them every run was two Graph calls per group for data that never
    # changed. Only groups the cache hasn't seen cost anything now.
    $siteCache = Get-SiteCache
    $cacheChanged = $false
    $desired = @{}
    foreach ($team in $teams) {
        $cached = $siteCache[$team.id]
        if ($cached -and $cached.SiteId -and $cached.WebId -and $cached.ListId -and $cached.WebUrl) {
            $info = [pscustomobject]@{ SiteId = $cached.SiteId; WebId = $cached.WebId; ListId = $cached.ListId; WebUrl = $cached.WebUrl }
        } else {
            $info = Get-TeamSiteInfo -Token $token -GroupId $team.id
            if ($info) {
                $siteCache[$team.id] = @{ SiteId = $info.SiteId; WebId = $info.WebId; ListId = $info.ListId; WebUrl = $info.WebUrl; cachedAt = (Get-Date -Format 'o') }
                $cacheChanged = $true
            }
        }
        if (-not $info) { Write-Log "Skipping $($team.displayName) - no document library found"; continue }
        $desired[$info.SiteId] = [pscustomobject]@{ Info = $info; DisplayName = $team.displayName }
    }

    # Drop cache entries for groups the user is no longer in, so the file doesn't grow forever and
    # a rejoin re-resolves against Graph rather than trusting arbitrarily old ids.
    $currentGroupIds = @{}
    foreach ($team in $teams) { $currentGroupIds[$team.id] = $true }
    foreach ($cachedId in @($siteCache.Keys)) {
        if (-not $currentGroupIds.ContainsKey($cachedId)) { $siteCache.Remove($cachedId); $cacheChanged = $true }
    }
    if ($cacheChanged) { Save-SiteCache -Cache $siteCache }

    #region Removals
    # Libraries to disconnect this run - the actual disconnect (stop OneDrive, clear its own
    # state, unregister the sync root, restart, verify) happens together in one block below,
    # not per-library here, since it only needs to stop/restart OneDrive once for the whole batch.
    $toDisconnect = @()

    # Actually-synced libraries for sites the user is no longer a Team member of. Matched by site
    # path rather than $lib.SiteId - UrlNamespace carries no ids of its own (see Get-SyncedLibraries),
    # so SiteId is always null here; $desired is keyed by the real SiteId from Graph, and
    # ContainsKey(null) throws rather than just returning false.
    $desiredSitePaths = @{}
    foreach ($d in $desired.Values) {
        $path = Get-SitePathFromUrl -Url $d.Info.WebUrl
        if ($path) { $desiredSitePaths[$path.ToLowerInvariant()] = $true }
    }
    # Only ever disconnect a library this tool itself previously added via TenantAutoMount - never
    # something merely "not currently desired," which is not the same as "ours to manage." Caught
    # for real in a live SYSTEM-context test on 2026-09-01: matching on "not desired" alone wrongly
    # flagged both the user's personal OneDrive root (its /personal/ UrlNamespace doesn't match
    # /sites/, so Get-SitePathFromUrl returns null - "no site path" got treated as "not desired")
    # and a private Team channel the user still has synced (its own distinct site path this tool
    # never automounted, so it can never appear in $desired either, even though the parent Team
    # itself is still desired). Restricting candidates to "was in $autoMounted before this run"
    # means the tool only ever touches what it itself put there.
    $autoMountedSitePaths = @{}
    foreach ($entry in $autoMounted) {
        if ($entry.Data -match 'webUrl=([^&]+)') {
            $path = Get-SitePathFromUrl -Url $Matches[1]
            if ($path) { $autoMountedSitePaths[$path.ToLowerInvariant()] = $true }
        }
    }
    foreach ($lib in $synced) {
        $sitePath = Get-SitePathFromUrl -Url $lib.UrlNamespace
        if (-not $sitePath) { continue }
        if (-not $autoMountedSitePaths.ContainsKey($sitePath.ToLowerInvariant())) { continue }
        if (-not $desiredSitePaths.ContainsKey($sitePath.ToLowerInvariant())) {
            $toDisconnect += $lib
        }
    }

    # Auto-mount entries we previously set for sites no longer desired. Safe to remove immediately
    # ONLY when nothing is actually synced for that site - if something is, removing this now and
    # having the actual disconnect fail afterward (OneDrive not stopping in time, etc.) would
    # permanently orphan the library: with nothing left in $autoMounted, "only touch what the tool
    # itself put there" (above) would refuse to ever recognize it as a disconnect candidate again.
    # Confirmed for real: a failed disconnect attempt removed this entry anyway, and the still-
    # fully-synced library was silently skipped on every run afterward. For a site that IS
    # currently synced, its entry is only removed once the disconnect is verified to have worked -
    # see the Disconnect region below.
    $syncedSitePathsNow = @{}
    foreach ($lib in $synced) {
        $p = Get-SitePathFromUrl -Url $lib.UrlNamespace
        if ($p) { $syncedSitePathsNow[$p.ToLowerInvariant()] = $true }
    }
    foreach ($entry in $autoMounted) {
        if ($desired.ContainsKey($entry.SiteId)) { continue }
        if ($entry.Data -match 'webUrl=([^&]+)') {
            $p = Get-SitePathFromUrl -Url $Matches[1]
            if ($p -and $syncedSitePathsNow.ContainsKey($p.ToLowerInvariant())) { continue }
        }
        Remove-AutoMountEntry -SiteId $entry.SiteId
    }

    # Channel-vs-team conflicts: a channel-specific folder already synced for a site where we
    # actually want the main library instead. Resolve (or prompt for) these before the additions
    # pass below, per an approved swap.
    # Pre-existing limitation, not introduced by the disconnect rework above: $_.SiteId/.ListId on
    # $synced entries are unresolved (UrlNamespace alone doesn't carry them - same reason
    # Get-SitePathFromUrl exists), so $existingForSite below never actually matches anything and
    # this conflict detection is currently inert. It has never worked in production since this
    # bug predates today's changes; fixing it is a separate task from making disconnect reliable.
    foreach ($siteId in $desired.Keys) {
        $info = $desired[$siteId].Info
        $existingForSite = $synced | Where-Object { $_.SiteId -eq $siteId }
        $mainAlreadySynced = $existingForSite | Where-Object { $_.ListId -eq $info.ListId }
        if ($mainAlreadySynced) { continue }

        $channelSynced = $existingForSite | Where-Object { $_.ListId -ne $info.ListId }
        if ($channelSynced) {
            $decision = $decisions[$siteId]
            if ($decision -and $decision.decision -eq 'approved') {
                foreach ($c in $channelSynced) { $toDisconnect += $c }
            } elseif ($decision -and $decision.decision -eq 'rejected') {
                Write-Log "Skipping $($desired[$siteId].DisplayName) - user previously rejected the channel->team swap"
                $desired.Remove($siteId)
            } else {
                Write-Log "Conflict detected for $($desired[$siteId].DisplayName) - prompting"
                Show-ConflictToast -TeamName $desired[$siteId].DisplayName -SiteId $siteId
                $desired.Remove($siteId)
            }
        }
    }

    # Every $toDisconnect candidate is, by construction above, already in $autoMountedSitePaths
    # and not in $desiredSitePaths - exactly the condition the auto-mount cleanup loop above
    # already removes by SiteId. A separate site-path-matched removal here used to duplicate that
    # (visible as the same site logged twice), so there's nothing left to do for this specific
    # case; kept as a region marker since Additions below still expects one.
    #endregion

    #region Disconnect - verified, all-or-nothing per batch
    # The sequence below is the only one confirmed, end to end and under real hydrated content
    # on a live tenant, to durably disconnect a library: OneDrive rebuilds SyncEngines and the
    # Cloud Filter sync-root registration FROM its own ini-based state on every start, so clearing
    # only the registry mirrors (as earlier versions of this script did) doesn't stick - OneDrive
    # just re-registers everything from that ini state on the next restart. Local folder deletion
    # only happens after CfGetSyncRootInfoByPath itself confirms the unregistration took - an
    # unverified or error state always leaves the local folder in place. Leaving local cruft
    # behind is an acceptable outcome here; deleting a file OneDrive still thinks is live is not
    # (two real production incidents already came from exactly that).
    if ($toDisconnect.Count -gt 0) {
        $pending = Get-PendingState
        $signature = (($toDisconnect | ForEach-Object { $_.MountPoint } | Sort-Object) -join '|')
        $oneDriveWasRunning = [bool](Get-OneDriveProcess)

        # Notify when the pending set changes, and again every $RenotifyHours while it is still
        # waiting on the user. An unparseable or missing timestamp counts as "due" rather than
        # "recent", so a corrupt state file produces an extra notification instead of silence.
        $notifyDue = $pending['signature'] -ne $signature
        if (-not $notifyDue -and $pending['notifiedAt']) {
            try { $notifyDue = ([datetime]::Parse($pending['notifiedAt'])).AddHours($RenotifyHours) -lt (Get-Date) }
            catch { $notifyDue = $true }
        } elseif (-not $notifyDue) {
            $notifyDue = $true
        }

        if ($oneDriveWasRunning -and $notifyDue) {
            Write-Log "Disconnect pending for $($toDisconnect.Count) librarie(s) - notifying the user."
            Show-DisconnectPendingToast -Names @($toDisconnect | ForEach-Object { if ($_.MountPoint) { Split-Path $_.MountPoint -Leaf } else { $_.UrlNamespace } })
            $pending['signature'] = $signature
            $pending['notifiedAt'] = (Get-Date -Format 'o')
            Save-PendingState -State $pending
        }

        if ($oneDriveWasRunning) {
            Write-Log "Waiting up to $DisconnectWaitMinutes minutes for OneDrive to be closed."
            [void](Wait-ForOneDriveToExit -TimeoutSeconds ($DisconnectWaitMinutes * 60))
        }

        if (Get-OneDriveProcess) {
            Write-Log "OneDrive is still running - deferring this disconnect to a later run."
        } else {
            $verified = @()
            $resolvedSiteIds = @{}
            try {
                foreach ($lib in $toDisconnect) {
                    $ids = Get-LibrarySiteIdentifiers -Token $token -Library $lib -AutoMounted $autoMounted
                    if (-not $ids) { throw "Could not resolve site identifiers for $($lib.UrlNamespace) - aborting this disconnect batch." }
                    $resolvedSiteIds[$lib.SyncId] = $ids.SiteId
                    Remove-OneDriveDeepSyncState -SyncId $lib.SyncId -SiteId $ids.SiteId -ListId $ids.ListId
                    Invoke-UnregisterSyncRoot -Path $lib.MountPoint
                }
            } catch {
                Write-Log "ERROR during disconnect cleanup: $($_.Exception.Message) - local folders will be left in place."
            }

            foreach ($lib in $toDisconnect) {
                try {
                    if (Test-SyncRootRegistered -Path $lib.MountPoint) {
                        Write-Log "Still registered as a sync root after disconnect attempt - leaving local folder: $($lib.MountPoint)"
                    } else {
                        $verified += $lib
                        # Only now - confirmed durably disconnected - is it safe to remove the
                        # TenantAutoMount entry. Removing it any earlier and having the disconnect
                        # itself fail would orphan a still-live library (see comment above this block).
                        if ($resolvedSiteIds.ContainsKey($lib.SyncId)) {
                            Remove-AutoMountEntry -SiteId $resolvedSiteIds[$lib.SyncId]
                        }
                    }
                } catch {
                    Write-Log "ERROR verifying disconnect for $($lib.MountPoint): $($_.Exception.Message) - leaving local folder."
                }
            }

            if ($verified.Count -gt 0) { Remove-StaleLocalFolders -Libraries $verified }

            # Start OneDrive again if it was closed for this (either the user clicked the toast's
            # button, or closed it themselves while we waited). If it was already closed when this
            # run started and nobody asked for a restart, leave it as we found it.
            if ($oneDriveWasRunning -or $pending['restartRequested']) { Start-OneDriveProcess }

            $pending.Remove('restartRequested')
            if ($verified.Count -eq $toDisconnect.Count) {
                # Fully done - drop the notification marker so a future pending set notifies again.
                $pending.Remove('signature')
                $pending.Remove('notifiedAt')
            }
            Save-PendingState -State $pending
        }
    }
    #endregion

    #region Additions
    # Re-read auto-mount state in case the removals pass above cleared an entry we're about to
    # recreate below with fresh data (e.g. a resolved channel/team conflict).
    #
    # Nothing is done to make OneDrive notice sooner: it re-reads the auto-mount list on its own
    # schedule and picks new entries up within a few hours, confirmed on a real device. Writing the
    # entry is the whole job here. An earlier version also zeroed OneDrive's TimerAutoMount cooldown
    # to force an immediate check - that write silently never took effect from SYSTEM, and since the
    # library mounts on its own anyway and the latency doesn't matter, it was dropped rather than
    # fixed. Adds only have to converge eventually, not promptly - some users go a year without a
    # reboot, which is why this runs hourly rather than only at logon.
    $autoMounted = @(Get-AutoMountEntries)
    foreach ($siteId in $desired.Keys) {
        $info = $desired[$siteId].Info
        $existing = $autoMounted | Where-Object { $_.SiteId -eq $siteId }
        $alreadySynced = ($synced | Where-Object { $_.SiteId -eq $siteId -and $_.ListId -eq $info.ListId })
        if ($existing -or $alreadySynced) { continue }
        Set-AutoMountEntry -SiteId $info.SiteId -WebId $info.WebId -ListId $info.ListId -WebUrl $info.WebUrl -DisplayName $desired[$siteId].DisplayName
    }

    #endregion

    # The toast's button stops OneDrive on the user's behalf and leaves it to this script to start
    # it again once the disconnect is done. If that work turned out to be already finished by the
    # time we got here, nothing above would have honoured the request - and OneDrive would just
    # stay closed. Catch that case regardless of whether there was anything left to disconnect.
    $pendingFinal = Get-PendingState
    if ($pendingFinal['restartRequested']) {
        if (-not (Get-OneDriveProcess)) { Start-OneDriveProcess }
        $pendingFinal.Remove('restartRequested')
        Save-PendingState -State $pendingFinal
    }

    Write-Log "=== Sync run complete ==="
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
}
#endregion
