# User Metrics Export to Azure Blob Storage

This solution converts the Power Query script to PowerShell that can run in Azure runners (GitHub Actions) and exports user metrics to Azure Blob Storage.

## Prerequisites

### Azure Resources Required
1. **Azure Key Vault** - to store secrets securely
2. **Azure Storage Account** - for CSV output
3. **Azure App Registration** - for Microsoft Graph API access
4. **Service Principal** - for GitHub Actions authentication

### Key Vault Secrets
Store these secrets in your Azure Key Vault:
- `tenant-id`: Your Azure AD tenant ID
- `client-id`: App registration client ID
- `client-secret`: App registration client secret

### App Registration Permissions
Your app registration needs these Microsoft Graph permissions:
- `User.Read.All` (Application permission)
- `AuditLog.Read.All` (Application permission) - for sign-in activity

## Setup Instructions

### 1. Create Azure App Registration
```bash
# Create app registration
az ad app create --display-name "UserMetricsExport" --sign-in-audience "AzureADMyOrg"

# Get the app ID
APP_ID=$(az ad app list --display-name "UserMetricsExport" --query "[0].appId" -o tsv)

# Create service principal
az ad sp create --id $APP_ID

# Create client secret
az ad app credential reset --id $APP_ID --display-name "GitHubActions"
```

### 2. Grant Microsoft Graph Permissions
```bash
# Get Microsoft Graph service principal ID
GRAPH_SP_ID=$(az ad sp list --display-name "Microsoft Graph" --query "[0].id" -o tsv)

# Grant User.Read.All permission
az ad app permission add --id $APP_ID --api 00000003-0000-0000-c000-000000000000 --api-permissions df021288-bdef-4463-88db-98f22de89214=Role

# Grant AuditLog.Read.All permission
az ad app permission add --id $APP_ID --api 00000003-0000-0000-c000-000000000000 --api-permissions b0afded3-3588-46d8-8b3d-9842eff778da=Role

# Grant admin consent
az ad app permission admin-consent --id $APP_ID
```

### 3. Store Secrets in Key Vault
```bash
# Create Key Vault (if needed)
az keyvault create --name "your-keyvault-name" --resource-group "your-rg" --location "eastus"

# Store secrets
az keyvault secret set --vault-name "your-keyvault-name" --name "tenant-id" --value "your-tenant-id"
az keyvault secret set --vault-name "your-keyvault-name" --name "client-id" --value "your-client-id"
az keyvault secret set --vault-name "your-keyvault-name" --name "client-secret" --value "your-client-secret"
```

### 4. Setup GitHub Repository Secrets
Add these secrets to your GitHub repository:

- `AZURE_CLIENT_ID`: Service principal client ID
- `AZURE_CLIENT_SECRET`: Service principal client secret
- `AZURE_TENANT_ID`: Your tenant ID
- `AZURE_CREDENTIALS`: JSON object with service principal credentials

Format for AZURE_CREDENTIALS:
```json
{
  "clientId": "your-client-id",
  "clientSecret": "your-client-secret",
  "subscriptionId": "your-subscription-id",
  "tenantId": "your-tenant-id"
}
```

### 5. Grant Service Principal Access
```bash
# Grant Key Vault access
az keyvault set-policy --name "your-keyvault-name" --spn $APP_ID --secret-permissions get

# Grant Storage Account access
az role assignment create --assignee $APP_ID --role "Storage Blob Data Contributor" --scope "/subscriptions/your-sub-id/resourceGroups/your-rg/providers/Microsoft.Storage/storageAccounts/your-storage-account"
```

## Usage

### Manual Run
```powershell
./PBI/Get-UserMetrics.ps1 -KeyVaultName "your-keyvault" -StorageAccountName "yourstorageaccount"
```

### GitHub Actions
The workflow runs automatically daily at 6 AM UTC, or you can trigger it manually with custom parameters.

## Output

The script generates a CSV file with these columns:
- UserId
- UserPrincipalName
- Name
- Email
- AlternateEmail
- Username
- Department
- Country
- Company Name
- LastLogon
- LoggedIn
- AccountStatus
- AccountType

## File Location
Files are saved to: `https://yourstorageaccount.blob.core.windows.net/usermetrics/UserMetrics_YYYYMMDD.csv`

## Troubleshooting

### Common Issues
1. **Permission Errors**: Ensure app registration has proper Graph API permissions
2. **Key Vault Access**: Verify service principal has access to Key Vault secrets
3. **Storage Access**: Check service principal has Storage Blob Data Contributor role

### Logs
GitHub Actions will show detailed logs. Failed runs will upload error logs as artifacts.
