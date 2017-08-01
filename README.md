
# Azure Resource Manager Script Samples

## Synopsis of Sample Scripts

* **Archive-AzureRMvm.ps1** - Archives or Rehydrates Azure V2 (ARM) Virtual Machines from specified resource group to save VM core allotment

* **Copy-AzureRMresourceGroup.ps1** - Copies resources from one resource group to another a different Azure Subscription AND Tenant

* **Clone-AzureRMresourceGroup.ps1** -Copies resources from one resource group to the same or different location/region in the same Azure Subscription

* **Backup-AzureRMvm.ps1** - Backs up VHDs blobs of each VM in a resource group to a defined container. Does not support VMs with managed disks because they provide snapshots.

* **Restore-AzureRMvm.ps1** - Restores a VM from a backed up VHD created by the above script. Not recommended in production environments.  Does not support VMs with managed disks because they provide snapshots.

* **Start-AzureV2vm.ps1** -  PowerShell workflow that starts all VMs in a resource group at once. Uses -ServicePrincipal flag of Login-AzureRMAccount 

* **Stop-AzureV2vm.ps1**  - PowerShell workflow that stops all VMs in a resource group at once. Uses -ServicePrincipal flag of Login-AzureRMAccount

* **Stop-AzureV2vmRunbook.ps1**  - Azure Automation Runbook that stops all VMs in a resource group. Requires Automation Connection e.g. AzureRunAsConnection

* **New-AzureServicePrincpal.ps1** - Creates Azure AD Service Principal, associated Application ID and certificate required to use -ServicePrincipal flag of Login-AzureRMAccount
 
 
 
## Contribution guide

New to Git?
-----------

* Make sure you have a [GitHub account](https://github.com/signup/free).
* Learning Git:
    * GitHub Help: [Good Resources for Learning Git and GitHub][good-git-resources].
    * [Git Basics](../docs/git/basics.md):
      install and getting started.
* [GitHub Flow Guide](https://guides.github.com/introduction/flow/):
  step-by-step instructions of GitHub flow.
* Review the [Contribution License Agreement](https://github.com/PowerShell/PowerShell/blob/master/.github/CONTRIBUTING.md#contributor-license-agreement-cla) requirement.



Contributing to Issues
----------------------

* Check if the issue you are going to file already exists in our [issues](https://github.com/JeffBow/AzurePowerShell/issues).
* If you can't find your issue already,
  [open a new issue](https://github.com/JeffBow/AzurePowerShell/issues/new),
  making sure to follow the directions as best you can.
* If the issue is marked as [`0 - Backlog`][help-wanted-issue],
  the community code maintainers are looking for help with the issue.

### Forks and Pull Requests

GitHub fosters collaboration through the notion of pull requests.
On GitHub, anyone can fork an existing repository
into their own user account, where they can make private changes to their fork.
To contribute these changes back into the original repository,
a user simply creates a pull request in order to "request" that the changes be taken "upstream".

Additional references:
* GitHub's guide on [forking](https://guides.github.com/activities/forking/)
* GitHub's guide on [Contributing to Open Source](https://guides.github.com/activities/contributing-to-open-source/#pull-request)
* GitHub's guide on [Understanding the GitHub Flow](https://guides.github.com/introduction/flow/)


### Lifecycle of a pull request

#### Before submitting

* To avoid merge conflicts, make sure your branch is rebased on the `master` branch of this repository.
* Clean up your commit history.
  Each commit should be a **single complete** change.
  This discipline is important when reviewing the changes as well as when using `git bisect` and `git revert`.


#### Pull request submission

**Always create a pull request to the `master` branch of this repository**.

* Run tests and ensure they are passing before pull request.

* Avoid making big pull requests.
  Before you invest a large amount of time,
  file an issue and start a discussion with the community.
    



