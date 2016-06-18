
function Confirm-Host {
    param(
        [string]   $Title = $null,
        [string]   $Message = "Are you sure you want to continue?",
        [string[]] $Options = @("&Yes", "&No"),
        [int]      $DefaultOptionIndex = 0
    )

    $choices = new-object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
    foreach ($opt in $Options) {
        $choices.Add((new-object Management.Automation.Host.ChoiceDescription -ArgumentList $opt))
    }

    $Host.UI.PromptForChoice($Title, $Message, $choices, $DefaultOptionIndex)
}

function GetMsBuildPath {
    
	# Get the path to the directory that the latest version of MSBuild is in.
	$MsBuildToolsVersionsStrings = Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\MSBuild\ToolsVersions\' | Where-Object { $_ -match '[0-9]+\.[0-9]' } | Select-Object -ExpandProperty PsChildName
	
    # Determine the highest tool version
    # NOTE: Converts tool versions into decimals for sorting purposes
	$HighestMSBuildToolsVersion = $MsBuildToolsVersionsStrings | Sort-Object { [double]::Parse($_, [cultureinfo]::InvariantCulture) } -Descending | Select-Object -First 1
    
    # Locate the MSBuild tools path
    $MSBuildToolsRegistryKey = ([string]::Format([cultureinfo]::InvariantCulture, 'HKLM:\SOFTWARE\Microsoft\MSBuild\ToolsVersions\{0}', $HighestMSBuildToolsVersion))
	$MsBuildToolsVersionsKeyToUse = Get-Item -Path $MSBuildToolsRegistryKey
	$MsBuildDirectoryPath = $MsBuildToolsVersionsKeyToUse | Get-ItemProperty -Name 'MSBuildToolsPath' | Select-Object -ExpandProperty 'MSBuildToolsPath'

	if(-not $MsBuildDirectoryPath)
	{
		throw 'MsBuild.exe was not found on the system.'          
	}

	# Get the path to the MSBuild executable.
	$MsBuildPath = (Join-Path -Path $MsBuildDirectoryPath -ChildPath 'msbuild.exe')

	if(!(Test-Path $MsBuildPath -PathType Leaf))
	{
		throw 'MsBuild.exe was not found on the system.'          
	}

	return $MsBuildPath
}

#-------------------------#
# Some well-known folders #
#-------------------------#

$script_dir = Split-Path $MyInvocation.MyCommand.Path

$out_dir = "$script_dir\out"
$temp_dir = "$script_dir\out\temp"
$tools_dir = "$script_dir\out\tools"

if (-not (test-path $out_dir))   { mkdir $out_dir   | out-null }
if (-not (test-path $temp_dir))  { mkdir $temp_dir  | out-null }
if (-not (test-path $tools_dir)) { mkdir $tools_dir | out-null }

#$tools_src_dir = "$script_dir\BuildTools"

#---------------#
# Prepare tools #
#---------------#

#-------#
# Nuget #
#-------#

$nuget_exe = "$tools_dir/nuget.exe"

if (-not (test-path $nuget_exe)) {
    # Download nuget
    Write-Verbose "Downloading NuGet"
    Invoke-WebRequest "https://nuget.org/nuget.exe" -OutFile (join-path $tools_dir "nuget.exe")
}

Set-Alias tool_nuget $nuget_exe -Scope 'Script'


#---------#
# MsBuild #
#---------#

Set-Alias tool_msbuild  (GetMsBuildPath) -Scope 'Script'