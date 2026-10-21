# Application-related resource inventory

Use this Azure Resource Graph query to inventory application-related resources across the subscriptions selected in your query scope.

## Scope

- App Service web apps, function apps, Logic Apps Standard, and deployment slots.
- Azure Container Apps and Container Apps jobs.
- Virtual machines and virtual machine scale sets.

## Query

Run the following in Azure Resource Graph Explorer with the required subscriptions selected:

```kusto
Resources
| where type in~ (
    'microsoft.web/sites',
    'microsoft.web/sites/slots',
    'microsoft.app/containerapps',
    'microsoft.app/jobs',
    'microsoft.compute/virtualmachines',
    'microsoft.compute/virtualmachinescalesets'
)
| extend workload = case(
    type =~ 'microsoft.app/containerapps', 'Container App',
    type =~ 'microsoft.app/jobs', 'Container Apps Job',
    type =~ 'microsoft.compute/virtualmachines', 'Virtual Machine',
    type =~ 'microsoft.compute/virtualmachinescalesets', 'VM Scale Set',
    kind contains 'workflowapp', 'Logic Apps Standard',
    kind contains 'functionapp', 'Function App',
    'Web App'
)
| extend
    isSlot = type =~ 'microsoft.web/sites/slots',
    linuxFxVersion = tostring(properties.siteConfig.linuxFxVersion),
    windowsFxVersion = tostring(properties.siteConfig.windowsFxVersion),
    phpVersion = tostring(properties.siteConfig.phpVersion),
    publicNetworkAccess = tostring(properties.publicNetworkAccess),
    containerImages = properties.template.containers,
    ingressExternal = tostring(properties.configuration.ingress.external)
| extend phpSignal = case(
    linuxFxVersion startswith 'PHP|', 'Configured PHP runtime',
    isnotempty(phpVersion)
        and phpVersion !in~ ('OFF', '0', 'NONE'),
        'PHP configuration present—verify',
    'PHP presence unknown—inspect runtime/image/packages'
)
| project
    subscriptionId,
    resourceGroup,
    name,
    workload,
    kind,
    isSlot,
    location,
    phpSignal,
    linuxFxVersion,
    windowsFxVersion,
    phpVersion,
    containerImages,
    publicNetworkAccess,
    ingressExternal,
    id
| order by workload asc, subscriptionId asc, name asc
```

## Reading the results

- `workload` classifies each resource using its resource type and App Service `kind`.
- `isSlot` identifies App Service deployment slots.
- `phpSignal` reports PHP runtime configuration when exposed in the resource properties. An unknown value does not mean PHP is absent.
- `linuxFxVersion`, `windowsFxVersion`, and `phpVersion` show the runtime configuration available to this query.
- `containerImages` returns the container definitions exposed under `properties.template.containers`; it does not inspect image contents.
- `publicNetworkAccess` and `ingressExternal` show the corresponding configuration values when available. Empty values do not establish whether a resource is publicly reachable.
- `id`, `subscriptionId`, and `resourceGroup` identify each resource for follow-up inspection.

## Limitations

This is a resource configuration inventory, not a complete application or software inventory. Resource Graph may return empty properties for some resource types. Verify the runtime, container image, or installed packages to confirm PHP usage, especially for virtual machines, scale sets, and containers.

Results depend on your selected query scope and read permissions. Related dependencies such as databases, storage accounts, and networking resources are outside this query's scope.
