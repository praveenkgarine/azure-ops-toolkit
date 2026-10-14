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

## References

- [Enable Azure Key Vault logging](https://learn.microsoft.com/en-us/azure/key-vault/general/howto-logging)
- [Monitor Azure Key Vault](https://learn.microsoft.com/en-us/azure/key-vault/general/monitor-key-vault)
