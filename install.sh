#!/bin/bash
#[ToDo]:
#add if else for it and also for user inputs and virtualization check
#Add some description to be echoed while the script is running

#Enter the hostname
echo "Enter the hostname: "
read hostname

#Check IP address and default gateway
#Identify the interface name
ip a
echo "Enter the interface name: "
read interface

#Assign the IP address and default gateway
ip=$(ip a | grep $interface | grep inet | awk '{print $2}' | cut -d '/' -f1)
gateway=$(ip route | grep default | awk '{print $3}')

#Install the required packages
sudo apt install chrony -y

#Install bridge-utils
sudo apt install bridge-utils -y

#Configure the ethernet and bridge in network manager
network_manager="/etc/netplan/01-network-manager-all.yaml"
/bin/cat <<EOM > "$network_manager"
network:
  version: 2
  renderer: networkd
  ethernets:
     $interface:
      dhcp4: false
      dhcp6: false
      optional: true
  bridges:
      cloudbr0:
        addresses: [$ip/24]
        routes:
          - to: default
            via: $gateway
        nameservers:
          addresses: [8.8.8.8,8.8.4.4]
        interfaces: [$interface]
        dhcp4: false
        dhcp6: false
        parameters:
          stp: false
          forward-delay: 0
EOM

#Apply the changes
sudo netplan generate
sudo netplan --debbug apply
sudo netplan --debbug apply
sudo systemctl restart NetworkManager 

#Update the /etc/hosts file
sed -i '2a\'"$ip apache.$hostname.u1 $hostname" /etc/hosts
sudo hostnamectl set-hostname apache.$hostname.u1

echo "Hostname is set to: "
hostname --fqdn

#Install the required packages
sudo apt install ntp -y
sudo apt install openjdk-11-jdk -y

#Add cloudstack management server repository to the sources list
echo "deb https://download.cloudstack.org/ubuntu jammy 4.18" | sudo tee /etc/apt/sources.list.d/cloudstack.list

wget -O - https://download.cloudstack.org/release.asc | sudo tee /etc/apt/trusted.gpg.d/cloudstack.asc

#Install the cloudstack management server
sudo apt update
sudo apt install cloudstack-management cloudstack-usage -y

#Install mysql server
sudo apt install mysql-server -y

#Configure the mysql server
echo "[mysqld]" >> /etc/mysql/my.cnf
echo "server-id=1" >> /etc/mysql/my.cnf
echo "innodb_rollback_on_timeout=1" >> /etc/mysql/my.cnf
echo "innodb_lock_wait_timeout=600" >> /etc/mysql/my.cnf
echo "max_connections=1000" >> /etc/mysql/my.cnf
echo "log-bin=mysql-bin" >> /etc/mysql/my.cnf
echo "binlog-format = 'ROW'" >> /etc/mysql/my.cnf

sudo systemctl restart mysql

sudo mysql_secure_installation 

#Run MySQL commands
echo "Enter the password for the cloudstack database user: ";
read password
#I am here
sudo mysql -u root -p -e "
CREATE DATABASE \`cloud\`;
CREATE DATABASE \`cloud_usage\`;

CREATE USER cloud@\`localhost\` identified by '$password';
CREATE USER cloud@\`%\` identified by '$password';

GRANT ALL ON cloud.* to cloud@\`localhost\`;
GRANT ALL ON cloud.* to cloud@\`%\`;

GRANT ALL ON cloud_usage.* to cloud@\`localhost\`;
GRANT ALL ON cloud_usage.* to cloud@\`%\`;

GRANT process ON *.* TO cloud@\`localhost\`;
GRANT process ON *.* TO cloud@\`%\`;
"
#Deploy the cloudstack databases
sudo cloudstack-setup-databases cloud:$password@localhost --deploy-as=root

#Run the cloudstack management server setup
sudo cloudstack-setup-management

#allow the mysql port in the firewall
sudo ufw allow mysql

#Prepare NFS server
sudo mkdir -p /export/primary
sudo mkdir -p /export/secondary
sudo touch /etc/exports
echo "/export *(rw,async,no_root_squash,no_subtree_check)" >> /etc/exports

#Install the NFS server
sudo apt install nfs-kernel-server -y
service nfs-kernel-server restart

sudo mkdir -p /mnt/primary
sudo mkdir -p /mnt/secondary

#Mount the NFS shares
sudo mount -t nfs $hostname:/export/primary /mnt/primary
sudo mount -t nfs $hostname:/export/secondary /mnt/secondary

#Start the cloudstack management server
service cloudstack-management start

#Virtualization check
sudo egrep -c '(vmx|svm)' /proc/cpuinfo && echo "Virtualization is supported" || echo "Virtualization is not supported"

#Install the cloudstack agent and kvm
sudo apt install qemu-kvm cloudstack-agent openssh-server cpu-checker uuid -y
sed -i -e 's/\#vnc_listen.*$/vnc_listen = "0.0.0.0"/g' /etc/libvirt/qemu.conf

#Configure the libvirtd
echo 'listen_tls = 0' >> /etc/libvirt/libvirtd.conf
echo 'listen_tcp = 1' >> /etc/libvirt/libvirtd.conf
echo 'tcp_port = "16509"' >> /etc/libvirt/libvirtd.conf
echo 'mdns_adv = 0' >> /etc/libvirt/libvirtd.conf
echo 'auth_tcp = "none"' >> /etc/libvirt/libvirtd.conf
sudo systemctl restart libvirtd

#Disable the apparmor for libvirtd
ln -s /etc/apparmor.d/usr.sbin.libvirtd /etc/apparmor.d/disable/
ln -s /etc/apparmor.d/usr.lib.libvirt.virt-aa-helper /etc/apparmor.d/disable/
apparmor_parser -R /etc/apparmor.d/usr.sbin.libvirtd
apparmor_parser -R /etc/apparmor.d/usr.lib.libvirt.virt-aa-helper

#Check kvm status
lsmod | grep kvm
echo "Output should be like this: "
echo "kvm_intel    55496     0"
echo "kvm          337772    1 kvm_intel"
echo "kvm_amd # if you are in AMD cpu"

#Permit root login in ssh
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
sudo systemctl restart sshd

#Add uuid to the libvirtd
uid = $(uuid)
echo "host_uuid = \"$uid\"" >> /etc/libvirt/qemu.conf

#Allow necessary ports in the firewall
sudo ufw allow proto tcp from any to any port 22,1798,16514,5900:6100,49152:49216

#configure additional settings in libvirtd.conf
echo "listen_addr = \"$gateway\"" >> /etc/libvirt/libvirtd.conf
echo "auth_tls = \"none\"" >> /etc/libvirt/libvirtd.conf

#Change properties of cloudstack-agent in agent.properties
cloudstack_agent = "/etc/cloudstack/agent/agent.properties"
/bin/cat <<EOM > "$cloudstack_agent"
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
# 
#   http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# Sample configuration file for CloudStack agent

# MANDATORY: The GUID to identify the agent with.
# Generated with "uuidgen"
guid=$uid

# The java class which the agent loads to execute.
resource=com.cloud.hypervisor.kvm.resource.LibvirtComputingResource

# The number of threads running in the agent.
workers=5

# The IP address of the management server.
host=localhost

# The time interval (in seconds) after which agent will check if the connected host
# is the preferred host (the first host in the comma-separated list is the preferred
# one). After that interval, if the agent is connected to one of the secondary/backup hosts,
# it will attempt to reconnect to the preferred host.
# The timer task is scheduled after the	 agent connects to a management server.
# On connection, it receives admin configured
# cluster-level 'indirect.agent.lb.check.interval' setting that will be used by
# the agent as the preferred host check interval, however, if the following setting
# is defined it will override the received value. The value 0 and lb algorithm 'shuffle'
# disables this background task.
#host.lb.check.interval=

# The port that the management server is listening on.
port=8250

# The cluster which the agent belongs to.
cluster=default

# The pod which the agent belongs to.
pod=default

# The zone which the agent belongs to.
zone=default

# The public NIC device.
# If this is commented, it will be autodetected on service startup.
public.network.device=cloudbr0

# The private NIC device.
# If this is commented, it will be autodetected on service startup.
private.network.device=cloudbr0

# The guest NIC device.
# If this is commented, the value of the private NIC device will be used.
guest.network.device=cloudbr0

# Local storage path. Multiple values can be entered and separated by commas.
#local.storage.path=/var/lib/libvirt/images/

# Directory where Qemu sockets are placed.
# These sockets are for the Qemu Guest Agent and SSVM provisioning.
# Make sure that AppArmor or SELinux allow libvirt to write there.
#qemu.sockets.path=/var/lib/libvirt/qemu

# MANDATORY: The UUID for the local storage pool. Multiple values can be entered and separated by commas.
# Generated with "uuidgen".
local.storage.uuid=

# Location for KVM virtual router scripts.
# The path defined in this property is relative to the directory "/usr/share/cloudstack-common/".
domr.scripts.dir=scripts/network/domr/kvm

# The timeout (in ms) for time-consuming operations, such as create/copy a snapshot.
#cmds.timeout=7200

# This parameter sets the VM migration speed.
# By default, it will try to guess the speed of the guest network and consume all possible bandwidth.
# The default value is -1, which means that the agent will use all possible bandwidth.
# When entering a value, make sure to enter it in megabytes per second.
#vm.migrate.speed=-1

# Sets target downtime (in ms) at end of livemigration, the 'hiccup' for final copy.
# Higher numbers make livemigration easier, lower numbers may cause migration to never complete.
# Less than 1 means hypervisor default (20ms).
#vm.migrate.downtime=-1

# Busy VMs may never finish migrating, depending on environment.
# Therefore, if configured, this option will pause the VM after the time entered (in ms) to force the migration to finish.
# Less than 1 means disabled.
#vm.migrate.pauseafter=-1

# Time (in seconds) to wait for VM migraton to finish. Less than 1 means disabled.
# If the VM migration is not finished in the time, the VM job will be cancelled by libvirt.
# It will be configured by cloudstack management server when cloudstack agent connects.
# please change the global setting 'migratewait' if needed (migratewait default value: 3600).
#vm.migrate.wait=-1

# ---------------- AGENT HOOKS -----------------
# Agent hooks is the way to override default agent behavior to extend the functionality without excessive coding
# for a custom deployment.
# There are 3 arguments needed for the hook to be called: the base directory (defined in agent.hooks.basedir),
# the name of the script that is located in the base directory (defined in agent.hooks.*.script)
# and the method that is going to be called on the script (defined in agent.hooks.*.method).
# These properties are detailed below.
# Hooks are implemented in Groovy and must be implemented in a way
# that keeps default CS behavior if something goes wrong.

# All hooks are located in a special directory defined in 'agent.hooks.basedir'.
# agent.hooks.basedir=/etc/cloudstack/agent/hooks

# Every hook has two major attributes - script name, specified in 'agent.hooks.*.script' and method name
# specified in 'agent.hooks.*.method'.

# Libvirt XML transformer hook does XML-to-XML transformation, which allows the provider to modify
# VM XML specification before is sent to libvirt.
# The provider can use this to add/remove/modify some sort of attributes in Libvirt XML domain specification.
#agent.hooks.libvirt_vm_xml_transformer.script=libvirt-vm-xml-transformer.groovy
#agent.hooks.libvirt_vm_xml_transformer.method=transform

# The hook is called right after libvirt successfully launched the VM.
#agent.hooks.libvirt_vm_on_start.script=libvirt-vm-state-change.groovy
#agent.hooks.libvirt_vm_on_start.method=onStart

# The hook is called right after libvirt successfully stopped the VM.
#agent.hooks.libvirt_vm_on_stop.script=libvirt-vm-state-change.groovy
#agent.hooks.libvirt_vm_on_stop.method=onStop
# ---------------- END AGENT HOOKS ---------------

# Sets the type of bridge used on the hypervisor. This defines what commands the resource
# will use to setup networking.
# Possible Values: native | openvswitch
#network.bridge.type=native

# Sets the driver used to plug and unplug NICs from the bridges.
# A sensible default value will be selected based on the network.bridge.type but can
# be overridden here.
# Also used to enable direct networking in libvirt (see properties below).
# Default value when network.bridge.type as native = com.cloud.hypervisor.kvm.resource.BridgeVifDriver
# Default value when network.bridge.type as openvswitch = com.cloud.hypervisor.kvm.resource.OvsVifDriver
#libvirt.vif.driver=

# Settings to enable direct networking in libvirt.
# Should not be used on hosts that run system VMs.
# Possible values for mode: private | bridge | vepa
#libvirt.vif.driver=com.cloud.hypervisor.kvm.resource.DirectVifDriver
#network.direct.source.mode=private
#network.direct.device=eth0

# Sets DPDK Support on OpenVswitch.
#openvswitch.dpdk.enabled=false
#openvswitch.dpdk.ovs.path=

# Sets the hypervisor type.
# Possible values: kvm | lxc
hypervisor.type=kvm

# This parameter specifies a directory on the host local storage for temporary storing direct download templates.
#direct.download.temporary.download.location=/var/lib/libvirt/images

# This parameter specifies a directory on the host local storage for creating and hosting the config drives.
#host.cache.location=/var/cache/cloud

# Sets the rolling maintenance hook scripts directory.
# Default is null, however, can be used as /etc/cloudstack/agent/hooks.d
#rolling.maintenance.hooks.dir=

# Disables the rolling maintenance service execution.
#rolling.maintenance.service.executor.disabled=false

# Sets the hypervisor URI. If null (default), the value defaults according the hypervisor.type:
# For KVM: qemu:///system
# For LXC: lxc:///
#hypervisor.uri=

# Setting to enable the CPU model to KVM guest globally.
# Possible values: custom | host-model | host-passthrough
# - custom: user customs the CPU model, which is specified by property guest.cpu.model.
# - host-model: identifies the named CPU model which most closely matches the host,
# and then requests additional CPU flags to complete the match. This should give
# close to maximum functionality/performance, which maintains good
# reliability/compatibility if the guest is migrated to another host with slightly different host CPUs.
# - host-passthrough: tells KVM to passthrough the host CPU with no modifications.
# It is different from host-model because instead of just matching feature flags,
# every last detail of the host CPU is matched. This gives absolutely best performance,
# and can be important to some apps which check low level CPU details,
# but it comes at a cost with migration. The guest can only be migrated to
# an exactly matching host CPU.
# If null (default), libvirt defaults to custom
#guest.cpu.mode=

# Custom CPU model. This param is only valid if guest.cpu.mode=custom.
# Possible values:"Conroe" | "Penryn" | "Nehalem" | "Westmere" | "pentiumpro" etc.
# Run virsh capabilities for more details.
#guest.cpu.model=

# This param will set the CPU architecture for the domain to override what
# the management server would send.
# In case of arm64 (aarch64), this will change the machine type to 'virt' and
# adds a SCSI and a USB controller in the domain xml.
# Possible values: x86_64 | aarch64
# If null (default), defaults to the VM's OS architecture
#guest.cpu.arch=

# This param will require CPU features on the CPU section.
# The features listed in this property must be separated by a blank space (e.g.: vmx vme)
#guest.cpu.features=

# Disables memory ballooning on VM guests for overcommit.
# By default overcommit feature enables balloon and sets currentMemory to a minimum value.
#vm.memballoon.disable=false

# The time interval (in seconds) at which the balloon driver will get memory stats updates.
# This is equivalent to Libvirt's --period parameter when using the dommemstat command.
# vm.memballoon.stats.period=0

# Set to true to check disk activity on VM's disks before starting a VM. This only applies
# to QCOW2 files, and ensures that there is no other running instance accessing
# the file before starting. It works by checking the modified time against the current time,
# so care must be taken to ensure that the cluster's time is synchronized, otherwise VMs may fail to start.
#vm.diskactivity.checkenabled=false

# Timeout (in seconds) for giving up on waiting for VM's disk files to become inactive.
# Hitting this timeout will result in failure to start VM.
# Value must be > 0.
#vm.diskactivity.checktimeout_s=120

# This is the length of time (in ms) that the disk needs to be inactive in order to pass the check.
# This means current time minus time of disk file needs to be greater than this number.
# It also has the side effect of setting the minimum threshold between a stop and start of
# a given VM.
#vm.diskactivity.inactivetime_ms=30000

# Some newer linux kernels are incapable of reliably migrating VMs with KVMclock.
# This is a workaround for the bug, admin can set this to true per-host.
#kvmclock.disable=false

# This enables the VirtIO Random Number Generator (RNG) device for guests.
#vm.rng.enable=false

# The model of VirtIO Random Number Generator (RNG) to present to the Guest.
# Currently only 'random' is supported.
#vm.rng.model=random

# Local Random Number Device Generator to use for VirtIO RNG for Guests.
# This is usually /dev/random, but it might be different per platform.
#vm.rng.path=/dev/random

# The amount of bytes the Guest may request/obtain from the RNG in the period
# specified in the property vm.rng.rate.period.
#vm.rng.rate.bytes=2048

# The number of milliseconds in which the guest is allowed to obtain the bytes
# specified  in the property vm.rng.rate.bytes.
#vm.rng.rate.period=1000

# Timeout value for aggregation commands to be sent to the virtual router (in seconds).
#router.aggregation.command.each.timeout=

# Allows virtually increase the amount of RAM (in MB) available on the host.
# This property can be useful if the host uses  Zswap, KSM features and other memory compressing technologies.
# For example: if the host has 2GB of RAM and this property is set to 2048, the amount of RAM of the host will be read as 4GB.
#host.overcommit.mem.mb=0

# How much host memory (in MB) to reserve for non-allocation.
# A useful parameter if a node uses some other software that requires memory,
# or in case that OOM Killer kicks in.
# If this parameter is used, property host.overcommit.mem.mb must be set to 0.
#host.reserved.mem.mb=1024

# The model of Watchdog timer to present to the Guest.
# For all models refer to the libvirt documentation.
#vm.watchdog.model=i6300esb

# Action to take when the Guest/Instance is no longer notifying the Watchdog timer.
# For all actions refer to the libvirt documentation.
# Possible values: none | reset | poweroff
#vm.watchdog.action=none

# Automatically clean up iSCSI sessions not attached to any VM.
# Should be enabled for users using managed storage (for example solidfire).
# Should be disabled for users with unmanaged iSCSI connections on their hosts.
iscsi.session.cleanup.enabled=false

# The heartbeat update timeout (in ms).
# Depending on the use case, this timeout might need increasing/decreasing.
#heartbeat.update.timeout=60000

# The timeout (in seconds) to retrieve the target's domain id when migrating a VM with KVM.
#vm.migrate.domain.retrieve.timeout=10

# This parameter specifies if the host must be rebooted when something goes wrong with the heartbeat.
#reboot.host.and.alert.management.on.heartbeat.timeout=true

# Enables manually setting CPU's topology on KVM's VM.
#enable.manually.setting.cpu.topology.on.kvm.vm=true

# Manually sets the host CPU MHz, in cases where CPU scaling support detects the value is wrong.
#host.cpu.manual.speed.mhz=0

# Defines the location for Hypervisor scripts.
# The path defined in this property is relative.
# To locate the script, ACS first tries to concatenate
# the property path with "/usr/share/cloudstack-agent/lib/".
# If it fails, it will test each folder of the path,
# decreasing one by one, until it reaches root.
# If the script is not found, ACS will repeat the same
# steps concatenating the property path with "/usr/share/cloudstack-common/".
# The path defined in this property is relative
# to the directory "/usr/share/cloudstack-common/".
#hypervisor.scripts.dir=scripts/vm/hypervisor

# Defines the location for KVM scripts.
# The path defined in this property is relative.
# To locate the script, ACS first tries to concatenate
# the property path with "/usr/share/cloudstack-agent/lib/".
# If it fails, it will test each folder of the path,
# decreasing one by one, until it reaches root.
# If the script is not found, ACS will repeat the same
# steps concatenating the property path with "/usr/share/cloudstack-common/".
# The path defined in this property is relative
# to the directory "/usr/share/cloudstack-common/".
#kvm.scripts.dir=scripts/vm/hypervisor/kvm

# Specifies start MAC address for private IP range.
#private.macaddr.start=00:16:3e:77:e2:a0

# Specifies start IP address for private IP range.
#private.ipaddr.start=192.168.166.128

# Defines Local Bridge Name.
#private.bridge.name=

# Defines private network name.
#private.network.name=

# Defines the location for network scripts.
# The path defined in this property is relative.
# To locate the script, ACS first tries to concatenate
# the property path with "/usr/share/cloudstack-agent/lib/".
# If it fails, it will test each folder of the path,
# decreasing one by one, until it reaches root.
# If the script is not found, ACS will repeat the same
# steps concatenating the property path with "/usr/share/cloudstack-common/".
# The path defined in this property is relative
# to the directory "/usr/share/cloudstack-common/".
#network.scripts.dir=scripts/vm/network/vnet

# Defines the location for storage scripts.
# The path defined in this property is relative.
# To locate the script, ACS first tries to concatenate
# the property path with "/usr/share/cloudstack-agent/lib/".
# If it fails, it will test each folder of the path,
# decreasing one by one, until it reaches root.
# If the script is not found, ACS will repeat the same
# steps concatenating the property path with "/usr/share/cloudstack-common/".
# The path defined in this property is relative
# to the directory "/usr/share/cloudstack-common/".
#storage.scripts.dir=scripts/storage/qcow2

# Time (in seconds) to wait for the VM to shutdown gracefully.
# If the time is exceeded shutdown will be forced.
#stop.script.timeout=120

# Definition of VMs video model type.
#vm.video.hardware=

# Definition of VMs video, specifies the amount of RAM in kibibytes (blocks of 1024 bytes).
#vm.video.ram=0

# System VM ISO path.
#systemvm.iso.path=

# If set to "true", allows override of the properties: private.macaddr.start, private.ipaddr.start, private.ipaddr.end.
#developer=false

# Can only be used if property developer = true. This property is used to define the link local bridge name and private network name.
#instance=

# Shows the path to the base directory in which NFS servers are going to be mounted.
#mount.path=/mnt

# Port listened by the console proxy.
#consoleproxy.httpListenPort=443

#ping.retries=5

# The number of iothreads. There should be only 1 or 2 IOThreads per VM CPU (default is 1). The recommended number of iothreads is 1
# iothreads=1
EOM

#change the root password
echo "Enter the new password for the root user: "
sudo passwd root
