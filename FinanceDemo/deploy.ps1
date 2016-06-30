<# NOTE: Read README.md before continuing.


#>

param (
    [Parameter(Mandatory = $true, HelpMessage = 'The DemoName will be used to construct URLs and names for deployed Azure components. Should be globally unique.')]
    [string] $DemoName,

    [Parameter(Mandatory = $true, HelpMessage = 'The name of the Resource Group to deploy this demo into. If this group does not exist, it will be created.')]
    [string] $ResourceGroup,

    [Parameter(Mandatory = $false, HelpMessage = 'The name of a Storage Account to used during deployment. If this account does not exist, it will be created.')]
    [string] $StorageAccountName = $null,

    [Parameter(Mandatory = $false, HelpMessage = 'The Azure region to deploy into.')]
    [string] $Region = "East US"
)

#----------------------#
# Normalise user input #
#----------------------#
$global_name_suffix = '0630'

if (-not ($DemoName -match '^[a-zA-Z0-9]+$')) {
    # Restrict demo names to only a simple set of characters
    Write-Warning "DemoName '$DemoName' is invalid - please use numbers and letters only"
    return    
}

if (-not $StorageAccountName) {
    # Build a storage account name from the demo name
    # See: http://blogs.msdn.com/b/jmstall/archive/2014/06/12/azure-storage-naming-rules.aspx
    $StorageAccountName = "$($DemoName)storage".ToLower()
}

# Append global suffix
$StorageAccountName = $StorageAccountName + $global_name_suffix

#------------------#
# Load Environment #
#------------------#

Write-Host 'Preparing Environment'

$script_dir = Split-Path $MyInvocation.MyCommand.Path

# Import utilities
. "$script_dir\deploy_utils.ps1"

# Import AzureRM
Import-Module AzureRM.Profile
Import-Module AzureRM.Resources
Import-Module AzureRM.Storage
Import-Module AzureRM.Websites
Import-Module Azure

#------------------------#
# Build Web Applications #
# (app and webjob)       #
#------------------------#

Write-Host 'Building web app'

tool_nuget restore '..\MSCorp.FinanceDemo.WebApp' -noninteractive

$log_path = (join-path $out_dir "msbuild.log")
tool_msbuild '..\MSCorp.FinanceDemo.WebApp\MSCorp.FinanceDemo.SettingsService\MSCorp.FinanceDemo.SettingsService.csproj' /p:Platform="AnyCPU" /T:Package /P:PackageLocation="$out_dir" /P:_PackageTempDir="$temp_dir" /fileLoggerParameters:LogFile="$log_path"

# Scan for build error
if (-not (test-path $log_path)) {
    Write-Warning "Unable to find msbuild log file $log_path"
    return
}

$build_success = ((Select-String -Path $log_path -Pattern "Build FAILED." -SimpleMatch) -eq $null) -and $LASTEXITCODE -eq 0

if (-not $build_success) {
    Write-Warning "Error building project. See build log: $log_path"
    return
}

#------------------------------------------#
# Find local machines' external ip address #
#------------------------------------------#

Write-Host 'Finding external IP address (this may take a while)'

$local_machine_external_ip_address = (Invoke-WebRequest 'http://bot.whatismyipaddress.com/' -TimeoutSec 240).Content.Trim()

if (-not $local_machine_external_ip_address) {
    Write-Warning 'Unable to determine external IP Address! Please try again.'
    return
}
else {
    Write-Host "Found external IP Address: $local_machine_external_ip_address"
}

#-------------------------------#
# Prompt for user configuration #
#-------------------------------#

Write-Host 'Configuring Deployment'

# All required config keys
$script_config_keys = @(
    "Dow Jones Price (eg. 17733.10)",
    'Customer Churn PowerBI Dashboard URL',
    'Suspicious Trade PowerBI Dashboard URL'
)

$script_config = @{};

foreach ($key in $script_config_keys) {
    
    while ($script_config[$key] -eq $null) {

        # Prompt the user for confguration value
        $result = Read-Host "Enter configuration for $key"

        if (-not [String]::IsNullOrWhitespace($result)) {
            # NOTE: The cast to string is required.
            $script_config[$key] = [string] $result    
        }
    }
}

if ((Confirm-Host -Title 'Ready to begin deployment') -eq 1) {
    # User declined
    return    
}

#------------------------------#
# Ensure the user is signed in #
#------------------------------#

Write-Host 'Verifying authentication'

$rm_context = 
    try {
        Get-AzureRmContext
    }
    catch {
        if ($_.Exception -and $_.Exception.Message.Contains('Login-AzureRmAccount')) { $null } else { throw }
    }

if (-not $rm_context) {
    
    $title = 'You must sign in with your Azure account to continue'
    $message = 'Sign in?'

    if ((Confirm-Host -Title $title -Message $message) -eq 1) {
        # use declined
        return
    }

    $rm_context = Login-AzureRmAccount
}

if (-not $rm_context) {
    Write-Warning 'Unable to sign in.'
    return    
}

#-----------------------#
# Select a subscription #
#-----------------------#

Write-Host "Selecting subscription..."
Write-Host "If you are associated with multiple Azure subscriptions, you may encounter a problem 
 selecting your desired subscription. If this is the case: run the following:"
Write-Host "> Get-AzureRmSubscription"
Write-Host "> Login-AzureRmAccount -TenantID <tenant id>"
Write-Host ""

$azure_subscriptions = Get-AzureRmSubscription

if ($azure_subscriptions.Count -eq 1) {

    $rm_subscription_id = $azure_subscriptions[0].SubscriptionId
}
elseif ($azure_subscriptions.Count -gt 0) {
    
    # Build an array of bare subscription IDs for lookups
    $subscription_ids = $azure_subscriptions | % { $_.SubscriptionId }

    Write-Host 'Available subscriptions:'
    $azure_subscriptions | Format-Table SubscriptionId,SubscriptionName -AutoSize

    # Loop until the user selects a valid subscription Id
    while (-not $rm_subscription_id -or -not $subscription_ids -contains $rm_subscription_id) {
        
        $rm_subscription_id = Read-Host 'Please select a valid SubscriptionId from the list'
    }
}

if (-not $rm_subscription_id) {
    Write-Warning 'No subscription available'
    return    
}

Select-AzureRmSubscription -SubscriptionId $rm_subscription_id | out-null

#-----------------------------------#
# Select or create a resource group #
#-----------------------------------#

Write-Host "Acquiring resource group ($ResourceGroup)"

$rm_resource_group = try {
    Get-AzureRmResourceGroup -Name $ResourceGroup -Verbose
} catch {
    if ($_.Exception.Message -eq 'Provided resource group does not exist.') { 
        $null 
    } else {
        throw
    }
}

if (-not $rm_resource_group) {
    if ((Confirm-Host -Title "Resource group $ResourceGroup does not exist" -Message "Create it?") -eq 0)  {

        Write-Host "Creating resource group $ResourceGroup..."

        $rm_resource_group = New-AzureRmResourceGroup -Name $ResourceGroup -Location $Region -Verbose
    }
}

if (-not $rm_resource_group) {
    Write-Warning 'No resource group!'
    return
}

$rm_resource_group_name = $rm_resource_group.ResourceGroupName

#--------------------------#
# Create a Storage Account #
#--------------------------#

Write-Host "Acquiring storage account ($StorageAccountName)"

$rm_storage_account = try {

    Get-AzureRmStorageAccount -ResourceGroupName $rm_resource_group_name -Name $StorageAccountName -Verbose
} catch {

    if ($_.Exception.Message.Contains('not found')) { $null } else { throw } 
}

if (-not $rm_storage_account) {

    if ((Confirm-Host -Title "Storage account $StorageAccountName does not exist" -Message "Create it?") -eq 0) {

        Write-Host "Creating storage account $StorageAccountName..."

        $rm_storage_account = New-AzureRmStorageAccount -ResourceGroupName $rm_resource_group_name -Name $StorageAccountName -Type "Standard_LRS" -Location $Region -Verbose
    }
}

if (-not $rm_storage_account) {
    Write-Warning 'No storage account'
    return
}

$rm_storage_account_name = $rm_storage_account.StorageAccountName

Write-Host "Using storage account $rm_storage_account_name"

$rm_storage_account_key = Get-AzureRmStorageAccountKey -ResourceGroupName $rm_resource_group_name -Name $rm_storage_account_name

if (-not $rm_storage_account_key) {
    Write-Warning 'Could not retrieve storage account key'
    return
}

# Get key 1. Older versions of powershell use .Key1
if (-not $rm_storage_account_key.Key1) {
    
    $rm_storage_account_key = $rm_storage_account_key.Value[0]
} else {

    $rm_storage_account_key = $rm_storage_account_key.Key1
}

#----------------------------#
# Upload web deploy packages #
#----------------------------#

Write-Host 'Uploading deployment package to blob storage'

Write-Host 'Connecting to blob storage'
$deployment_container_name = 'deployment'

# Connect to blob storage
$blob_context = New-AzureStorageContext -StorageAccountName $rm_storage_account_name -StorageAccountKey $rm_storage_account_key
if (-not $blob_context) {
    Write-Warning "Failed to connect to Azure Storage"
    return
}

# Verify or create container
$container = 
    try {
        Get-AzureStorageContainer -Context $blob_context -Name $deployment_container_name
    }
    catch {
        if ($_.Exception.Message.Contains('Can not find the container')) { $null } else { throw }
    }

if (-not $container) {
    $container = New-AzureStorageContainer -Context $blob_context -Name $deployment_container_name -Permission Blob
}

if (-not $container) {
    Write-Warning "Failed to create deployment container"
    return
}

# Upload web deploy package

Write-Host 'Uploading web app'

$web_deploy_package_name_web_app = 'MSCorp.FinanceDemo.SettingsService.zip'
$web_deploy_package_web_app = (join-path $out_dir $web_deploy_package_name_web_app)

$blob_result_web_app = Set-AzureStorageBlobContent -Context $blob_context `
                                                   -Container $deployment_container_name `
                                                   -Blob $web_deploy_package_name_web_app `
                                                   -File $web_deploy_package_web_app `
                                                   -Force
if (-not $blob_result_web_app) {
    Write-Warning "Failed to upload blob $web_deploy_package_name_web_app"
    return
}

$web_app_package_url = $blob_result_web_app.ICloudBlob.Uri.AbsoluteUri;

Write-Host "Uploaded web app to $web_app_package_url"

#---------------------------------#
# Start resource group deployment #
#---------------------------------#

Write-Host 'Starting resource group deployment'

$template = "$script_dir\deploy_template.json"

$params = @{
    'demo_name'                         = $DemoName;
    'global_suffix'                     = $global_name_suffix;
    'datacenter_location'               = $Region;
    'web_service_package_url'           = $web_app_package_url;
    'local_machine_external_ip_address' = $local_machine_external_ip_address;
    'dow_jones_price'                   = $script_config['Dow Jones Price (eg. 17733.10)'];
    'currency_pairs_data'               = '[]';
    'customer_churn_pbi_url'            = $script_config['Customer Churn PowerBI Dashboard URL'];
    'financial_advisor_pbi_url'         = $script_config['Suspicious Trade PowerBI Dashboard URL']

    # All required config keys
}

$result = New-AzureRmResourceGroupDeployment -ResourceGroupName $rm_resource_group_name -TemplateFile $template -TemplateParameterObject $params -Verbose

if (-not $result -or $result.ProvisioningState -ne 'Succeeded') {
    Write-Warning 'An error occured during provisioning'
    Write-Output $result
    return
}

# Copy output values into a dictionary for easy consumption
$OUTPUTS = @{}

foreach ($name in $result.Outputs.Keys) {
    $OUTPUTS[$name] = $result.Outputs[$name].Value
}

#-----------------------#
# Build database tables #
#-----------------------#

$sql_scripts = @(
    "$script_dir\sql_scripts\sqldb_tables.sql"
)

$sql_server          = $OUTPUTS['sql_server_fqdn']
$sql_server_username = $OUTPUTS['sql_server_fq_username']
$sql_server_password = $OUTPUTS['sql_server_password']
$sql_server_database = $OUTPUTS['sql_server_database_name']

$msg = 'You may like to wait a few minutes before continuing to ensure that the DB Server is ready.
If you would like to deploy the database manually then press [S] and follow the on-screen instructions'; 

if ((Confirm-Host -Title 'Deploy database tables?' -Message $msg -Options @('&Deploy', '&Skip')) -eq 1) {
    
    # User skipped
    Write-Host 'You may manually deploy the database by connecting to the database with the following credentials;'
    Write-Host "`tServer Name: $sql_server"
    Write-Host "`tUsername: $sql_server_username"
    Write-Host "`tPassword: $sql_server_password"
    Write-Host "`tDatabase: $sql_server_database"
    Write-Host 'And executing the following scripts:'
    foreach ($script_path in $sql_scripts) {
        Write-Host "`t$script_path"
    } 
}
else {
    
    Write-Host 'Executing database bootstrap scripts (this may take some time)'

    $sql_timeout_seconds = [int] [TimeSpan]::FromMinutes(8).TotalSeconds 
    $sql_connection_timeout_seconds = [int] [TimeSpan]::FromMinutes(2).TotalSeconds

    Push-Location
    try {
        foreach ($script_path in $sql_scripts) {
            Write-Host "Executing $script_path"
            Invoke-Sqlcmd -ServerInstance $sql_server -Username $sql_server_username -Password $sql_server_password -Database $sql_server_database -InputFile $script_path -QueryTimeout $sql_timeout_seconds -ConnectionTimeout $sql_connection_timeout_seconds
        }
    }
    catch {
        Write-Warning "Error executing $sql_script (consider executing manually)`n$($_.Exception)"
    }
    finally {
        # Work around Invoke-Sqlcmd randomly changing the working directory
        Pop-Location
    }
}

#-----------------------------#
# Build Data Warehouse Tables #
#-----------------------------#


$sqldw_scripts = @(
    "$script_dir\sql_scripts\sqldw_tables.sql",
    "$script_dir\sql_scripts\sqldw_procs.sql"
)

$sqldw_server          = $OUTPUTS['sqldw_server_fqdn']
$sqldw_server_username = $OUTPUTS['sqldw_server_fq_username']
$sqldw_server_password = $OUTPUTS['sqldw_server_password']
$sqldw_server_database = $OUTPUTS['sqldw_server_database_name']

$msg = 'You may like to wait a few minutes before continuing to ensure that the Data Warehouse Server is ready.
If you would like to deploy the database manually then press [S] and follow the on-screen instructions'; 

if ((Confirm-Host -Title 'Deploy data warehouse tables?' -Message $msg -Options @('&Deploy', '&Skip')) -eq 1) {
    
    # User skipped
    Write-Host 'You may manually deploy the database by connecting to the database with the following credentials;'
    Write-Host "`tServer Name: $sqldw_server"
    Write-Host "`tUsername: $sqldw_server_username"
    Write-Host "`tPassword: $sqldw_server_password"
    Write-Host "`tDatabase: $sqldw_server_database"
    Write-Host 'And executing the following scripts:'
    foreach ($script_path in $sqldw_scripts) {
        Write-Host "`t$script_path"
    } 
}
else {
    
    Write-Host 'Executing database bootstrap scripts (this may take some time)'

    $sqldw_timeout_seconds = [int] [TimeSpan]::FromMinutes(8).TotalSeconds 
    $sqldw_connection_timeout_seconds = [int] [TimeSpan]::FromMinutes(2).TotalSeconds

    Push-Location
    try {
        foreach ($script_path in $sqldw_scripts) {
            Write-Host "Executing $script_path"
            Invoke-Sqlcmd -ServerInstance $sqldw_server -Username $sqldw_server_username -Password $sqldw_server_password -Database $sqldw_server_database -InputFile $script_path -QueryTimeout $sqldw_timeout_seconds -ConnectionTimeout $sqldw_connection_timeout_seconds
        }
    }
    catch {
        Write-Warning "Error executing $sqldw_script (consider executing manually)`n$($_.Exception)"
    }
    finally {
        # Work around Invoke-Sqlcmd randomly changing the working directory
        Pop-Location
    }
}

#--------------------------------------------------#
# Now that the databases have been built:          #
# Start resource group deployment for Data Factory #
#--------------------------------------------------#

Write-Host 'Starting resource group deployment for Data Factory'

$template = "$script_dir\deploy_template_df.json"

$params = @{
    'demo_name'                         = $DemoName;
    'global_suffix'                     = $global_name_suffix;
    'datacenter_location'               = $Region;
    'sql_server_name'                   = $OUTPUTS['sql_server_name'];
    'sqldw_server_name'                 = $OUTPUTS['sqldw_server_name'];
    'sql_server_db_name'                = $OUTPUTS['sql_server_database_name'];
    'sql_server_dw_name'                = $OUTPUTS['sqldw_server_database_name'];
    'sql_server_username'               = $OUTPUTS['sql_server_username'];
    'sqldw_server_username'             = $OUTPUTS['sqldw_server_username'];
    'sql_server_password'               = $OUTPUTS['sql_server_password'];
    'sqldw_server_password'             = $OUTPUTS['sqldw_server_password'];

    # All required config keys
}

$result = New-AzureRmResourceGroupDeployment -ResourceGroupName $rm_resource_group_name -TemplateFile $template -TemplateParameterObject $params -Verbose

if (-not $result -or $result.ProvisioningState -ne 'Succeeded') {
    Write-Warning 'An error occured during provisioning'
    Write-Output $result
    return
}

# Don't print outputs from data factory deployment - it's unlikely that they'll
# be useful.

#----------------#
# Report results #
#----------------#

Write-Host "Deployment Successful. Writing output variables..."

# To std-out
$OUTPUTS | Format-Table Key,Value -AutoSize

# Out to file
$output_file_name = (join-path $pwd "output_$([DateTime]::Now.ToString('yyyy-MM-dd-HH-mm-ss')).json")

Write-Host "Writing the output variables to $output_file_name"

$OUTPUTS | ConvertTo-Json | Out-File -Encoding Utf8 $output_file_name

Write-Host "Done."
