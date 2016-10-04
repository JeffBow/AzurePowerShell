<#
.SYNOPSIS
   Restores Azure v2 ARM virtual machines from a backup VHD location
    
.DESCRIPTION
   Copies VHD files from a backup location - from using the associated script Backup-AzureRMvm.ps1.  Since VHDs have a lease on them 
   from being attached to a VM, the VM must first be deleted.  The VHD is copied over the original location and then the VM
   is recreated using the same configuration.

   VMs must be shutdown prior to running this script. It will halt if they are still running.



.EXAMPLE
   .\Restore-AzureRMvm.ps1 -ResourceGroupName 'CONTOSO'

.EXAMPLE
   .\Restore-AzureRMvm.ps1 -ResourceGroupName 'CONTOSO' -BackupContainer 'vhd-backups-9021' -VhdContainer 'MyVMs'



.PARAMETER -ResourceGroupName [string]
  Name of resource group being copied

.PARAMETER -BackupContainer [string]
  Name of container that holds the backup VHD blobs

.PARAMETER -VhdContainer [string]
  Name of container that will hold VHD blobs attached to VMs


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

    [Parameter(Mandatory=$false)]
    [string]$BackupContainer= 'vhd-backups',

    [Parameter(Mandatory=$false)]
    [string]$VhdContainer= 'vhds'

)
$ProgressPreference = 'SilentlyContinue'
$resourceGroupVMjsonPath = "$env:TEMP\$ResourceGroupName.resourceGroupVMs.json"

if ((Get-Module AzureRM.profile).Version -lt "2.1.0") {
   Write-warning "Old Version of Azure Modules  $((Get-Module AzureRM.profile).Version.ToString()) detected.  Minimum of 2.1.0 required. Run Update-AzureRM"
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
    $StorageAccountKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $StorageAccountName).Value[0]
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
$login= Login-AzureRmAccount 
$loginID = $login.context.account.id
$sub = Get-AzureRmSubscription -TenantID $login.context.Subscription.TenantID
$SubscriptionId = $sub.SubscriptionId

# check for multiple subs under same account and force user to pick one
if($sub.count -gt 1) {
    $SubscriptionId = (Get-AzureRmSubscription | select * | Out-GridView -title "Select Target Subscription" -OutputMode Single).SubscriptionId
    Select-AzureRmSubscription -SubscriptionId $SubscriptionId| Out-Null
    $sub = Get-AzureRmSubscription -SubscriptionId $SubscriptionId
    $SubscriptionId = $sub.SubscriptionId
}

   

# check for valid sub
if(! $SubscriptionId) 
{
   write-warning "The provided credentials failed to authenticate or are not associcated to a valid subscription. Exiting the script."
   break
}

write-verbose "Logged into $($sub.SubscriptionName) with subscriptionID $SubscriptionId as $loginID" -verbose

# check for valid source resource group
if(-not ($sourceResourceGroup = Get-AzureRmResourceGroup  -ResourceGroupName $resourceGroupName)) 
{
   write-warning "The provided resource group $resourceGroupName could not be found. Exiting the script."
   break
}


# get configuration details for all VMs
[string] $location = $sourceResourceGroup.location
$resourceGroupVMs = Get-AzureRMVM -ResourceGroupName $resourceGroupName


if(! $resourceGroupVMs){write-warning "No virtual machines found in resource group $resourceGroupName"; break}

$resourceGroupVMs | %{
   $status = ((get-azurermvm -ResourceGroupName $resourceGroupName -Name $_.name -status).Statuses|where{$_.Code -like 'PowerState*'}).DisplayStatus
   write-output "$($_.name) status is $status" 
   if($status -eq 'VM running'){write-warning "All virtual machines in this resource group are not stopped.  Please stop all VMs and try again"; break}
}

#save off VM config to temp drive for drive
$resourceGroupVMs | ConvertTo-Json -depth 10 | Out-File $resourceGroupVMjsonPath

# remove each VM, copy in new copy of disk and recreate the VM
foreach($srcVM in $resourceGroupVMs)
{

    # get source VM attributes
    $VMName = $srcVM.Name
    $VMSize = $srcVM.HardwareProfile.VMSize
    $OSDiskName = $srcVM.StorageProfile.OsDisk.Name
    $OSType = $srcVM.storageprofile.osdisk.OsType
    $OSDiskCaching = $srcVM.StorageProfile.OsDisk.Caching
    $avSetRef = ($srcVM.AvailabilitySetReference.id).Split('/')
    $avSetName = $avSetRef[($avSetRef.count -1)]
    $AvailabilitySet = Get-AzureRmAvailabilitySet -ResourceGroupName $ResourceGroupName -Name $avSetName
    $CreateOption = "Attach"

    # remove VM
    write-verbose "Restoring Virtual Machine $vmName" -verbose

    try
    { 
      Remove-AzureRmVM -Name $vmName -ResourceGroupName $resourceGroupName -Force -ea Stop | out-null
      write-output "Removed $vmName"
    }
    catch
    {
      $_
      Write-Warning "Failed to remove Virtual Machine $vmName" 
      break
    }


    # over-write existing disk from backup location

    # get storage account context from $srcVM.storageprofile.osdisk.vhd.uri
    $OSDiskUri = $null
    $OSDiskUri = $srcVM.storageprofile.osdisk.vhd.uri
    $OSsplit = $OSDiskUri.Split('/')
    $OSblobName = $OSsplit[($OSsplit.count -1)]
    $OScontainerName = $OSsplit[3]
    $OSstorageContext = Get-StorageObject -resourceGroupName $resourceGroupName -srcURI $OSDiskUri
    $backupURI = $OSDiskUri.Replace($vhdContainer, $backupContainer)
    
    copy-azureBlob -srcUri $backupURI -srcContext $OSstorageContext -destContext $OSstorageContext -containerName $vhdContainer
    
    # check on copy status
    do{
       $rtn = $null
       $rtn = Get-AzureStorageBlob -Context $OSstorageContext -container $OScontainerName -Blob $OSblobName | Get-AzureStorageBlobCopyState
       $rtn | select Source, Status, BytesCopied, TotalBytes | fl
       if($rtn.status  -ne 'Success'){
         write-verbose "Waiting for blob copy $OSblobName to complete" -verbose
         Sleep 10
       }  
    }
    while($rtn.status  -ne 'Success')

    # exit script if user breaks out of above loop   
    if($rtn.status  -ne 'Success'){EXIT} 



    # get the Network Interface Card we created previously based on the original source name
    $NICRef = ($srcVM.NetworkInterfaceIDs).Split('/')
    $NICName = $NICRef[($NICRef.count -1)]
    $NIC = Get-AzureRmNetworkInterface -Name $NICName -ResourceGroupName $ResourceGroupName 

    
    

    # create VM Config
    if($AvailabilitySet)
    {
        $VirtualMachine = New-AzureRmVMConfig -VMName $VMName -VMSize $VMSize  -AvailabilitySetID $AvailabilitySet.Id  -wa SilentlyContinue
    }
    else
    {
        $VirtualMachine = New-AzureRmVMConfig -VMName $VMName -VMSize $VMSize -wa SilentlyContinue
    }
    
    # Set OS Disk based on OS type
    if($OStype -eq 'Windows' -or $OStype -eq '0'){
       $VirtualMachine = Set-AzureRmVMOSDisk -VM $VirtualMachine -Name $OSDiskName -VhdUri $OSDiskUri -Caching $OSDiskCaching -CreateOption $createOption -Windows
    }
    else
    {
       $VirtualMachine = Set-AzureRmVMOSDisk -VM $VirtualMachine -Name $OSDiskName -VhdUri $OSDiskUri -Caching $OSDiskCaching -CreateOption $createOption -Linux
    }

    # add NIC
    $VirtualMachine = Add-AzureRmVMNetworkInterface -VM $VirtualMachine -Id $NIC.Id

    # copy and readd data disk if they were present
    if($srcVM.storageProfile.datadisks)
    {
        foreach($disk in $srcVM.storageProfile.DataDisks) 
        {
            $dataDiskName = $null
            $dataDiskUri = $null
            $diskBlobName = $null
            $dataDiskName = $disk.Name
            $dataDiskLUN = $disk.Lun
            $diskCaching = $disk.Caching
            $DiskSizeGB = $disk.DiskSizeGB
            $dataDiskUri = $disk.vhd.uri
            $split = $dataDiskUri.Split('/')
            $diskBlobName = $split[($split.count -1)]
            $diskContainerName = $split[3]
            
            $diskStorageContext = Get-StorageObject -resourceGroupName $resourceGroupName -srcURI $dataDiskUri
            $backupDiskURI = $dataDiskUri.Replace($vhdContainer, $backupContainer)
         
            copy-azureBlob -srcUri $backupDiskURI -srcContext $diskStorageContext -destContext $diskStorageContext -containerName $vhdContainer
       
            # check copy status
            do
            { 
              $drtn = $null
              $drtn = Get-AzureStorageBlob -Context $diskStorageContext -container $diskContainerName -Blob $diskBlobName | Get-AzureStorageBlobCopyState
              $drtn| select Source, Status, BytesCopied, TotalBytes|fl
              if($rtn.status  -ne 'Success')
              {
               write-verbose "Waiting for blob copy $diskBlobName to complete" -verbose
               Sleep 10
              }
            }
            while($drtn.status  -ne 'Success')
            
            # exit script if user breaks out of above loop   
            if($rtn.status  -ne 'Success'){EXIT}
                
            Add-AzureRmVMDataDisk -VM $VirtualMachine -Name $dataDiskName -DiskSizeInGB $DiskSizeGB -Lun $dataDiskLUN -VhdUri $dataDiskUri -Caching $diskCaching -CreateOption $CreateOption | out-null
        }
    }
     
    # create the VM from the config
    try
    {
        
        write-verbose "Recreating Virtual Machine $VMName in resource group $resourceGroupName at location $location" -verbose
       # $VirtualMachine
        New-AzureRmVM -ResourceGroupName $ResourceGroupName -Location $location -VM $VirtualMachine -ea Stop -wa SilentlyContinue | out-null
        write-output "Successfully recreated Virtual Machine $VMName"
    }
    catch
    {
         $_
         write-warning "Failed to create Virtual Machine $VMName"
    }
}





        
