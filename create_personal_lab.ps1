# Create a single LAB virtual esx for personal nested environment
$vcenter = "vcsa"
$viUsername = "administrator@vsphere.local"
$viPassword = "VMware1!"
$NestedESXiApplianceOVA = "Z:\Nested_ESXi6.7u3_Appliance_Template_v1.ova"
$windows_2019_template = "Z:\windows_2019_template.ova"
$target_vmcluster = ""
$target_vmhost = ""
$target_datastore = ""
$ext_network = ""
$base_prefix = ""
$vds_name = $base_prefix + "_VDS"
$pg_name = $base_prefix + "_Nested_PG"
# Nested ESXi VM Resources
$NestedESXivCPU = "12"
$NestedESXivMEM = "96" #GB
$NestedESXivDisk = "500" #GB

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

$viConnection = Connect-VIServer $vcenter -User $VIUsername -Password $VIPassword -WarningAction SilentlyContinue

$cluster = Get-Cluster -Name $target_vmcluster
$datacenter = $cluster | Get-Datacenter
$vmhost = $cluster | Get-VMHost | Select -First 1
$datastore = Get-Datastore -Name $target_datastore | Select -First 1
$target_datacenter = Get-Cluster -Name $target_vmcluster | Get-Datacenter
$VMName = $base_prefix + "-vesx"

My-Logger "Create VDS and add to the ESXi host(s)"
$vds = New-VDSwitch -Name $vds_name -Location (Get-Cluster -name $target_vmcluster | Get-Datacenter) -Mtu 9000 -NumUplinkPorts 1 -Version 6.6.0 
$vds | New-VDPortgroup -Name $pg_name | Out-Null
$vds | Add-VDSwitchVMHost -VMHost (Get-Cluster -name $target_vmcluster | Get-VMHost)

$ovfconfig = Get-OvfConfiguration $NestedESXiApplianceOVA
$ovfconfig.NetworkMapping.VM_Network.value = $pg_name
$ovfconfig.common.guestinfo.hostname.value = $VMName
$ovfconfig.common.guestinfo.ipaddress.value = "10.10.10.10"
$ovfconfig.common.guestinfo.netmask.value = "255.255.255.0"
$ovfconfig.common.guestinfo.gateway.value = "10.10.10.1"
$ovfconfig.common.guestinfo.dns.value = "10.10.10.1"
$ovfconfig.common.guestinfo.domain.value = "lay.house"
$ovfconfig.common.guestinfo.ntp.value = "10.10.10.1"
$ovfconfig.common.guestinfo.syslog.value = "10.10.10.1"
$ovfconfig.common.guestinfo.password.value = "VMware1!"
$ovfconfig.common.guestinfo.ssh.value = $true

$VApp = New-Vapp -Name $base_prefix -Location $target_vmcluster

$vm = Import-VApp -Source $NestedESXiApplianceOVA -OvfConfiguration $ovfconfig -Name $VMName -Location $VApp -VMHost $vmhost -Datastore $target_datastore -DiskStorageFormat thin

Set-VM -VM $vm -NumCpu $NestedESXivCPU -MemoryGB $NestedESXivMEM -Server $viConnection -Confirm:$false 
Get-HardDisk -VM $vm -Name "Hard disk 2" | Set-HardDisk -CapacityGB $NestedESXivDisk -Confirm:$false 
# Remove second drive and NIC
Get-HardDisk -VM $vm -Name "Hard disk 3" | Remove-HardDisk -Confirm:$false 
$vm | Get-NetworkAdapter -name "Network adapter 2" | Remove-NetworkAdapter -Confirm:$false
$vm | Set-VM -Version v14 -Confirm:$false
$vm | Start-Vm -RunAsync | Out-Null

# Windows jump box
My-Logger "Deploy OVA image for jumpbox"
$jump_name = $base_prefix + "-jumpbox"

$ovfconfig = Get-OvfConfiguration $windows_2019_template 
$ovfconfig.NetworkMapping.VM_Network.value = $ext_network

$jumpvm = Import-VApp -Server $viConnection -Source $windows_2019_template -OvfConfiguration $ovfconfig -Name $jump_name -VMHost $target_vmhost -Location $VApp -Datastore $target_datastore -DiskStorageFormat thin -Force
$jumpvm | New-NetworkAdapter -Portgroup $pg_name -StartConnected -Type Vmxnet3 | Out-Null

My-Logger "Start the VM"
$jumpvm | Start-VM | Out-Null

My-Logger "Wait until the machine has a working VM-Tools"
$VMToolStatus = ""
do {
	sleep 10
    $VMToolStatus = ($jumpvm | Get-View).Guest.ToolsStatus
} until ( $VMToolStatus -eq ‘toolsOk’ )


My-Logger "continuing with setup"
# Define Guest Credentials
$username="Administrator"
$password=ConvertTo-SecureString "VMware1!" -AsPlainText -Force
$GuestOSCred=New-Object -typename System.Management.Automation.PSCredential -argumentlist $username, $password

My-Logger "Rename the Jump Box"
Invoke-VMScript -ScriptType PowerShell -ScriptText "Rename-Computer -NewName $jump_name" -VM $jumpvm -GuestCredential $GuestOSCred | out-null

My-Logger "Setup Host"
$setup_host = @'
Disable-NetAdapterBinding -InterfaceAlias Ethernet0 -ComponentID ms_tcpip6
New-NetIPAddress '10.10.10.254' -interfaceAlias Ethernet1 -AddressFamily IPV4 -PrefixLength 24
Get-NetAdapter -Name Ethernet1 | Set-DnsClientServerAddress -ServerAddresses 10.10.10.1
Disable-NetAdapterBinding -InterfaceAlias Ethernet1 -ComponentID ms_tcpip6
NetSh Advfirewall set allprofiles state off
mkdir -Force C:\Temp\VMWare\
'@
Invoke-VMScript -ScriptText $setup_host -VM $jumpvm -GuestCredential $GuestOSCred | out-null

$vms_in_vapp = $vapp | Get-VM
New-DrsRule -Cluster $target_vmcluster -Name $base_prefix -KeepTogether $true -VM $vms_in_vapp


My-Logger "Mapping jumpbox to copy files down"
$jump_ip = ($jumpvm | Get-View).Guest.Net.IpAddress[0]
New-PSDrive –Name “K” –PSProvider FileSystem –Root “\\$jump_ip\c$” –Credential $GuestOSCred | out-null

Copy-Item -Path 'C:\LocalStorage\*' -Destination 'K:\Temp\VMWare\'  -Force -Recurse | out-null

Remove-PSDrive -name "K" | out-null

My-Logger "Enable firewall"
Invoke-VMScript -ScriptText "NetSh Advfirewall set allprofiles state on" -VM $jumpvm -GuestCredential $GuestOSCred | out-null

My-Logger "Restart to complete the installation"
$jumpvm | Restart-VMGuest | out-null




$EndTime = Get-Date
$duration = [math]::Round((New-TimeSpan -Start $StartTime -End $EndTime).TotalMinutes,2)

My-Logger "Lab Deployment Complete!"
My-Logger "StartTime: $StartTime"
My-Logger "  EndTime: $EndTime"
My-Logger " Duration: $duration minutes"
