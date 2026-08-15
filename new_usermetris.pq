let
    // ==========================
    // Configuration
    tenant_id = "tenant_id_here",
    client_id = "client_id_here",
    client_secret = "client_secret_here",

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
    // 2. Function: Get one page of users using static URL base (for refreshable queries)
    GetUsersPage = (skip as number) as table =>
        let
            baseUrl = "https://graph.microsoft.com",
            relativePath = "/v1.0/users",
            query = [
                #"$top" = "999",
                #"$skip" = Text.From(skip),
                #"$select" = "id,displayName,userPrincipalName,mail,otherMails,department,country,companyName,accountEnabled,userType,signInActivity"
            ],
            response = Json.Document(Web.Contents(baseUrl,
                [
                    RelativePath = relativePath,
                    Query = query,
                    Headers = [Authorization = "Bearer " & access_token]
                ])),
            users = try response[value] otherwise {}
        in
            Table.FromList(users, Splitter.SplitByNothing(), null, null, ExtraValues.Error),

    // ==========================
    // 3. Generate skip values for up to 10,000 users (increase upper limit if needed)
    Skips = List.Generate(() => 0, each _ < 10000, each _ + 999),

    // ==========================
    // 4. Get all user pages and combine
    AllPages = List.Transform(Skips, each GetUsersPage(_)),
    AllUsersRaw = Table.Combine(AllPages),

    // ==========================
    // 5. Expand and transform fields as in your PowerShell logic
    usersExpanded = Table.ExpandRecordColumn(
        AllUsersRaw, "Column1",
        {"id","displayName","userPrincipalName","mail","otherMails","department","country","companyName","accountEnabled","userType","signInActivity"}
    ),
    usersWithEmails = Table.TransformColumns(usersExpanded, {{"otherMails", each Text.Combine(List.Transform(_, Text.From), ", "), type text}}),
    usersWithSignIn = Table.ExpandRecordColumn(usersWithEmails, "signInActivity", {"lastSignInDateTime"}, {"LastLogon"}),
    withLoggedIn = Table.AddColumn(usersWithSignIn, "LoggedIn", each if [LastLogon] <> null and [LastLogon] <> "" then "Yes" else "No"),
    withAccountStatus = Table.AddColumn(withLoggedIn, "AccountStatus", each if [accountEnabled]=true then "Enabled" else "Disabled"),
    withAccountType = Table.AddColumn(withAccountStatus, "AccountType", each if [userType]="Guest" then "Guest" else "Standard"),
    withUsername = Table.AddColumn(withAccountType, "Username", each [userPrincipalName]),

    // ==========================
    // 6. Select columns, rename to match PowerShell/CSV output
    output = Table.RenameColumns(
        Table.SelectColumns(withUsername, {
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
        {
            {"id", "UserId"},
            {"userPrincipalName", "UserPrincipalName"},
            {"displayName", "DisplayName"},
            {"mail", "Email"},
            {"otherMails", "AlternateEmail"},
            {"Username", "Username"},
            {"department", "Department"},
            {"country", "Country"},
            {"companyName", "CompanyName"},
            {"LastLogon", "LastLogon"},
            {"LoggedIn", "LoggedIn"},
            {"AccountStatus", "AccountStatus"},
            {"AccountType", "AccountType"}
        }
    )
in
    output