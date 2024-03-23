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
      br0:
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
sudo apt install qemu-kvm cloudstack-agent -y
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
