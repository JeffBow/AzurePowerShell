<#
.SYNOPSIS
    Copies VHD blobs attached to each VM in a resource group to a designated backup container.  
    Does not work with VMs configured with managed disks because they allow snapshots.
	
    Requires AzureRM module version 4.2.1 or later.
    
.DESCRIPTION
   Copies VHD blobs from each VM in a resource group to the vhd-backups container or other container name
   specified in the -BackupContainer parameter

   VMs must be shutdown prior to running this script. It will halt if they are still running.


.EXAMPLE
   .\Backup-AzureRMvm.ps1 -ResourceGroupName 'CONTOSO'

.EXAMPLE
   .\Backup-AzureRMvm.ps1 -ResourceGroupName 'CONTOSO' -BackupContainer 'vhd-backups-9021' 



.PARAMETER -ResourceGroupName [string]
  Name of resource group being copied

.PARAMETER -BackupContainer [string]
  Name of container that will hold the backup VHD blobs

.PARAMETER -Environment [string]
  Name of Environment e.g. AzureUSGovernment.  Defaults to AzureCloud


.NOTES

    Original Author:   https://github.com/JeffBow
    
 ------------------------------------------------------------------------
               Copyright (C) 2017 Microsoft Corporation

 You have a royalty-free right to use, modify, reproduce and distribute
 this sample script (and/or any modified version) in any way
 you find useful, provided that you agree that Microsoft has no warranty,
 obligations or liability for any sample application or script files.
 ------------------------------------------------------------------------
#>
#Requires -Version 4.0

param(

    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,


    [Parameter(Mandatory=$false)]
    [string]$BackupContainer= 'vhd-backups',

     
    [Parameter(Mandatory=$false)]
    [string]$Environment= "AzureCloud"
)
$ProgressPreference = 'SilentlyContinue'

import-module AzureRM 

if ((Get-Module AzureRM).Version -lt "4.2.1") {
   Write-warning "Old version of Azure PowerShell module  $((Get-Module AzureRM).Version.ToString()) detected.  Minimum of 4.2.1 required. Run Update-Module AzureRM"
   BREAK
}


<###############################
 Get Storage Context function
################################>
function Get-StorageObject 
{ param($resourceGroupName, $srcURI) 
    
    $split = $srcURI.Split('/')
    $strgDNS = $split[2]
    $splitDNS = $strgDNS.Split('.')
    $storageAccountName = $splitDNS[0]
    $StorageAccountKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $resourceGroupName -Name $StorageAccountName).Value[0]
    $StorageContext = New-AzureStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey
  
    
    return $StorageContext

} # end of Get-StorageObject function



<###############################
  Copy blob function
################################>
function copy-azureBlob 
{  param($srcUri, $srcContext, $destContext, $containerName)

    $split = $srcURI.Split('/')
    $blobName = $split[($split.count -1)]
    $blobSplit = $blobName.Split('.')
    $extension = $blobSplit[($blobSplit.count -1)]
    if($($extension.tolower()) -eq 'status' ){Write-Output "Status file blob $blobname skipped";return}

    if(! $containerName){$containerName = $split[3]}

    # add full path back to blobname 
    if($split.count -gt 5) 
      { 
        $i = 4
        do
        {
            $path = $path + "/" + $split[$i]
            $i++
        }
        while($i -lt $split.length -1)

        $blobName= $path + '/' + $blobName
        $blobName = $blobName.Trim()
        $blobName = $blobName.Substring(1, $blobName.Length-1)
      }
    
    
   # create container if doesn't exist    
    if (!(Get-AzureStorageContainer -Context $destContext -Name $containerName -ea SilentlyContinue)) 
    { 
         try
         {
            $newRtn = New-AzureStorageContainer -Context $destContext -Name $containerName -Permission Off -ea Stop 
            Write-Output "Container $($newRtn.name) was created." 
         }
         catch
         {
             $_ ; break
         }
    } 


   try 
   {
        $blobCopy = Start-AzureStorageBlobCopy `
            -srcUri $srcUri `
            -SrcContext $srcContext `
            -DestContainer $containerName `
            -DestBlob $blobName `
            -DestContext $destContext `
            -Force -ea Stop

         write-output "$srcUri is being copied to $containerName"
    
   }
   catch
   { 
      $_ ; write-warning "Failed to copy to $srcUri to $containerName"
   }
  

} # end of copy-azureBlob function



# get Azure creds 
write-host "Enter credentials for your Azure Subscription..." -F Yellow
$login= Login-AzureRmAccount -EnvironmentName $Environment
$loginID = $login.context.account.id
$sub = Get-AzureRmSubscription 
$SubscriptionId = $sub.Id

# check for multiple subs under same account and force user to pick one
if($sub.count -gt 1) 
{
    $SubscriptionId = (Get-AzureRmSubscription | select * | Out-GridView -title "Select Target Subscription" -OutputMode Single).Id
    Select-AzureRmSubscription -SubscriptionId $SubscriptionId| Out-Null
    $sub = Get-AzureRmSubscription -SubscriptionId $SubscriptionId
    $SubscriptionId = $sub.Id
}

   

# check for valid sub
if(! $SubscriptionId) 
{
   write-warning "The provided credentials failed to authenticate or are not associcated to a valid subscription. Exiting the script."
   break
}

write-verbose "Logged into $($sub.Name) with subscriptionID $SubscriptionId as $loginID" -verbose


$resourceGroupVMs = Get-AzureRMVM -ResourceGroupName $resourceGroupName

if(! $resourceGroupVMs){write-warning "No virtual machines found in resource group $resourceGroupName"; break}

$resourceGroupVMs | %{
   $status = ((get-azurermvm -ResourceGroupName $resourceGroupName -Name $_.name -status).Statuses|where{$_.Code -like 'PowerState*'}).DisplayStatus
   write-output "$($_.name) status is $status" 
   if($status -eq 'VM running'){write-warning "All virtual machines in this resource group are not stopped.  Please stop all VMs and try again"; break}
}


foreach($vm in $resourceGroupVMs) 
{
    # get storage account name from VM.URI
    $vmURI = $vm.storageprofile.osdisk.vhd.uri
    $context = Get-StorageObject -resourceGroupName $resourceGroupName -srcURI $vmURI
    copy-azureBlob -srcUri $vmURI -srcContext $context -destContext $context -containerName $backupContainer
    
    if($vm.storageProfile.datadisks)
    {
       foreach($disk in $vm.storageProfile.datadisks) 
       {
         $diskURI = $disk.vhd.uri
         $context = Get-StorageObject -resourceGroupName $resourceGroupName -srcURI $diskURI
         copy-azureBlob -srcUri $diskURI -srcContext $context -destContext $context -containerName $backupContainer
       }
    }
}






        
