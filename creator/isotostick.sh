#!/bin/bash
# Convert a live CD iso so that it's bootable off of a USB stick
# Copyright 2007  Red Hat, Inc.
# Jeremy Katz <katzj@redhat.com>
# 
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Library General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.


export PATH=/sbin:/usr/sbin:$PATH

usage() {
    echo "$0 <isopath> <usbstick device>"
    exit 1
}

cleanup() {
    [ -d $CDMNT ] && umount $CDMNT && rmdir $CDMNT
    [ -d $USBMNT ] && umount $USBMNT && rmdir $USBMNT
}

exitclean() {
    echo "Cleaning up to exit..."
    cleanup
    exit 1
}

getdisk() {
    DEV=$1

    p=$(udevinfo --query=path --name=$DEV)
    if [ -e /sys/$p/device ]; then
	device=$(basename /sys/$p)
    else
	device=$(basename $(readlink -f /sys/$p/../))
    fi
    if [ ! -e /sys/block/$device -o ! -e /dev/$device ]; then
	echo "Error finding block device of $DEV.  Aborting!"
	exitclean
    fi

    device="/dev/$device"
}

checkMBR() {
    getdisk $1

    bs=$(mktemp /tmp/bs.XXXXXX)
    dd if=$device of=$bs bs=512 count=1 2>/dev/null || exit 2
    
    mbrword=$(hexdump -n 2 $bs |head -n 1|awk {'print $2;'})
    rm -f $bs
    if [ "$mbrword" = "0000" ]; then
	echo "MBR appears to be blank."
	echo "You can add an MBR to this device with "
	echo "   # cat /usr/lib/syslinux/mbr.bin > $device"
	exitclean
    fi

    return 0
}

checkPartActive() {
    dev=$1
    getdisk $dev
    
    # if we're installing to whole-disk and not a partition, then we 
    # don't need to worry about being active
    if [ "$dev" = "$device" ]; then
	return
    fi

    if [ "$(/sbin/fdisk -l $device 2>/dev/null |grep $dev |awk {'print $2;'})" != "*" ]; then
	echo "Partition isn't marked bootable!"
	echo "You can mark the partition as bootable with "
        echo "    # /sbin/parted $device"
	echo "    (parted) toggle N boot"
	exitclean
    fi
}

checkFilesystem() {
    dev=$1

    USBFS=$(/lib/udev/vol_id -t $dev)
    if [ "$USBFS" != "vfat" -a "$USBFS" != "msdos" -a "$USBFS" != "ext2" -a "$USBFS" != "ext3" ]; then
	echo "USB filesystem must be vfat or ext[23]"
	exitclean
    fi

    USBLABEL=$(/lib/udev/vol_id -u $dev)
    if [ -n "$USBLABEL" ]; then 
	USBLABEL="UUID=$USBLABEL" ; 
    else
	USBLABEL=$(/lib/udev/vol_id -l $dev)
	if [ -n "$USBLABEL" ]; then 
	    USBLABEL="LABEL=$USBLABEL" 
	else
	    echo "Need to have a filesystem label or UUID for your USB device"
	    if [ "$USBFS" = "vfat" -o "$USBFS" = "msdos" ]; then
		echo "Label can be set with /sbin/dosfslabel"
	    elif [ "$USBFS" = "ext2" -o "$USBFS" = "ext3" ]; then
		echo "Label can be set with /sbin/e2label"
	    fi
	    exitclean
	fi
    fi
}

checkSyslinuxVersion() {
    if ! syslinux 2>&1 | grep -qe -d; then
	echo "Your syslinux is too old for this."
	exitclean
    fi
}

if [ $(id -u) != 0 ]; then 
    echo "You need to be root to run this script"
    exit 1
fi

if [ $# -ne 2 ]; then
    usage
fi

ISO=$1
USBDEV=$2

if [ ! -f $ISO ]; then
    usage
fi

if [ ! -b $USBDEV ]; then
    usage
fi

# FIXME: would be better if we had better mountpoints
CDMNT=$(mktemp -d /media/cdtmp.XXXXXX)
mount -o loop $ISO $CDMNT || exitclean
USBMNT=$(mktemp -d /media/usbdev.XXXXXX)
mount $USBDEV $USBMNT || exitclean

# do some basic sanity checks.  
checkSyslinuxVersion 
checkFilesystem $USBDEV
checkPartActive $USBDEV
checkMBR $USBDEV

trap exitclean SIGINT SIGTERM

if [ -d $USBMNT/syslinux -o -d $USBMNT/LiveOS ]; then
    echo "Already set up as live image.  Deleting old in fifteen seconds..."
    sleep 15

    rm -rf $USBMNT/syslinux $USBMNT/LiveOS
fi

echo "Copying live image to USB stick"
mkdir $USBMNT/syslinux $USBMNT/LiveOS
cp $CDMNT/squashfs.img $USBMNT/LiveOS/squashfs.img || exitclean 
cp $CDMNT/isolinux/* $USBMNT/syslinux/

echo "Updating boot config file"
# adjust label and fstype
sed -i -e "s/CDLABEL=[^ ]*/$USBLABEL/" -e "s/rootfstype=[^ ]*/rootfstype=$USBFS/" $USBMNT/syslinux/isolinux.cfg

echo "Installing boot loader"
if [ "$USBFS" = "vfat" -o "$USBFS" = "msdos" ]; then
    # syslinux expects the config to be named syslinux.cfg 
    # and has to run with the file system unmounted
    mv $USBMNT/syslinux/isolinux.cfg $USBMNT/syslinux/syslinux.cfg
    cleanup
    syslinux -d syslinux $USBDEV
elif [ "$USBFS" = "ext2" -o "$USBFS" = "ext3" ]; then
    # extlinux expects the config to be named extlinux.conf
    # and has to be run with the file system mounted
    mv $USBMNT/syslinux/isolinux.cfg $USBMNT/syslinux/extlinux.conf
    extlinux -i $USBMNT/syslinux
    cleanup
fi

echo "USB stick set up as live image!"