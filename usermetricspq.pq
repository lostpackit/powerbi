let
    // ==========================
    // Configuration
    tenant_id = "tenant_id_here", // Replace with your tenant ID
    client_id = "client_id_here", // Replace with your client ID
    client_secret = "client_secret_here", // Replace with your client secret

    // ==========================
    // 1. Get OAuth2 token
    token_url = "https://login.microsoftonline.com/" & tenant_id & "/oauth2/v2.0/token",
    tokenResponse = Json.Document(Web.Contents(token_url,
        [
            Content = Text.ToBinary(
                "grant_type=client_credentials" &
                "&client_id=" & client_id &
                "&client_secret=" & client_secret &
                "&scope=https://graph.microsoft.com/.default"
            ),
            Headers = [
                #"Content-Type" = "application/x-www-form-urlencoded"
            ]
        ]
    )),
    access_token = tokenResponse[access_token],

    // ==========================
    // 2. Paging Function for Users
    GetPagedUsers = (url as text, token as text) as list =>
        let
            response = Json.Document(Web.Contents(url, [Headers = [Authorization = "Bearer " & token]])),
            users = response[value],
            nextLink = Record.FieldOrDefault(response, "@odata.nextLink", null),
            moreUsers = if nextLink <> null and nextLink <> "" then @GetPagedUsers(nextLink, token) else {},
            allUsers = List.Combine({users, moreUsers})
        in
            allUsers,

    // ==========================
    // 3. Pull all users with all needed fields
    selectFields = "id,displayName,userPrincipalName,mail,otherMails,department,country,companyName,accountEnabled,userType,signInActivity",
    baseUsersUrl = "https://graph.microsoft.com/v1.0/users?$top=999&$select=" & selectFields,
    allUsersList = GetPagedUsers(baseUsersUrl, access_token),
    usersTable = Table.FromList(allUsersList, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
    usersExpanded = Table.ExpandRecordColumn(
        usersTable, "Column1", 
        {"id","displayName","userPrincipalName","mail","otherMails","department","country","companyName","accountEnabled","userType","signInActivity"}
    ),

    // ==========================
    // 4. Flatten and Transform Fields
    usersWithEmails = Table.TransformColumns(usersExpanded, {{"otherMails", each Text.Combine(List.Transform(_, Text.From), ", "), type text}}),
    usersWithSignIn = Table.ExpandRecordColumn(usersWithEmails, "signInActivity", {"lastSignInDateTime"}, {"LastLogon"}),
    withLoggedIn = Table.AddColumn(usersWithSignIn, "LoggedIn", each if [LastLogon] <> null and [LastLogon] <> "" then "Yes" else "No"),
    withAccountStatus = Table.AddColumn(withLoggedIn, "AccountStatus", each if [accountEnabled]=true then "Enabled" else "Disabled"),
    withAccountType = Table.AddColumn(withAccountStatus, "AccountType", each if [userType]="Guest" then "Guest" else "Standard"),
    withUsername = Table.AddColumn(withAccountType, "Username", each [userPrincipalName]),

    // ==========================
    // 5. Select Columns to Match PowerShell Output
    output = Table.SelectColumns(withUsername, {
        "id",                   // UserId
        "userPrincipalName",    // UserPrincipalName
        "displayName",          // DisplayName
        "mail",                 // Email
        "otherMails",           // AlternateEmail
        "Username",             // Username
        "department",           // Department
        "country",              // Country
        "companyName",          // CompanyName
        "LastLogon",            // LastLogon
        "LoggedIn",             // LoggedIn
        "AccountStatus",        // AccountStatus
        "AccountType"           // AccountType
    }),
    #"Renamed Columns" = Table.RenameColumns(output,{{"companyName", "Company Name"}, {"country", "Country"}, {"mail", "Email"}, {"displayName", "Name"}, {"id", "UserId"}}),
    #"Changed Type" = Table.TransformColumnTypes(#"Renamed Columns",{{"LastLogon", type datetime}})
in
    #"Changed Type"