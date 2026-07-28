#Requires -Version 5.1
<#
.SYNOPSIS
    Creates managed shortcuts on the Public Desktop if they do not already exist.

.DESCRIPTION
    Runs as NT AUTHORITY\SYSTEM from a scheduled task fired at every interactive logon.
    Reads a JSON config describing the desired shortcuts (Url, Local, or Network targets)
    and creates any that are missing from the Public Desktop.

    Because the task runs as SYSTEM, %USERNAME%/%USERPROFILE% in the task's own environment
    do not refer to the interactive user. Instead this script resolves the currently
    logged-on interactive user's profile directly from the registry (ProfileList, keyed by
    SID) via the owner of the explorer.exe process, and substitutes that into any {USERNAME}
    / {USERPROFILE} tokens found in a shortcut's Target path. This lets a single Local-type
    entry in the config resolve to a different real path per user, while the resulting
    shortcut file itself is only ever created once (idempotent on Public Desktop).

    A Url entry's IconFile may be a bare filename (e.g. "canva.ico"). Such filenames are
    resolved against $IconDir - the Icons folder deployed alongside this script - so an
    icon shipped inside the Win32 package renders on the shortcut. IconFile values that are
    rooted or contain a path separator (e.g. "%SystemRoot%\System32\shell32.dll") are used
    verbatim, so system icon sources still work.

    Url shortcuts are icon-verified rather than create-once: if a Url shortcut already
    exists but its stored IconFile/IconIndex no longer match what the config specifies,
    it is recreated so an updated packaged icon takes effect. (If the expected icon file
    is missing at run time, the existing shortcut is left untouched rather than stripped.)
    Local/Network shortcuts keep the create-only-if-missing behavior.

.NOTES
    Deployed to disk by the PSADT Win32 app; invoked by the "Deploy Desktop Shortcuts"
    scheduled task. Not intended to be run manually as a normal user.
#>
[CmdletBinding()]
param (
    [String]$ConfigPath,
    [String]$IconDir,
    [String]$LogPath = (Join-Path $env:ProgramData 'LundsFontanhus\ShortcutDeployment\Logs\New-Shortcuts.log')
)

# Script-relative defaults MUST be resolved here in the body, not in param()
# defaults: under powershell.exe -File, $PSScriptRoot is empty while parameter
# defaults are evaluated (it is only populated once the body runs), so a
# Join-Path $PSScriptRoot default crashes parameter binding with "Cannot bind
# argument to parameter 'Path' because it is an empty string" and the script
# exits 1 before logging anything.
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot 'Shortcuts.json' }
if ([string]::IsNullOrWhiteSpace($IconDir))    { $IconDir    = Join-Path $PSScriptRoot 'Icons' }

$ErrorActionPreference = 'Stop'
$PublicDesktop = Join-Path $env:Public 'Desktop'

#region Logging
function Write-ShortcutLog {
    param(
        [Parameter(Mandatory)][String]$Message,
        [ValidateSet('Info','Warning','Error')][String]$Severity = 'Info'
    )
    try {
        $logDir = Split-Path -Path $LogPath -Parent
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }
        if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 2MB)) {
            Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
        }
        $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Severity, $Message
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {
        # Logging must never break shortcut creation.
    }
}
#endregion

#region Active user resolution
function Get-ActiveUserProfiles {
    <#
        Returns the distinct ProfileImagePath(s) of interactively logged-on users,
        derived from the SID that owns each explorer.exe process. This is the
        authoritative source for "this user's profile directory" - it correctly
        handles domain accounts, Entra ID (AzureAD) joined UPN-style profile
        folders, and renamed/redirected profile paths, none of which can be
        reliably reconstructed by string-guessing a username.
    #>
    $profiles = New-Object System.Collections.Generic.List[string]
    $seenSids = New-Object System.Collections.Generic.HashSet[string]

    try {
        $explorerProcs = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction Stop
    } catch {
        Write-ShortcutLog -Severity Warning -Message "Could not enumerate explorer.exe processes: $_"
        return $profiles
    }

    foreach ($proc in $explorerProcs) {
        try {
            $ownerInfo = Invoke-CimMethod -InputObject $proc -MethodName GetOwnerSid -ErrorAction Stop
            $sid = $ownerInfo.Sid
            if ([string]::IsNullOrWhiteSpace($sid) -or -not $seenSids.Add($sid)) { continue }

            $profileKey = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
            if (Test-Path -LiteralPath $profileKey) {
                $profileImagePath = (Get-ItemProperty -LiteralPath $profileKey -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
                if (-not [string]::IsNullOrWhiteSpace($profileImagePath)) {
                    $profiles.Add($profileImagePath)
                }
            }
        } catch {
            Write-ShortcutLog -Severity Warning -Message "Could not resolve profile for an explorer.exe owner: $_"
        }
    }

    # The comma operator prevents PowerShell from unrolling a single-item
    # list into a bare string on return - without it, a solo match would
    # come out as a [string] instead of a collection, and $result[0] would
    # index into the string's characters instead of selecting the element.
    return ,$profiles
}

function Resolve-TargetTokens {
    param(
        [Parameter(Mandatory)][String]$Target,
        [Parameter(Mandatory)][String]$UserProfilePath
    )
    # Plain literal substitution (not -replace/regex) so backslashes in the
    # profile path and any UNC prefix already in $Target (e.g. \\server\share)
    # pass through untouched.
    $userName = Split-Path -Path $UserProfilePath -Leaf
    return $Target.Replace('{USERPROFILE}', $UserProfilePath).Replace('{USERNAME}', $userName)
}
#endregion

#region Shortcut creation
function Resolve-IconPath {
    <#
        Turns a config IconFile value into an absolute path suitable for a .url
        IconFile= line. Bare filenames (no path separator, not rooted) are treated
        as icons bundled in the package and resolved against $IconDir. Anything with
        a separator or a drive/UNC root - including %ENV%-based system paths - is
        expanded and used as-is. Returns an empty string for empty input.
    #>
    param(
        [String]$IconFile,
        [Parameter(Mandatory)][String]$IconDir
    )
    if ([string]::IsNullOrWhiteSpace($IconFile)) { return '' }

    # Expand %ENV% first so e.g. %SystemRoot%\System32\shell32.dll works.
    $expanded = [System.Environment]::ExpandEnvironmentVariables($IconFile)

    if (-not [System.IO.Path]::IsPathRooted($expanded) -and $expanded -notmatch '[\\/]') {
        return (Join-Path $IconDir $expanded)
    }
    return $expanded
}

function New-UrlShortcutFile {
    param(
        [Parameter(Mandatory)][String]$LinkPath,
        [Parameter(Mandatory)][String]$Url,
        [String]$IconFile,
        [int]$IconIndex = 0
    )
    $lines = @('[InternetShortcut]', "URL=$Url")
    if (-not [string]::IsNullOrWhiteSpace($IconFile)) {
        $lines += "IconFile=$IconFile"
        $lines += "IconIndex=$IconIndex"
    }
    Set-Content -LiteralPath $LinkPath -Value $lines -Encoding ASCII -Force
}

function Get-UrlShortcutIcon {
    <#
        Reads the IconFile / IconIndex currently stored in an existing .url file so
        it can be compared against what the config now wants. A .url with no icon
        (no IconFile= line) reports IconFile '' and IconIndex 0 - the same values a
        no-icon entry produces - so the two compare equal.
    #>
    param(
        [Parameter(Mandatory)][String]$LinkPath
    )
    $iconFile = ''
    $iconIndex = 0
    foreach ($line in (Get-Content -LiteralPath $LinkPath -ErrorAction SilentlyContinue)) {
        if     ($line -match '^\s*IconFile\s*=\s*(.+?)\s*$')   { $iconFile  = $Matches[1] }
        elseif ($line -match '^\s*IconIndex\s*=\s*(-?\d+)\s*$') { $iconIndex = [int]$Matches[1] }
    }
    return [pscustomobject]@{ IconFile = $iconFile; IconIndex = $iconIndex }
}

function New-FileShortcutFile {
    param(
        [Parameter(Mandatory)][String]$LinkPath,
        [Parameter(Mandatory)][String]$TargetPath,
        [String]$Arguments,
        [String]$WorkingDirectory,
        [String]$IconLocation,
        [String]$Description
    )
    # WScript.Shell writes the .lnk target as a literal string - it does not
    # validate or require that TargetPath exist, so network/local destinations
    # that aren't reachable yet at creation time are perfectly fine here.
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($LinkPath)
        $shortcut.TargetPath = $TargetPath
        if ($Arguments)        { $shortcut.Arguments = $Arguments }
        if ($WorkingDirectory) { $shortcut.WorkingDirectory = $WorkingDirectory }
        if ($IconLocation)     { $shortcut.IconLocation = $IconLocation }
        if ($Description)      { $shortcut.Description = $Description }
        $shortcut.Save()
    } finally {
        [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
    }
}
#endregion

#region Main
Write-ShortcutLog -Message '--- Shortcut deployment run started ---'

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-ShortcutLog -Severity Error -Message "Config file not found at '$ConfigPath'. Aborting."
    return
}

try {
    # Read as UTF-8 explicitly. Windows PowerShell 5.1's default Get-Content encoding is
    # ANSI, which mangles non-ASCII characters in shortcut names (e.g. "Fontänhus" ->
    # "FontÃ¤nhus") when Shortcuts.json is saved UTF-8 without a BOM.
    $shortcutDefs = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-ShortcutLog -Severity Error -Message "Failed to parse config file '$ConfigPath': $_"
    return
}

if (-not (Test-Path -LiteralPath $PublicDesktop)) {
    New-Item -Path $PublicDesktop -ItemType Directory -Force | Out-Null
}

# Only resolved lazily, since Url shortcuts without tokens don't need it.
$activeProfiles = $null

foreach ($def in $shortcutDefs) {
    try {
        if ([string]::IsNullOrWhiteSpace($def.Name) -or [string]::IsNullOrWhiteSpace($def.Type) -or [string]::IsNullOrWhiteSpace($def.Target)) {
            Write-ShortcutLog -Severity Warning -Message "Skipping malformed entry: $($def | ConvertTo-Json -Compress)"
            continue
        }

        $safeName = $def.Name -replace '[\\/:*?"<>|]', '_'
        $extension = if ($def.Type -eq 'Url') { 'url' } else { 'lnk' }
        $linkPath = Join-Path $PublicDesktop "$safeName.$extension"

        # Existence alone no longer means "skip" - for Url shortcuts the icon of an
        # already-present shortcut is verified below and the shortcut recreated if it
        # drifted from the icon the config now specifies. Local/Network shortcuts keep
        # the create-only-if-missing behavior.
        $linkExists = Test-Path -LiteralPath $linkPath

        $targetNeedsToken = $def.Target -match '\{USER(NAME|PROFILE)\}'
        $iconNeedsToken   = $def.IconLocation -and ($def.IconLocation -match '\{USER(NAME|PROFILE)\}')

        switch ($def.Type) {
            'Url' {
                $expectedIcon  = Resolve-IconPath -IconFile $def.IconFile -IconDir $IconDir
                $expectedIndex = if ($null -ne $def.IconIndex) { [int]$def.IconIndex } else { 0 }
                $iconMissing   = ($expectedIcon -and -not (Test-Path -LiteralPath $expectedIcon))

                $shouldWrite = $true
                if ($linkExists) {
                    if ($iconMissing) {
                        # The intended icon source isn't on disk right now, so we can't
                        # trust a comparison - leave the existing shortcut untouched
                        # rather than risk stripping a good icon over a transient miss.
                        Write-ShortcutLog -Severity Warning -Message "Expected icon '$expectedIcon' for '$($def.Name)' not found; leaving existing '$linkPath' unchanged."
                        $shouldWrite = $false
                    }
                    else {
                        $current = Get-UrlShortcutIcon -LinkPath $linkPath
                        if (($current.IconFile -eq $expectedIcon) -and ($current.IconIndex -eq $expectedIndex)) {
                            Write-ShortcutLog -Message "'$linkPath' already exists with the expected icon; skipping."
                            $shouldWrite = $false
                        }
                        else {
                            Write-ShortcutLog -Message "'$linkPath' icon differs (current: '$($current.IconFile)',$($current.IconIndex) -> expected: '$expectedIcon',$expectedIndex); recreating."
                        }
                    }
                }
                elseif ($iconMissing) {
                    Write-ShortcutLog -Severity Warning -Message "Expected icon '$expectedIcon' for '$($def.Name)' not found; creating shortcut without a custom icon."
                }

                if ($shouldWrite) {
                    $iconToWrite = if ($iconMissing) { '' } else { $expectedIcon }
                    New-UrlShortcutFile -LinkPath $linkPath -Url $def.Target -IconFile $iconToWrite -IconIndex $expectedIndex
                    $verb = if ($linkExists) { 'Recreated' } else { 'Created' }
                    Write-ShortcutLog -Message "$verb URL shortcut '$linkPath' -> $($def.Target)$(if ($iconToWrite) { " (icon: $iconToWrite)" })"
                }
            }

            { $_ -in @('Local', 'Network') } {
                if ($linkExists) {
                    Write-ShortcutLog -Message "'$linkPath' already exists; skipping."
                    continue
                }

                if (($targetNeedsToken -or $iconNeedsToken) -and $null -eq $activeProfiles) {
                    # @() forces array context defensively, on top of the
                    # comma operator inside the function - belt and braces
                    # against PowerShell's collection-unrolling behavior.
                    $activeProfiles = @(Get-ActiveUserProfiles)
                }

                if ($targetNeedsToken -and $activeProfiles.Count -eq 0) {
                    Write-ShortcutLog -Severity Warning -Message "No logged-on user resolved yet; deferring '$($def.Name)' to a later logon."
                    continue
                }

                # First resolvable session wins; the Test-Path check above
                # keeps this idempotent across subsequent users' logons.
                $resolvedTarget = if ($targetNeedsToken) {
                    Resolve-TargetTokens -Target $def.Target -UserProfilePath $activeProfiles[0]
                } else {
                    $def.Target
                }

                $resolvedIcon = if ($iconNeedsToken -and $activeProfiles.Count -gt 0) {
                    Resolve-TargetTokens -Target $def.IconLocation -UserProfilePath $activeProfiles[0]
                } else {
                    $def.IconLocation
                }

                New-FileShortcutFile -LinkPath $linkPath -TargetPath $resolvedTarget `
                    -Arguments $def.Arguments -WorkingDirectory $def.WorkingDirectory `
                    -IconLocation $resolvedIcon -Description $def.Description
                Write-ShortcutLog -Message "Created $($def.Type) shortcut '$linkPath' -> $resolvedTarget"
            }

            default {
                Write-ShortcutLog -Severity Warning -Message "Unknown Type '$($def.Type)' for entry '$($def.Name)'."
            }
        }
    } catch {
        Write-ShortcutLog -Severity Error -Message "Failed to create shortcut '$($def.Name)': $_"
    }
}

Write-ShortcutLog -Message '--- Shortcut deployment run finished ---'
#endregion
