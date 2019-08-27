# Assumptions that you already have a working base vcenter and cluster setup with storage with 2016 OVA created
$vcenter = ""
$viUsername = "administrator@vsphere.local"
$viPassword = ""
$base_prefix = ""
$target_vmcluster = ""
$target_int = $base_prefix + "_Nested_PG"
$target_vmhost = "esx-amd.lay.house"
$target_datastore = "esx-amd-optane1"

$windows_2019_template = "C:\Temp\VMWare\Windows_2019_template.ova"
$NestedESXiApplianceOVA = "C:\Temp\VMWare\Nested_ESXi6.7u3_Appliance_Template_v1.ova"
$vcsa_isopath = "C:\Temp\VMWare\VMware-VCSA-all-6.7.0-14367737.iso"

# DO NOT EDIT PAST HERE
Set-PowerCLIConfiguration -Scope AllUsers -ParticipateInCEIP:$false -confirm:$false | Out-Null
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
$viConnection = Connect-VIServer $vcenter -User $viUsername -Password $viPassword -WarningAction SilentlyContinue

### DO NOT EDIT PAST HERE

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

My-Logger "Deploy OVA image for Domain Controller"
$ADVM_Name = $base_prefix + "-dc1"
$target_datacenter = Get-Cluster -Name $target_vmcluster | Get-Datacenter

$ovfconfig = Get-OvfConfiguration $windows_2019_template
$ovfconfig.NetworkMapping.VM_Network.value = $target_int

$ADvm = Import-VApp -Server $viConnection -Source $windows_2019_template -OvfConfiguration $ovfconfig -Name $ADVM_Name -VMHost $target_vmhost -Location $VApp -Datastore $target_datastore -DiskStorageFormat thin -Force

My-Logger "Start the AD VM"
$ADvm | Start-VM | Out-Null
# Wait until the machine has a working VM-Tools
$VMToolStatus = ""
do {
	sleep 10
    $VMToolStatus = ($ADvm | Get-View).Guest.ToolsStatus
} until ( $VMToolStatus -eq ‘toolsOk’ )
# -or 'toolsOld'
My-Logger "Starting Phase 1 Configuration"

# Define Guest Credentials.
$username="Administrator"
$password=ConvertTo-SecureString "VMware1!" -AsPlainText -Force
$GuestOSCred=New-Object -typename System.Management.Automation.PSCredential -argumentlist $username, $password

My-Logger "Configure IP address, disable firewall, Set Timezone to EST, disable IPV6, Set DNS Server and Rename to DC1"
$ad_phase1 = @'
netsh interface ip set address name="Ethernet0" static 10.10.10.1 255.255.255.0
NetSh Advfirewall set allprofiles state off
Set-TimeZone -Name "Eastern Standard Time"
Disable-NetAdapterBinding -InterfaceAlias Ethernet0 -ComponentID ms_tcpip6
Get-NetAdapter -Name Ethernet0 | Set-DnsClientServerAddress -ServerAddresses 127.0.0.1
Rename-Computer -NewName "dc1"
'@

Invoke-VMScript -ScriptText $ad_phase1 -VM $ADvm -GuestCredential $GuestOSCred | Out-Null

My-Logger "Restart to complete the phase 1"
$ADvm | Restart-VMGuest | out-null

# Wait until the machine has a working VM-Tools
$VMToolStatus = ""
do {
	sleep 10
    $VMToolStatus = ($ADvm | Get-View).Guest.ToolsStatus
} until ( $VMToolStatus -eq ‘toolsOk’ )

My-Logger "Install and configure AD"
$ad_phase2 = @'
net stop vmtools
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
Install-ADDSForest -DatabasePath "C:\Windows\NTDS" -DomainMode 7 -DomainName "bofa.lab" -DomainNetbiosName "BOFA" -ForestMode 7 -LogPath "C:\Windows\NTDS" -SysvolPath "C:\Windows\SYSVOL" -NoRebootOnCompletion:$false -Confirm:$false -SafeModeAdministratorPassword (ConvertTo-SecureString VMware1! -AsPlainText -Force)
'@
Invoke-VMScript -ScriptText $ad_phase2 -VM $ADvm -GuestCredential $GuestOSCred -RunAsync | Out-Null

$VMToolStatus = ""
do {
	Write-Host -NoNewLine "."
    sleep 10
    $VMToolStatus = ($ADvm | Get-View).Guest.ToolsStatus
} until ( $VMToolStatus -eq ‘toolsOk’ )

My-Logger "Creating DNS records"

$add_dns = @'
Add-DnsServerPrimaryZone -NetworkID "10.10.10.0/24" -ReplicationScope "Forest"
Add-DnsServerResourceRecordPtr -Name "1" -ZoneName "10.10.10.in-addr.arpa" -AllowUpdateAny -PtrDomainName "dc1.bofa.lab"
Add-DnsServerResourceRecordA -Name "vcsa" -ZoneName "bofa.lab" -AllowUpdateAny -IPv4Address "10.10.10.2" -CreatePtr
Add-DnsServerResourceRecordA -Name "vrops" -ZoneName "bofa.lab" -AllowUpdateAny -IPv4Address "10.10.10.3" -CreatePtr
Add-DnsServerResourceRecordA -Name "vlog" -ZoneName "bofa.lab" -AllowUpdateAny -IPv4Address "10.10.10.4" -CreatePtr
Add-DnsServerResourceRecordA -Name "vra" -ZoneName "bofa.lab" -AllowUpdateAny -IPv4Address "10.10.10.5" -CreatePtr
Add-DnsServerResourceRecordA -Name "vesx-01" -ZoneName "bofa.lab" -AllowUpdateAny -IPv4Address "10.10.10.111" -CreatePtr
Add-DnsServerResourceRecordA -Name "vesx-02" -ZoneName "bofa.lab" -AllowUpdateAny -IPv4Address "10.10.10.112" -CreatePtr
Add-DnsServerResourceRecordA -Name "vesx-03" -ZoneName "bofa.lab" -AllowUpdateAny -IPv4Address "10.10.10.113" -CreatePtr
'@
Invoke-VMScript -ScriptText $add_dns -VM $ADvm -GuestCredential $GuestOSCred -RunAsync | Out-Null

My-Logger "Installing VCSA"
# mount the vcsa iso
$vcsa_iso = mount-diskimage -imagepath $vcsa_isopath -passthru

# get the drive letter assigned to the iso.
$vcsa_driveletter = ($vcsa_iso | get-volume).driveletter + ':'

$vcsa_json = $vcsa_driveletter + "vcsa-cli-installer\templates\install\embedded_vCSA_on_VC.json"

$config = (Get-Content -Raw $vcsa_json | convertfrom-json) 
$config.'new_vcsa'.vc.hostname = $vcenter
$config.'new_vcsa'.vc.username = $VIusername
$config.'new_vcsa'.vc.password = $VIpassword
$config.'new_vcsa'.vc.'deployment_network' = $pg_name
$config.'new_vcsa'.vc.datastore = $target_datastore
$config.'new_vcsa'.vc.datacenter = $target_datacenter
$config.'new_vcsa'.vc.target = $target_vmcluster
$config.'new_vcsa'.appliance.'thin_disk_mode' = $true
$config.'new_vcsa'.appliance.'deployment_option' = "tiny"
$config.'new_vcsa'.appliance.name = $base_prefix + "-vcsa"
$config.'new_vcsa'.network.'ip_family' = "ipv4"
$config.'new_vcsa'.network.mode = "static"
$config.'new_vcsa'.network.ip = "10.10.10.2"
$config.'new_vcsa'.network.'dns_servers'[0] = "10.10.10.1"
$config.'new_vcsa'.network.prefix = "24"
$config.'new_vcsa'.network.gateway = "10.10.10.1"
$config.'new_vcsa'.network.'system_name' = "vcsa.bofa.lab"
$config.'new_vcsa'.os.password = "VMware1!"
$config.'new_vcsa'.os.'ssh_enable' = $true
$config.'new_vcsa'.sso.password = "VMware1!"
$config.'new_vcsa'.sso.'domain_name' = "vsphere.local"

$config | ConvertTo-Json | Set-Content -Path "$($ENV:Temp)\jsontemplate.json"

$vcsa_cmd = $vcsa_driveletter + "\vcsa-cli-installer\win32\vcsa-deploy.exe install --no-ssl-certificate-verification --accept-eula --acknowledge-ceip $($ENV:Temp)\jsontemplate.json"
Invoke-Expression $vcsa_cmd

# Deploy vrops image
$vrops_name = $base_prefix + "-vrops"
& "$vcsa_driveletter\vcsa\ovftool\win32\ovftool.exe" --overwrite --powerOn --acceptAllEulas --noSSLVerify --skipManifestCheck --allowAllExtraConfig --X:enableHiddenProperties --deploymentOption="xsmall" "--net:Network 1=$pg_name" --datastore=$target_datastore --diskMode="thin" --name=$vrops_name --prop:vamitimezone="America/New_York" --prop:vami.DNS.vRealize_Operations_Manager_Appliance="10.10.10.1" --prop:vami.gateway.vRealize_Operations_Manager_Appliance="10.10.10.1" --prop:vami.ip0.vRealize_Operations_Manager_Appliance="10.10.10.3" --prop:vami.netmask0.vRealize_Operations_Manager_Appliance="255.255.255.0" --prop:guestinfo.cis.appliance.ssh.enabled="true" $vrops_ova vi://${viUsername}:$viPassword@$vcenter/?dns=$target_vmhost

$vms_in_vapp = $vapp | Get-VM
New-DrsRule -Cluster $target_vmcluster -Name $base_prefix -KeepTogether $true -VM $vms_in_vapp

Dismount-DiskImage -imagepath $vcsa_isopath

# Nested ESXi VMs to deploy
$AF_NestedESXiHostnameToIPs = @{
"vesx-01" = "10.10.10.111"
"vesx-02" = "10.10.10.112"
"vesx-03" = "10.10.10.113"
}

# Nested ESXi VM Resources
$NestedESXivCPU = "4"
$NestedESXivMEM = "12" #GB
$NestedESXiCachingvDisk = "100" #GB
$NestedESXiCapacityvDisk = "500" #GB

$AF_NestedESXiHostnameToIPs.GetEnumerator() | Sort-Object -Property Value | Foreach-Object {
    $VMName = $_.Key
    $VMIPAddress = $_.Value

    $ovfconfig = Get-OvfConfiguration $NestedESXiApplianceOVA
    $ovfconfig.NetworkMapping.VM_Network.value = $pg_name

    $ovfconfig.common.guestinfo.hostname.value = $VMName
    $ovfconfig.common.guestinfo.ipaddress.value = $VMIPAddress
    $ovfconfig.common.guestinfo.netmask.value = "255.255.255.0"
    $ovfconfig.common.guestinfo.gateway.value = "10.10.10.1"
    $ovfconfig.common.guestinfo.dns.value = "10.10.10.1"
    $ovfconfig.common.guestinfo.domain.value = "bofa.lab"
    $ovfconfig.common.guestinfo.ntp.value = "10.10.10.1"
    $ovfconfig.common.guestinfo.syslog.value = "10.10.10.1"
    $ovfconfig.common.guestinfo.password.value = "VMware1!"
    $ovfconfig.common.guestinfo.ssh.value = $true

    $base_vmname = $base_prefix + "-" + $VMName
    My-Logger "Creating $base_vmname"
    $vm = Import-VApp -Source $NestedESXiApplianceOVA -OvfConfiguration $ovfconfig -Name $base_vmname -Location $target_vmcluster -VMHost $target_vmhost -Datastore $target_datastore -DiskStorageFormat thin

    # Add the dvfilter settings to the exisiting ethernet1 (not part of ova template)
    $vm | New-AdvancedSetting -name "ethernet1.filter4.name" -value "dvfilter-maclearn" -confirm:$false -ErrorAction SilentlyContinue 
    $vm | New-AdvancedSetting -Name "ethernet1.filter4.onFailure" -value "failOpen" -confirm:$false -ErrorAction SilentlyContinue 

    Set-VM -VM $vm -NumCpu $NestedESXivCPU -MemoryGB $NestedESXivMEM -Confirm:$false | Out-Null

    My-Logger "Updating vSAN Caching VMDK size to $NestedESXiCachingvDisk GB ..."
    Get-HardDisk -Server $viConnection -VM $vm -Name "Hard disk 2" | Set-HardDisk -CapacityGB $NestedESXiCachingvDisk -Confirm:$false 

    My-Logger "Updating vSAN Capacity VMDK size to $NestedESXiCapacityvDisk GB ..."
    Get-HardDisk -Server $viConnection -VM $vm -Name "Hard disk 3" | Set-HardDisk -CapacityGB $NestedESXiCapacityvDisk -Confirm:$false 

    $vm | Start-Vm -RunAsync | Out-Null
    Move-VM -VM $vm -Destination $VApp -Confirm:$false 
}

$EndTime = Get-Date
$duration = [math]::Round((New-TimeSpan -Start $StartTime -End $EndTime).TotalMinutes,2)

My-Logger "Lab Deployment Complete!"
My-Logger "StartTime: $StartTime"
My-Logger "  EndTime: $EndTime"
My-Logger " Duration: $duration minutes"
