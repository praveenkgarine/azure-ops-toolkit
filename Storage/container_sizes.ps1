#Requires -Modules Az.Accounts, Az.Storage
<#
.SYNOPSIS
Reports current blob sizes per container across the configured subscriptions.
.DESCRIPTION
Uses Microsoft Entra authentication. Requires permission to list storage accounts
and Storage Blob Data Reader access, plus network access to blob endpoints.
Lists blob metadata only; no blob contents are downloaded. Listing requests incur
transactions and can take time on large accounts. Sizes are logical content sizes,
not billed capacity; snapshots, previous versions and deleted blobs are excluded.
The scan is not a point-in-time snapshot if blobs change while it runs.
Results are appended as each container completes. Failed scans have blank totals
and separate partial totals. Excluded accounts are recorded without data requests.
.EXAMPLE
.\container_sizes.ps1
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = ('.\container-sizes-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff')),
    [ValidateRange(1, 5000)]
    [int]$PageSize = 5000
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

function Write-SizeResult {
    param($SubscriptionId, $SubscriptionName, $Account, $Container, $Status,
          [decimal]$Bytes = 0, [long]$Count = 0, [string]$ErrorMessage = '')

    $complete = $Status -eq 'Complete'
    [pscustomobject]@{
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
        ScanTimeUTC      = (Get-Date).ToUniversalTime().ToString('o')
        Error            = $ErrorMessage
    } | Export-Csv -LiteralPath $OutputPath -Append -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
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
                        }
                    } while ($null -ne $blobToken)
                }
                catch {
                    $status = 'ContainerError'
                    $scanError = $_.Exception.Message
                    Write-Warning "$($account.StorageAccountName)/$($container.Name): $scanError"
                }
                Write-SizeResult @row -Container $container.Name -Status $status `
                    -Bytes $bytes -Count $count -ErrorMessage $scanError
            }
            if ($containers.Count -eq 0 -and $containerCount -eq 0) {
                Write-SizeResult @row -Status 'NoContainers'
            }
        } while ($null -ne $containerToken)
    }
}

Write-Host "Report saved to $OutputPath"
