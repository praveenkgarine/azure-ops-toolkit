param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionIds,
    [string]$OutputPath = ".\storage-account-overview.csv",
    [datetime]$EndTime = (Get-Date),
    [datetime]$StartTime = (Get-Date).AddDays(-2)
)

if ($StartTime -ge $EndTime) {
    throw 'StartTime must be earlier than EndTime.'
}

if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Connect-AzAccount -ErrorAction Stop
}

function Get-MetricValue {
    param(
        [Parameter(Mandatory = $false)]
        [object]$Point,
        [string[]]$PropertyOrder = @('Average')
    )

    if ($null -eq $Point) {
        return $null
    }

    foreach ($propertyName in $PropertyOrder) {
        if ($Point.PSObject.Properties.Name -contains $propertyName) {
            $value = $Point.$propertyName
            if ($null -ne $value) {
                return $value
            }
        }
    }

    return $null
}

function Get-LatestMetricPoint {
    param(
        [string]$ResourceId,
        [string]$MetricName,
        [ValidateSet('Average', 'Total', 'Maximum', 'Minimum', 'Count')][string]$AggregationType = 'Average',
        [datetime]$StartTime,
        [datetime]$EndTime
    )

    # Let query failures reach the caller so the report retains their cause.
    $metric = Get-AzMetric `
        -ResourceId $ResourceId `
        -MetricName $MetricName `
        -StartTime $StartTime `
        -EndTime $EndTime `
        -TimeGrain ([TimeSpan]::FromHours(1)) `
        -AggregationType $AggregationType `
        -ErrorAction Stop `
        -WarningAction SilentlyContinue

    $point = $metric.Data |
        Where-Object {
            $null -ne $_ -and
            $null -ne (Get-MetricValue -Point $_ -PropertyOrder @($AggregationType))
        } |
        Sort-Object TimeStamp -Descending |
        Select-Object -First 1

    if ($null -ne $point) {
        return $point
    }

    return $null
}

$report = @(
    foreach ($subscriptionId in $SubscriptionIds) {
        try {
            $context = Set-AzContext `
                -SubscriptionId $subscriptionId `
                -ErrorAction Stop

            $accounts = @(Get-AzStorageAccount -ErrorAction Stop)
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
            $metricSettings = @{
                'UsedCapacity' = 'Average'
                'BlobCapacity' = 'Average'
                'BlobCount'    = 'Average'
            }

            foreach ($metricName in 'UsedCapacity', 'BlobCapacity', 'BlobCount') {
                $resourceId = $account.Id

                if ($metricName -ne 'UsedCapacity') {
                    $resourceId += '/blobServices/default'
                }

                try {
                    $point = Get-LatestMetricPoint `
                        -ResourceId $resourceId `
                        -MetricName $metricName `
                        -AggregationType $metricSettings[$metricName] `
                        -StartTime $StartTime `
                        -EndTime $EndTime

                    $values[$metricName] = $point

                    if ($null -eq $point) {
                        $errors += "$metricName has no data"
                    }
                }
                catch {
                    $errors += "${metricName}: $($_.Exception.Message)"
                }
            }

            $usedCapacityValue = Get-MetricValue -Point $values.UsedCapacity
            $blobCapacityValue = Get-MetricValue -Point $values.BlobCapacity
            $blobCountValue = Get-MetricValue -Point $values.BlobCount

            [pscustomobject]@{
                SubscriptionId   = $subscriptionId
                SubscriptionName = $context.Subscription.Name
                StorageAccount   = $account.StorageAccountName
                ResourceGroup    = $account.ResourceGroupName
                Location         = $account.Location
                Kind             = $account.Kind
                SKU              = $account.Sku.Name

                AccountUsedTiB = if ($null -ne $usedCapacityValue) {
                    [math]::Round([double]$usedCapacityValue / 1TB, 3)
                } else { $null }
                BlobUsedTiB = if ($null -ne $blobCapacityValue) {
                    [math]::Round([double]$blobCapacityValue / 1TB, 3)
                } else { $null }
                BlobCount = if ($null -ne $blobCountValue) {
                    [long][math]::Round([double]$blobCountValue)
                } else { $null }

                CapacityTimeUTC  = if ($null -ne $values.UsedCapacity) { $values.UsedCapacity.TimeStamp } else { $null }
                BlobSizeTimeUTC  = if ($null -ne $values.BlobCapacity) { $values.BlobCapacity.TimeStamp } else { $null }
                BlobCountTimeUTC = if ($null -ne $values.BlobCount) { $values.BlobCount.TimeStamp } else { $null }
                Errors           = $errors -join '; '
            }
        }
    }
)

$report = @($report | Sort-Object AccountUsedTiB -Descending)

$report | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop

$report |
    Format-Table SubscriptionName, StorageAccount,
                 AccountUsedTiB, BlobUsedTiB, BlobCount -AutoSize

Write-Host "Report saved to $OutputPath"
