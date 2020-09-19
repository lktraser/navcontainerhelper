<# 
 .Synopsis
  Preview script for running simple AL pipeline
 .Description
  Preview script for running simple AL pipeline
#>
function Run-AlPipeline {
Param(
    [string] $pipelineName,
    [string] $baseFolder,
    [string] $licenseFile,
    [string] $containerName = "$($pipelineName.Replace('.','-') -replace '[^a-zA-Z0-9---]', '')-bld".ToLowerInvariant(),
    [string] $imageName = 'my',
    [Boolean] $enableTaskScheduler = $false,
    [string] $memoryLimit,
    [PSCredential] $credential,
    [string] $codeSignCertPfxFile = "",
    [SecureString] $codeSignCertPfxPassword = $null,
    $installApps = @(),
    $appFolders = @("app", "application"),
    $testFolders = @("test", "testapp"),
    [int] $appBuild = 0,
    [int] $appRevision = 0,
    [string] $testResultsFile = "TestResults.xml",
    [string] $packagesFolder = "",
    [string] $outputFolder = ".output",
    [string] $artifact = "bcartifacts/sandbox//us/latest",
    [string] $buildArtifactFolder = "",
    [switch] $createRuntimePackages,
    [switch] $installTestFramework,
    [switch] $installTestLibraries,
    [switch] $installPerformanceToolkit,
    [switch] $azureDevOps,
    [switch] $useDevEndpoint,
    [switch] $doNotRunTests,
    [switch] $keepContainer,
    [string] $updateLaunchJson = "",
    [switch] $enableCodeCop,
    [switch] $enableAppSourceCop,
    [switch] $enableUICop,
    [switch] $enablePerTenantExtensionCop
)

function randomchar([string]$str)
{
    $rnd = Get-Random -Maximum $str.length
    [string]$str[$rnd]
}

function Get-RandomPassword {
    $cons = 'bcdfghjklmnpqrstvwxz'
    $voc = 'aeiouy'
    $numbers = '0123456789'

    ((randomchar $cons).ToUpper() + `
     (randomchar $voc) + `
     (randomchar $cons) + `
     (randomchar $voc) + `
     (randomchar $numbers) + `
     (randomchar $numbers) + `
     (randomchar $numbers) + `
     (randomchar $numbers))
}

Function UpdateLaunchJson {
    Param(
        [string] $launchJsonFile,
        [string] $configuration,
        [string] $Name,
        [string] $Server,
        [int] $Port = 7049,
        [string] $ServerInstance = "BC"
    )
    
    $launchSettings = [ordered]@{
        "type" = 'al';
        "request" = 'launch';
        "name" = $configuration; 
        "server" = "http://$Server"
        "serverInstance" = $serverInstance
        "port" = $Port
        "tenant" = 'default'
        "authentication" =  'UserPassword'
    }
    
    if (Test-Path $launchJsonFile) {
        Write-Host "Modifying $launchJsonFile"
        $launchJson = Get-Content $LaunchJsonFile | ConvertFrom-Json
        $oldSettings = $launchJson.configurations | Where-Object { $_.name -eq $launchsettings.name }
        if ($oldSettings) {
            $oldSettings.PSObject.Properties | % {
                $prop = $_.Name
                if (!($launchSettings.Keys | Where-Object { $_ -eq $prop } )) {
                    $launchSettings += @{ "$prop" = $oldSettings."$prop" }
                }
            }
        }
        $launchJson.configurations = @($launchJson.configurations | Where-Object { $_.name -ne $launchsettings.name })
        $launchJson.configurations += $launchSettings
        $launchJson | ConvertTo-Json -Depth 10 | Set-Content $launchJsonFile
    }
}

if ($memoryLimit -eq "")       { $memoryLimit = "6G" }

if ($installApps -is [String]) { $installApps = $installApps.Split(',') | Where-Object { $_ } }
if ($appFolders  -is [String]) { $appFolders  = $appFolders.Split(',')  | Where-Object { $_ } }
if ($testFolders -is [String]) { $testFolders = $testFolders.Split(',') | Where-Object { $_ } }

$appFolders  = @($appFolders  | ForEach-Object { if (!$_.contains(':')) { Join-Path $baseFolder $_ } else { $_ } } | Where-Object { Test-Path $_ } )
$testFolders = @($testFolders | ForEach-Object { if (!$_.contains(':')) { Join-Path $baseFolder $_ } else { $_ } } | Where-Object { Test-Path $_ } )
if (!$testResultsFile.Contains(':')) { $testResultsFile = Join-Path $baseFolder $testResultsFile }

if ($useDevEndpoint) {
    $packagesFolder = ""
}
else {
    if ($packagesFolder -eq "") {
        $packagesFolder = ".packages"
    }
    if (!$packagesFolder.Contains(':')) {
        $packagesFolder  = Join-Path $baseFolder $packagesFolder
    }
    if (Test-Path $packagesFolder) {
        Remove-Item $packagesFolder -Recurse -Force
    }

    if (!$outputFolder.Contains(':')) {
        $outputFolder = Join-Path $baseFolder $outputFolder
    }
    if (Test-Path $outputFolder) {
        Remove-Item $outputFolder -Recurse -Force
    }
}

if (!($appFolders)) {
    throw "No app folders found"
}

$sortedFolders = Sort-AppFoldersByDependencies -appFolders ($appFolders+$testFolders) -WarningAction SilentlyContinue

if ($artifact -like "https://*") {
    $artifactUrl = $artifact
}
else {
    $segments = "$artifact/////".Split('/')
    $storageAccount = $segments[0];
    $type = $segments[1]; if ($type -eq "") { $type = 'Sandbox' }
    $version = $segments[2]
    $country = $segments[3]; if ($country -eq "") { $country = "us" }
    $select = $segments[4]; if ($select -eq "") { $select = "latest" }
    $sasToken = $segments[5]

    $artifactUrl = Get-BCArtifactUrl -storageAccount $storageAccount -type $type -version $version -country $country -select $select -sasToken $sasToken | Select-Object -First 1
}

if (!($artifactUrl)) {
    throw "Unable to locate artifacts"
}

if ($buildArtifactFolder) {
    if (!(Test-Path $buildArtifactFolder)) {
        throw "BuildArtifactFolder must exist"
    }
}

Write-Host -ForegroundColor Yellow @'
  _____                               _                
 |  __ \                             | |               
 | |__) |_ _ _ __ __ _ _ __ ___   ___| |_ ___ _ __ ___ 
 |  ___/ _` | '__/ _` | '_ ` _ \ / _ \ __/ _ \ '__/ __|
 | |  | (_| | | | (_| | | | | | |  __/ |_  __/ |  \__ \
 |_|   \__,_|_|  \__,_|_| |_| |_|\___|\__\___|_|  |___/

'@
Write-Host -NoNewLine -ForegroundColor Yellow "Pipeline name               "; Write-Host $pipelineName
Write-Host -NoNewLine -ForegroundColor Yellow "Container name              "; Write-Host $containerName
Write-Host -NoNewLine -ForegroundColor Yellow "Image name                  "; Write-Host $imageName
Write-Host -NoNewLine -ForegroundColor Yellow "ArtifactUrl                 "; Write-Host $artifactUrl.Split('?')[0]
Write-Host -NoNewLine -ForegroundColor Yellow "SasToken                    "; if ($artifactUrl.Contains('?')) { Write-Host "Specified" } else { Write-Host "Not Specified" }
Write-Host -NoNewLine -ForegroundColor Yellow "Credential                  ";
if ($credential) {
    Write-Host "Specified"
}
else {
    $password = Get-RandomPassword
    Write-Host "admin/$password"
    $credential= (New-Object pscredential 'admin', (ConvertTo-SecureString -String $password -AsPlainText -Force))
}
Write-Host -NoNewLine -ForegroundColor Yellow "MemoryLimit                 "; Write-Host $memoryLimit
Write-Host -NoNewLine -ForegroundColor Yellow "Enable Task Scheduler       "; Write-Host $enableTaskScheduler
Write-Host -NoNewLine -ForegroundColor Yellow "Install Test Framework      "; Write-Host $installTestFramework
Write-Host -NoNewLine -ForegroundColor Yellow "Install Test Libraries      "; Write-Host $installTestLibraries
Write-Host -NoNewLine -ForegroundColor Yellow "Install Perf. Toolkit       "; Write-Host $installPerformanceToolkit
Write-Host -NoNewLine -ForegroundColor Yellow "enableCodeCop               "; Write-Host $enableCodeCop
Write-Host -NoNewLine -ForegroundColor Yellow "enableAppSourceCop          "; Write-Host $enableAppSourceCop
Write-Host -NoNewLine -ForegroundColor Yellow "enableUICop                 "; Write-Host $enableUICop
Write-Host -NoNewLine -ForegroundColor Yellow "enablePerTenantExtensionCop "; Write-Host $enablePerTenantExtensionCop
Write-Host -NoNewLine -ForegroundColor Yellow "azureDevOps                 "; Write-Host $azureDevOps
Write-Host -NoNewLine -ForegroundColor Yellow "License file                "; if ($licenseFile) { Write-Host "Specified" } else { "Not specified" }
Write-Host -NoNewLine -ForegroundColor Yellow "CodeSignCertPfxFile         "; if ($codeSignCertPfxFile) { Write-Host "Specified" } else { "Not specified" }
Write-Host -NoNewLine -ForegroundColor Yellow "TestResultsFile             "; Write-Host $testResultsFile
Write-Host -NoNewLine -ForegroundColor Yellow "PackagesFolder              "; Write-Host $packagesFolder
Write-Host -NoNewLine -ForegroundColor Yellow "OutputFolder                "; Write-Host $outputFolder
Write-Host -NoNewLine -ForegroundColor Yellow "BuildArtifactFolder         "; Write-Host $buildArtifactFolder
Write-Host -NoNewLine -ForegroundColor Yellow "CreateRuntimePackages       "; Write-Host $createRuntimePackages
Write-Host -NoNewLine -ForegroundColor Yellow "AppBuild                    "; Write-Host $appBuild
Write-Host -NoNewLine -ForegroundColor Yellow "AppRevision                 "; Write-Host $appRevision
Write-Host -ForegroundColor Yellow "Install Apps"
if ($installApps) { $installApps | ForEach-Object { Write-Host "- $_" } } else { Write-Host "- None" }
Write-Host -ForegroundColor Yellow "Application folders"
if ($appFolders) { $appFolders | ForEach-Object { Write-Host "- $_" } }  else { Write-Host "- None" }
Write-Host -ForegroundColor Yellow "Test application folders"
if ($testFolders) { $testFolders | ForEach-Object { Write-Host "- $_" } } else { Write-Host "- None" }

$signApps = ($codeSignCertPfxFile -ne "")

Measure-Command {

Measure-Command {

Write-Host -ForegroundColor Yellow @'

  _____       _ _ _                                          _        _                            
 |  __ \     | | (_)                                        (_)      (_)                           
 | |__) |   _| | |_ _ __   __ _    __ _  ___ _ __   ___ _ __ _  ___   _ _ __ ___   __ _  __ _  ___ 
 |  ___/ | | | | | | '_ \ / _` |  / _` |/ _ \ '_ \ / _ \ '__| |/ __| | | '_ ` _ \ / _` |/ _` |/ _ \
 | |   | |_| | | | | | | | (_| | | (_| |  __/ | | |  __/ |  | | (__  | | | | | | | (_| | (_| |  __/
 |_|    \__,_|_|_|_|_| |_|\__, |  \__, |\___|_| |_|\___|_|  |_|\___| |_|_| |_| |_|\__,_|\__, |\___|
                           __/ |   __/ |                                                 __/ |     
                          |___/   |___/                                                 |___/      

'@

$genericImageName = Get-BestGenericImageName
Write-Host "Pulling $genericImageName"
docker pull $genericImageName

} | ForEach-Object { Write-Host -ForegroundColor Yellow "`nPulling generic image took $([int]$_.TotalSeconds) seconds" }

$error = $null
$prevProgressPreference = $progressPreference
$progressPreference = 'SilentlyContinue'

try {

Write-Host -ForegroundColor Yellow @'

   _____                _   _                               _        _                 
  / ____|              | | (_)                             | |      (_)                
 | |     _ __ ___  __ _| |_ _ _ __   __ _    ___ ___  _ __ | |_ __ _ _ _ __   ___ _ __ 
 | |    | '__/ _ \/ _` | __| | '_ \ / _` |  / __/ _ \| '_ \| __/ _` | | '_ \ / _ \ '__|
 | |____| | |  __/ (_| | |_| | | | | (_| | | (__ (_) | | | | |_ (_| | | | | |  __/ |   
  \_____|_|  \___|\__,_|\__|_|_| |_|\__, |  \___\___/|_| |_|\__\__,_|_|_| |_|\___|_|   
                                     __/ |                                             
                                    |___/                                              

'@

Measure-Command {

    New-BcContainer `
        -accept_eula `
        -containerName $containerName `
        -imageName $imageName `
        -artifactUrl $artifactUrl `
        -Credential $credential `
        -auth UserPassword `
        -updateHosts `
        -licenseFile $licenseFile `
        -EnableTaskScheduler:$enableTaskScheduler `
        -MemoryLimit $memoryLimit `
        -additionalParameters @("--volume $($baseFolder):c:\sources")

    Invoke-ScriptInBcContainer -containerName $containerName -scriptblock {
        $progressPreference = 'SilentlyContinue'
    }
} | ForEach-Object { Write-Host -ForegroundColor Yellow "`nCreating container took $([int]$_.TotalSeconds) seconds" }

if (($installApps) -or $installTestFramework -or $installTestLibraries -or $installPerformanceToolkit) {
Write-Host -ForegroundColor Yellow @'

  _____           _        _ _ _                                     
 |_   _|         | |      | | (_)                                    
   | |  _ __  ___| |_ __ _| | |_ _ __   __ _    __ _ _ __  _ __  ___ 
   | | | '_ \/ __| __/ _` | | | | '_ \ / _` |  / _` | '_ \| '_ \/ __|
  _| |_| | | \__ \ |_ (_| | | | | | | | (_| | | (_| | |_) | |_) \__ \
 |_____|_| |_|___/\__\__,_|_|_|_|_| |_|\__, |  \__,_| .__/| .__/|___/
                                        __/ |       | |   | |        
                                       |___/        |_|   |_|        

'@
Measure-Command {

    if ($installTestLibraries) {
        Import-TestToolkitToBcContainer -containerName $containerName -credential $credential -includeTestLibrariesOnly -includePerformanceToolkit:$installPerformanceToolkit -doNotUseRuntimePackages
    }
    elseif ($installTestFramework -or $installPerformanceToolkit) {
        Import-TestToolkitToBcContainer -containerName $containerName -credential $credential -includeTestFrameworkOnly -includePerformanceToolkit:$installPerformanceToolkit -doNotUseRuntimePackages
    }

    $installApps | ForEach-Object{
        Publish-BcContainerApp -containerName $containerName -credential $credential -appFile $_ -skipVerification -sync -install
    }

} | ForEach-Object { Write-Host -ForegroundColor Yellow "`nInstalling apps took $([int]$_.TotalSeconds) seconds" }
}

Write-Host -ForegroundColor Yellow @'

   _____                      _ _ _                                     
  / ____|                    (_) (_)                                    
 | |     ___  _ __ ___  _ __  _| |_ _ __   __ _    __ _ _ __  _ __  ___ 
 | |    / _ \| '_ ` _ \| '_ \| | | | '_ \ / _` |  / _` | '_ \| '_ \/ __|
 | |____ (_) | | | | | | |_) | | | | | | | (_| | | (_| | |_) | |_) \__ \
  \_____\___/|_| |_| |_| .__/|_|_|_|_| |_|\__, |  \__,_| .__/| .__/|___/
                       | |                 __/ |       | |   | |        
                       |_|                |___/        |_|   |_|        

'@
Measure-Command {
$appsFolder = @{}
$apps = @()
$testApps = @()
$sortedFolders | ForEach-Object {
    $folder = $_
    $testApp = $testFolders.Contains($folder)
    $compileParams = @{ }
    if (-not $testApp) {
        $compileParams += @{ 
            "EnableCodeCop" = $enableCodeCop
            "EnableAppSourceCop" = $enableAppSourceCop
            "EnableUICop" = $enableUICop
            "EnablePerTenantExtensionCop" = $enablePerTenantExtensionCop
        }
    }

    if ($appBuild) {
        $appJsonFile = Join-Path $folder "app.json"
        $appJson = Get-Content $appJsonFile | ConvertFrom-Json
        $appJsonVersion = [System.Version]$appJson.Version
        $version = [System.Version]::new($appJsonVersion.Major, $appJsonVersion.Minor, $appBuild, $appRevision)
        Write-Host "Using Version $version"
        $appJson.version = "$version"
        $appJson | ConvertTo-Json -Depth 99 | Set-Content $appJsonFile
    }

    if ($useDevEndpoint) {
        $appPackagesFolder = Join-Path $folder ".alPackages"
        $appOutputFolder = $folder
    }
    else {
        $appOutputFolder = $outputFolder
        $appPackagesFolder = $packagesFolder
        $compileParams += @{ "CopyAppToSymbolsFolder" = $true }
    }

    $appFile = Compile-AppInBcContainer @compileParams `
        -containerName $containerName `
        -credential $credential `
        -appProjectFolder $folder `
        -appOutputFolder $appOutputFolder `
        -appSymbolsFolder $appPackagesFolder `
        -AzureDevOps:$azureDevOps

    if ($useDevEndpoint) {
        Publish-BcContainerApp `
            -containerName $containerName `
            -credential $credential `
            -appFile $appFile `
            -skipVerification `
            -sync `
            -install `
            -useDevEndpoint

        if ($updateLaunchJson) {
            $launchJsonFile = Join-Path $folder ".vscode\launch.json"
            UpdateLaunchJson -launchJsonFile $launchJsonFile -configuration $updateLaunchJson -Name $pipelineName -Server $containerName
        }
    }

    if ($testApp) {
        $testApps += $appFile
    }
    else {
        $apps += $appFile
        $appsFolder += @{ "$appFile" = $folder }
    }
}
} | ForEach-Object { Write-Host -ForegroundColor Yellow "`nCompiling apps took $([int]$_.TotalSeconds) seconds" }

if ($signApps -and !$useDevEndpoint) {
Write-Host -ForegroundColor Yellow @'

   _____ _             _                                        
  / ____(_)           (_)                 /\                    
 | (___  _  __ _ _ __  _ _ __   __ _     /  \   _ __  _ __  ___ 
  \___ \| |/ _` | '_ \| | '_ \ / _` |   / /\ \ | '_ \| '_ \/ __|
  ____) | | (_| | | | | | | | | (_| |  / ____ \| |_) | |_) \__ \
 |_____/|_|\__, |_| |_|_|_| |_|\__, | /_/    \_\ .__/| .__/|___/
            __/ |               __/ |          | |   | |        
           |___/               |___/           |_|   |_|        

'@
Measure-Command {
$apps | ForEach-Object {
    $appFile = $_
    Sign-BcContainerApp `
        -containerName $containerName `
        -appFile $appFile `
        -pfxFile $codeSignPfxFile `
        -pfxPassword $codeSignPfxPassword
}
} | ForEach-Object { Write-Host -ForegroundColor Yellow "`nSigning apps took $([int]$_.TotalSeconds) seconds" }
}

if (!$useDevEndpoint) {
Write-Host -ForegroundColor Yellow @'

  _____       _     _ _     _     _                                        
 |  __ \     | |   | (_)   | |   (_)                 /\                    
 | |__) |   _| |__ | |_ ___| |__  _ _ __   __ _     /  \   _ __  _ __  ___ 
 |  ___/ | | | '_ \| | / __| '_ \| | '_ \ / _` |   / /\ \ | '_ \| '_ \/ __|
 | |   | |_| | |_) | | \__ \ | | | | | | | (_| |  / ____ \| |_) | |_) \__ \
 |_|    \__,_|_.__/|_|_|___/_| |_|_|_| |_|\__, | /_/    \_\ .__/| .__/|___/
                                           __/ |          | |   | |        
                                          |___/           |_|   |_|        

'@
Measure-Command {
$apps+$testApps | ForEach-Object {
    $appFile = $_
    Publish-BcContainerApp `
        -containerName $containerName `
        -credential $credential `
        -appFile $appFile `
        -skipVerification:($testApps.Contains($appFile) -or !$signApps) `
        -sync `
        -install
}
} | ForEach-Object { Write-Host -ForegroundColor Yellow "`nPublishing apps took $([int]$_.TotalSeconds) seconds" }
}

if (!$doNotRunTests) {
Remove-Item -Path $testResultsFile -Force -ErrorAction SilentlyContinue
if ($testFolders) {
Write-Host -ForegroundColor Yellow @'

  _____                   _               _______       _       
 |  __ \                 (_)             |__   __|     | |      
 | |__) |   _ _ __  _ __  _ _ __   __ _     | | ___ ___| |_ ___ 
 |  _  / | | | '_ \| '_ \| | '_ \ / _` |    | |/ _ \ __| __/ __|
 | | \ \ |_| | | | | | | | | | | | (_| |    | |  __\__ \ |_\__ \
 |_|  \_\__,_|_| |_|_| |_|_|_| |_|\__, |    |_|\___|___/\__|___/
                                   __/ |                        
                                  |___/                         

'@
Measure-Command {
$testFolders | ForEach-Object {
    $appJson = Get-Content -Path (Join-Path $_ "app.json") | ConvertFrom-Json
    Run-TestsInBcContainer `
        -containerName $containerName `
        -credential $credential `
        -extensionId $appJson.id `
        -AzureDevOps "$(if($azureDevOps){'error'}else{'no'})" `
        -XUnitResultFileName $testResultsFile `
        -AppendToXUnitResultFile
}
} | ForEach-Object { Write-Host -ForegroundColor Yellow "`nRunning tests took $([int]$_.TotalSeconds) seconds" }
}
}

if ($buildArtifactFolder) {
Write-Host -ForegroundColor Yellow @'
   _____                    _          ____        _ _     _                 _   _  __           _       
  / ____|                  | |        |  _ \      (_) |   | |     /\        | | (_)/ _|         | |      
 | |     ___  _ __  _   _  | |_ ___   | |_) |_   _ _| | __| |    /  \   _ __| |_ _| |_ __ _  ___| |_ ___ 
 | |    / _ \| '_ \| | | | | __/ _ \  |  _ <| | | | | |/ _` |   / /\ \ | '__| __| |  _/ _` |/ __| __/ __|
 | |____ (_) | |_) | |_| | | |_ (_) | | |_) | |_| | | | (_| |  / ____ \| |  | |_| | || (_| | (__| |_\__ \
  \_____\___/| .__/ \__, |  \__\___/  |____/ \__,_|_|_|\__,_| /_/    \_\_|   \__|_|_| \__,_|\___|\__|___/
             | |     __/ |                                                                               
             |_|    |___/                                                                                
'@

Measure-Command {

$destFolder = Join-Path $buildArtifactFolder "Apps"
if (!(Test-Path $destFolder -PathType Container)) {
    New-Item $destFolder -ItemType Directory | Out-Null
}
$no = 1
$apps | ForEach-Object {
    $appFile = $_
    $name = [System.IO.Path]::GetFileName($appFile)
    Write-Host "Copying $name to build artifact"
    if ($apps.Count -gt 1) {
        $name = "$($no.ToString('00')) - $name"
        $no++
    }
    Copy-Item -Path $appFile -Destination (Join-Path $destFolder $name) -Force
}
$destFolder = Join-Path $buildArtifactFolder "TestApps"
if (!(Test-Path $destFolder -PathType Container)) {
    New-Item $destFolder -ItemType Directory | Out-Null
}
$no = 1
$testApps | ForEach-Object {
    $appFile = $_
    $name = [System.IO.Path]::GetFileName($appFile)
    Write-Host "Copying $name to build artifact"
    if ($testApps.Count -gt 1) {
        $name = "$($no.ToString('00')) - $name"
        $no++
    }
    Copy-Item -Path $appFile -Destination (Join-Path $destFolder $name) -Force
}
if ($createRuntimePackages) {
    $destFolder = Join-Path $buildArtifactFolder "RuntimePackages"
    if (!(Test-Path $destFolder -PathType Container)) {
        New-Item $destFolder -ItemType Directory | Out-Null
    }
    $no = 1
    $apps | ForEach-Object {
        $appFile = $_
        $tempRuntimeAppFile = "$($appFile.TrimEnd('.app')).runtime.app"
        $name = [System.IO.Path]::GetFileName($appFile)
        if ($apps.Count -gt 1) {
            $runtimeAppFile = Join-Path $destFolder "$($no.ToString('00')) - $name"
        }
        else {
            $runtimeAppFile = Join-Path $destFolder $name
        }
        $folder = $appsFolder[$appFile]
        $appJson = Get-Content -Path (Join-Path $folder "app.json") | ConvertFrom-Json
        Write-Host "Getting Runtime Package for $([System.IO.Path]::GetFileName($appFile))"
        Get-NavContainerAppRuntimePackage `
            -containerName $containerName `
            -appName $appJson.name `
            -appVersion $appJson.Version `
            -publisher $appJson.Publisher `
            -appFile $tempRuntimeAppFile

        if ($signApps) {
            Write-Host "Signing runtime package"
            Sign-BcContainerApp `
                -containerName $containerName `
                -appFile $tempRuntimeAppFile `
                -pfxFile $codeSignPfxFile `
                -pfxPassword $codeSignPfxPassword
        }

        Write-Host "Copying runtime package to build artifact"
        Copy-Item -Path $tempRuntimeAppFile -Destination $runtimeAppFile -Force
    }
}

} | ForEach-Object { Write-Host -ForegroundColor Yellow "`nCopying to Build Artifacts took $([int]$_.TotalSeconds) seconds" }

}

} catch {
    $error = $_
}
finally {
    $progressPreference = $prevProgressPreference
}

if (!$keepContainer) {
Write-Host -ForegroundColor Yellow @'

  _____                           _                _____            _        _                 
 |  __ \                         (_)              / ____|          | |      (_)                
 | |__) |___ _ __ ___   _____   ___ _ __   __ _  | |     ___  _ __ | |_ __ _ _ _ __   ___ _ __ 
 |  _  // _ \ '_ ` _ \ / _ \ \ / / | '_ \ / _` | | |    / _ \| '_ \| __/ _` | | '_ \ / _ \ '__|
 | | \ \  __/ | | | | | (_) \ V /| | | | | (_| | | |____ (_) | | | | |_ (_| | | | | |  __/ |   
 |_|  \_\___|_| |_| |_|\___/ \_/ |_|_| |_|\__, |  \_____\___/|_| |_|\__\__,_|_|_| |_|\___|_|   
                                           __/ |                                               
                                          |___/                                                

'@
Measure-Command {
Remove-BcContainer `
    -containerName $containerName
} | ForEach-Object { Write-Host -ForegroundColor Yellow "`nRemoving container took $([int]$_.TotalSeconds) seconds" }

}

if ($error) {
    throw $error
}

} | ForEach-Object { Write-Host -ForegroundColor Yellow "`nAL Pipeline finished in $([int]$_.TotalSeconds) seconds" }

}
Export-ModuleMember -Function Run-AlPipeline

