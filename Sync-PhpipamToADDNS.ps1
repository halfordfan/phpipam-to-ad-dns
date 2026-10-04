<#
.SYNOPSIS
    Syncs phpIPAM addresses to Windows DNS (A, PTR and a tracking TXT record).

.DESCRIPTION
    phpIPAM is authoritative. For every address with the custom field (default 'sync2ad'):
        0 / empty / No      -> ignored (and removed from DNS if previously managed)
        1 / Yes / True      -> A + PTR
        A / OnlyA           -> A only
    For each managed address a TXT record is written next to the A record:
        phpipam-sync;id=<ipam address id>;ip=<ip>;ptr=<0|1>;fqdn=<fqdn>
    On every run, TXT records carrying that tag are compared with IPAM. If the ID is gone from
    IPAM (deleted, flag set to 0, hostname/IP/mode changed) the old A, PTR and TXT are removed.
    The script never touches DNS records it did not tag with a TXT record, apart from replacing
    a conflicting PTR on a managed IP (and, with -ReplaceExistingA, conflicting A records).
    Dynamic records (those with a DNS timestamp, e.g. registered by domain-joined clients or DHCP)
    are never modified or removed: an entry whose name already has a dynamic A record is skipped
    with a warning, a dynamic PTR on a managed IP blocks only the PTR, and cleanup leaves dynamic
    A/PTR records in place while still removing the script's own TXT tag.

    Run on the DNS server / domain controller (needs the DnsServer module).

.EXAMPLE
    # Edit the $Config block below (URL, app ID, token), then:
    .\Sync-PhpIpamToDns.ps1 -WhatIf -Verbose
#>
#Requires -Modules DnsServer
[CmdletBinding(SupportsShouldProcess)]
param()   # keeps -WhatIf and -Verbose; all settings live in $Config below

# ---------- configuration ----------
$Config = @{
    BaseUrl              = 'https://ipam.example.com'       # phpIPAM base URL
    AppId                = 'YOUR_APP_ID'                    # phpIPAM API app ID
    Token                = 'PASTE-READ-ONLY-API-TOKEN-HERE' # phpIPAM API token (app is read-only)
    CustomField          = 'sync2ad'                        # custom field name as shown in phpIPAM (without the 'custom_' API prefix)
    DefaultZone          = $env:USERDNSDOMAIN               # zone for hostnames without a domain suffix
    DnsServer            = 'localhost'
    ForwardZones         = @()                              # empty = all primary, non-reverse, non-autocreated zones
    TtlSeconds           = 3600
    ReplaceExistingA     = $false                           # remove A records on the same name that IPAM doesn't list
    SkipCertificateCheck = $false                           # $true for a self-signed IPAM certificate
    MaxDeletePercent     = 25                               # abort if more than this % of managed entries would vanish
}

$BaseUrl              = [string]$Config.BaseUrl
$AppId                = [string]$Config.AppId
$Token                = ([string]$Config.Token).Trim()
$CustomField          = [string]$Config.CustomField
$ApiField             = "custom_$CustomField"          # property name on address objects in the phpIPAM API
$DefaultZone          = [string]$Config.DefaultZone
$DnsServer            = [string]$Config.DnsServer
$ForwardZones         = @($Config.ForwardZones | Where-Object { $_ })
$Ttl                  = New-TimeSpan -Seconds ([int]$Config.TtlSeconds)
$ReplaceExistingA     = [bool]$Config.ReplaceExistingA
$SkipCertificateCheck = [bool]$Config.SkipCertificateCheck
$MaxDeletePercent     = [int]$Config.MaxDeletePercent

$ErrorActionPreference = 'Stop'
$Tag = 'phpipam-sync'

# ---------- helpers ----------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ($SkipCertificateCheck) {
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

function Get-SyncMode([object]$Value) {
    $v = ("$Value").Trim().ToLower()
    switch -Regex ($v) {
        '^(|0|no|n|false)$'    { return $null }
        '^(1|yes|y|true)$'     { return 'AandPTR' }
        '^(a|onlya)$'          { return 'A' }
        default                { Write-Warning "Unrecognised $CustomField value '$Value' - ignoring"; return $null }
    }
}

function Invoke-Ipam([string]$Path) {
    try {
        $r = Invoke-RestMethod -Uri "$script:Api/$Path" -Headers $script:Headers -Method Get
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 404) { return @() } # "no addresses found"
        throw
    }
    if (-not $r.success) { throw "phpIPAM API error on $Path : $($r.message)" }
    return $r.data
}

function Get-BestZone([string]$Name, [string[]]$Zones) {
    $Zones | Where-Object { $Name -eq $_ -or $Name.EndsWith(".$_") } |
        Sort-Object Length -Descending | Select-Object -First 1
}

function Get-RelativeName([string]$Fqdn, [string]$Zone) {
    if ($Fqdn -eq $Zone) { return '@' }
    return $Fqdn.Substring(0, $Fqdn.Length - $Zone.Length - 1)
}

function Get-ReverseInfo([string]$Ip) {
    $o = $Ip.Split('.')
    $rev = "$($o[3]).$($o[2]).$($o[1]).$($o[0]).in-addr.arpa"
    $zone = Get-BestZone $rev $script:ReverseZoneNames
    if (-not $zone) { return $null }
    [pscustomobject]@{ Zone = $zone; Name = (Get-RelativeName $rev $zone) }
}

function Get-DnsRecords($Zone, $Name, $Type) {
    Get-DnsServerResourceRecord -ComputerName $DnsServer -ZoneName $Zone -Name $Name -RRType $Type -ErrorAction SilentlyContinue
}

# A dynamic (client-registered / DHCP) record carries a timestamp; a static record has none.
function Test-IsDynamic($Record) {
    $ts = $Record.TimeStamp
    return ($null -ne $ts -and $ts -gt [datetime]'1970-01-01')
}

function Remove-ManagedEntry($e) {
    # A
    foreach ($r in @(Get-DnsRecords $e.Zone $e.Name 'A')) {
        if ($r.RecordData.IPv4Address.IPAddressToString -eq $e.Ip) {
            if (Test-IsDynamic $r) { Write-Warning "Not removing dynamic A record $($e.Fqdn) -> $($e.Ip)"; continue }
            if ($PSCmdlet.ShouldProcess("$($e.Fqdn) A $($e.Ip)", 'Remove A record')) {
                Remove-DnsServerResourceRecord -ComputerName $DnsServer -ZoneName $e.Zone -InputObject $r -Force
                Write-Host "Removed A    $($e.Fqdn) -> $($e.Ip)"
            }
        }
    }
    # PTR
    if ($e.Ptr -eq '1') {
        $ri = Get-ReverseInfo $e.Ip
        if ($ri) {
            foreach ($r in @(Get-DnsRecords $ri.Zone $ri.Name 'PTR')) {
                if ($r.RecordData.PtrDomainName.TrimEnd('.') -ieq $e.Fqdn) {
                    if (Test-IsDynamic $r) { Write-Warning "Not removing dynamic PTR record $($e.Ip) -> $($e.Fqdn)"; continue }
                    if ($PSCmdlet.ShouldProcess("$($e.Ip) PTR $($e.Fqdn)", 'Remove PTR record')) {
                        Remove-DnsServerResourceRecord -ComputerName $DnsServer -ZoneName $ri.Zone -InputObject $r -Force
                        Write-Host "Removed PTR  $($e.Ip) -> $($e.Fqdn)"
                    }
                }
            }
        }
    }
    # TXT (last, so a failure above leaves the tag in place for the next run)
    if ($PSCmdlet.ShouldProcess("$($e.Fqdn) TXT id=$($e.Id)", 'Remove TXT record')) {
        Remove-DnsServerResourceRecord -ComputerName $DnsServer -ZoneName $e.Zone -InputObject $e.Record -Force
        Write-Host "Removed TXT  $($e.Fqdn) id=$($e.Id)"
    }
}

# ---------- authenticate to phpIPAM ----------
$script:Api = "$($BaseUrl.TrimEnd('/'))/api/$AppId"
if (-not $Token -or $Token -like 'PASTE-*') { throw 'Set Token in the $Config block.' }
$script:Headers = @{ token = $Token }

# ---------- DNS zone inventory ----------
$allZones = Get-DnsServerZone -ComputerName $DnsServer
$script:ReverseZoneNames = @($allZones | Where-Object { $_.IsReverseLookupZone -and $_.ZoneType -eq 'Primary' } |
                              ForEach-Object { $_.ZoneName.ToLower() })
if ($ForwardZones) {
    $fwdZones = @($ForwardZones | ForEach-Object { $_.ToLower() })
} else {
    $fwdZones = @($allZones | Where-Object {
        -not $_.IsReverseLookupZone -and -not $_.IsAutoCreated -and $_.ZoneType -eq 'Primary' -and
        $_.ZoneName -ne 'TrustAnchors' -and $_.ZoneName -notlike '_msdcs.*'
    } | ForEach-Object { $_.ZoneName.ToLower() })
}
if (-not $DefaultZone) { throw 'Could not determine -DefaultZone; please pass it.' }
$DefaultZone = $DefaultZone.ToLower()

# ---------- read desired state from phpIPAM ----------
Write-Verbose 'Reading subnets and addresses from phpIPAM...'
$desired = @{}
foreach ($subnet in @(Invoke-Ipam 'subnets/')) {
    if ($subnet.isFolder -eq '1') { continue }
    foreach ($a in @(Invoke-Ipam "subnets/$($subnet.id)/addresses/")) {
        $mode = Get-SyncMode $a.$ApiField
        if (-not $mode) { continue }

        $ipObj = $null
        if (-not [ipaddress]::TryParse($a.ip, [ref]$ipObj) -or $ipObj.AddressFamily -ne 'InterNetwork') {
            Write-Warning "IPAM id $($a.id): '$($a.ip)' is not IPv4 - skipped"; continue
        }
        $hn = ("$($a.hostname)").Trim().TrimEnd('.').ToLower()
        if (-not $hn) { Write-Warning "IPAM id $($a.id) ($($a.ip)): no hostname - skipped"; continue }
        $fqdn = if ($hn.Contains('.')) { $hn } else { "$hn.$DefaultZone" }

        $zone = Get-BestZone $fqdn $fwdZones
        if (-not $zone) { Write-Warning "IPAM id $($a.id): no matching forward zone for $fqdn - skipped"; continue }

        $ptr = if ($mode -eq 'AandPTR') { '1' } else { '0' }
        $desired[[string]$a.id] = [pscustomobject]@{
            Id   = [string]$a.id
            Ip   = $a.ip
            Fqdn = $fqdn
            Zone = $zone
            Name = Get-RelativeName $fqdn $zone
            Ptr  = $ptr
            Text = "$Tag;id=$($a.id);ip=$($a.ip);ptr=$ptr;fqdn=$fqdn"
        }
    }
}
Write-Host "phpIPAM: $($desired.Count) address(es) flagged for sync"

# ---------- read current state from DNS (TXT tags) ----------
$existing = New-Object System.Collections.Generic.List[object]
foreach ($z in $fwdZones) {
    foreach ($rec in @(Get-DnsServerResourceRecord -ComputerName $DnsServer -ZoneName $z -RRType TXT -ErrorAction SilentlyContinue)) {
        $text = ($rec.RecordData.DescriptiveText -join '')
        if (-not $text.StartsWith("$Tag;")) { continue }
        $kv = @{}
        foreach ($part in $text.Split(';')) {
            $i = $part.IndexOf('=')
            if ($i -gt 0) { $kv[$part.Substring(0, $i)] = $part.Substring($i + 1) }
        }
        $existing.Add([pscustomobject]@{
            Id = $kv['id']; Ip = $kv['ip']; Ptr = $kv['ptr']; Fqdn = $kv['fqdn']
            Zone = $z; Name = $rec.HostName; Text = $text; Record = $rec
        })
    }
}
Write-Host "DNS: $($existing.Count) managed TXT tag(s) found"

# ---------- safety valve against a bad/empty IPAM response ----------
$orphans = @($existing | Where-Object { -not $desired.ContainsKey($_.Id) })
if ($existing.Count -ge 4 -and ($orphans.Count * 100 / $existing.Count) -gt $MaxDeletePercent) {
    throw "Refusing to remove $($orphans.Count) of $($existing.Count) managed entries (> $MaxDeletePercent%). Check IPAM, or raise -MaxDeletePercent."
}

# ---------- remove stale / changed entries ----------
$inSync = @{}
foreach ($e in $existing) {
    $d = $desired[$e.Id]
    if ($d -and $d.Text -ceq $e.Text -and -not $inSync.ContainsKey($e.Id)) {
        $inSync[$e.Id] = $true      # unchanged; A/PTR are re-verified below
        continue
    }
    try { Remove-ManagedEntry $e } catch { Write-Warning "Failed removing id $($e.Id) ($($e.Fqdn)): $_" }
}

# ---------- create / repair desired entries ----------
$ipsByFqdn = @{}
foreach ($d in $desired.Values) {
    if (-not $ipsByFqdn.ContainsKey($d.Fqdn)) { $ipsByFqdn[$d.Fqdn] = @() }
    $ipsByFqdn[$d.Fqdn] += $d.Ip
}

foreach ($d in $desired.Values) {
    try {
        # A record
        $aRecs = @(Get-DnsRecords $d.Zone $d.Name 'A')
        if (@($aRecs | Where-Object { Test-IsDynamic $_ }).Count -gt 0) {
            Write-Warning "id $($d.Id): $($d.Fqdn) has a dynamic (timestamped) A record - entry skipped, nothing changed"
            continue
        }
        if ($ReplaceExistingA) {
            foreach ($r in $aRecs) {
                $rip = $r.RecordData.IPv4Address.IPAddressToString
                if ($ipsByFqdn[$d.Fqdn] -notcontains $rip -and
                    $PSCmdlet.ShouldProcess("$($d.Fqdn) A $rip", 'Remove conflicting A record')) {
                    Remove-DnsServerResourceRecord -ComputerName $DnsServer -ZoneName $d.Zone -InputObject $r -Force
                    Write-Host "Removed conflicting A $($d.Fqdn) -> $rip"
                }
            }
        }
        $hasA = $aRecs | Where-Object { $_.RecordData.IPv4Address.IPAddressToString -eq $d.Ip }
        if (-not $hasA -and $PSCmdlet.ShouldProcess("$($d.Fqdn) A $($d.Ip)", 'Add A record')) {
            Add-DnsServerResourceRecordA -ComputerName $DnsServer -ZoneName $d.Zone -Name $d.Name `
                -IPv4Address $d.Ip -TimeToLive $Ttl
            Write-Host "Added A      $($d.Fqdn) -> $($d.Ip)"
        }

        # PTR record
        if ($d.Ptr -eq '1') {
            $ri = Get-ReverseInfo $d.Ip
            if (-not $ri) {
                Write-Warning "No reverse zone for $($d.Ip) - PTR for $($d.Fqdn) skipped"
            } else {
                $hasPtr = $false
                $ptrBlocked = $false
                foreach ($r in @(Get-DnsRecords $ri.Zone $ri.Name 'PTR')) {
                    if ($r.RecordData.PtrDomainName.TrimEnd('.') -ieq $d.Fqdn) { $hasPtr = $true; continue }
                    if (Test-IsDynamic $r) {
                        Write-Warning "id $($d.Id): $($d.Ip) has a dynamic PTR ($($r.RecordData.PtrDomainName)) - PTR skipped"
                        $ptrBlocked = $true; continue
                    }
                    if ($PSCmdlet.ShouldProcess("$($d.Ip) PTR $($r.RecordData.PtrDomainName)", 'Remove conflicting PTR')) {
                        Remove-DnsServerResourceRecord -ComputerName $DnsServer -ZoneName $ri.Zone -InputObject $r -Force
                        Write-Host "Removed conflicting PTR $($d.Ip) -> $($r.RecordData.PtrDomainName)"
                    }
                }
                if (-not $hasPtr -and -not $ptrBlocked -and $PSCmdlet.ShouldProcess("$($d.Ip) PTR $($d.Fqdn)", 'Add PTR record')) {
                    Add-DnsServerResourceRecordPtr -ComputerName $DnsServer -ZoneName $ri.Zone -Name $ri.Name `
                        -PtrDomainName "$($d.Fqdn)." -TimeToLive $Ttl
                    Write-Host "Added PTR    $($d.Ip) -> $($d.Fqdn)"
                }
            }
        }

        # TXT tag (written last so a half-created entry is retried next run)
        if (-not $inSync.ContainsKey($d.Id) -and $PSCmdlet.ShouldProcess("$($d.Fqdn) TXT id=$($d.Id)", 'Add TXT record')) {
            Add-DnsServerResourceRecord -ComputerName $DnsServer -ZoneName $d.Zone -Name $d.Name -Txt `
                -DescriptiveText $d.Text -TimeToLive $Ttl
            Write-Host "Added TXT    $($d.Fqdn) id=$($d.Id)"
        }
    } catch {
        Write-Warning "Failed syncing id $($d.Id) ($($d.Fqdn) / $($d.Ip)): $_"
    }
}

Write-Host 'Sync complete.'
