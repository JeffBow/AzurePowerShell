<#
.SYNOPSIS
  Azure Automation runbook that stops of all VMs in the specified Azure subscription or resource group

.DESCRIPTION
  This Azure runbook connects to Azure and stops all VMs in an Azure subscription or resource group.  
  You can attach a schedule to this runbook to run it at a specific time. Note that this runbook does not stop
  Azure classic VMs. Use https://gallery.technet.microsoft.com/scriptcenter/Stop-Azure-Classic-VMs-7a4ae43e for that.



.PARAMETER automationConnectionName
   Optional with default of "AzureRunAsConnection".
   The name of an Automation Connection used to authenticate

.PARAMETER ResourceGroupName
   Required
   Allows you to specify the resource group containing the VMs to stop.  
   If this parameter is included, only VMs in the specified resource group will be stopped, otherwise all VMs in the subscription will be stopped.  

.NOTES
   AUTHOR: Jeff Bowles
   LASTEDIT: Sept 6, 2016
#>

param (
    [Parameter(Mandatory=$false)]
    [string]$automationConnectionName = 'AzureRunAsConnection',

        
    [Parameter(Mandatory=$false)] 
    [String] $ResourceGroupName
)



# Connect to Azure and select the subscription to work against
try
{
    # Get the connection "AzureRunAsConnection "
    $servicePrincipalConnection = Get-AutomationConnection -Name $automationConnectionName          

    # Log into Azure
    $login = Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
}
catch 
{
    if (!$servicePrincipalConnection)
    {
        $ErrorMessage = "Connection $connectionName not found."
        throw $ErrorMessage
    } else{
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}

write-output "Logged in as $($login.Context.Account.id) to subscriptionID $($login.Context.Subscription.SubscriptionId)."



# $SubId = Get-AutomationVariable -Name $AzureSubscriptionIdAssetName -ErrorAction Stop 

# If there is a specific resource group, then get all VMs in the resource group,
# otherwise get all VMs in the subscription.
if ($ResourceGroupName) 
{ 
	$VMs = Get-AzureRmVM -ResourceGroupName $ResourceGroupName
}
else 
{ 
	$VMs = Get-AzureRmVM
}

# Stop each of the VMs
foreach ($VM in $VMs)
{
	$vmName = $vm.Name
    $ResourceGroupName = $vm.resourceGroupName
    $status = ((Get-AzureRmVm -ResourceGroupName $ResourceGroupName -Name $vmName -status).Statuses|where{$_.Code -like 'PowerState*'}).DisplayStatus

    if($status -ne 'VM deallocated')
    {
    	$stopRtn = Stop-AzureRMVM -Name $VMName -ResourceGroupName $resourceGroupName -force -ea SilentlyContinue

		if (-not($StopRtn.IsSuccessStatusCode))
		{
			# The VM failed to stop, so send notice
        	Write-Output ($VMName + " failed to stop")
        	Write-Error ($VMName + " failed to stop. Error was:") -ErrorAction Continue
			Write-Error (ConvertTo-Json $StopRtn.Error) -ErrorAction Continue
		}
		else
		{
			# The VM stopped, so send notice
			Write-Output ($VMName + " has been stopped")
		}
	}
	else
	{
		Write-Output ($VMName + " is already stopped")
	}
}