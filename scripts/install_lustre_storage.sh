#!/bin/bash

set -x
#set -xeuo pipefail

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

if [ $# < 2 ]; then
    echo "Usage: $0 <ManagementHost> <adminuser> <index>"
    exit 1
fi


MGMT_HOSTNAME=$1
OSS_INDEX=$2
TEMPLATELINK=$3
echo "MGS - $MGMT_HOSTNAME Index - $OSS_INDEX and templatelink - $TEMPLATELINK"

# Shares
SHARE_HOME=/share/home
SHARE_SCRATCH=/share/scratch
#if [ -n "$3" ]; then
#	SHARE_SCRATCH=$3
#fi

LUSTRE_STORAGE=/mnt/oss

# User
HPC_USER=hpcuser
HPC_UID=7007
HPC_GROUP=hpc
HPC_GID=7007


# Installs all required packages.
#
install_pkgs()
{
    yum -y install epel-release
    yum -y install zlib zlib-devel bzip2 bzip2-devel bzip2-libs openssl openssl-devel openssl-libs gcc gcc-c++ nfs-utils rpcbind mdadm wget python-pip openmpi openmpi-devel automake autoconf
}
setup_raid()
{
	#Update system and install mdadm for managing RAID
	yum clean all && yum update
	yum install mdadm -y

	#Verify attached data disks
	ls -l /dev | grep sd

	#Examine data disks
	mdadm --examine /dev/sd[c-l]

	#Create RAID md device
	mdadm -C /dev/md0 -l raid0 -n 10 /dev/sd[c-l]
}
setup_user()
{
    mkdir -p $SHARE_HOME
    mkdir -p $SHARE_SCRATCH

	echo "$MGMT_HOSTNAME:$SHARE_HOME $SHARE_HOME    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
	mount -a
	mount
   
    groupadd -g $HPC_GID $HPC_GROUP

    # Don't require password for HPC user sudo
    echo "$HPC_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
    
    # Disable tty requirement for sudo
    sed -i 's/^Defaults[ ]*requiretty/# Defaults requiretty/g' /etc/sudoers

	useradd -c "HPC User" -g $HPC_GROUP -d $SHARE_HOME/$HPC_USER -s /bin/bash -u $HPC_UID $HPC_USER

    chown $HPC_USER:$HPC_GROUP $SHARE_SCRATCH	
}

install_lustre_repo()
{
    # Install Lustre repo
    wget -O LustrePack.repo $TEMPLATELINK/LustrePack.repo
    mv LustrePack.repo /etc/yum.repos.d/LustrePack.repo
}

install_lustre()
{
	 yum -y install kernel-3.10.0-514.el7_lustre.x86_64
     yum -y install lustre-2.9.0-1.el7.x86_64
     yum -y install kmod-lustre-2.9.0-1.el7.x86_64
     yum -y install kmod-lustre-osd-ldiskfs-2.9.0-1.el7.x86_64
     yum -y install lustre-osd-ldiskfs-mount-2.9.0-1.el7.x86_64
     yum -y install e2fsprogs
     yum -y install lustre-tests-2.9.0-1.el7.x86_64

     echo �options lnet networks=tcp�> /etc/modprobe.d/lnet.conf
     chkconfig lnet --add
     chkconfig lnet on
     chkconfig lustre --add
     chkconfig lustre on
}

setup_lustrecron()
{
SETUP_L=/root/lustre.setup
cat <<EOF>/root/installlustre.sh
#!/bin/bash
if [ -e "$SETUP_L" ]; then
	echo "We're already configured, exiting..."
	exit 0
fi
sudo mkfs.lustre --fsname=LustreFS --backfstype=ldiskfs --reformat --ost --mgsnode=$MGMT_HOSTNAME --index=$OSS_INDEX /dev/md0
mkdir /mnt/oss
sudo mount -t lustre /dev/md0 /mnt/oss
echo "/dev/md0 /mnt/oss lustre noatime,nodiratime,nobarrier,nofail 0 2" >> /etc/fstab
touch /root/lustre.setup
EOF
	chmod 700 /root/installlustre.sh
	crontab -l > lustrecron
	echo "@reboot /root/installlustre.sh >>/root/log.txt" >> lustrecron
	crontab lustrecron
	rm lustrecron
}

SETUP_MARKER=/var/local/install_lustre.marker
if [ -e "$SETUP_MARKER" ]; then
    echo "We're already configured, exiting..."
    exit 0
fi

systemctl stop firewalld
systemctl disable firewalld

# Disable SELinux
sed -i 's/SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
setenforce 0

install_pkgs
#setup_disks
setup_raid
setup_user
install_lustre_repo
install_lustre
setup_lustrecron
#download_lis
#install_lis_in_cron

# Create marker file so we know we're configured
touch $SETUP_MARKER

shutdown -r +1 &
exit 0
