#!/bin/bash

set -x
#set -xeuo pipefail

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

if [ $# < 2 ]; then
    echo "Usage: $0 <ManagementHost>"
    exit 1
fi


MGMT_HOSTNAME=$1
echo "MGS - $MGMT_HOSTNAME"

# Shares
SHARE_HOME=/share/home
SHARE_SCRATCH=/share/scratch

LUSTRE_CLIENT=/mnt/lustre

# User
HPC_USER=hpcuser
HPC_UID=7007
HPC_GROUP=hpc
HPC_GID=7007


# Installs all required packages.
install_pkgs()
{
    yum -y install epel-release
    yum -y install zlib zlib-devel bzip2 bzip2-devel bzip2-libs openssl openssl-devel openssl-libs gcc gcc-c++ nfs-utils rpcbind mdadm wget python-pip openmpi openmpi-devel automake autoconf
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
    wget -O LustrePack.repo https://raw.githubusercontent.com/azmigproject/Lustre/master/scripts/LustrePack.repo
    mv LustrePack.repo /etc/yum.repos.d/LustrePack.repo
}

install_lustre()
{
	yum -y install kmod-lustre-client-2.9.0-1.el7.x86_64
	yum -y install lustre-client-2.9.0-1.el7.x86_64
	yum -y install lustre-client-dkms-2.9.0-1.el7.noarch --skip-broken
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
mkdir /mnt/lustre
mount -t lustre $MGMT_HOSTNAME@tcp:/LustreFS /mnt/lustre
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
setup_user
install_lustre_repo
install_lustre
setup_lustrecron

# Create marker file so we know we're configured
touch $SETUP_MARKER

shutdown -r +1 &
exit 0
