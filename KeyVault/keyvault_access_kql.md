# Azure Key Vault Access Query

Use this Kusto Query Language (KQL) query to see when a specific Azure Key Vault secret was read or a read was attempted, including the timestamp, caller IP address, and result.

## Before you start

- Enable Key Vault **AuditEvent** diagnostic logs and send them to a Log Analytics workspace.
- Run the query in that workspace. This example uses the `AzureDiagnostics` table.
- Replace `your-key-vault-name` and `your-secret-name` with your vault and secret names. Adjust `ago(7d)` for the time range you need.

## Review access to a specific secret

```kusto
let VaultName = "your-key-vault-name";
let SecretName = "your-secret-name";
AzureDiagnostics
| where TimeGenerated >= ago(7d)
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where Category == "AuditEvent"
| where Resource =~ VaultName
| where OperationName == "SecretGet"
| extend RequestUri = tostring(column_ifexists("requestUri_s", ""))
| extend AccessedSecret = extract(@"/secrets/([^/?]+)", 1, RequestUri)
| where AccessedSecret =~ SecretName
| project
    TimeGenerated,
    VaultName = Resource,
    SecretName = AccessedSecret,
    OperationName,
    CallerIPAddress,
    RequestUri,
    ResultType,
    ResultSignature,
    ResultDescription
| order by TimeGenerated desc
```

Each row represents a logged read request for the selected secret. `TimeGenerated` shows the request timestamp in UTC. The filter matches the secret name with or without a version in the request URI.

Review the result fields to distinguish successful reads from failures or denied requests. A caller IP address alone does not identify a user or application. Logs are available only for the period covered by your diagnostic settings and workspace retention.

## Identify callers and summarize their requests

Use this query to group secret read requests by caller IP, token identity, client information, and result over the last 30 days. Replace both name placeholders before running it.

```kusto
let VaultName = "your-key-vault-name";
let SecretName = "your-secret-name";
AzureDiagnostics
| where TimeGenerated >= ago(30d)
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where Category == "AuditEvent"
| where Resource =~ VaultName
| where OperationName == "SecretGet"
| extend RequestUri = tostring(column_ifexists("requestUri_s", ""))
| extend AccessedSecret = extract(@"/secrets/([^/?]+)", 1, RequestUri)
| where AccessedSecret =~ SecretName
| extend
    User = tostring(column_ifexists("identity_claim_upn_s", "")),
    ObjectId = coalesce(
        tostring(column_ifexists("identity_claim_oid_g", "")),
        tostring(column_ifexists("identity_claim_http_schemas_microsoft_com_identity_claims_objectidentifier_g", ""))),
    AppId = tostring(column_ifexists("identity_claim_appid_g", "")),
    ClientInfo = tostring(column_ifexists("clientInfo_s", ""))
| summarize
    Requests = count(),
    FirstSeenUTC = min(TimeGenerated),
    LastSeenUTC = max(TimeGenerated)
    by CallerIPAddress, User, ObjectId, AppId,
       ClientInfo, ResultType, ResultSignature
| order by Requests desc
```

- `User`: Compare this with your sign-in name.
- `ObjectId`: Look up the identity in Microsoft Entra ID under Users or Enterprise applications. For a managed identity, compare it with the Azure resource's principal ID.
- `AppId`: Search Enterprise applications by application ID.
- `ClientInfo`: May identify the SDK or tool making the requests.
- `Requests`, `FirstSeenUTC`, and `LastSeenUTC`: Show the request volume and time span for each group.

Identity fields may be empty depending on the token and log schema. The IP address alone cannot identify the caller. Check the result fields to distinguish successful reads from failed attempts.

## Summarize requests by day

Use this query to count read requests for the selected secret each UTC day over the last 30 days. This helps check whether older records exist when the detailed results show only today's newest requests.

```kusto
let VaultName = "your-key-vault-name";
let SecretName = "your-secret-name";
AzureDiagnostics
| where TimeGenerated >= ago(30d)
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where Category == "AuditEvent"
| where Resource =~ VaultName
| where OperationName == "SecretGet"
| extend RequestUri = tostring(column_ifexists("requestUri_s", ""))
| extend AccessedSecret = extract(@"/secrets/([^/?]+)", 1, RequestUri)
| where AccessedSecret =~ SecretName
| summarize Requests = count() by DayUTC = bin(TimeGenerated, 1d)
| order by DayUTC asc
```

Counts include successful and failed read requests. Days with no matching records are omitted. In Log Analytics, check that the time picker is set to **Set in query** or **Last 30 days**. If older records are missing, check when diagnostic logging started and the workspace retention settings. Querying stored logs does not read the secret itself.

## References

- [Enable Azure Key Vault logging](https://learn.microsoft.com/en-us/azure/key-vault/general/howto-logging)
- [Monitor Azure Key Vault](https://learn.microsoft.com/en-us/azure/key-vault/general/monitor-key-vault)
