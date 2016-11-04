<#
.SYNOPSIS
    Starts all Azure V2 (ARM) virtual machines by resource group.  
    
    
.DESCRIPTION
   Uses PowerShell workflow to start all VMs in parallel.  Includes a retry and wait cycle to display when VMs are started.
   Workflow sessions require Azure authentication into each session so this script uses a splatting of parameters required for Login-AzureRmAccount that
   can be passed to each session.  Recommend using the New-AzureServicePrincipal script to create the required service principal and associated ApplicationId
   and certificate thumbprint required to log into Azure with the -servicePrincipal flag


.EXAMPLE
   .\Start-AzureV2vm.ps1 -ResourceGroupName 'CONTOSO'  -CertificateThumbprint 'F3FB843E7D22594E16066F1A3A04CA29D5D6DA91' -ApplicationID 'd2d20159-4482-4987-9724-f367afb170e8' -TenantID '72f632bf-86f6-41af-77ab-2d7cd011db47' 

.EXAMPLE
   .\Start-AzureV2vm.ps1 -FirstServer 'DC-CONTOSO-01' -ResourceGroupName 'CONTOSO'  -CertificateThumbprint 'F3FB843E7D22594E16066F1A3A04CA29D5D6DA91' -ApplicationID 'd2d20159-4482-4987-9724-f367afb170e8' -TenantID '72f632bf-86f6-41af-77ab-2d7cd011db47'  



.PARAMETER -ResourceGroupName [string]
  Name of resource group being copied

.PARAMETER -CertificateThumbprint [string]
  Thumbprint of the x509 certificate that is used for authentication

.PARAMETER -ApplicationId [string]
  Aplication ID of the registered Azure Active Directory Service Principal

.PARAMETER -TenantId [string]
  Tenant ID of the registered Azure Active Directory Service Principal

.PARAMETER -Environment [string]
  Name of Environment e.g. AzureUSGovernment.  Defaults to AzureCloud

.PARAMETER -FirstServer [string]
  Identifies the the first server to start. i.e. a domain controller


.NOTES

    Original Author:   https://github.com/JeffBow
    
 ------------------------------------------------------------------------
               Copyright (C) 2016 Microsoft Corporation

 You have a royalty-free right to use, modify, reproduce and distribute
 this sample script (and/or any modified version) in any way
 you find useful, provided that you agree that Microsoft has no warranty,
 obligations or liability for any sample application or script files.
 ------------------------------------------------------------------------
#>
#Requires -Version 4.0
#Requires -Module AzureRM.Profile
#Requires -Module AzureRM.Resources
#Requires -Module AzureRM.Storage
#Requires -Module AzureRM.Compute


param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string]$CertificateThumbprint,
    
    [Parameter(Mandatory=$true)]
    [string]$ApplicationId,
    
    [Parameter(Mandatory=$true)]
    [string]$TenantId,

    [Parameter(Mandatory=$false)]
    [string]$Environment= "AzureCloud",

    [Parameter(Mandatory=$false)]
    [string]$FirstServer

)

$loginParams = @{
"CertificateThumbprint" = $CertificateThumbprint
"ApplicationId" = $ApplicationId
"TenantId" = $TenantId
"ServicePrincipal" = $null
"EnvironmentName" = $Environment
}


$ProgressPreference = 'SilentlyContinue'

if ((Get-Module AzureRM.profile).Version -lt "2.1.0") 
{
   Write-warning "Old Version of Azure Modules  $((Get-Module AzureRM.profile).Version.ToString()) detected.  Minimum of 2.1.0 required. Run Update-AzureRM"
   BREAK
}

function Start-Vm 
{
    param($vmName, $resourceGroupName)
       
       $status = ((get-azurermvm -ResourceGroupName $resourceGroupName -Name $vmName -status).Statuses|where{$_.Code -like 'PowerState*'}).DisplayStatus
       if($status -ne 'VM running')
       { 
        Write-Output "Starting $vmName..." 
        $startRtn = Start-AzureRMVM -Name $VMName -ResourceGroupName $ResourceGroupName  -ea SilentlyContinue
        $count=1

         if($startRtn.Status -ne 'Succeeded')
         {
           do{
              Write-Output "Failed to start $VMName. Retrying in 60 seconds..."
              sleep 60
              $startRtn = Start-AzureRMVM -Name $VMName -ResourceGroupName $ResourceGroupName -ea SilentlyContinue
              $count++
              }
            while($startRtn.Status -ne 'Succeeded' -and $count -lt 5)
         
           }
           else
           { 
               Write-Output "  $vmName started" 
           }
           
           if($startRtn.Status -ne 'Succeeded'){Write-Output "Startup of $VMName FAILED on attempt number $count of 5."}
        }
}  # end of function
    

Workflow Start-VMs 
{ param($VMs, $ResourceGroupName, $loginParams)

  foreach -parallel ($vm in $VMs)
    { 
      $login = Login-AzureRmAccount @loginParams      
      $vmName = $vm.Name
      Start-Vm -VmName $vmName -ResourceGroupName $resourceGroupName 
    }
} # end of worflow   



# Connect to Azure and with Service Principal
try
{
    # Log into Azure
    Login-AzureRmAccount @loginParams -ea Stop | out-null
}
catch 
{
    if (! $CertificateThumbprint)
    {
        $ErrorMessage = "Certificate $CertificateThumbprint not found."
        throw $ErrorMessage
    } 
    else
    {
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
   
    BREAK
}


$vms = Get-AzureRmVM -ResourceGroupName $ResourceGroupName 

 #pre action confirmation
 write-output "Starting..."
foreach ($vm in $VMs) 
{       
   $status = ((get-azurermvm -ResourceGroupName $resourceGroupName -Name $vm.Name -status).Statuses|where{$_.Code -like 'PowerState*'}).DisplayStatus
   "$($vm.Name) - $status"
}

# start your DC or other server first
if($firstServer)
{
    Start-Vm -vmName $firstServer -ResourceGroupName $resourceGroupName
    sleep 10
} 


# Get remaining VMs that are stopped and Start everything 
$remainingVMs = $vms | where-object -FilterScript{$_.name -ne $firstServer} 

Start-VMs -VMs $remainingVMs -ResourceGroupName $resourceGroupName -loginParams $loginParams

  
 #post action confirmation
 do{
    cls
    write-host "Waiting for VMs in $resourceGroupName to start..."
    $allStatus = @()  
    foreach ($vm in $VMs) 
    {
        $status = ((get-azurermvm -ResourceGroupName $resourceGroupName -Name $vm.Name -status).Statuses|where{$_.Code -like 'PowerState*'}).DisplayStatus
        "$($vm.Name) - $status"
        $allStatus  += $status
    }
    sleep 3
 }
 while($allStatus -ne 'VM Running')

cls
write-host "All VMs in $resourceGroupName are ready..."
foreach ($vm in $VMs)
{       
   $status = ((get-azurermvm -ResourceGroupName $resourceGroupName -Name $vm.Name -status).Statuses|where{$_.Code -like 'PowerState*'}).DisplayStatus
   "$($vm.Name) - $status"
}

