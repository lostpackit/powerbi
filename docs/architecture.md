# Architecture

The repository provides three ways to retrieve and transform Microsoft Entra user metrics:

- `Get-UserMetrics.ps1` runs as a batch job and uploads a dated CSV to Azure Blob Storage.
- `run.ps1` runs as an HTTP-triggered Azure Function, uploads a CSV, and returns a JSON status response.
- `let.dart` contains a Power Query M query that returns the transformed users directly to Power BI.

```mermaid
flowchart LR
    subgraph entrypoints[Entrypoints]
        runner[Automation runner]
        client[HTTP client]
        powerbi[Power BI refresh]
    end

    subgraph implementations[Repository implementations]
        batch[Get-UserMetrics.ps1]
        function[Azure Function run.ps1]
        query[Power Query M let.dart]
    end

    subgraph identity[Identity and secrets]
        keyvault[Azure Key Vault]
        entra[Microsoft Entra OAuth]
    end

    graphApi[Microsoft Graph users API]

    subgraph outputs[Outputs]
        blob[Azure Blob Storage CSV]
        response[HTTP JSON response]
        table[Power BI user metrics table]
    end

    runner --> batch
    client --> function
    powerbi --> query

    batch -->|Azure identity| keyvault
    function -->|Managed identity| keyvault
    keyvault -->|Graph app credentials| batch
    keyvault -->|Graph app credentials| function

    batch -->|Client credentials| entra
    function -->|Client credentials| entra
    query -->|Client credentials| entra
    entra -->|Access token| graphApi

    batch -->|Paged user request| graphApi
    function -->|Paged user request| graphApi
    query -->|Paged user request| graphApi

    graphApi -->|User records| batch
    graphApi -->|User records| function
    graphApi -->|User records| query

    batch -->|Transformed CSV| blob
    function -->|Transformed CSV| blob
    function --> response
    query --> table
```

## Security Boundary

The PowerShell paths retrieve Microsoft Graph application credentials from Azure Key Vault. The Power Query path currently requires credential values in its query configuration; use a controlled parameter or supported secret-management mechanism rather than committing credentials to source control.