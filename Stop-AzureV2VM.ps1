<#
.SYNOPSIS
    Stops all Azure V2 (ARM) virtual machines by resource group.  
    
    
.DESCRIPTION
   Uses PowerShell workflow to stop all VMs in parallel. Includes a retry and wait cycle to display when VMs are stopped. PowerShell
   Workflow sessions require Azure authentication into each session so this script uses a splatting of parameters required for Login-AzureRmAccount that
   can be passed to each session.  Recommend using the New-AzureServicePrincipal script to create the required service principal and associated ApplicationId
   and certificate thumbprint required to log into Azure with the -servicePrincipal flag


.EXAMPLE
   .\Stop-AzureV2vm.ps1 -ResourceGroupName 'CONTOSO' -CertificateThumbprint 'F3FB843E7D22594E16066F1A3A04CA29D5D6DA91' -ApplicationID 'd2d20159-4482-4987-9724-f367afb170e8' -TenantID '72f632bf-86f6-41af-77ab-2d7cd011db47' 

.EXAMPLE
   .\Stop-AzureV2vm.ps1 -ResourceGroupName 'CONTOSO'-CertificateThumbprint 'F3FB843E7D22594E16066F1A3A04CA29D5D6DA91' -ApplicationID 'd2d20159-4482-4987-9724-f367afb170e8' -TenantID '72f632bf-86f6-41af-77ab-2d7cd011db47'



.PARAMETER -ResourceGroupName [string]
  Name of resource group being copied

.PARAMETER -CertificateThumbprint [string]
  Thumbprint of the x509 certificate that is used for authentication

.PARAMETER -ApplicationId [string]
  Aplication ID of the registered Azure Active Directory Service Principal

.PARAMETER -TenantId [string]
  Tenant ID of the registered Azure Active Directory Service Principal


.NOTES

    Original Author:  https://github.com/JeffBow
    
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
    [string]$TenantId
     
)

$ProgressPreference = 'SilentlyContinue'

if ((Get-Module AzureRM.profile).Version -lt "2.1.0") 
{
   Write-warning "Old Version of Azure Modules  $((Get-Module AzureRM.profile).Version.ToString()) detected.  Minimum of 2.1.0 required. Run Update-AzureRM"
   BREAK
}

workflow Stop-Vms 
{ param($VMS, $ResourceGroupName, $loginParams)
     
	# Get all Azure VMs in the subscription that are not stopped and deallocated, and shut them down
    $login = Login-AzureRmAccount @loginParams

    foreach -parallel ($vm in $VMs)
      {       
          $null = Login-AzureRmAccount @loginParams
          
          $vmName = $vm.Name
          $status = ((get-azurermvm -ResourceGroupName $resourceGroupName -Name $vmName -status).Statuses|where{$_.Code -like 'PowerState*'}).DisplayStatus

          if($status -ne 'VM deallocated')
          {
            $stopRtn = Stop-AzureRMVM -Name $VMName -ResourceGroupName $resourceGroupName -force -ea SilentlyContinue

            $count=1
            if($stopRtn.Status -ne 'Succeeded')
              {
               do{
                  Write-Output "Failed to stop $VMname. Retrying in 60 seconds..."
                  sleep 60
                  $stopRtn = Stop-AzureRMVM -Name $VMname -ResourceGroupName $resourceGroupName -force -ea SilentlyContinue
                  $count++
                  }
                while($stopRtn.Status -ne 'Succeeded' -and $count -lt 5)
            
              }
              else
              { 
                Write-Output "  $vmName stopped" 
              }
              
            if($stopRtn.Status -ne 'Succeeded'){Write-Output "Shutdown for $VMName FAILED on attempt number $count of 5."}
          }
           
      }
}  # end of workflow



$loginParams = @{
"CertificateThumbprint" = $CertificateThumbprint
"ApplicationId" = $ApplicationId
"TenantId" = $TenantId
"ServicePrincipal" = $null
}


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

    break     
}



$vms = Get-AzureRmVM -ResourceGroupName $ResourceGroupName 

 #pre action confirmation
 write-output "Shutting down..."
foreach ($vm in $VMs)
{       
   $status = ((get-azurermvm -ResourceGroupName $resourceGroupName -Name $vm.Name -status).Statuses|where{$_.Code -like 'PowerState*'}).DisplayStatus
   "$($vm.Name) - $status"
}



# call workflow
 Stop-Vms -VMs $vms -ResourceGroupName $resourceGroupName -loginParams $loginParams


 #post action confirmation

 do
 {
    cls
    write-host "Waiting for VMs in $resourceGroupName to stop..."
    $allStatus = @()  
    foreach ($vm in $VMs) 
    {
        $status = ((get-azurermvm -ResourceGroupName $resourceGroupName -Name $vm.Name -status).Statuses|where{$_.Code -like 'PowerState*'}).DisplayStatus
        "$($vm.Name) - $status"
        $allStatus  += $status
    }
    sleep 3
 }
 while($allStatus -ne 'VM deallocated')

 cls
 write-host "All VMs in $resourceGroupName are stopped..."
 foreach ($vm in $VMs)
 {       
   $status = ((get-azurermvm -ResourceGroupName $resourceGroupName -Name $vm.Name -status).Statuses|where{$_.Code -like 'PowerState*'}).DisplayStatus
   "$($vm.Name) - $status"
 }



