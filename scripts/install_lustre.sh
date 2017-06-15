#!/bin/bash

set -x
#set -xeuo pipefail

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

if [ $# < 2 ]; then
    echo "Usage: $0 <ManagementHost> <Type (meta,storage,both,client)> <Mount> <customDomain>"
    exit 1
fi

MGMT_HOSTNAME=`hostname`
NODE_TYPE="$2"

# Shares
SHARE_HOME=/share/home
SHARE_SCRATCH=/share/scratch
if [ -n "$3" ]; then
	SHARE_SCRATCH=$3
fi

METADATA=/mnt/mgsmds

# User
HPC_USER=hpcuser
HPC_UID=7007
HPC_GROUP=hpc
HPC_GID=7007

# Returns 0 if this node is the management node.
#
is_management()
{
    hostname | grep "$MGMT_HOSTNAME"
    return $?
}

is_metadatanode()
{
	if [ "$NODE_TYPE" == "meta" ]; then 
		return 0
	fi
	return 1
}

# Installs all required packages.
#
install_pkgs()
{
    yum -y install epel-release
    yum -y install zlib zlib-devel bzip2 bzip2-devel bzip2-libs openssl openssl-devel openssl-libs gcc gcc-c++ nfs-utils rpcbind mdadm wget python-pip openmpi openmpi-devel automake autoconf
}

# Partitions all data disks attached to the VM and creates
# a RAID-0 volume with them.
#
setup_data_disks()
{
    mountPoint="$1"
    filesystem="$2"
    devices="$3"
    raidDevice="$4"
    createdPartitions=""

    # Loop through and partition disks until not found
    for disk in $devices; do
        fdisk -l /dev/$disk || break
        fdisk /dev/$disk << EOF
n
p
1


t
fd
w
EOF
        createdPartitions="$createdPartitions /dev/${disk}1"
    done
    
    sleep 10

    # Create RAID-0 volume
    #if [ -n "$createdPartitions" ]; then
     #   devices=`echo $createdPartitions | wc -w`
        #mdadm --create /dev/$raidDevice --level 0 --raid-devices $devices $createdPartitions
        
      #  sleep 10
        
        #mdadm /dev/$raidDevice

        #if [ "$filesystem" == "xfs" ]; then
            #mkfs -t $filesystem /dev/$raidDevice
            #echo "/dev/$raidDevice $mountPoint $filesystem rw,noatime,attr2,inode64,nobarrier,sunit=1024,swidth=4096,nofail 0 2" >> /etc/fstab
        #else
            #mkfs.ext4 -i 2048 -I 512 -J size=400 -Odir_index,filetype /dev/$raidDevice
       #     sleep 5
            #tune2fs -o user_xattr /dev/$raidDevice
            #echo "/dev/$raidDevice $mountPoint $filesystem noatime,nodiratime,nobarrier,nofail 0 2" >> /etc/fstab
        #fi
        
        #sleep 10
        
        #mount /dev/$raidDevice
    #fi
}

setup_disks()
{      
    # Dump the current disk config for debugging
    fdisk -l
    
    # Dump the scsi config
    lsscsi
    
    # Get the root/OS disk so we know which device it uses and can ignore it later
    rootDevice=`mount | grep "on / type" | awk '{print $1}' | sed 's/[0-9]//g'`
    
    # Get the TMP disk so we know which device and can ignore it later
    tmpDevice=`mount | grep "on /mnt/resource type" | awk '{print $1}' | sed 's/[0-9]//g'`

    # Get the metadata and storage disk sizes from fdisk, we ignore the disks above
    metadataDiskSize=`fdisk -l | grep '^Disk /dev/' | grep -v $rootDevice | grep -v $tmpDevice | awk '{print $3}' | sort -n -r | tail -1`
    storageDiskSize=`fdisk -l | grep '^Disk /dev/' | grep -v $rootDevice | grep -v $tmpDevice | awk '{print $3}' | sort -n | tail -1`

    if [ "$metadataDiskSize" == "$storageDiskSize" ]; then
	
		# Compute number of disks
		nbDisks=`fdisk -l | grep '^Disk /dev/' | grep -v $rootDevice | grep -v $tmpDevice | wc -l`
		echo "nbDisks=$nbDisks"
		let nbMetadaDisks=nbDisks
		let nbStorageDisks=nbDisks
			
		if is_convergednode; then
			# If metadata and storage disks are the same size, we grab 1/3 for meta, 2/3 for storage
			
			# minimum number of disks has to be 2
			let nbMetadaDisks=nbDisks/3
			if [ $nbMetadaDisks -lt 2 ]; then
				let nbMetadaDisks=2
			fi
			
			let nbStorageDisks=nbDisks-nbMetadaDisks
		fi
		
		echo "nbMetadaDisks=$nbMetadaDisks nbStorageDisks=$nbStorageDisks"			
		
		metadataDevices="`fdisk -l | grep '^Disk /dev/' | grep $metadataDiskSize | awk '{print $2}' | awk -F: '{print $1}' | sort | head -$nbMetadaDisks | tr '\n' ' ' | sed 's|/dev/||g'`"
		storageDevices="`fdisk -l | grep '^Disk /dev/' | grep $storageDiskSize | awk '{print $2}' | awk -F: '{print $1}' | sort | tail -$nbStorageDisks | tr '\n' ' ' | sed 's|/dev/||g'`"
    else
        # Based on the known disk sizes, grab the meta and storage devices
        metadataDevices="`fdisk -l | grep '^Disk /dev/' | grep $metadataDiskSize | awk '{print $2}' | awk -F: '{print $1}' | sort | tr '\n' ' ' | sed 's|/dev/||g'`"
        storageDevices="`fdisk -l | grep '^Disk /dev/' | grep $storageDiskSize | awk '{print $2}' | awk -F: '{print $1}' | sort | tr '\n' ' ' | sed 's|/dev/||g'`"
    fi
    setup_data_disks $METADATA "ext4" "$metadataDevices" "md10"
}

install_lustre_repo()
{
    # Install Lustre repo
    wget -O LustrePack.repo https://raw.githubusercontent.com/azmigproject/Lustre/master/scripts/LustrePack.repo
    mv LustrePack.repo /etc/yum.repos.d/LustrePack.repo
    

}

install_lustre()
{     
	# setup metata data
    if is_metadatanode; then
		
        yum -y install kernel-3.10.0-514.el7_lustre.x86_64
        yum -y install lustre-2.9.0-1.el7.x86_64
        yum -y install kmod-lustre-2.9.0-1.el7.x86_64
        yum -y install kmod-lustre-osd-ldiskfs-2.9.0-1.el7.x86_64
        yum -y install lustre-osd-ldiskfs-mount-2.9.0-1.el7.x86_64
        yum -y install e2fsprogs
        yum -y install lustre-tests-2.9.0-1.el7.x86_64

        echo “options lnet networks=tcp”> /etc/modprobe.d/lnet.conf
        chkconfig lnet --add
        chkconfig lnet on
        chkconfig lustre --add
        chkconfig lustre on
        
        mkfs.lustre --fsname=LustreFS --mgs --mdt  --backfstype=ldiskfs --reformat /dev/sdc
        mkdir /mnt/mgsmds
        mount -t lustre /dev/sdc /mnt/mgsmds
		
		echo "/dev/sdc /mnt/mgsmds lustre noatime,nodiratime,nobarrier,nofail 0 2" >> /etc/fstab
	fi
}

setup_user()
{
    mkdir -p $SHARE_HOME
    mkdir -p $SHARE_SCRATCH

	echo "$MGMT_HOSTNAME:$SHARE_HOME $SHARE_HOME    nfs4    rw,auto,_netdev 0 0" >> /etc/exports
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

setup_lustrecron()
{
    cat >  /root/installlustre.sh << "EOF"
#!/bin/bash
SETUP_L=/root/lustresetup	.setup

if [ -e "$SETUP_L" ]; then
    #echo "We're already configured, exiting..."
    exit 0
fi
mkfs.lustre --fsname=LustreFS --mgs --mdt  --backfstype=ldiskfs --reformat /dev/sdc
mkdir /mnt/mgsmds
mount -t lustre /dev/sdc /mnt/mgsmds
echo "/dev/sdc /mnt/mgsmds lustre noatime,nodiratime,nobarrier,nofail 0 2" >> /etc/fstab
touch $SETUP_LIS
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

#systemctl stop firewalld
#systemctl disable firewalld

# Disable SELinux
sed -i 's/SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
setenforce 0

install_pkgs
setup_disks
setup_user
install_lustre_repo
install_lustre
setup_lustrecron

# Create marker file so we know we're configured
touch $SETUP_MARKER

shutdown -r +1 &
exit 0
