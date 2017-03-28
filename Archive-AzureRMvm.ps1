<#
.SYNOPSIS
    Archives or Rehydrates Azure V2 (ARM) Virtual Machines from specified resource group to save VM core allotment  

    
.DESCRIPTION
   Removes VMs from a subscription leaving the VHDs, NICs and other assets along with a JSON configuration file that can 
   be used later to recreate the environment using the -Rehydrate switch

.EXAMPLE
   .\Archive-AzureRMvm.ps1 -ResourceGroupName 'CONTOSO'

Archives all VMs in the CONTOSO resource group

.EXAMPLE
   .\Archive-AzureRMvm.ps1 -ResourceGroupName 'CONTOSO' -Rehydrate 

Rehydrates the VMs using the saved configuration and remaining resource group components (VNet, NIC, NSG, AvSet etc...


.PARAMETER -ResourceGroupName [string]
  Name of resource group being copied

.PARAMETER -Rehydrate[switch]
  Rebuilds VMs from configuration file

.PARAMETER -OptionalEnvironment [string]
  Name of the Environment. e.g. AzureUSGovernment, AzureGermanCloud or AzureChinaCloud. Defaults to AzureCloud.


.NOTES

  The script attempts to restore VM extensions but some extensions may need to be reinstalled manually. 

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
#Requires -Module AzureRM.Profile
#Requires -Module AzureRM.Resources
#Requires -Module AzureRM.Storage
#Requires -Module AzureRM.Compute
#Requires -Module AzureRM.Network

param(

    [Parameter(mandatory=$True,
      HelpMessage="Enter the name of the Azure Resource Group you want to target and Press <Enter> e.g. CONTOSO")]
    [string]$ResourceGroupName,

    [Parameter(mandatory=$False,
      HelpMessage="Use this switch to rebuild the script after waiting for the blob copy to complete")]
    [switch]$Rehydrate,

    [Parameter(mandatory=$True,
      HelpMessage="Press <Enter> to default to AzureCloud or enter the Azure Environment name of the subscription. e.g. AzureUSGovernment")]
    [AllowEmptyString()]
    [string]$OptionalEnvironment

)  

$ProgressPreference = 'SilentlyContinue'

if ((Get-Module AzureRM.profile).Version -lt "2.1.0") 
{
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
 New-VM function
 param $vmobj takes Microsoft.Azure.Commands.Compute.Models.PSVirtualMachineList object 
 or custom PS object that was hydrated from a JSON export of the VM configuration
################################>
function New-VM
{ param($vmObj) 

    $created = $false

    # get source VM attributes
    $VMName = $vmObj.Name
    $location = $vmObj.location
    $VMSize = $vmObj.HardwareProfile.VMSize
    $OSDiskName = $vmObj.StorageProfile.OsDisk.Name
    $OSType = $vmObj.storageprofile.osdisk.OsType
    $OSDiskCaching = $vmObj.StorageProfile.OsDisk.Caching
    $CreateOption = "Attach"


    if($vmObj.AvailabilitySetReference)
    {
        $avSetRef = ($vmObj.AvailabilitySetReference.id).Split('/')
        $avSetName = $avSetRef[($avSetRef.count -1)]
        $AvailabilitySet = Get-AzureRmAvailabilitySet -ResourceGroupName $ResourceGroupName -Name $avSetName
    }

    # get storage account context from $vmObj.storageprofile.osdisk.vhd.uri
    $OSDiskUri = $null
    $OSDiskUri = $vmObj.storageprofile.osdisk.vhd.uri
    $OSsplit = $OSDiskUri.Split('/')
    $OSblobName = $OSsplit[($OSsplit.count -1)]
    $OScontainerName = $OSsplit[3]
    $OSstorageContext = Get-StorageObject -resourceGroupName $resourceGroupName -srcURI $OSDiskUri

    # get the Network Interface Card we created previously based on the original source name
    $NICRef = ($vmObj.NetworkInterfaceIDs).Split('/')
    $NICName = $NICRef[($NICRef.count -1)]
    $NIC = Get-AzureRmNetworkInterface -Name $NICName -ResourceGroupName $ResourceGroupName 

    #create VM config
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

    # readd data disk if they were present
    if($vmObj.storageProfile.datadisks)
    {
        foreach($disk in $vmObj.storageProfile.DataDisks) 
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
                
            Add-AzureRmVMDataDisk -VM $VirtualMachine -Name $dataDiskName -DiskSizeInGB $DiskSizeGB -Lun $dataDiskLUN -VhdUri $dataDiskUri -Caching $diskCaching -CreateOption $CreateOption | out-null
        }
    }
    
    # create the VM from the config
    try
    {
        
        write-verbose "Rehydrating Virtual Machine $VMName in resource group $resourceGroupName at location $location" -verbose
        New-AzureRmVM -ResourceGroupName $ResourceGroupName -Location $location -VM $VirtualMachine -ea Stop -wa SilentlyContinue | out-null
        $created = $true
        write-host "Successfully rehydrated Virtual Machine $VMName" 
    }
    catch
    {
        $_
        write-warning "Failed to create Virtual Machine $VMName"
        $created = $false
    }
    
    if($created)
    {
        try 
        {
            $newVM = Get-AzureRmVM -ResourceGroupName $resourceGroupName -Name $VMName

            if($vmObj.DiagnosticsProfile.BootDiagnostics.Enabled -eq 'True')
            {   
                write-verbose "Adding Boot Diagnostics to virtual machine $VMName" -Verbose
                $storageURI = $vmObj.DiagnosticsProfile.BootDiagnostics.StorageUri
                $StgSplit = $storageUri.Split('/')
                $DiagStorageAccountName = $StgSplit[2].Split('.')[0]
                $newVM | Set-AzureRmVMBootDiagnostics -Enable -ResourceGroupName $ResourceGroupName -StorageAccountName $DiagStorageAccountName | Out-Null
            }
            else
            { 
                write-verbose "Disabling Boot Diagnostics on virtual machine $VMName" -Verbose
                $newVM | Set-AzureRmVMBootDiagnostics -Disable | Out-Null
            }

            $newVM | Update-AzureRMVm -ResourceGroupName $resourceGroupName | Out-Null
        }
        catch{}

    }
    
    return $created


} # end of New-VM function



# Verify specified Environment
if($OptionalEnvironment -and (Get-AzureRMEnvironment -Name $OptionalEnvironment) -eq $null)
{
   write-warning "The specified -OptionalSourceEnvironment could not be found. Select one of these valid environments."
   $OptionalEnvironment = (Get-AzureRMEnvironment | Select-Object Name, ManagementPortalUrl | Out-GridView -title "Select a valid Azure environment for your source subscription" -OutputMode Single).Name
}

# get Azure creds for source
write-host "Enter credentials for the Azure Subscription..." -f Yellow
if($OptionalEnvironment)
{
   $login= Login-AzureRmAccount -EnvironmentName $OptionalEnvironment
}
else
{
   $login= Login-AzureRmAccount
}

$loginID = $login.context.account.id
$sub = Get-AzureRmSubscription
$SubscriptionId = $sub.SubscriptionId

# check for multiple subs under same account and force user to pick one
if($sub.count -gt 1) 
{
    $SubscriptionId = (Get-AzureRmSubscription | Select-Object * | Out-GridView -title "Select Target Subscription" -OutputMode Single).SubscriptionId
    Select-AzureRmSubscription -SubscriptionId $SubscriptionId | Out-Null
    $sub = Get-AzureRmSubscription -SubscriptionId $SubscriptionId
}

   

# check for valid sub
if(! $SubscriptionId) 
{
   write-warning "The provided credentials failed to authenticate or are not associcated to a valid subscription. Exiting the script."
   break
}

write-host "Logged into $($sub.SubscriptionName) with subscriptionID $SubscriptionId as $loginID" -f Green

# check for valid source resource group
if(-not ($sourceResourceGroup = Get-AzureRmResourceGroup  -ResourceGroupName $resourceGroupName)) 
{
   write-warning "The provided resource group $resourceGroupName could not be found. Exiting the script."
   break
}
# check for valid source resource group
if(-not ($sourceResourceGroup = Get-AzureRmResourceGroup  -ResourceGroupName $resourceGroupName)) 
{
   write-warning "The provided resource group $resourceGroupName could not be found. Exiting the script."
   break
}

if($Rehydrate)
{
   # search all storage accounts and containers for rehydrate files
    foreach($StorageAccount in (Get-AzureRmStorageAccount -ResourceGroupName $resourceGroupName))
    { 
        $StorageAccountName = $StorageAccount.StorageAccountName
        write-verbose "Searching for rehydrate files in storage account $StorageAccountName)..." -verbose        
        $StorageAccountKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $StorageAccountName).Value[0]
        $StorageContext = New-AzureStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey

        foreach($StorageContainer in (Get-AzureStorageContainer -Context $StorageContext) )
        { 
            $StorageContainerName = $StorageContainer.Name
            write-verbose "Searching for rehydrate files in container $StorageContainerName)..." -verbose
            $rehydrateBlobs = Get-AzureStorageBlob -Container $StorageContainerName -Context $StorageContext | Where-Object{$_.name -like "*.rehydrate.json"}
            foreach($rehydrateBlob in $rehydrateBlobs)
            {
                write-verbose "Retreiving rehydrate file $($rehydrateBlob.name)..." -verbose
                try 
                {
                    $TempRehydratefile = Get-AzureStorageBlobContent -CloudBlob $RehydrateBlob.iCloudBlob -Context $StorageContext -Destination $env:temp -Force -ea Stop
                    $TempRehydratefileName = $TempRehydratefile.Name
                    $fileContent = get-content "$env:temp\$TempRehydratefileName" -ea Stop
                    $fileContent | Where-Object{$_ -ne ''} | out-file "$env:temp\$TempRehydratefileName"
                    $rehydrateVM = (get-content "$env:temp\$TempRehydratefileName" -ea Stop) -Join "`n"| ConvertFrom-Json -ea Stop
                }
                catch
                {
                    write-warning "Virtual machine object data could not be restored from rehydrate file $($rehydrateBlob.Name) "
                }
               

                if($rehydrateVM)
                {
                    $created = New-VM -vmObj $rehydrateVM

                    if($created)
                    {
      
                        try
                        {
                            write-verbose "Searching for Diagnostics config file in container $StorageContainerName..." -verbose
                            $rehydrateDiagBlob = Get-AzureStorageBlob -Container $StorageContainerName -Context $StorageContext -ea Stop | Where-Object{$_.name -like "*$($rehydrateVM.Name).rehydratediag.xml"}  
                            if($rehydrateDiagBlob)
                            {
                                write-verbose "Retreiving Diagnostics config file $($rehydrateDiagBlob.name)..." -verbose
                                $TempDiagRehydratefile = Get-AzureStorageBlobContent -CloudBlob $RehydrateDiagBlob.iCloudBlob -Context $StorageContext -Destination $env:temp -Force -ea Stop
                                $TempDiagRehydratefileName = $TempDiagRehydratefile.Name
                                $DiagfileContent = get-content "$env:temp\$TempDiagRehydratefileName" -ea Stop
                                $DiagfileContent | Where-Object{$_ -ne ''} | out-file "$env:temp\$TempDiagRehydratefileName"
                                $rehydrateVMDiag = (get-content "$env:temp\$TempDiagRehydratefileName" -ea Stop) -Join "`n"| ConvertFrom-Json
                                $wadCfg = $rehydrateVMDiag.wadCfg
                                $wadStorageAccount = $rehydrateVMDiag.StorageAccount
                                $wadStorageAccountKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $wadStorageAccount -ea Stop).Value[0]
                                write-verbose "Applying VM Diagnostic settings to virtual machine $($rehydrateVM.Name)..." -verbose
                                Set-AzureRmVMDiagnosticsExtension -ResourceGroupName $ResourceGroupName -VMName $($rehydrateVM.Name) -DiagnosticsConfigurationPath "$env:temp\$TempDiagRehydratefileName" -StorageAccountName $wadStorageAccount -StorageAccountKey $wadStorageAccountKey | out-null
                            }
                            else 
                            {
                                write-verbose "No Diagnostics config file found for $($rehydrateVM.Name)..." -verbose
                            }
                        }
                        catch{}
                    }
                }
 
           }
        }

    }
} # end of if rehydrate
else 
{
    
    # get configuration details for all VMs
    [string] $location = $sourceResourceGroup.location
    $resourceGroupVMs = Get-AzureRMVM -ResourceGroupName $resourceGroupName


    if(! $resourceGroupVMs){write-warning "No virtual machines found in resource group $resourceGroupName"; break}

    $resourceGroupVMs | %{
    $status = ((get-azurermvm -ResourceGroupName $resourceGroupName -Name $_.name -status).Statuses|where{$_.Code -like 'PowerState*'}).DisplayStatus
    write-output "$($_.name) status is $status" 
    if($status -eq 'VM running')
        {write-warning "All virtual machines in this resource group are not stopped.  Please stop all VMs and try again"; break}
    }

    
     
    # remove each VM - leaving VHD for archive and possible rehydration
    foreach($srcVM in $resourceGroupVMs)
    {
        # get source VM OS disk attributes to determine storage account and container to copy config file
        $vmName = $srcVM.Name
        $OSDiskUri = $null
        $OSDiskUri = $srcVM.storageprofile.osdisk.vhd.uri
        $OSsplit = $OSDiskUri.Split('/')
        $OScontainerName = $OSsplit[3]
        $StorageContext = Get-StorageObject -resourceGroupName $resourceGroupName -srcURI $OSDiskUri

        $diagSettings = (Get-AzureRmVMDiagnosticsExtension -ResourceGroupName $ResourceGroupName -VMName $vmName).PublicSettings
        if($diagSettings)
        {
            $RehydrateDiagFile = ("$ResourceGroupName.$vmName.rehydrateDiag.xml").ToLower()
            $tempDiagFilePath = "$env:TEMP\$RehydrateDiagFile"
            $diagSettings | Out-File -FilePath $tempDiagFilePath -Force
            # expand file size to 20KB for Page blob write if we experience Premium_LRS storage
            $file = [System.IO.File]::OpenWrite($tempDiagFilePath)
            $file.SetLength(40960)
            $file.Close()

            # copy to cloud container as Page blog  
            $copyDiagResult = Set-AzureStorageBlobContent -File $tempDiagFilePath -Blob $RehydrateDiagFile -Context $StorageContext -Container $OScontainerName -BlobType Page -Force 
        }

        #save off VM config to temp drive before copying it back to cloud storage
        $RehydrateFile = ("$ResourceGroupName.$vmName.rehydrate.json").ToLower()
        $tempFilePath = "$env:TEMP\$RehydrateFile"
        $srcVM | ConvertTo-Json -depth 10 | Out-File -FilePath $tempFilePath -Force

        # expand file size to 20KB for Page blob write if we experience Premium_LRS storage
        $file = [System.IO.File]::OpenWrite($tempFilePath)
        $file.SetLength(20480)
        $file.Close()
        
        # copy to cloud container as Page blog  
        $copyResult = Set-AzureStorageBlobContent -File $tempFilePath -Blob $RehydrateFile -Context $StorageContext -Container $OScontainerName -BlobType Page -Force 
        
        if($copyResult)
        {
            # remove VM
            write-verbose "Archiving Virtual Machine $vmName..." -verbose
            try
            { 
                Remove-AzureRmVM -Name $vmName -ResourceGroupName $resourceGroupName -Force -ea Stop | out-null
                write-output "Archived $vmName"
            }
            catch
            {
                $_
                Write-Warning "Failed to remove Virtual Machine $vmName" 
            }
        }

     }
}
