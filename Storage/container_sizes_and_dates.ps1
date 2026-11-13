#Requires -Modules Az.Accounts, Az.Storage
<#
.SYNOPSIS
Reports current blob sizes and available dates per container.
.DESCRIPTION
Uses Microsoft Entra authentication. Requires permission to list storage accounts
and Storage Blob Data Reader access, plus network access to blob endpoints.
Lists blob metadata only; no blob contents are downloaded. Listing requests incur
transactions and can take time on large accounts. Sizes are logical content sizes,
not billed capacity; snapshots, previous versions and deleted blobs are excluded.
The scan is not a point-in-time snapshot if blobs change while it runs.
Results are appended as each container completes. Failed scans have blank totals
and separate partial totals. Excluded accounts are recorded without data requests.
Dates are ISO 8601 UTC. Blob date ranges describe current live blobs only.
Each date includes a coverage count; blank means unknown, never unused.
Failed scans have partial date ranges, identified by BlobDateScanStatus.
Container creation is ARM systemData.createdAt when returned; never inferred
from blob creation. ARM read failures are recorded without stopping size scans.
Access tracking must already be enabled; this script does not enable tracking
or recover historical access. Access timestamps can have daily granularity.
Dates depend on the installed Az.Storage version and properties returned by Azure.
Snapshots, versions and deleted blobs are excluded, including their dates.
Additional ARM permission: Microsoft.Storage/storageAccounts/blobServices/containers/read.
Use -StorageAccountNames to restrict accounts, or -SkipArmDates to omit ARM requests.
References:
https://learn.microsoft.com/en-us/azure/storage/blobs/blob-powershell
https://learn.microsoft.com/en-us/rest/api/storagerp/blob-containers/get
.EXAMPLE
.\container_sizes_and_dates.ps1 -StorageAccountNames mystorageaccount
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = ('.\container-sizes-and-dates-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff')),
    [ValidateRange(1, 5000)]
    [int]$PageSize = 5000,
    [string[]]$StorageAccountNames = @(),
    [switch]$SkipArmDates
)

# Specify the subscriptions to include (same list as storageaccount_with_sizes_from_metrics_v2.ps1).
$subscriptionIds = @(
    "00000000-0000-0000-0000-000000000001"
    "00000000-0000-0000-0000-000000000002"
)

# Specify storage accounts to skip. Uncomment and replace the examples as needed.
# Account names are matched exactly, case-insensitively, across all subscriptions.
$excludeStorageAccounts = @(
    # "hugeaccount1"
    # "hugeaccount2"
)

$excluded = @{}
foreach ($name in $ExcludeStorageAccounts) {
    if (-not [string]::IsNullOrWhiteSpace($name)) { $excluded[$name.Trim()] = $true }
}

if (Test-Path -LiteralPath $OutputPath) {
    throw "Output already exists: $OutputPath. Choose a new output path to preserve the existing report."
}
$outputDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    throw "Output directory does not exist: $outputDirectory"
}
if (-not (Get-AzContext -ErrorAction Stop)) {
    Connect-AzAccount -ErrorAction Stop | Out-Null
}

$dateFields = [ordered]@{
    Created = @('CreatedOn', 'CreationTime')
    Modified = @('LastModified')
    LastAccessed = @('LastAccessedOn', 'LastAccessed', 'LastAccessTime')
    TierChanged = @('AccessTierChangedOn', 'AccessTierChangeTime')
    CopyCompleted = @('CopyCompletedOn', 'CopyCompletionTime')
    Expires = @('ExpiresOn', 'ExpiryTime')
    ImmutabilityExpires = @('ExpiresOn', 'ImmutabilityPolicyExpiresOn')
}

function ConvertTo-UtcDate {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return }
    try {
        $date = [datetimeoffset]::Parse([string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
        if ($date.Year -gt 1) { return $date }
    } catch { return }
}

function Get-AvailableDate {
    param([object[]]$Objects, [string[]]$Names)
    foreach ($obj in $Objects) {
        foreach ($name in $Names) {
            if ($null -ne $obj) {
                $date = ConvertTo-UtcDate $obj.$name
                if ($null -ne $date) { return $date }
            }
        }
    }
}

function New-DateSummary {
    $result = @{}
    foreach ($key in $dateFields.Keys) {
        $result[$key] = @{ Earliest = $null; Latest = $null; Count = 0L }
    }
    return $result
}

function Add-BlobDates {
    param($Blob, $Summary)
    $objects = @($Blob.BlobProperties, $Blob, $Blob.ICloudBlob.Properties)
    foreach ($key in $dateFields.Keys) {
        $candidates = $objects
        if ($key -eq 'ImmutabilityExpires') {
            $candidates = @($Blob.BlobProperties.ImmutabilityPolicy, $Blob.ImmutabilityPolicy)
        }
        $date = Get-AvailableDate -Objects $candidates -Names $dateFields[$key]
        if ($null -eq $date) { continue }
        $entry = $Summary[$key]
        $entry.Count++
        if ($null -eq $entry.Earliest -or $date -lt $entry.Earliest) { $entry.Earliest = $date }
        if ($null -eq $entry.Latest -or $date -gt $entry.Latest) { $entry.Latest = $date }
    }
}

function Format-UtcDate {
    param($Value)
    if ($null -ne $Value) { return $Value.ToUniversalTime().ToString('o') }
}

function Write-SizeResult {
    param($SubscriptionId, $SubscriptionName, $Account, $Container, $Status,
          [decimal]$Bytes = 0, [long]$Count = 0, [string]$ErrorMessage = '',
          $Dates, $ContainerDates, [string]$ContainerDateError = '')

    $complete = $Status -eq 'Complete'
    $result = [ordered]@{
        SubscriptionId   = $SubscriptionId
        SubscriptionName = $SubscriptionName
        StorageAccount   = $Account.StorageAccountName
        ResourceGroup    = $Account.ResourceGroupName
        Container        = $Container
        Status           = $Status
        BlobCount        = if ($complete) { $Count } else { $null }
        SizeBytes        = if ($complete) { $Bytes } else { $null }
        SizeGiB          = if ($complete) { [math]::Round($Bytes / 1GB, 6) } else { $null }
        SizeTiB          = if ($complete) { [math]::Round($Bytes / 1TB, 6) } else { $null }
        PartialBlobCount = if ($Status -eq 'ContainerError') { $Count } else { $null }
        PartialSizeBytes = if ($Status -eq 'ContainerError') { $Bytes } else { $null }
        ContainerCreatedUTC = Format-UtcDate $ContainerDates.Created
        ContainerLastModifiedUTC = Format-UtcDate $ContainerDates.Modified
        ContainerArmLastModifiedUTC = Format-UtcDate $ContainerDates.ArmModified
        ContainerDateStatus = $ContainerDates.Status
        ContainerDateError = $ContainerDateError
        BlobDateScanStatus = if ($complete) { 'Complete' } elseif ($Status -eq 'ContainerError') { 'Partial' } else { 'NotScanned' }
        ScanTimeUTC      = (Get-Date).ToUniversalTime().ToString('o')
        Error            = $ErrorMessage
    }
    foreach ($key in $dateFields.Keys) {
        $entry = if ($null -ne $Dates) { $Dates[$key] } else { $null }
        $result["EarliestBlob${key}UTC"] = Format-UtcDate $entry.Earliest
        $result["LatestBlob${key}UTC"] = Format-UtcDate $entry.Latest
        $result["BlobsWith${key}Date"] = if ($null -ne $entry) { $entry.Count } else { $null }
    }
    [pscustomobject]$result | Export-Csv -LiteralPath $OutputPath -Append -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
}

foreach ($subscriptionId in $subscriptionIds) {
    try {
        $context = Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop
        $accounts = @(Get-AzStorageAccount -DefaultProfile $context -ErrorAction Stop)
    }
    catch {
        Write-SizeResult -SubscriptionId $subscriptionId -Status 'SubscriptionError' -ErrorMessage $_.Exception.Message
        Write-Warning "Subscription ${subscriptionId}: $($_.Exception.Message)"
        continue
    }

    foreach ($account in $accounts) {
        if ($StorageAccountNames.Count -gt 0 -and $account.StorageAccountName -notin $StorageAccountNames) { continue }
        $row = @{
            SubscriptionId = $subscriptionId
            SubscriptionName = $context.Subscription.Name
            Account = $account
        }
        if ($excluded.ContainsKey($account.StorageAccountName)) {
            Write-Host "Skipping excluded account $($account.StorageAccountName)"
            Write-SizeResult @row -Status 'Excluded'
            continue
        }
        if ($account.Kind -eq 'FileStorage') {
            Write-SizeResult @row -Status 'NoBlobService'
            continue
        }

        Write-Host "Scanning $($context.Subscription.Name) / $($account.StorageAccountName)"
        try {
            # Uses the active context selected by Set-AzContext above.
            # New-AzStorageContext does not support -DefaultProfile.
            $storageContext = New-AzStorageContext -StorageAccountName $account.StorageAccountName `
                -Endpoint $context.Environment.StorageEndpointSuffix -UseConnectedAccount -ErrorAction Stop
        }
        catch {
            Write-SizeResult @row -Status 'AccountError' -ErrorMessage $_.Exception.Message
            continue
        }

        $containerToken = $null
        $containerCount = 0
        do {
            try {
                $containers = @(Get-AzStorageContainer -Context $storageContext -MaxCount $PageSize `
                    -ContinuationToken $containerToken -ErrorAction Stop)
            }
            catch {
                Write-SizeResult @row -Status 'AccountError' -ErrorMessage $_.Exception.Message
                break
            }
            $containerToken = $null
            if ($containers.Count -gt 0) { $containerToken = $containers[-1].ContinuationToken }
            foreach ($container in $containers) {
                $containerCount++
                $dates = New-DateSummary
                $containerDateError = ''
                $containerDates = @{
                    Created = $null
                    Modified = Get-AvailableDate -Objects @($container, $container.BlobContainerProperties, $container.CloudBlobContainer.Properties) -Names @('LastModified')
                    ArmModified = $null
                    Status = 'Skipped'
                }
                if (-not $SkipArmDates) {
                    try {
                        $path = $account.Id + '/blobServices/default/containers/' +
                            [uri]::EscapeDataString($container.Name) + '?api-version=2025-06-01'
                        $response = Invoke-AzRestMethod -Path $path -Method GET -DefaultProfile $context -ErrorAction Stop
                        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
                            throw "ARM container request returned HTTP $($response.StatusCode): $($response.Content)"
                        }
                        $arm = $response.Content | ConvertFrom-Json -ErrorAction Stop
                        $containerDates.Created = ConvertTo-UtcDate $arm.systemData.createdAt
                        $containerDates.ArmModified = ConvertTo-UtcDate $arm.systemData.lastModifiedAt
                        $armModified = ConvertTo-UtcDate $arm.properties.lastModifiedTime
                        if ($null -ne $armModified) { $containerDates.Modified = $armModified }
                        $containerDates.Status = if ($null -ne $containerDates.Created) { 'Available' } else { 'CreationDateNotReturned' }
                    } catch {
                        $containerDates.Status = 'ArmError'
                        $containerDateError = $_.Exception.Message
                    }
                }
                [decimal]$bytes = 0
                [long]$count = 0
                $blobToken = $null
                $status = 'Complete'
                $scanError = ''
                Write-Host "  Container: $($container.Name)"
                try {
                    do {
                        $blobs = @(Get-AzStorageBlob -Container $container.Name -Context $storageContext `
                            -MaxCount $PageSize -ContinuationToken $blobToken -ErrorAction Stop)
                        $blobToken = $null
                        if ($blobs.Count -gt 0) { $blobToken = $blobs[-1].ContinuationToken }
                        foreach ($blob in $blobs) {
                            # Get-AzStorageBlob also returns snapshots; count only current blobs.
                            if ($null -ne $blob.SnapshotTime) { continue }
                            if ($null -eq $blob.Length -or $blob.Length -lt 0) {
                                throw "Missing or invalid content length for blob '$($blob.Name)'."
                            }
                            $bytes += [decimal]$blob.Length
                            $count++
                            Add-BlobDates -Blob $blob -Summary $dates
                        }
                    } while ($null -ne $blobToken)
                }
                catch {
                    $status = 'ContainerError'
                    $scanError = $_.Exception.Message
                    Write-Warning "$($account.StorageAccountName)/$($container.Name): $scanError"
                }
                Write-SizeResult @row -Container $container.Name -Status $status `
                    -Bytes $bytes -Count $count -ErrorMessage $scanError -Dates $dates -ContainerDates $containerDates -ContainerDateError $containerDateError
            }
            if ($containers.Count -eq 0 -and $containerCount -eq 0) {
                Write-SizeResult @row -Status 'NoContainers'
            }
        } while ($null -ne $containerToken)
    }
}

Write-Host "Report saved to $OutputPath"

