# Azure Function version - if you prefer serverless
# This would go in an Azure Function App

using namespace System.Net

param($Request, $TriggerMetadata)

# Import required modules
Import-Module Az.KeyVault
Import-Module Az.Storage  
Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Users

# Function to write log messages
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

try {
    Write-Log "Starting User Metrics Export Function"
    
    # Get configuration from app settings
    $keyVaultName = $env:KEY_VAULT_NAME
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $containerName = $env:CONTAINER_NAME ?? "usermetrics"
    
    if (-not $keyVaultName -or -not $storageAccountName) {
        throw "KEY_VAULT_NAME and STORAGE_ACCOUNT_NAME must be configured in app settings"
    }
    
    # ==========================
    # 1. Get secrets from Key Vault using managed identity
    # ==========================
    Write-Log "Retrieving secrets from Key Vault: $keyVaultName"
    
    $tenantId = (Get-AzKeyVaultSecret -VaultName $keyVaultName -Name "tenant-id" -AsPlainText)
    $clientId = (Get-AzKeyVaultSecret -VaultName $keyVaultName -Name "client-id" -AsPlainText)  
    $clientSecret = (Get-AzKeyVaultSecret -VaultName $keyVaultName -Name "client-secret" -AsPlainText)
    
    if (-not $tenantId -or -not $clientId -or -not $clientSecret) {
        throw "Failed to retrieve secrets from Key Vault"
    }
    
    # ==========================
    # 2. Connect to Microsoft Graph
    # ==========================
    Write-Log "Connecting to Microsoft Graph..."
    
    $secureClientSecret = ConvertTo-SecureString $clientSecret -AsPlainText -Force
    $clientCredential = New-Object System.Management.Automation.PSCredential($clientId, $secureClientSecret)
    
    Connect-MgGraph -TenantId $tenantId -ClientSecretCredential $clientCredential -NoWelcome
    
    # ==========================
    # 3. Get and process users (same logic as main script)
    # ==========================
    Write-Log "Retrieving users from Microsoft Graph..."
    
    $properties = @(
        'id', 'displayName', 'userPrincipalName', 'mail', 'otherMails',
        'department', 'country', 'companyName', 'accountEnabled', 'userType', 'signInActivity'
    )
    
    $users = Get-MgUser -All -Property $properties -PageSize 999
    Write-Log "Retrieved $($users.Count) users"
    
    # Process users (same transformation logic)
    $processedUsers = foreach ($user in $users) {
        $alternateEmails = if ($user.OtherMails) { $user.OtherMails -join ", " } else { "" }
        $lastLogon = $null
        $loggedIn = "No"
        if ($user.SignInActivity -and $user.SignInActivity.LastSignInDateTime) {
            $lastLogon = $user.SignInActivity.LastSignInDateTime
            $loggedIn = "Yes"
        }
        $accountStatus = if ($user.AccountEnabled) { "Enabled" } else { "Disabled" }
        $accountType = if ($user.UserType -eq "Guest") { "Guest" } else { "Standard" }
        
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
    
    # ==========================
    # 4. Upload to blob storage
    # ==========================
    $fileName = "UserMetrics_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $csvData = $processedUsers | ConvertTo-Csv -NoTypeInformation
    
    $storageAccount = Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $storageAccountName }
    $ctx = $storageAccount.Context
    
    # Create temporary file and upload
    $tempFile = [System.IO.Path]::GetTempFileName() + ".csv"
    $csvData -join "`n" | Out-File -FilePath $tempFile -Encoding UTF8
    
    Set-AzStorageBlobContent -File $tempFile -Container $containerName -Blob $fileName -Context $ctx -Force
    Remove-Item $tempFile -Force
    
    Write-Log "Successfully uploaded $fileName to blob storage"
    
    # Success response
    $responseBody = @{
        status = "success"
        message = "User metrics exported successfully"
        fileName = $fileName
        recordCount = $processedUsers.Count
        timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC"
    }
    
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body = ($responseBody | ConvertTo-Json)
        Headers = @{ "Content-Type" = "application/json" }
    })
    
} catch {
    Write-Log "Error: $($_.Exception.Message)" -Level "ERROR"
    
    $errorResponse = @{
        status = "error"
        message = $_.Exception.Message
        timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC"
    }
    
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = ($errorResponse | ConvertTo-Json)
        Headers = @{ "Content-Type" = "application/json" }
    })
} finally {
    if (Get-MgContext) {
        Disconnect-MgGraph
    }
}
