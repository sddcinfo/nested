# vROps OVF
$VROPS_OVA="C:\Temp\VMware\vRealize-Operations-Manager-Appliance-6.6.1.6163035_OVF10.ova"

# VM Settings
$vrops_name = $base_prefix + "-vrops"

$VROPS_IPPROTOCOL = "IPv4"
$VROPS_TIMEZONE = "America/New_York"

& 'E:\vcsa\ovftool\win32\ovftool.exe' --overwrite --powerOn --acceptAllEulas --noSSLVerify --skipManifestCheck --allowAllExtraConfig --X:enableHiddenProperties --deploymentOption="xsmall" --net:Network 1=$pg_name --datastore=$target_datastore --diskMode="thin" --name=$vrops_name --prop:vami.DNS.vRealize_Operations_Manager_Appliance="10.10.10.1" --prop:vami.gateway.vRealize_Operations_Manager_Appliance="10.10.10.1" --prop:vami.ip0.vRealize_Operations_Manager_Appliance="10.10.10.3" --prop:vami.netmask0.vRealize_Operations_Manager_Appliance="255.255.255.0" --prop:guestinfo.cis.appliance.ssh.enabled="true" $vrops_ova vi://$viUsername:$viPassword@$vcenter/?dns=$target_vmhost


--datastore=${VROPS_DATASTORE} --diskMode=${VROPS_DISK_TYPE} --name=${VROPS_DISPLAY_NAME} --prop:vami.DNS.vRealize_Operations_Manager_Appliance=${VROPS_DNS} --prop:vami.gateway.vRealize_Operations_Manager_Appliance=${VROPS_GATEWAY} --prop:vami.ip0.vRealize_Operations_Manager_Appliance=${VROPS_IPADDRESS} --prop:vami.netmask0.vRealize_Operations_Manager_Appliance=${VROPS_NETMASK} --prop:guestinfo.cis.appliance.ssh.enabled=${ENABLE_SSH} ${VROPS_OVA} vi://${VCENTER_USERNAME}:${VCENTER_PASSWORD}@${VCENTER_HOSTNAME}/?dns=${ESXI_HOSTNAME}
