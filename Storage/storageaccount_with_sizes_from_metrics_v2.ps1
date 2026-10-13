param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionIds,
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = '.\storage-account-overview.csv',
    [datetime]$EndTime = (Get-Date).ToUniversalTime(),
    [datetime]$StartTime = $EndTime.AddDays(-2)
)

$startTime = $StartTime.ToUniversalTime()
$endTime = $EndTime.ToUniversalTime()
if ($startTime -ge $endTime) {
    throw 'StartTime must be earlier than EndTime.'
}
if (-not (Get-AzContext -ErrorAction Stop)) {
    Connect-AzAccount -ErrorAction Stop | Out-Null
}

function Get-LatestMetricPoint {
    param(
        [string]$ResourceId,
        [string]$MetricName,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [object]$DefaultProfile
    )

    $metric = Get-AzMetric `
        -ResourceId $ResourceId `
        -MetricName $MetricName `
        -StartTime $startTime `
        -EndTime $endTime `
        -TimeGrain ([TimeSpan]::FromHours(1)) `
        -AggregationType Average `
        -DefaultProfile $DefaultProfile `
        -ErrorAction Stop `
        -WarningAction SilentlyContinue

    $metric.Data |
        Where-Object { $null -ne $_ -and $null -ne $_.Average } |
        Sort-Object TimeStamp -Descending |
        Select-Object -First 1
}

$report = @(
    foreach ($subscriptionId in $subscriptionIds) {
        try {
            $context = Set-AzContext `
                -SubscriptionId $subscriptionId `
                -ErrorAction Stop

            $accounts = @(Get-AzStorageAccount -DefaultProfile $context -ErrorAction Stop)
        }
        catch {
            Write-Warning "Skipping subscription ${subscriptionId}: $($_.Exception.Message)"
            continue
        }

        Write-Host "Subscription: $($context.Subscription.Name) - $($accounts.Count) accounts"

        foreach ($account in $accounts) {
            Write-Host "  Querying $($account.StorageAccountName)"

            $values = @{}
            $errors = @()

            foreach ($metricName in "UsedCapacity", "BlobCapacity", "BlobCount") {
                $resourceId = $account.Id

                if ($metricName -ne "UsedCapacity") {
                    $resourceId += "/blobServices/default"
                }

                try {
                    $point = Get-LatestMetricPoint `
                        -ResourceId $resourceId `
                        -MetricName $metricName `
                        -StartTime $startTime `
                        -EndTime $endTime `
                        -DefaultProfile $context

                    $values[$metricName] = $point

                    if ($null -eq $point) {
                        $errors += "$metricName has no data"
                    }
                }
                catch {
                    $errors += "${metricName}: $($_.Exception.Message)"
                }
            }

            [pscustomobject]@{
                SubscriptionId   = $subscriptionId
                SubscriptionName = $context.Subscription.Name
                StorageAccount   = $account.StorageAccountName
                ResourceGroup    = $account.ResourceGroupName
                Location         = $account.Location
                Kind             = $account.Kind
                SKU              = $account.Sku.Name

                AccountUsedTiB = if ($null -ne $values.UsedCapacity) {
                    [math]::Round($values.UsedCapacity.Average / 1TB, 3)
                } else { $null }
                BlobUsedTiB = if ($null -ne $values.BlobCapacity) {
                    [math]::Round($values.BlobCapacity.Average / 1TB, 3)
                } else { $null }
                BlobCount = if ($null -ne $values.BlobCount) {
                    [long][math]::Round($values.BlobCount.Average)
                } else { $null }

                CapacityTimeUTC  = $values.UsedCapacity.TimeStamp
                BlobSizeTimeUTC  = $values.BlobCapacity.TimeStamp
                BlobCountTimeUTC = $values.BlobCount.TimeStamp
                Errors           = $errors -join "; "
            }
        }
    }
)

$report = @($report | Sort-Object AccountUsedTiB -Descending)

if ($report.Count -eq 0) {
    throw 'No storage accounts were retrieved. No report was written; check subscriptions and warnings.'
}

$report | Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop

$report |
    Format-Table SubscriptionName, StorageAccount,
                 AccountUsedTiB, BlobUsedTiB, BlobCount -AutoSize

Write-Host "Report saved to $outputPath"
