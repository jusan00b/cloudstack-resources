#!/bin/bash

#[ToDo]:
#add virtualization support check
#add if else for it and also for user inputs
#Configure mysql and find a way to run mysql commands in a script
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

#Update the /etc/hosts file
sed -i '2a\'"$ip apache.$hostname.u1 $hostname" /etc/hosts
sudo hostnamectl set-hostname apache.$hostname.u1

#Install bridge-utils
sudo apt install bridge-utils -y

#Create a bridge br0
sudo brctl addbr br0
sudo brctl addif br0 $interface

#Configure the ethernet and bridge in network manager
netowrk_manager="/etc/netplan/01-network-manager-all.yaml"
/bin/cat <<EOM > "$netowrk_manager"
network:
  version: 2
  renderer: networkd
  ethernets:
    $interface:
      dhcp4: no
      dhcp6: no
  bridges:
    br0:
      interfaces: [$interface]
      dhcp4: no
      dhcp6: no
      addresses: [$ip/24]
      gateway4: $gateway
      nameservers:
	addresses: [8.8.8.8, 8.8.4.4]
EOM

#Apply the changes
sudo netplan apply
sudo systemctl restart NetworkManager

#Install the required packages
sudo apt install ntp -y
sudo apt install chrony -y
sudo apt install openjdk-11-jdk -y

#Add cloudstack management server repository to the sources list
echo "deb https://download.cloudstack.org/ubuntu jammy 4.18" | sudo tee /etc/apt/sources.list.d/cloudstack.list
wget -O - https://download.cloudstack.org/release.asc | sudo tee /etc/apt/trusted.gpg.d/cloudstack.asc
sudo apt update

#Install the cloudstack management server
sudo apt install cloudstack-management cloudstack-usage -y

#Install mysql server
sudo apt install mysql-server -y

#Configure the mysql server
echo "[mysqld]" >> /etc/mysql/my.cnf
echo "server-id=1" >> /etc/mysql/my.cnf
echo "innodb_rollback_on_timeout=1" >> /etc/mysql/my.cnf
echo "innodb_lock_wait_timeout=600" >> /etc/mysql/my.cnf
echo "max_connections=350" >> /etc/mysql/my.cnf
echo "log-bin=mysql-bin" >> /etc/mysql/my.cnf
echo "binlog-format = 'ROW'" >> /etc/mysql/my.cnf
sudo systemctl restart mysql
sudo mysql_secure_installation 

#Run the cloudstack management server setup
sudo cloudstack-setup-management
#allow the mysql port in the firewall
sudo ufw allow mysql

#Prepare NFS server
sudo mkdir -p /export/primary
sudo mkdir -p /export/secondary

echo "/export *(rw,async,no_root_squash,no_subtree_check)" >> /etc/exports
sudo apt install nfs-kernel-server -y
sudo systemctl restart nfs-kernel-server

sudo mkdir -p /mnt/primary
sudo mkdir -p /mnt/secondary

#Mount the NFS shares
sudo mount -t nfs $hostname:/export/primary /mnt/primary
sudo mount -t nfs $hostname:/export/secondary /mnt/secondary

#Install the cloudstack agent and kvm
sudo apt install qemu-kvm cloudstack-agent -y
sed -i -e 's/\#vnc_listen.*$/vnc_listen = "0.0.0.0"/g' /etc/libvirt/qemu.conf

#Configure the libvirtd
echo 'listen_tls = 0' >> /etc/libvirt/libvirtd.conf
echo 'listen_tcp = 1' >> /etc/libvirt/libvirtd.conf
echo 'tcp_port = "16509"' >> /etc/libvirt/libvirtd.conf
echo 'mdns_adv = 0' >> /etc/libvirt/libvirtd.conf
echo 'auth_tcp = "none"' >> /etc/libvirt/libvirtd.conf
systemctl restart libvirtd

#Disable the apparmor for libvirtd
ln -s /etc/apparmor.d/usr.sbin.libvirtd /etc/apparmor.d/disable/
ln -s /etc/apparmor.d/usr.lib.libvirt.virt-aa-helper /etc/apparmor.d/disable/
apparmor_parser -R /etc/apparmor.d/usr.sbin.libvirtd
apparmor_parser -R /etc/apparmor.d/usr.lib.libvirt.virt-aa-helper

#Check kvm status
lsmod | grep kvm
echo "kvm_intel 55496 0"
echo "kvm 337772 1 kvm_intel"
echo "kvm_amd # if you are in AMD cpu"
