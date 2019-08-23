# Physical ESXi host or vCenter Server to deploy vSphere 6.5 lab

$VIServer = "vcsa.sddc.info"
$VIusername = "administrator@vsphere.local"
$VIpassword = "VMware1!" 
$viConnection = Connect-VIServer $VIServer -User $VIUsername -Password $VIPassword -WarningAction SilentlyContinue

# Full Path to both the Nested ESXi 6.7 VA + extracted VCSA 6.7 ISO
$NestedESXiApplianceOVA = "Z:\Nested_ESXi6.7u2_Appliance_Template_v1.ova"

#VLAN12	10.1.2.0/24	Nested-01

$NestedESXiHostnameToIPs = @{
"vesx-t1-1" = "10.1.2.11"
"vesx-t1-2" = "10.1.2.12"
"vesx-t1-3" = "10.1.2.13"
"vesx-t1-4" = "10.1.2.14"
"vesx-t1-5" = "10.1.2.15"
"vesx-t1-6" = "10.1.2.16"
"vesx-t1-7" = "10.1.2.17"
"vesx-t1-8" = "10.1.2.18"
}
$VMGateway = "10.1.2.1"
$VMMGMTVlan = "12"
$NewVCVSANClusterName = "Nested-T1"

# Nested ESXi VM Resources
$NestedESXivCPU = "2"
$NestedESXivMEM = "6" #GB
$NestedESXiCachingvDisk = "30" #GB
$NestedESXiCapacityvDisk = "300" #GB

# General Deployment Configuration for Nested ESXi, VCSA & NSX VMs
$NestedPGs = "Nested-01-DVPG"
$VMDatastore = "vsanDatastore"
$VMNetmask = "255.255.255.0"
$VMDNS = "10.10.1.1"
$VMNTP = "10.10.1.1"
$VMPassword = "VMware1!"
$VMDomain = "sddc.info"
$VMSyslog = "10.10.1.1"
# Applicable to VC Deployment Target only
$VMCluster = "VSAN"

# DO NOT EDIT PAST HERE

Function My-Logger {
    param(
    [Parameter(Mandatory=$true)]
    [String]$message
    )

    $timeStamp = Get-Date -Format "MM-dd-yyyy_hh-mm-ss"

    Write-Host -NoNewline -ForegroundColor White "[$timestamp]"
    Write-Host -ForegroundColor Green " $message"
}
$StartTime = Get-Date
Clear-Host
My-Logger "Starting Deployment"


$viConnection = Connect-VIServer $VIServer -User $VIUsername -Password $VIPassword -WarningAction SilentlyContinue

$cluster = Get-Cluster -Name $VMCluster
$datacenter = $cluster | Get-Datacenter
$vmhost = $cluster | Get-VMHost | Select -First 1
$datastore = Get-Datastore -Name $VMDatastore | Select -First 1

New-Datacenter -Location (Get-Folder -NoRecursion) -Name "Lab"

if($datastore.Type -eq "vsan") {
    Get-AdvancedSetting -Entity $vmhost -Name "VSAN.FakeSCSIReservations" | Set-AdvancedSetting -Value 1 -Confirm:$false
}

$vds = Get-VDSwitch -Name "VDS" 

#$dvpg = New-VDPortgroup -Name $NestedPGs -VDSwitch $vds -VlanTrunkRange 0-4094
# re-deploy
$dvpg = Get-VDPortgroup -Name $NestedPGs -VDSwitch $vds

$originalSecurityPolicy = $dvpg.ExtensionData.Config.DefaultPortConfig.SecurityPolicy

$spec = New-Object VMware.Vim.DVPortgroupConfigSpec
$dvPortSetting = New-Object VMware.Vim.VMwareDVSPortSetting
$macMmgtSetting = New-Object VMware.Vim.DVSMacManagementPolicy
$macLearnSetting = New-Object VMware.Vim.DVSMacLearningPolicy
$macMmgtSetting.MacLearningPolicy = $macLearnSetting
$dvPortSetting.MacManagementPolicy = $macMmgtSetting
$spec.DefaultPortConfig = $dvPortSetting
$spec.ConfigVersion = $dvpg.ExtensionData.Config.ConfigVersion

$macMmgtSetting.AllowPromiscuous = $false
$macMmgtSetting.ForgedTransmits = $false
$macMmgtSetting.MacChanges = $false
$macLearnSetting.Enabled = $false
$macLearnSetting.AllowUnicastFlooding = $true
$macLearnSetting.LimitPolicy = "DROP"
$macLearnsetting.Limit = 4096

$task = $dvpg.ExtensionData.ReconfigureDVPortgroup_Task($spec)

# Set Mac Learning so you don't need promisc
Set-MacLearn -DVPortgroupName @("$NestedPGs") -EnableMacLearn $true -EnablePromiscuous $false -EnableForgedTransmit $true -EnableMacChange $false

$NestedESXiHostnameToIPs.GetEnumerator() | Sort-Object -Property Value | Foreach-Object {
    $VMName = $_.Key
    $VMIPAddress = $_.Value

    $ovfconfig = Get-OvfConfiguration $NestedESXiApplianceOVA
    $ovfconfig.NetworkMapping.VM_Network.value = $NestedPGs

    $ovfconfig.common.guestinfo.hostname.value = $VMName
    $ovfconfig.common.guestinfo.ipaddress.value = $VMIPAddress
    $ovfconfig.common.guestinfo.netmask.value = $VMNetmask
    $ovfconfig.common.guestinfo.gateway.value = $VMGateway
    $ovfconfig.common.guestinfo.vlan.Value = $VMMGMTVlan
    $ovfconfig.common.guestinfo.dns.value = $VMDNS
    $ovfconfig.common.guestinfo.domain.value = $VMDomain
    $ovfconfig.common.guestinfo.ntp.value = $VMNTP
    $ovfconfig.common.guestinfo.syslog.value = $VMSyslog
    $ovfconfig.common.guestinfo.password.value = $VMPassword
    $ovfconfig.common.guestinfo.ssh.value = $true

    $vm = Import-VApp -Source $NestedESXiApplianceOVA -OvfConfiguration $ovfconfig -Name $VMName -Location $cluster -VMHost $vmhost -Datastore $datastore -DiskStorageFormat thin

    # Add the dvfilter settings to the exisiting ethernet1 (not part of ova template)
    $vm | New-AdvancedSetting -name "ethernet1.filter4.name" -value "dvfilter-maclearn" -confirm:$false -ErrorAction SilentlyContinue 
    $vm | New-AdvancedSetting -Name "ethernet1.filter4.onFailure" -value "failOpen" -confirm:$false -ErrorAction SilentlyContinue 

    Set-VM -VM $vm -NumCpu $NestedESXivCPU -MemoryGB $NestedESXivMEM -Server $viConnection -Confirm:$false 

    Get-HardDisk -VM $vm -Name "Hard disk 2" | Set-HardDisk -CapacityGB $NestedESXiCachingvDisk -Confirm:$false 

    Get-HardDisk -VM $vm -Name "Hard disk 3" | Set-HardDisk -CapacityGB $NestedESXiCapacityvDisk -Confirm:$false 

    $vm | Start-Vm -RunAsync | Out-Null
}

New-Cluster -Name $NewVCVSANClusterName -Location "Lab" -DrsAutomationLevel FullyAutomated -VsanEnabled

# Create VDS
$cluster = Get-Cluster -Name $NewVCVSANClusterName
$datacenter = $cluster | Get-Datacenter
## Create VDS
$vds = New-VDSwitch -Server $viConnection -Name $NewVCVSANClusterName -NumUplinkPorts 2 -mtu 9000 -Location $Datacenter -LinkDiscoveryProtocol CDP -LinkDiscoveryProtocolOperation Both
# Upgrade VDS to NIOC3 and Enhanced LACP.
$spec = New-Object VMware.Vim.VMwareDVSConfigSpec
$spec.networkResourceControlVersion = 'version3'
$spec.configVersion = $vds.ExtensionData.config.configVersion
$vds.ExtensionData.ReconfigureDvs($spec)
# Enable NIOC on VDS. overwrites if not enabled
$vds.ExtensionData.EnableNetworkResourceManagement($true)
# Create the vSAN and vMotion Port Groups
New-VDPortgroup -Name T1-MGMT -vds $vds -VlanId 11
New-VDPortgroup -Name T1-TEP -vds $vds -VlanId 12
New-VDPortgroup -Name T1-VMOTION -vds $vds -VlanId 13
New-VDPortgroup -Name T1-VSAN -vds $vds -VlanId 14
New-VDPortgroup -Name T1-VMGuest -vds $vds -VlanId 15

$NestedESXiHostnameToIPs.GetEnumerator() | sort -Property Value | Foreach-Object {
    $VMName = $_.Key
    $VMIPAddress = $_.Value
    $targetVMHost = $VMName

    $esxi = Add-VMHost -Location $NewVCVSANClusterName -User "root" -Password $VMPassword -Name $targetVMHost -Force 
    $vdswitchVMhostresult = Add-VDSwitchVMHost -VDSwitch $vds -VMHost $esxi

    $dvsuplinks = Get-VMHostNetworkAdapter -VMHost $esxi -Name vmnic0
    $vmk = Get-VMHostNetworkAdapter -Name vmk0 -VMHost $esxi
    $vds | Add-VDSwitchPhysicalNetworkAdapter -VMHostPhysicalNic $dvsuplinks -Confirm:$false -VMHostVirtualNic $vmk -VirtualNicPortgroup "T1-MGMT"    
    $esxi | Get-VMHostNetworkAdapter -name $vmk | Set-VMHostNetworkAdapter -Mtu 1500 -VMotionEnabled $true -Confirm:$false
    $vdswitchVMhostresult | Get-VDPortgroup | Get-VDUplinkTeamingPolicy | Set-VDUplinkTeamingPolicy -ActiveUplinkPort dvUplink1 -UnusedUplinkPort dvUplink2
}

# Configure Cluster
Get-VsanClusterConfiguration -Cluster $NewVCVSANClusterName | Set-VsanClusterConfiguration -SpaceEfficiencyEnabled $true -HealthCheckIntervalMinutes 0 

foreach ($vmhost in Get-Cluster -Name $NewVCVSANClusterName | Get-VMHost) {
    $luns = $vmhost | Get-ScsiLun | select CanonicalName, CapacityGB


    foreach ($lun in $luns) {
        if(([int]($lun.CapacityGB)).toString() -eq "$NestedESXiCachingvDisk") {
            $vsanCacheDisk = $lun.CanonicalName
        }
        if(([int]($lun.CapacityGB)).toString() -eq "$NestedESXiCapacityvDisk") {
            $vsanCapacityDisk = $lun.CanonicalName
        }
    }
    New-VsanDiskGroup -VMHost $vmhost -SsdCanonicalName $vsanCacheDisk -DataDiskCanonicalName $vsanCapacityDisk 
}

Disconnect-VIServer $viConnection -Confirm:$false

$EndTime = Get-Date
$duration = [math]::Round((New-TimeSpan -Start $StartTime -End $EndTime).TotalMinutes,2)

My-Logger "Lab Deployment Complete!"
My-Logger "StartTime: $StartTime"
My-Logger "  EndTime: $EndTime"
My-Logger " Duration: $duration minutes"
