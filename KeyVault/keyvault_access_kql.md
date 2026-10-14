# Azure Key Vault Access Query

Use this Kusto Query Language (KQL) query to review recent Azure Key Vault access, including the operation, caller IP address, requested resource, and result.

## Before you start

- Enable Key Vault **AuditEvent** diagnostic logs and send them to a Log Analytics workspace.
- Run the query in that workspace. This example uses the `AzureDiagnostics` table.
- Replace `your-key-vault-name` with your vault name and adjust `ago(7d)` for the time range you need.

## Review recent access

```kusto
let VaultName = "your-key-vault-name";
AzureDiagnostics
| where TimeGenerated >= ago(7d)
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where Category == "AuditEvent"
| where Resource =~ VaultName
| project
    TimeGenerated,
    VaultName = Resource,
    OperationName,
    CallerIPAddress,
    RequestUri = tostring(column_ifexists("requestUri_s", "")),
    ResultType,
    ResultSignature,
    ResultDescription
| order by TimeGenerated desc
```

Each row represents a logged request. Check the operation and request URI to see what was accessed, and review the result fields to investigate failures or denied requests. A caller IP address alone does not identify a user or application.

To focus on secret reads, add `| where OperationName == "SecretGet"` before the `project` step. Logs are available only for the period covered by your diagnostic settings and workspace retention.

## References

- [Enable Azure Key Vault logging](https://learn.microsoft.com/en-us/azure/key-vault/general/howto-logging)
- [Monitor Azure Key Vault](https://learn.microsoft.com/en-us/azure/key-vault/general/monitor-key-vault)
