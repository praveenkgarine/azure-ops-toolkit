
# Find Unattached Managed Identities

## 1) List every user-assigned identity and its resource attachments

Run this in Azure Resource Graph Explorer with all relevant subscriptions selected:

```kusto
resources
| where type =~ 'microsoft.managedidentity/userassignedidentities'
| project
    identityId = tolower(id),
    identityName = name,
    subscriptionId,
    resourceGroup,
    location,
    principalId = tostring(properties.principalId),
    clientId = tostring(properties.clientId)
| join kind=leftouter (
    Resources
    | where isnotempty(identity.userAssignedIdentities)
    | mv-expand kind=array assignedIdentity = identity.userAssignedIdentities
    | extend identityId = tolower(tostring(assignedIdentity[0]))
    | summarize
        attachedResourceCount = count(),
        attachedResourceIds = make_set(id)
      by identityId
) on identityId
| extend attachedResourceCount = coalesce(attachedResourceCount, tolong(0))
| extend attachmentStatus = iff(
    attachedResourceCount == 0,
    'No attachment found - review',
    'Attached'
)
| project
    identityName,
    subscriptionId,
    resourceGroup,
    location,
    principalId,
    clientId,
    identityId,
    attachedResourceCount,
    attachmentStatus,
    attachedResourceIds
| order by attachedResourceCount asc, identityName asc
```

To show only potential orphans, add this filter immediately before the final `order by`:

```kusto
| where attachedResourceCount == 0
```

---

## 2) Export system-assigned identities separately

These are already attached to the resource shown in each row:

```kusto
Resources
| where tostring(identity.type) contains 'SystemAssigned'
| project
    resourceName = name,
    resourceType = type,
    subscriptionId,
    resourceGroup,
    resourceId = id,
    principalId = tostring(identity.principalId),
    identityType = tostring(identity.type)
| order by resourceName asc
```

---

## 3) Check whether any unassociated identities are used in federated credentials

### Azure PowerShell

```powershell
Set-AzContext -SubscriptionId "<subscription-id>"

$credentials = @(
    Get-AzFederatedIdentityCredential `
        -ResourceGroupName "<resource-group>" `
        -IdentityName "<managed-identity-name>" `
        -ErrorAction Stop
)

$credentials |
    Select-Object Name, Issuer, Subject, Audiences

"Federated credential count: $($credentials.Count)"
```

### Azure CLI

```bash
az identity federated-credential list \
    --subscription "<subscription-id>" \
    --resource-group "<resource-group>" \
    --identity-name "<managed-identity-name>" \
    --output json
```