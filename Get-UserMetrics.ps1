#Requires -Modules Az.Accounts, Az.KeyVault, Az.Storage, Microsoft.Graph.Authentication, Microsoft.Graph.Users

<#
.SYNOPSIS
    Retrieves user metrics from Microsoft Graph API and exports to Azure Blob Storage
.DESCRIPTION
    This script authenticates to Microsoft Graph using credentials from Azure Key Vault,
    retrieves user information with sign-in activity, and exports the data to a CSV file
    in Azure Blob Storage. Designed to run in Azure DevOps/GitHub Actions runners.
.PARAMETER KeyVaultName
    Name of the Azure Key Vault containing the secrets
.PARAMETER StorageAccountName
    Name of the Azure Storage Account for output
.PARAMETER ContainerName
    Name of the blob container for output (default: usermetrics)
.PARAMETER OutputFileName
    Name of the output CSV file (default: UserMetrics_YYYYMMDD.csv)
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,
    
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,
    
    [Parameter(Mandatory = $false)]
    [string]$ContainerName = "usermetrics",
    
    [Parameter(Mandatory = $false)]
    [string]$OutputFileName = "UserMetrics_$(Get-Date -Format 'yyyyMMdd').csv"
)

# Function to write log messages
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

try {
    Write-Log "Starting User Metrics Export Process"
    
    # ==========================
    # 1. Authenticate to Azure and get secrets from Key Vault
    # ==========================
    Write-Log "Connecting to Azure..."
    
    # For Azure runners, use managed identity or service principal
    if ($env:AZURE_CLIENT_ID -and $env:AZURE_CLIENT_SECRET -and $env:AZURE_TENANT_ID) {
        Write-Log "Using service principal authentication"
        $secpasswd = ConvertTo-SecureString $env:AZURE_CLIENT_SECRET -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($env:AZURE_CLIENT_ID, $secpasswd)
        Connect-AzAccount -ServicePrincipal -Credential $credential -Tenant $env:AZURE_TENANT_ID
    } else {
        Write-Log "Using managed identity authentication"
        Connect-AzAccount -Identity
    }
    
    Write-Log "Retrieving secrets from Key Vault: $KeyVaultName"
    
    # Get secrets from Key Vault
    $tenantId = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "tenant-id" -AsPlainText)
    $clientId = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "client-id" -AsPlainText)
    $clientSecret = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "client-secret" -AsPlainText)
    
    if (-not $tenantId -or -not $clientId -or -not $clientSecret) {
        throw "Failed to retrieve one or more secrets from Key Vault"
    }
    
    Write-Log "Successfully retrieved secrets from Key Vault"
    
    # ==========================
    # 2. Connect to Microsoft Graph
    # ==========================
    Write-Log "Connecting to Microsoft Graph..."
    
    $secureClientSecret = ConvertTo-SecureString $clientSecret -AsPlainText -Force
    $clientCredential = New-Object System.Management.Automation.PSCredential($clientId, $secureClientSecret)
    
    Connect-MgGraph -TenantId $tenantId -ClientSecretCredential $clientCredential -NoWelcome
    
    Write-Log "Connected to Microsoft Graph successfully"
    
    # ==========================
    # 3. Get all users with pagination
    # ==========================
    Write-Log "Retrieving users from Microsoft Graph..."
    
    $allUsers = @()
    $pageSize = 999
    $properties = @(
        'id',
        'displayName',
        'userPrincipalName',
        'mail',
        'otherMails',
        'department',
        'country',
        'companyName',
        'accountEnabled',
        'userType',
        'signInActivity'
    )
    
    # Get users with pagination
    $users = Get-MgUser -All -Property $properties -PageSize $pageSize
    
    Write-Log "Retrieved $($users.Count) users from Microsoft Graph"
    
    # ==========================
    # 4. Process and transform user data
    # ==========================
    Write-Log "Processing user data..."
    
    $processedUsers = foreach ($user in $users) {
        # Handle alternate emails
        $alternateEmails = if ($user.OtherMails) { 
            $user.OtherMails -join ", " 
        } else { 
            "" 
        }
        
        # Handle last logon
        $lastLogon = $null
        $loggedIn = "No"
        if ($user.SignInActivity -and $user.SignInActivity.LastSignInDateTime) {
            $lastLogon = $user.SignInActivity.LastSignInDateTime
            $loggedIn = "Yes"
        }
        
        # Account status
        $accountStatus = if ($user.AccountEnabled) { "Enabled" } else { "Disabled" }
        
        # Account type
        $accountType = if ($user.UserType -eq "Guest") { "Guest" } else { "Standard" }
        
        # Create custom object
        [PSCustomObject]@{
            UserId = $user.Id
            UserPrincipalName = $user.UserPrincipalName
            Name = $user.DisplayName
            Email = $user.Mail
            AlternateEmail = $alternateEmails
            Username = $user.UserPrincipalName
            Department = $user.Department
            Country = $user.Country
            'Company Name' = $user.CompanyName
            LastLogon = $lastLogon
            LoggedIn = $loggedIn
            AccountStatus = $accountStatus
            AccountType = $accountType
        }
    }
    
    Write-Log "Processed $($processedUsers.Count) user records"
    
    # ==========================
    # 5. Export to CSV and upload to Azure Blob Storage
    # ==========================
    Write-Log "Preparing to upload to Azure Blob Storage..."
    
    # Create temporary file
    $tempFile = [System.IO.Path]::GetTempFileName() + ".csv"
    
    # Export to CSV
    $processedUsers | Export-Csv -Path $tempFile -NoTypeInformation -Encoding UTF8
    
    Write-Log "Exported data to temporary CSV file"
    
    # Get storage account context
    $storageAccount = Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $StorageAccountName }
    if (-not $storageAccount) {
        throw "Storage account '$StorageAccountName' not found"
    }
    
    $ctx = $storageAccount.Context
    
    # Create container if it doesn't exist
    $container = Get-AzStorageContainer -Name $ContainerName -Context $ctx -ErrorAction SilentlyContinue
    if (-not $container) {
        Write-Log "Creating container: $ContainerName"
        New-AzStorageContainer -Name $ContainerName -Context $ctx -Permission Off
    }
    
    # Upload file to blob storage
    Write-Log "Uploading file to blob storage: $OutputFileName"
    
    Set-AzStorageBlobContent -File $tempFile -Container $ContainerName -Blob $OutputFileName -Context $ctx -Force
    
    Write-Log "Successfully uploaded file to Azure Blob Storage"
    
    # Clean up temporary file
    Remove-Item $tempFile -Force
    
    Write-Log "User metrics export completed successfully"
    Write-Log "File location: https://$($StorageAccountName).blob.core.windows.net/$ContainerName/$OutputFileName"
    
} catch {
    Write-Log "Error occurred: $($_.Exception.Message)" -Level "ERROR"
    Write-Log "Stack trace: $($_.Exception.StackTrace)" -Level "ERROR"
    throw
} finally {
    # Disconnect from services
    if (Get-MgContext) {
        Disconnect-MgGraph
        Write-Log "Disconnected from Microsoft Graph"
    }
}
