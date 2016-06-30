
Deployment Instructions
=========================

Information about the Azure Powershell 1.0 commandlets:

https://msdn.microsoft.com/en-us/library/azure/mt619274.aspx

At the time of writing `deploy.ps1` was tested with: 
*   Azure PowerShell 1.0.1
*   AzureRM PowerShell 1.0.1

## Requirements

1.  Visual Studio 2010 (or newer)
2.  PowerShell 5.0

## Preparation

Begin by preparing the local environment by installing the 
Azure and Azure Resource Manager commandlets.

**Note:** [Requires Windows 10 or WMF 5][azure_ps_info].
 
1.  Launch a PowerShell session
2.  Install the AzureRM and Azure modules from the PowerShell Gallery:

        > Install-Module AzureRM -Scope CurrentUser
        > Install-Module Azure -Scope CurrentUser
        
3.  Install AzureRM (requires Administrator privelages):

        > Install-AzureRM


[azure_ps_info]: https://www.powershellgallery.com/GettingStarted?section=Get%20Started

## Running the deployment script

Launch a PowerShell session and execute the deploy.ps1 script.
There are two required arguments:

*   'DemoName' - The DemoName will be used to construct URLs and names for
     deployed Azure components. Should be globally unique.

*   'ResourceGroup' - The name of the Resource Group to deploy this demo into.
    If this group does not exist, it will be created.


For example:

    > deploy.ps1 -DemoName MyUniqueDemo -ResourceGroup DemoResourceGroup

The script begins by compiling the source code used during deployment. You will then be
prompted for a few configuration values:

    **INSERT Configuration values required for script here.**
    Enter configuration for Dow Jones Price: ...
    Enter configuration for Customer Churn PowerBI Dashboard URL: ...
    Enter configuration for Suspicious Trade PowerBI Dashboard URL: ...
    
You will be prompted for confirmation before the script progresses. Depending on the
state of your Azure subscription, you may be prompted to confirm creation of some resources.

    Ready to begin deployment
    Are you sure you want to continue?
    [Y] Yes  [N] No  [?] Help (default is "Y"):


Is is safe to run this script again after successful (or unsuccessful) completion.
