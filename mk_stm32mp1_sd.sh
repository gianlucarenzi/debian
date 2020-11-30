#!/bin/bash

# Copyright (c) 2020 Gianluca Renzi <gianlucarenzi@eurek.it>
#
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification,
# are permitted provided that the following conditions are met:
#
# o Redistributions of source code must retain the above copyright
#   notice, this list of conditions and the following disclaimer.
#
# o Redistributions in binary form must reproduce the above copyright
#   notice, this list of conditions and the following disclaimer in the
#   documentation and/or other materials provided with the distribution.
#
# o Neither the name of Eurek S.R.L. nor the names of
#   its contributors may be used to endorse or promote products derived
#   from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
# ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# This script prepares a SD card with a boot image for the STM32MP157-DK2
# Requires the root file system with a valid stm32mp157 boot streams
#
# Modification History
#
#

# ERRORCODES
# ----------
# 1 EUSAGE
# 2 EBOARD
# 3 ESTORAGE
# 4 EFILESYS
# 5 EEXT4FORM
# 6 EFSCKEXT2
# 7 ETUNE2FS
# 8 ENILFS2FORM
# 9 EF2FSFORM
#10 EUUIDBOOT
#11 EUUIDSETBOOT
#12 EUUIDSETNILFS2
#13 EFILESYSINST
#14 EIMAGEINSTALL
#15 EMKIMAGEMISSING
#16 ECREATEIMAGE
#17 EEXT3FORMIMAGE
#18 EMOUNTIMAGE
#19 ENOSUPP
#20 EMBRERASE
#21 EMOUNTDEV
#

opt=''

DEBUG=
use_hab=0
require_unmounted=1
dont_ask=1
bootlets_fsl_in_use=0
raw_mode=0
install_fs=0
use_rootfs_filesystem=0
put_barebox=1
erase_mbr=0
create_mbr=0
app_name="bootstream"
raw_name="boot-barebox"
ivt=""
board_type=0
DO_LINUX=0
UUID=""
format_rootfs=0
format_home=0
format_boot=0
create_image=0
DO_REAL_INSTALL=0
SUDO="sudo"
verbose=0
restore_board_config=0
restore_splash_png=0
restore_anim_png=0
restore_init_board=0
restore_lcd_config=0
DEFAULT_IMAGE_DISK_SIZE_MB=3500
disk_image_size_requested=0
DEFAULT_VIRTUAL_DISK_IMAGE_SIZE_MB="3600M"
virtual_image_size_requested=0
patchset_exec="data/patchset-install.sh"
netif="data/prod-network-interface"
MACHINENAME=`uname -n`
CONFIG_BAK=/tmp/board-config.bak
SPLASH_BAK=/tmp/splash.png.bak
ANIM_BAK=/tmp/anim.png.bak
INIT_BAK=/tmp/init-board.bak
LCDCONFIG_BAK=/tmp/lcd-config.bak
tempmount_boot=/tmp/zzzsdcard_boot
tempmount_root=/tmp/zzzsdcard
tempmount_image=/tmp/zzzimage
# during rootfs install this file will contain the percentage of
# installation
progress=/tmp/progress
rs485_configured=0
DEFAULT_RS485_DEVICE="/dev/ttyAMA0"
HAS_RS485_DRIVER_DEFAULT="no"
skip_autobuild_requested=0
skip_autobuild=0

function ansi_red()
{
	echo -n -e '\x1b[31m'
}

function ansi_green()
{
	echo -n -e '\x1b[32m'
}

function ansi_yellow()
{
	echo -n -e '\x1b[33m'
}

function ansi_reset()
{
	echo -n -e '\x1b[0m'
}

function error() {
	MSG=$1
	ansi_red
	echo $MSG " ## ERROR ##"
	ansi_reset
}

function alert() {
	MSG=$1
	ansi_red
	echo "#### $MSG ####"
	ansi_reset
}

function warning() {
	MSG=$1
	ansi_yellow
	echo "#### $MSG ####"
	ansi_reset
}

# This function tests to see if the given device $1 is
# mounted, as shown in /etc/mtab.
# Return value $bMounted==1 if mounted, zero otherwise.
function is_mounted() {
	if [ "$(grep "$1" /etc/mtab; true)" == "" ]; then
		# not mounted
		bMounted=0
	else
		# mounted
		bMounted=1
	fi
}


function found_bootdev()
{
	BOOT=`cat /proc/cmdline`
	idx=1
	toinstall=$1

	for step in $BOOT
	do
		# find boot device from kernel cmdline
		cmd=`echo $step | cut -f $idx -d ' '`
		assignment=`echo $cmd | grep '='`
		if [ "$assignment" != "" ]; then
			is_root=`echo $assignment | grep root`
			if [ "$is_root" != "" ]; then
				uuid=`echo $is_root | grep UUID`
				if [ "$uuid" != "" ]; then
					uuid_disk=`echo $uuid | cut -f 3 -d '='`
					uuid=1
				else
					bDisk=`echo $is_root | cut -f 2 -d '='`
					uuid=0
				fi

			fi
		fi
		idx=$(($idx+1))
	done

	# if uuid root find out the hard disk device
	if [ $uuid -eq 1 ]; then
		idx=1
		while [ 1 ];
		do
			bDisk=`ls -l /dev/disk/by-uuid/$uuid_disk | tail -c $idx`
			# Looking for '/' for finding the device name
			slash=`echo $bDisk | grep '/'`
			if [ "$slash" == "" ]; then
				idx=$(($idx+1))
			else
				bDisk=`ls -l /dev/disk/by-uuid/$uuid_disk | tail -c $(($idx-1))`
				break
			fi
		done
	fi

	bDisk="/dev/$bDisk"

	# Now we can check if the device to write to is which we are
	# running from
	bootDevice=`echo $bDisk | grep $toinstall`
	if [ "$bootDevice" == "" ]; then
		# We can install
		bootDisk=0
	else
		bootDisk=1
	fi
}


function get_environment()
{
	# Device name in real installation
	[ -z "$BOARD_CONFIG" ] && BOARD_CONFIG=board.conf
	[ ! -e $BOARD_CONFIG ] && echo "ERROR: Config file ($BOARD_CONFIG) not found!" && exit 1
	. $BOARD_CONFIG
}

function print_usage() {
	echo "Usage: $0 [-hndxbfrzZFvLBIVSQ] /dev/sd#"
	echo "where /dev/sd# is a valid devnode for the SD/eMMC card."
	echo
	echo "         -h    Help.  (This information.)"
	echo "         -n    Do nothing. Just echo intended actions."
	echo "         -d    Use HAB disabled boot images."
	echo "         -x    Enable expert mode (see below)."
	echo "         -k    Do ask to proceed further."
	echo "         -b    Enable bootlets FSL mode (see below)."
	echo "         -f    Enable rootfs filesystem mode."
	echo "         -r    Enable RAW MODE bootstream."
	echo "         -z    Erase Disk MBR."
	echo "         -Z    Create Disk MBR."
	echo "         -F    Install FileSystem."
	echo "         -v    Format / RootFileSystem."
	echo "         -L    Install Linux & DTB on the boot partition"
	echo "         -B    Specify board type: EK330 - EK340 - EK350 - MX28EVK - EK380 - EK420 - EK422"
	echo "         -I    Create image instead of write sdcard"
	echo "         -V    Setting verbose mode ON (default OFF)"
	echo "         -S    Size of disk image to write (default 750 MB)"
	echo "         -Q    Use QEMU tools to build a virtual disk image (default 2Gb)"
	echo "         -s    Skip install autobuild tools (default: no)"
	echo
	echo "This utility uses sudo to: "
	echo
	echo "  1. erase the GPT on the given /dev/sd#"
	echo "  2. repartitions the device as required to boot the"
	echo "     stm32mp1 from sd media"
	echo "  3. installs the boot streams, kernel, /boot and root"
	echo "     filesystem to the sd card"
	echo
	echo "Notes:"
	echo "This script will refuse to work on /dev/sda, which is "
	echo "usually a hard disk.This script will refuse to work on any"
	echo "medium which is ALREADY MOUNTED when the script starts."
	echo "Therefore, start the script, then insert the card"
	echo "(when asked if you want to continue)."
	echo "Expert mode causes the script to run even if the device"
	echo "is already mounted, and will not ask if you want to continue."
}

function do_dtb() {
	if [ $DO_REAL_INSTALL -eq 0 ]; then
		BOARD=$1
		dtb_name="pendisk-${BOARD}/dtb-${BOARD}.bin"
		case $BOARD in
			STM32MP157DK2)
					;;
			*)
					#
					error "Need a valid BOARDNAME, no ${BOARD}"
					exit 2
					;;
		esac
		# Check if the dtb file is really present
		if [ ! -f $dtb_name ]; then
			error "DTB $dtb_name is not present"
			exit 2
		fi
	fi
	echo "** dtb: $dtb_name for BOARD: $BOARD"
}

function emmc_prepare() {
	DEVICENAME=$1
	WRITE_RELIABILITY=`mmc extcsd read $DEVICENAME | grep 'WR_REL_SET]:' | cut -f2 -d ':' | awk '{ print $1 }'`
	if [ $? -ne 0 ]; then
		warning "No /usr/local/bin/mmc COMMAND. WRITING on eMMC is NOT POWERFAIL PRONE"
	else
		# We have mmc command in the system! MUST BE 0x1f [31 dec] (all partitions powerfail safe)
		if [ "$WRITE_RELIABILITY" != "0x1f" ]; then
			warning "eMMC partitions WR_REL_SET are not ready"
			alert "Setting WR_REL_SET for all partitions"
			$DEBUG $SUDO mmc write_reliability set_register 31 $DEVICENAME
			if [ $? -eq 0 ]; then
				ansi_green
				echo "eMMC partitions are POWERFAIL PRONE"
				ansi_reset
			else
				# Proseguiamo in ogni caso, segnalando l'errore
				error "WR_REL_SET"
			fi
		else
			ansi_green
			echo "eMMC User partition is ready WR_REL_SET OK"
			ansi_reset
		fi
	fi
}

#function emmc_rootfs_calculate_size() {
#	DEVICENAME=`echo $1 | rev | cut -f1 -d '/' | rev`
#	SMALL_EMMC=`dmesg | grep '$DEVICENAME' | grep MMC02G`
#	if [ "{SMALL_EMMC}" = "" ];
#	then
#		# LARGE eMMC
#		# 512 bytes/block = 2.5Gb
#		PARTSIZE=5120000
#	else
#		# SMALL eMMC
#		# 512 bytes/block = 1.4Gb
#		PARTSIZE=2867200
#	fi
#	PARTSTART=$(($PARTSIZE+90112+1))
#	# Ora possiamo gestire le due variabili globali PARTSIZE e PARTSTART
#}

#
#GPT fdisk (gdisk) version 1.0.3
#
#Partition table scan:
#  MBR: protective
#  BSD: not present
#  APM: not present
#  GPT: present
#
#Found valid GPT with protective MBR; using GPT.
#
#Disk sd-dk1.img: 2097152 sectors, 1024.0 MiB
#Sector size (logical): 512 bytes
#Disk identifier (GUID): C0509DC0-DEDE-4A34-BC78-CBA83110718A
#Partition table holds up to 128 entries
#Main partition table begins at sector 2 and ends at sector 33
#First usable sector is 34, last usable sector is 2097118
#Partitions will be aligned on 2048-sector boundaries
#Total free space is 5086 sectors (2.5 MiB)
#
#Number  Start (sector)    End (sector)  Size       Code  Name
#   1            2048            2559   256.0 KiB   8301  fsbl1
#   2            4096            4607   256.0 KiB   8301  fsbl2
#   3            6144           10239   2.0 MiB     8301  ssbl
#   4           10240           75775   32.0 MiB    8300  boot
#   5           75776         2097118   987.0 MiB   8300  rootfs
#
#
# per part#4 considerare -o ro (/boot)
# per part#5 considerare data=journal, data=writeback, data=ordered
#
# $1 contains the name of the device to partition.
function make_nominal_partition() {
	emmc_prepare $1
	GDISK=`which gdisk`
	if [[ $DEBUG ]] ;
	then
		WRITE=q
	else
		WRITE=w
	fi
echo "n


+256K
8301
c
fsbl1
n


+256K
8301
c
2
fsbl2
n


+2M
8301
c
3
ssbl
n



8300
c
4
rootfs
p
$WRITE
Y
" | $SUDO $GDISK $1
}

function wipe_partition_table() {
	# Erasing existing MBR
	$DEBUG $SUDO dd if=/dev/zero of=$1 count=1 bs=4096
}

# This function installs the raw boot stream named in $1
# into the device partition $2.
function install_raw_boot_stream() {
	echo -n "Installing boot stream $1 on $2..."
#	$DEBUG $SUDO dd if=$1 of=$2 ibs=512 obs=512 conv=sync
#	if [ $? -ne 0 ]; then
#		error "Installing bootstream RAW"
#		exit 3
#	fi
	$DEBUG $SUDO sync
	echo -n "Read back boot stream for later use..."
#	$DEBUG $SUDO dd if=$2 of=bootstream_raw_saved.dat obs=512 conv=sync
#	if [ $? -ne 0 ]; then
#		error "Reading back boot stream"
#		exit 3
#	fi
	echo "...finished installing boot stream on $2."
}

# This function installs the boot stream named in $1
# into the device partition $2.
function install_boot_stream() {
	echo -n "Installing boot stream $1 on $2..."
#	STARTSECTOR=`$SUDO fdisk -lu $2|awk '$5==53 {print $2}'`
#	echo -n "Bootstream partition starting @ ${STARTSECTOR} "
#	$DEBUG ./mk_hdr.sh $STARTSECTOR 1 > temp.bin
#	$DEBUG $SUDO dd if=temp.bin of=$2 ibs=512 conv=sync 1>/dev/null 2>/dev/null
#	if [ $? -ne 0 ]; then
#		error "install_boot_stream (1)"
#		exit 3
#	fi
#	$DEBUG $SUDO dd if=$1 of=$2 ibs=512 obs=512 seek=1 conv=sync 1>/dev/null 2>/dev/null
#	if [ $? -ne 0 ]; then
#		error "install_boot_stream (2)"
#		exit 3
#	else
#		ansi_green
#		echo "Ok"
#		ansi_reset
#	fi
	$DEBUG $SUDO sync
#	echo -n "Read back boot stream for later use..."
#	$DEBUG $SUDO dd if=$2 of=bootstream_saved.dat obs=512 conv=sync 1>/dev/null 2>/dev/null
#	if [ $? -ne 0 ]; then
#		echo "install_boot_stream (3)"
#		exit 3
#	fi
	echo "...finished installing boot stream on $2."
}

function install_boot_stream_system() {
#	if [ $raw_mode -eq 1 ]; then
#		echo -n "Bootstream raw mode... $sb_raw_name in filesystem"
#		SBNAME=$sb_raw_name
#	else
#		echo -n "Bootstream... $sb_name in filesystem"
#		SBNAME=$sb_name
#	fi
#	echo -n " into $1 folder..."
#	$DEBUG $SUDO cp $SBNAME $1 1>/dev/null 2>/dev/null
#	if [ $? -ne 0 ]; then
#		error "install_boot_stream_system"
#		exit 4
#	fi
	ansi_green
	echo "Ok."
	ansi_reset
}

function set_uuid_boot()
{
	echo "Setting UUID for next use in /boot partition..."
	# UUID is globally defined, starting empty then after formatting
	# setting to this static uuid value (uuidgen generated)
	UUID="94578d91-6cd2-401d-b172-a1c4292a3845"
}

function format_disk_ext4() {
	echo -n "Formatting partition $1..."
	$DEBUG $SUDO mkfs.ext4 $1 1>/dev/null 2>/dev/null
	if [ $? -ne 0 ]; then
		error "format_disk_ext4"
		exit 5
	else
		ansi_green
		echo "Ok."
		ansi_reset
	fi
	# Needed for compatibility Debian Wheezy on kernel 3.12!
	# So it can be used in latest kernel!
	$DEBUG $SUDO tune2fs -O ^metadata_csum,^64bit $1 1>/dev/null 2>/dev/null
}

function disabling_journaling_ext4() {
	echo -n "Disabling Journaling on ext4 filesystem partition $1..."
	$DEBUG $SUDO tune2fs -O ^has_journal $1 1>/dev/null 2>/dev/null
	if [ $? -ne 0 ]; then
		error "tune2fs"
		exit 7
	else
		ansi_green
		echo "Ok."
		ansi_reset
	fi
}

function format_disk_nilfs2() {
	echo -n "Formatting NILFS2 partition $1..."
	$DEBUG $SUDO mkfs.nilfs2 -f -O block_count $1 1>/dev/null 2>/dev/null
	if [ $? -ne 0 ]; then
		warning "Retry without [-f] flag..."
		# Could be an older version of mkfs.nilfs2 without -f [force]
		# support. so try another time without -f flag
		$DEBUG $SUDO mkfs.nilfs2 -O block_count $1 1>/dev/null 2>/dev/null
		if [ $? -ne 0 ]; then
			error "mkfs.nilfs2"
			exit 8
		fi
	else
		ansi_green
		echo "Ok."
		ansi_reset
	fi
}


function create_rootfs_fstab() {
	lUUID=$2
	if [ "$lUUID" == "" ]; then
		ansi_yellow
		echo "Need UUID for /boot partition."
		ansi_reset
		exit 10
	fi
	echo "# /etc/fstab: static filesystem information table." > $1
	echo "#" >> $1
	echo "# Use 'blkid' to print the universally unique identifier for a" >> $1
	echo "# device; this may be used with UUID= as a more robust way " >> $1
	echo "# to name devices" >> $1
	echo "# that works even if disks are added and removed. See fstab(5)." >> $1
	echo "#" >> $1
	echo "# <file system> <mount point>   <type>  <options>       <dump>  <pass>" >> $1
	echo "" >> $1
	echo "# rootfs /dev/root will be mounted with noatime flag" >> $1
	if [ "$ROOTFS_FILESYSTEM_TYPE" = "ext4" ];
	then
		echo "/dev/root / ext4  nodelalloc,noatime,nodiratime,rw,errors=remount-ro 0 0" >> $1
	else
		# Default to NILFS
		if [ "$NILFS2_KERNEL_PATCH_INSTALL" = "yes" ];
		then
			echo "/dev/root / nilfs2  noatime,nodiratime,rw,bad_ftl,errors=remount-ro 0 0" >> $1
		else
			echo "/dev/root / nilfs2  noatime,nodiratime,rw,errors=remount-ro 0 0" >> $1
		fi
	fi
	echo "" >> $1
	echo "# /boot" >> $1
	echo "UUID=$lUUID /boot ext4 ro 0 0" >> $1
	echo "" >> $1
	echo "# VIRTUAL Filesystems /proc and /sys can be writable" >> $1
	echo "proc /proc proc defaults 0 0" >> $1
	echo "" >> $1
	echo "# Needed to be writeable by OS services (those are lost " >> $1
	echo "# between reboots)" >> $1
	echo "tmpfs /run tmpfs defaults 0 0" >> $1
	echo "tmpfs /var/lock tmpfs defaults 0 0" >> $1
	echo "tmpfs /var/log tmpfs defaults 0 0" >> $1
	echo "tmpfs /media tmpfs defaults 0 0" >> $1
	echo "" >> $1
	echo "# Temporary files go here..." >> $1
	echo "tmpfs /tmp tmpfs defaults 0 0" >> $1
}

function create_rootfs_fstab_ro() {
	lUUID=$2
	if [ "$lUUID" == "" ]; then
		ansi_yellow
		echo "Need UUID for /boot partition."
		ansi_reset
		exit 10
	fi
	echo "# /etc/fstab: static filesystem information table." > $1
	echo "#" >> $1
	echo "# Use 'blkid' to print the universally unique identifier for a" >> $1
	echo "# device; this may be used with UUID= as a more robust way " >> $1
	echo "# to name devices" >> $1
	echo "# that works even if disks are added and removed. See fstab(5)." >> $1
	echo "#" >> $1
	echo "# <file system> <mount point>   <type>  <options>       <dump>  <pass>" >> $1
	echo "" >> $1
	echo "# rootfs /dev/root will be mounted with noatime flag" >> $1
	if [ "$ROOTFS_FILESYSTEM_TYPE" = "ext4" ];
	then
		echo "/dev/root / ext4  nodelalloc,noatime,nodiratime,ro,errors=remount-ro 0 0" >> $1
	else
		# Default to nilfs2
		if [ "$NILFS2_KERNEL_PATCH_INSTALL" = "yes" ];
		then
			echo "/dev/root / nilfs2  noatime,nodiratime,ro,bad_ftl,errors=remount-ro 0 0" >> $1
		else
			echo "/dev/root / nilfs2  noatime,nodiratime,ro,errors=remount-ro 0 0" >> $1
		fi
	fi
	echo "" >> $1
	echo "# /boot" >> $1
	echo "UUID=$lUUID /boot ext4 ro 0 0" >> $1
	echo "" >> $1
	echo "# VIRTUAL Filesystems /proc and /sys can be writable" >> $1
	echo "proc /proc proc defaults 0 0" >> $1
	echo "" >> $1
	echo "# Needed to be writeable by OS services (those are lost " >> $1
	echo "# between reboots)" >> $1
	echo "tmpfs /run tmpfs defaults 0 0" >> $1
	echo "tmpfs /var/lock tmpfs defaults 0 0" >> $1
	echo "tmpfs /var/log tmpfs defaults 0 0" >> $1
	echo "tmpfs /media tmpfs defaults 0 0" >> $1
	echo "" >> $1
	echo "# Temporary files go here..." >> $1
	echo "tmpfs /tmp tmpfs defaults 0 0" >> $1
}

function set_uuid_disk_ext4() {
	echo -n "Checking filesystem $2..."
	$DEBUG $SUDO e2fsck -y -f $2
	# e2fsck restituisce:
	# 0 - Tutto ok
	# 1 - FileSystem corretto automaticamente e tutto ok
	# ??? - Altri errori
	lrvale2fsck=$?
	if [ $lrvale2fsck -eq 0 ] || [ $lrvale2fsck -eq 1 ]; then
		echo -n "Setting UUID = $1 for disk (EXT4) $2..."
		$DEBUG $SUDO tune2fs -U $1 $2 1>/dev/null 2>/dev/null
		ansi_green
		echo "Ok."
		ansi_reset
	else
		error "E2FSCK Error"
		exit 11
	fi
}

function rs485_prepare()
{
	case $BOARD in
		STM32MP157DK2)
			;;
		*)
			#
			error "Need a valid BOARDNAME, no ${BOARD}"
			exit 2
			;;
	esac
}

function rs485_activate_tx()
{
	# Disable rx
	echo 1 > $RXEN
	# Enable tx
	echo 1 > $TXEN
}

function rs485_activate_rx()
{
	# Enable rx
	echo 0 > $RXEN
	# Disable tx
	echo 0 > $TXEN
}

function rs485_flush()
{
	DEVICE=$1
	stty -F $DEVICE flush 0
	stty -F $DEVICE flush 1
	stty -F $DEVICE flush 0
	stty -F $DEVICE flush 1
}

function rs485_send_string()
{
	DEVICE=$1
	STR=$2
	stty -F $DEVICE ispeed 9600 ospeed 9600
	rs485_activate_tx
	echo $STR > $DEVICE
}

function rs485_receive_string()
{
	DEVICE=$1
	stty -F $DEVICE ispeed 9600 ospeed 9600
	rs485_activate_rx
	read -t 60 rx < $DEVICE
	if [ $? -eq 0 ]; then
		echo $rx
	else
		# Abbiamo letto male o nulla...
		echo "!ERR!"
	fi
}

function setprogress()
{
	val=$1
	echo $val > $progress

	# Sulla scheda reale notifichiamo anche sulla seriale RS485
	# lo stato dell'avanzamento percentuale
	if [ $DO_REAL_INSTALL -eq 1 ]; then
		# Se siamo in recovery, allora non trasmettiamo nulla
		# sulla RS485, in quanto potremmo essere installati
		# sulla macchina reale, e queste stringhe potrebbero disturbare
		# le schede connesse...
		if [ $restore_board_config -eq 0 ]; then
			if [ $rs485_configured -eq 0 ]; then
				rs485_prepare
				rs485_flush $RS485_DEVICE
				rs485_configured=1
			fi
			rs485_send_string $RS485_DEVICE $val
		fi
	fi
}

# This function will install rootfilesystem into board and will
# give back the percentage of installation depending on how big the
# filesystem is...
function do_install_fs_root()
{
	SOURCE=$1
	DEST=$2
	VERBOSE=$3
	USE_RSYNC=$4

	if [ "$VERBOSE" == "verbose" ]; then
		V="v"
	else
		V=""
	fi

	if [ $use_rsync -eq 1 ]; then
		$DEBUG $SUDO rsync -a$V $SOURCE/ $DEST
	else
		$DEBUG $SUDO cp -Rpa$V $SOURCE/* $DEST
	fi

	# Check the error code of rsync or cp command
	if [ $? -ne 0 ]; then
		error "Error installing rootfs!"
		exit 13
	else
		# Trigger the ending of the installation
		touch /tmp/install_done
	fi
}

function do_install_fs_get_size()
{
	FOLDER=$1
	rval=`df -k $FOLDER | tail -1 | tr -s ' ' | cut -f3 -d ' '`
	echo $rval
}

# This function installs the rootfs directory named in $1
# into the mount point named in $2
function install_fs_rootfs() {
	if [ $verbose -eq 1 ]; then
		V="verbose"
	else
		V="silent"
	fi

	source=$1
	dest=$2
	boost=$3
	warning "Calculating source disk usage...Wait"
	ssize=`du -k -s -D ${source} 2>/dev/null|cut -f1 -d '/'`
	case "$INSTALL_METHOD" in
		RSYNC)	#
				use_rsync=1
				;;
		COPY)	#
				use_rsync=0
				;;
		*)		#
				error "Unknown method of installation >> $INSTALL_METHOD <<"
				exit 14
				;;
	esac

	# Erase triggering for starting purposes
	if [ -f /tmp/install_done ]; then
		rm /tmp/install_done
	fi

	if [ "$boost" == "boost" ]; then
		alert "SOURCE:$source (size: $ssize (Kbytes)) DEST:$dest -$V mode- with $INSTALL_METHOD BOOST"
		boostinstall=1
	else
		alert "SOURCE:$source (size: $ssize (Kbytes)) DEST:$dest -$V mode- with $INSTALL_METHOD"
		boostinstall=0
	fi

	# Preleviamo dal file di configurazione (se esiste) la variabile
	# del nome della seriale RS485, altrimenti il fallback e` su
	# $DEFAULT_RS485_DEVICE
	get_environment
	if [ "$RS485_DEVICE" == "" ]; then
		alert "RS485_DEVICE not found. Fallback to $DEFAULT_RS485_DEVICE"
		RS485_DEVICE=$DEFAULT_RS485_DEVICE
	else
		warning "RS485_DEVICE is $RS485_DEVICE"
	fi
	if [ "$HAS_RS485_DRIVER" == "" ]; then
		alert "This board has no RS485 Driver"
		HAS_RS485_DRIVER=$HAS_RS485_DRIVER_DEFAULT
	else
		warning "This board has RS485 Driver Installed"
	fi

	if [ $boostinstall -eq 0 ]; then
		# Put the installation procedure in background with '&' command
		# while this code will wait until the system is fully installed.
		do_install_fs_root $source $dest $V $use_rsync &

		# Start at 0%
		pct_has_changed=0

		# Loop until done
		while [ 1 ];
		do
			# Get the percentage of installation looking at the
			# drive space from image and the destination device
			dsize=$(do_install_fs_get_size $dest)
			pct=$(((100*$dsize)/$ssize))
			if [ $pct -lt 100 ]; then
				# Due to filesystem storage allocation and reserved
				# space, there is some mismatch between the single-file
				# total length and the disk space usage, so the percentage
				# can be little higher than 100% (up to 5%)...
				# So stop update progress if near the end of process...
				setprogress $pct
				#echo $pct > $progress
			fi
			# Trigger to stop while - do - loop
			# /tmp/install_done is created by the background function
			# do_install_fs_root
			if [ -f /tmp/install_done ]; then
				sync
				sleep 1
				setprogress 100
				#echo 100 > $progress
				break
			else
				# The install process is running, do nothing as much as
				# possible, so higher the number of sleeps, higher the
				# cpu power to do installation.
				sleep 5
			fi
			if [ $pct_has_changed -ne $pct ]; then
				ansi_yellow
				printf "$pct\r"
				ansi_reset
				pct_has_changed=$pct
			fi
		done
	else
		# Check verbosity
		if [ "$VERBOSE" == "verbose" ]; then
			V="v"
		else
			V=""
		fi
		# In modalita` boostinstall la percentuale di avanzamento
		# e` 0 all'inizio e 100 alla fine
		setprogress 0
		#echo 0 > $progress
		# Check if RSYNC or CP command
		if [ $use_rsync -eq 0 ]; then
			$DEBUG $SUDO cp -Rpa$V $source/* $dest
		else
			$DEBUG $SUDO rsync -a$V $source $dest
		fi
		if [ $? -ne 0 ]; then
			error "Error Installing rootfs! Boost-Mode"
			exit 13
		fi
		setprogress 100
		#echo 100 > $progress
	fi
	alert "...finished installing rootfs on $2 from $1"
}

function install_image_rootfs() {
	echo -n "Installing rootfs partition from image..."
	$DEBUG $SUDO dd if=$1 of=$2 obs=512 conv=sync 1>/dev/null 2>/dev/null
	if [ $? -ne 0 ]; then
		error "install_image_rootfs"
		exit 14
	fi
	echo "...finished installing rootfs on $2."
}

# this function installs the kernel and device tree blob named $1 and $2
# in a mounted /boot filesystem $3 folder
function install_kernel() {
	if [ $DO_REAL_INSTALL -eq 0 ]; then
		MKIMAGE=`which mkimage`
		if [ "${MKIMAGE}" == "" ]; then
			error "Need mkimage tool to run this command"
			exit 15
		fi
		# Filenames used below
		uImage=uImage
		dtb=dtb
		# Gathering Kernel version and extraversion
		KVER=`${MKIMAGE} -l ${1} | grep 'Image Name' | cut -f2 -d '-'`
		if [ $? -ne 0 ]; then
			error "MKIMAGE KVER"
			exit 15
		fi
		KEXTVER=`${MKIMAGE} -l ${1} | grep 'Image Name' | cut -f3 -d '-'`
		if [ $? -ne 0 ]; then
			error "MKIMAGE KEXTVER"
			exit 15
		fi
		KERNELVER=${KVER}-${KEXTVER}
		echo "Installing kernel ${1} and DTB ${2} (${KERNELVER}) "
		echo "in boot filesystem ${3}"
		$DEBUG $SUDO cp ${1} ${3}/${uImage}-${KERNELVER}
		if [ $? -ne 0 ]; then
			error "Copying ${uImage}"
			exit 15
		fi
		$DEBUG $SUDO cp ${2} ${3}/${dtb}-${KERNELVER}
		if [ $? -ne 0 ]; then
			error "Copying ${dtb}"
			exit 15
		fi
		echo -n "Removing symbolic links if exist..."
		if [ -e ${3}/${uImage} ]; then
			$DEBUG $SUDO rm ${3}/${uImage}
		else
			echo -n "${uImage} Symlink does not exists..."
		fi
		if [ -e ${3}/${dtb} ]; then
			$DEBUG $SUDO rm ${3}/${dtb}
		else
			echo -n "${dtb} Symlink does not exists..."
		fi
		echo
		echo "Creating symlinks for next boot"
		LOC_PWD=`pwd`
		# Entering in boot folder ${3}
		$DEBUG cd ${3}
		$DEBUG $SUDO ln -s uImage-${KERNELVER} uImage
		$DEBUG $SUDO ln -s dtb-${KERNELVER} dtb
		# Exiting from boot folder ${3}
		$DEBUG cd ${LOC_PWD}
	else
		# REAL INSTALLATION! We are running as ROOT!
		echo "Installing kernel ${kernel_name} and DTB ${dtb_name}"
		echo "in /boot filesystem ${3}"
		$DEBUG $SUDO cp ${1} ${3}/uImage
		if [ $? -ne 0 ]; then
			error "Copying ${1}"
			exit 15
		fi
		$DEBUG $SUDO cp ${2} ${3}/dtb
		if [ $? -ne 0 ]; then
			error "Copying ${2}"
			exit 15
		fi
	fi
	echo -n "Synching..."
	$DEBUG $SUDO sync
	echo "...finished installing kernel and dtb on ${3}."
}

function create_image_rootfs() {
	if [ $DO_REAL_INSTALL -eq 0 ]; then
		echo -n "Creating rootfs image $1 of $2 MB (please wait)..."
		$DEBUG dd if=/dev/zero of=$1 bs=1024 count=$(($2*1024)) 1>/dev/null 2>/dev/null
		if [ $? -ne 0 ]; then
			error "create_image_rootfs: Maybe disk full?"
			exit 16
		else
			ansi_green
			echo "Ok."
			ansi_reset
		fi
		echo -n "Formatting rootfs image $1 (ext3)..."
		$DEBUG $SUDO mkfs.ext3 -m 1 -F $1 1>/dev/null 2>/dev/null
		if [ $? -ne 0 ]; then
			error "create_image_rootfs: mkfs.ext3"
			exit 17
		else
			ansi_green
			echo "Ok."
			ansi_reset
		fi
		$DEBUG mkdir -p $tempmount_image
		if mount -o loop $1 $tempmount_image
		then
			echo "Ext3Fs mounted in $tempmount_image."
		else
			error "Mounting $tempmount_image"
			exit 18
		fi
	else
		error "Unsupported function"
		exit 19
	fi
}

function sdcard_fstab()
{
	local board=$1
	local rootfspath=$2

	warning "Updating FSTAB for booting from SDCard for board $board -- $rootfspath..."

	case $board in
		STM32MP157DK2)
			sed -i 's@UUID=94578d91-6cd2-401d-b172-a1c4292a3845@/dev/mmcblk1p4@g' $rootfspath/etc/fstab
			;;
		* )
			;;
	esac
}

while getopts "hndxbkfrzZFvLBIVSQs" Option
do
	case $Option in
	h ) print_usage
		exit 1
		;;
	n ) DEBUG="echo"
		echo "*** DEBUG mode. No changes will be applied. ***"
		;;
	d ) use_hab=0
		echo "Use HAB = no"
		;;
	x ) require_unmounted=0
		echo "Don't require umounted drives (CRITICAL)"
		;;
	k ) dont_ask=1
		echo "Don't ask to proceed further"
		;;
	b ) bootlets_fsl_in_use=1
		echo "Using bootlets..."
		;;
	f ) use_rootfs_filesystem=1
		echo "Using rootfs in filesystem..."
		;;
	r ) raw_mode=1
		echo "Using raw mode bootloaders..."
		;;
	z ) erase_mbr=1
		echo "Erasing MBR disk structure..."
		;;
	Z ) create_mbr=1
		echo "Creating MBR disk structure..."
		;;
	F ) install_fs=1
		echo "Installing rootfs..."
		;;
	v ) format_rootfs=1
		echo "Formatting filesystem..."
		;;
	L ) DO_LINUX=1
		echo "Installing Linux & DTB..."
		;;
	B ) board_type=1
		echo "Board type selected..."
		;;
	I ) create_image=1
		echo "Create Image Filesystem..."
		;;
	V ) verbose=1
		echo "Verbose mode ON"
		;;
	S ) disk_image_size_requested=1
		echo "Disk Image size Requested"
		;;
	Q ) virtual_image_size_requested=1
		echo "Disk Virtual Image size Requested"
		;;
	s ) skip_autobuild_requested=1
		echo "Skip autobuild tools Requested"
		;;
	esac
done

NR_ARGS=$#

if [ $NR_ARGS -lt 2 ]; then
	print_usage
	exit 1
fi

# Print-out all options
if [ "${DEBUG}" != "" ]; then
	warning "DEBUG mode. No changes will be applied."
else
	alert "REAL mode. Changes will be applied."
fi
if [ $use_hab -eq 0 ]; then
	echo "Use HAB = no"
else
	echo "Use HAB = yes"
fi
if [ $require_unmounted -eq 1 ]; then
	echo "Don't ask to mount"
else
	echo "Ask to mount"
fi
if [ $bootlets_fsl_in_use -eq 1 ]; then
	echo "Using bootlets FSL..."
else
	echo "Using bootlets..."
fi
if [ $use_rootfs_filesystem -eq 1 ]; then
	echo "Using rootfs in filesystem..."
else
	echo "Do not use rootfs in filesystem. Image (?)"
fi
if [ $raw_mode -eq 1 ]; then
	echo "Using raw mode bootloaders..."
else
	echo "Using bootloaders and calculating bootsector offset..."
fi
if [ $erase_mbr -eq 1 ]; then
	echo "Erasing MBR disk structure..."
else
	echo "Do not erase MBR disk structure..."
fi
if [ $create_mbr -eq 1 ]; then
	echo "Creating MBR disk structure..."
else
	echo "Do not create MBR disk structure..."
fi
if [ $DO_LINUX -eq 1 ]; then
	echo "Install Linux & DTB on the boot partition..."
else
	echo "Do not install Linux & DTB on the boot partition..."
fi
if [ $install_fs -eq 1 ]; then
	echo -n "Install root filesystem..."
	# Eventually the rootfs_dir is the fourth argument
	ROOTFS_PATH=$4
	if [ "${ROOTFS_PATH}" == "" ]; then
		echo "No rootfs_dir given"
	else
		rootfs_dir=$ROOTFS_PATH
		echo "rootfs_dir $rootfs_dir"
	fi
else
	echo "Do not install root filesystem..."
fi

if [ $board_type -eq 1 ]; then
	# If creating an image the board will be the 2nd arguments,
	# otherwise it will be the 3rd
	if [ $NR_ARGS -lt 3 ]; then
		BRD=$2
	else
		BRD=$3
	fi
	ansi_green
	case $BRD in
		STM32MP157DK2)
			echo "Board STM32MP157DK2 passed."
			;;
		*)
			error "Invalid Board found."
			exit 2;
			;;
	esac
	ansi_reset
	BOARD=$BRD
else
	# If no board -B flag is used, try to find out
	# which board we are... :-)
	BOARD=`cat /sys/devices/soc0/machine 2>/dev/null | cut -f 2 -d ' '`
	ansi_green
	echo "Board $BOARD found"
	ansi_reset
fi
if [ $create_image -eq 1 ]; then
	# Do not touch the sd if creating image
	create_mbr=0
	erase_mbr=0
	raw_mode=0
	bootlets_fsl_in_use=0
	use_rootfs_filesystem=0
	format_rootfs=0
	install_fs=1
	echo "CREATING IMAGE need to disable all accesses to sdcard..."
fi
if [ $skip_autobuild_requested -eq 1 ]; then
	echo "Skipping autobuild tools..."
	skip_autobuild=1
fi
if [ "$BOARD" == "" ]; then
	error "Please specify the board: EK330, EK340, EK350, EK380 or IMX28EVK with -B"
	exit 1
fi
if [ $verbose -eq 1 ]; then
	echo "Verbose mode ON"
else
	echo "Verbose mode OFF"
fi

warning "Board Type is: ${BOARD}"

#
# If we are running from embedded board, check in sequence:
#
# (1) - What platform we are running on
# (2) - What board we are
# (3) - What boot device we are running from

ARM_PLAT=`uname -m | grep arm`
EK_BOARD=`cat /sys/devices/soc0/machine 2>/dev/null`
SD_BOOTDEV=`cat /proc/cmdline | grep mmcblk1`

echo -n "Checking platform..."

if [ "$ARM_PLAT" != "" ] && [ "$EK_BOARD" != "" ] && [ "$SD_BOOTDEV" != "" ]; then
	# We are running from Recovery BootDevice (external SDCard), and
	# we are an Eurek Embedded Board running on ARM Processor.
	kernel_name="/root/linux-kernel-$BOARD.bin"
	dtb_name="/root/dtb-$BOARD.bin"
	rootfs_name="/root/rootfs-$BOARD.img"
	rootfs_dir=$tempmount_image
	dont_ask=1
	SUDO=""
	DO_REAL_INSTALL=1
	alert "${BOARD} REAL INSTALLATION!"
else
	warning "${BOARD} is sudoers ready"
	kernel_name="pendisk-${BOARD}/linux-kernel-$BOARD.bin"
	dtb_name="pendisk-${BOARD}/dtb-$BOARD.bin"
	rootfs_name="rootfs-$BOARD.img"
fi

if [ "${rootfs_dir}" == "" ]; then
	get_environment
	rootfs_dir=$ROOTFS_DIR
fi
echo "** ROOTFS_DIR=${rootfs_dir}..."

do_dtb $BOARD

if [ $disk_image_size_requested -eq 1 ]; then
	# Get environment variables
	get_environment
	warning "Parsing $BOARD_CONFIG file for image disk size: $IMAGE_DISK_SIZE_MB"
else
	warning "Setting the image size to default $DEFAULT_IMAGE_DISK_SIZE_MB (MiB)"
	IMAGE_DISK_SIZE_MB=$DEFAULT_IMAGE_DISK_SIZE_MB
fi

if [ $virtual_image_size_requested -eq 1 ]; then
	# Get environment variables
	get_environment
	warning "Parsing $BOARD_CONFIG file for virtual image disk size: $VIRTUAL_DISK_IMAGE_SIZE_MB"
else
	warning "Setting the virtual image disk size to default $DEFAULT_VIRTUAL_DISK_IMAGE_SIZE_MB"
	VIRTUAL_IMAGE_DISK_SIZE_MB=$DEFAULT_VIRTUAL_IMAGE_DISK_SIZE_MB
fi

# Disallow the use of boot disk
if [ $create_image -eq 0 ]; then
	if [ $DO_REAL_INSTALL -eq 0 ]; then

		# Found bootdisk in $bootDisk envar
		found_bootdev $2
		if [ $bootDisk -eq 1 ];	then
			ansi_red
			echo "This script will not work on $2,"
			echo "which is your boot device. Exiting."
			ansi_reset
			exit 19
		fi

		# On PC the mmc-subsystem is sd[X] form, like ATA, SATA, PATA
		# hard drives name!
		# When launching this script to build a virtual disk image
		# the nbd device has the structure as: /dev/nbd0p1, /dev/nbd0p2,
		# ... so actually we need (as in real device) the [p] in the
		# device name partition

		# Remember the device name
		p0=$2
		if [ $virtual_image_size_requested -eq 1 ]; then
			p1=$p0"p1"
			p2=$p0"p2"
			p3=$p0"p3"
			p4=$p0"p4"
			p5=$p0"p5"
		else
			# Construct all volume-names
			# (bootstream with bootloader, /boot, /)
			p1=$p0"1"
			p2=$p0"2"
			p3=$p0"3"
			p4=$p0"4"
			p5=$p0"5"
		fi
	else
		get_environment
		p0=$INSTALL_DEVICE
		# Construct all volume-names
		# (bootstream with bootloader, /boot, /)
		p1=$p0"p1"
		p2=$p0"p2"
		p3=$p0"p3"
		p4=$p0"p4"
		p5=$p5"p5"
		# Possibly in a boot-environment from sdcard /boot could be
		# already mounted if the system has not cleaned out completely
		# or fresh new system. Backup the board-config first!
		if [ "$SD_BOOTDEV" != "" ]; then
			alert "Running from a RECOVERY SD SYSTEM"
			# Now check if uuid and udev had mounted the /boot folder
			# in an already programmed eMMC, so backup board-config first
			is_mounted /dev/mmcblk0p4
			if [[ $bMounted -eq 1 ]]; then
				alert "Already configured system."
				if [ -f /boot/board-config ]; then
					alert "Backing up board-config"
					$DEBUG $SUDO cp /boot/board-config $CONFIG_BAK
					restore_board_config=1
					if [ -f /boot/splash.png ]; then
						alert "Backing up splash.png"
						$DEBUG $SUDO cp /boot/splash.png $SPLASH_BAK
						restore_splash_png=1
						if [ -f /boot/anim.png ]; then
							alert "Backing up anim.png"
							$DEBUG $SUDO cp /boot/anim.png $ANIM_BAK
							restore_anim_png=1
						fi
					fi
					if [ -f /boot/init-board ]; then
						alert "Backing up init-board"
						$DEBUG $SUDO cp /boot/init-board $INIT_BAK
						restore_init_board=1
					fi
					if [ -f /boot/lcd-config ]; then
						alert "Backing up lcd-config"
						$DEBUG $SUDO cp /boot/lcd-config $LCDCONFIG_BAK
						restore_lcd_config=1
					fi
				fi
				$DEBUG $SUDO umount /boot
				# and now remount the /boot from sdcard
				$DEBUG $SUDO mount -t ext4 -o ro /dev/mmcblk1p4 /boot
			else
				alert "Try to find an already programmed board"
				$DEBUG $SUDO mkdir -p /tmp/_boot
				$DEBUG $SUDO mount -t ext4 -o ro /dev/mmcblk0p4 /tmp/_boot
				if [ $? -eq 0 ]; then
					if [ -f /tmp/_boot/board-config ]; then
						$DEBUG $SUDO cp /tmp/_boot/board-config $CONFIG_BAK
						if [ $? -eq 0 ]; then
							alert "Already configured system. Backing up board-config"
							restore_board_config=1
							if [ -f /tmp/_boot/splash.png ]; then
								$DEBUG $SUDO cp /tmp/_boot/splash.png $SPLASH_BAK
								if [ $? -eq 0 ]; then
									alert "Backing up splash.png"
									restore_splash_png=1
									if [ -f /tmp/_boot/anim.png ]; then
										$DEBUG $SUDO cp /tmp/_boot/anim.png $ANIM_BAK
										if [ $? -eq 0 ]; then
											alert "Backing up anim.png"
											restore_anim_png=1
										else
											# Badly copied anim.png
											# Assume no anim at all!
											restore_anim_png=0
										fi
									else
										restore_anim_png=0
									fi
								else
									# Badly copied splash.png
									# Assume no splash at all!
									restore_splash_png=0
								fi
							else
								restore_splash_png=0
							fi
							if [ -f /tmp/_boot/init-board ]; then
								$DEBUG $SUDO cp /tmp/_boot/init-board $INIT_BAK
								if [ $? -eq 0 ]; then
									alert "Backing up init-board"
									restore_init_board=1
								else
									# Badly copied init-board
									# Assume no init-board at all!
									restore_init_board=0
								fi
							else
								restore_init_board=0
							fi
							if [ -f /tmp/_boot/lcd-config ]; then
								$DEBUG $SUDO cp /tmp/_boot/lcd-config $LCDCONFIG_BAK
								if [ $? -eq 0 ]; then
									alert "Backing up lcd-config"
									restore_lcd_config=1
								else
									# Badly copied lcd-config
									# Assume no lcd-config at all!
									restore_lcd_config=0
								fi
							else
								restore_lcd_config=0
							fi
						else
							# Badly copied board-config!
							# Assume no config at all!
							restore_board_config=0
						fi
					else
						restore_board_config=0
						# A partition is found, but there is no
						# config file!
					fi
					# And now umount it
					$DEBUG $SUDO umount /tmp/_boot
				else
					warning "It seems to be a FRESH UNPROGRAMMED BOARD"
					restore_board_config=0
					restore_splash_png=0
					restore_anim_png=0
					restore_init_board=0
				fi
			fi
		fi
	fi

	warning "Volume names: $p0 --> $p1, $p2, $p3 --> Device $p0"

fi


# Check if the internal eMMC is powerfail prone, looking at its
# extended CSD registers. The command mmc can fail depending on distro
if [ $DO_REAL_INSTALL -eq 1 ]; then
	WRITE_RELIABILITY=`mmc extcsd read /dev/mmcblk0 | grep 'WR_REL_SET]:' | cut -f2 -d ':' | awk '{ print $1 }'`
	if [ $? -ne 0 ]; then
		warning "No /usr/local/bin/mmc COMMAND. WRITING on eMMC is NOT POWERFAIL PRONE"
	else
		# We have mmc command in the system! MUST BE 0x1F [31 dec] (all partitions powerfail safe)
		if [ "$WRITE_RELIABILITY" != "0x1f" ]; then
			alert "eMMC partitions WR_REL_SET are not ready"
			warning "Setting WR_REL_SET for all partitions"
			$DEBUG $SUDO mmc write_reliability set_register 31 /dev/mmcblk0
			if [ $? -eq 0 ]; then
				warning "eMMC partitions are POWERFAIL PRONE"
			else
				error "WR_REL_SET. Continue NOT POWERFAIL PRONE"
			fi
		else
			warning "eMMC User partition is ready"
		fi
	fi
fi

#############################################
# OK, here it goes.
#############################################
if [ $create_image -eq 0 ]; then

	is_mounted $p0

	if [[ $require_unmounted -eq 1 ]]; then
		# This script is not running in "expert" mode.
		# We care if the target volume is already mounted.  We don't
		# want to clobber the contents accidentally.
		if [[ $bMounted -eq 1 ]]; then
			# The target volume is indeed already mounted.
			ansi_red
			echo
			echo "The requested volume $p0 is already mounted."
			echo "Possibly this volume is a hard disk or some other "
			echo "important medium."
			echo "Therefore, this script will exit and not touch it."
			echo "Please make sure your sd card is unmounted before "
			echo "running this script."
			ansi_reset
			exit 19
		fi
	else
		# This script is running in "expert" mode.
		# We will clobber any contents of the target volume.
		echo
	fi

	# Ask the user if they want to make changes unless they said to skip this.
	if [[ $dont_ask -eq 0 ]]; then
		ansi_yellow
		echo "This script requires the use of 'sudo' and erases the "
		echo "content of the specified device ($p0)"
		echo "Are you sure you want to continue? (yes/no): "
		read opt
		ansi_reset

		if [ ! "$opt" = "yes" ]; then
			error "Aborting..., nothing was altered!"
			exit 19
		fi
	fi

	# Pick boot stream based on whether to use HAB and whether to write
	# bootloader or linux.
	if [[ $use_hab -eq 1 ]]; then
		ivt="_ivt"
	fi

	if [[ $bootlets_fsl_in_use -eq 1 ]]; then
		app_name="${app_name}_fsl"
		raw_name="${raw_name}-fsl"
	fi
fi

if [ $DO_REAL_INSTALL -eq 0 ]; then
	sb_name="bootdescriptor/${app_name}${ivt}_barebox.sb"
	sb_raw_name="pendisk-${BOARD}/${raw_name}-${BOARD}.bin"
else
	sb_name="/root/${app_name}${ivt}_barebox.sb"
	sb_raw_name="/root/${raw_name}-${BOARD}.bin"
fi

if [ $erase_mbr -eq 1 ]; then
	echo -n "Erasing mbr partition map (4K) in $p0..."
	$DEBUG $SUDO dd if=/dev/urandom of=$p0 bs=$((4*1024)) count=1 1>/dev/null 2>/dev/null
	if [ $? -ne 0 ]; then
		error "Erasing mbr partition"
		exit 20
	else
		ansi_green
		echo "Ok."
		ansi_reset
	fi
	$DEBUG $SUDO partprobe $p0 1>/dev/null 2>/dev/null
	if [ $verbose -eq 1 ]; then
		warning "waiting device to settle after erasing mbr"
	fi
	sleep 1
	format_rootfs=1
	install_fs=1
fi

if [ $create_mbr -eq 1 ]; then
	alert "Make nominal partition $p0"
	make_nominal_partition $p0
	$DEBUG $SUDO partprobe $p0
	if [ $verbose -eq 1 ]; then
		warning "waiting device to settle after creating partition map"
	fi
	sleep 1
	format_rootfs=1
	install_fs=1
fi


if [ $format_rootfs -eq 1 ] && [ $install_fs -eq 1 ]; then
	$DEBUG $SUDO partprobe $p0
	if [ $verbose -eq 1 ]; then
		warning "waiting device to settle before writing rootfilesystem"
	fi
	sleep 1
fi

if [ $create_image -eq 0 ]; then
	if [ $raw_mode -eq 1 ]; then
		warning "Installing boot stream raw mode $sb_raw_name"
		install_raw_boot_stream $sb_raw_name $p1
	else
		warning "Installing boot stream: $sb_name"
		install_boot_stream $sb_name $p1
	fi

	is_mounted $p2
	if [[ $bMounted -eq 1 ]]; then
		if [ $verbose -eq 1 ]; then
			warning "$p2 was automounted, unmounting..."
		fi
		$DEBUG $SUDO umount $p2
	else
		if [ $verbose -eq 1 ]; then
			warning "$p2 is not mounted, continuing..."
		fi
	fi

	is_mounted $p3
	if [[ $bMounted -eq 1 ]]; then
		if [ $verbose -eq 1 ]; then
			warning "$p3 was automounted, unmounting..."
		fi
		$DEBUG $SUDO umount $p3
	else
		if [ $verbose -eq 1 ]; then
			warning "$p3 is not mounted, continuing..."
		fi
	fi
fi

if [ $install_fs -eq 1 ]; then
	alert "Installing ROOTFILESYSTEM..."
	if [ $use_rootfs_filesystem -eq 1 ]; then
		if [ $format_rootfs -eq 1 ]; then
			# Format /boot partition only if recreating MBR partition map
			if [ $erase_mbr -eq 1 ] && [ $create_mbr -eq 1 ]; then
				alert "FORMATTING FILESYSTEM DEVICE /boot ${p4} (boot)..."
				format_disk_ext4 $p4
				disabling_journaling_ext4 $p4
			fi
			set_uuid_boot
			alert "SETTING UUID for ${p4} (boot)..."
			set_uuid_disk_ext4 $UUID $p4
			if [ "$ROOTFS_FILESYSTEM_TYPE" = "ext4" ]; then
				alert "FORMATTING FILESYSTEM DEVICE / ${p5} (EXT4)..."
				format_disk_ext4 $p5
			else
				alert "FORMATTING FILESYSTEM DEVICE / ${p5} (NILFS2)..."
				format_disk_nilfs2 $p5
			fi
		else
			UUID="94578d91-6cd2-401d-b172-a1c4292a3845"
			alert "Setting UUID ${UUID} for ${p4} (boot) in fstab..."
		fi
		alert "MOUNTING ALL FILESYSTEMS NEEDED (/boot, /)"
		alert "Creating (1) $tempmount_boot mountpoint..."
		$DEBUG mkdir -p $tempmount_boot
		echo -n "#### Mounting ${p4} into ${tempmount_boot}..."
		$DEBUG $SUDO mount -t ext4 $p4 $tempmount_boot
		if [ $? -eq 0 ]; then
			ansi_green
			echo "Ok."
			ansi_reset
		else
			error "MOUNTING ${p4} into ${tempmount_boot}"
			exit 21
		fi
		alert "Creating (2) $tempmount_root mountpoint..."
		$DEBUG mkdir -p $tempmount_root
		echo -n "#### Mounting ${p5} into ${tempmount_root}..."
		if [ "$ROOTFS_FILESYSTEM_TYPE" = "ext4" ]; then
			$DEBUG $SUDO mount -t ext4 $p5 $tempmount_root
		else
			$DEBUG $SUDO mount -t nilfs2 $p5 $tempmount_root
		fi
		if [ $? -eq 0 ]; then
			ansi_green
			echo "Ok."
			ansi_reset
		else
			error "MOUNTING ${p5} into ${tempmount_root}"
			exit 21
		fi
		if [ $DO_REAL_INSTALL -eq 1 ]; then
			rootfs_image=$rootfs_name
			echo -n "#### Mount image $rootfs_image in $rootfs_dir (READ-ONLY)... "
			$DEBUG mkdir -p $rootfs_dir
			$DEBUG $SUDO mount -o ro $rootfs_image $rootfs_dir
			if [ $? -eq 0 ]; then
				ansi_green
				echo "Ok."
				ansi_reset
			else
				error "MOUNTING ${rootfs_image} into ${rootfs_dir}"
				exit 21
			fi
		fi
		alert "Installing filesystem from $rootfs_dir to $tempmount_root"
		get_environment
		install_fs_rootfs $rootfs_dir $tempmount_root $INSTALL_BOOST
		create_rootfs_fstab $tempmount_root/etc/fstab $UUID
		# Update the permissions of /var/log for logrotate
		alert "Update /var/log permissions..."
		$DEBUG $SUDO chmod 1755 $tempmount_root/var/log 
		if [ $DO_REAL_INSTALL -eq 0 ]; then
			rootfs_name="rootfs-$BOARD.img"
			if [ ! -f $rootfs_name ]; then
				warning "Cannot copy the $rootfs_name to $tempmount_root/root"
			else
				if [ $skip_autobuild -eq 0 ]; then
					# Copy to the sdcard the rootfilesystem image for eMMC
					# installation on target
					alert "Installing packages for production"
					ansi_yellow
					TOOLS="$rootfs_name             " # RootFileSystem
					TOOLS="$TOOLS rootfs-md5sum.log " # RootFS MD5SUM
					TOOLS="$TOOLS RootFS_version    " # RootFS Version
					TOOLS="$TOOLS mk_mx28_sd.sh     " # Installation Script
					TOOLS="$TOOLS mk_hdr.sh         " # Headers Script
					TOOLS="$TOOLS buildup_sys.sh    " # Script di esecuzione
					TOOLS="$TOOLS common.conf       " # Configurazione standard
					TOOLS="$TOOLS board.conf        " # Configurazione di scheda
					TOOLS="$TOOLS devices-$BOARD.sh " # Script di test hw
					TOOLS="$TOOLS linux-kernel-$BOARD.bin " # Kernel di produzione
					TOOLS="$TOOLS boot-barebox-$BOARD.bin " # Bootlets boot
					TOOLS="$TOOLS dtb-$BOARD.bin          " # Device Tree Block
					if [ -f distro.conf ]; then
						TOOLS="$TOOLS distro.conf"
					else
						# Se non l'abbiamo ne creiamo uno di default
						# che andrà o meno inserito nel cvs/git
						echo "!#/bin/bash" > distro.conf
						echo "DISTRO=buster" >> distro.conf
						TOOLS="$TOOLS distro.conf"
					fi
					for tools in $TOOLS ; do
						echo "Copying $tools for production..."
						$DEBUG $SUDO cp $tools $tempmount_root/root
						echo "==="
					done
					# Workaround: CVS sembra ricordare i bit di eseguibilita`
					# della prima volta. Se ci si sbaglia facendo il commit
					# allora il file copiato non avra` i bit giusti, per
					# cui correggiamo qui...
					$DEBUG $SUDO chmod +x $tempmount_root/root/*.sh
					ansi_reset
				fi
				if [ -x $PRJROOT/misc/build-misc-$BOARD.sh ]; then
					alert "Building extra packages for board $BOARD"
					. $PRJROOT/misc/build-misc-$BOARD.sh `pwd` $HOMEDIR
					if [ $? -ne 0 ]; then
						error "Patchset extra packages compiling"
						exit 13
					fi
					$DEBUG $SUDO cp `cat $PRJROOT/misc/extra-packages-$BOARD` $tempmount_root/root
					if [ $? -ne 0 ]; then
						error "Patchset extra packages installing"
						exit 13
					fi
				else
					alert "No Extra package for board $BOARD found"
				fi
				alert "Installing fixed ip-address for sd boot for board $BOARD"
				$DEBUG $SUDO cp $netif $tempmount_root/etc/network/interfaces
				if [ $? -ne 0 ]; then
					error "Fixed ip-address installing"
					exit 13
				fi
				# Apply any patch outside the distribution
				alert "Applying patchset for production"
				$DEBUG $SUDO $patchset_exec $tempmount_root
				if [ $? -ne 0 ]; then
					error "Patchset installing"
					exit 13
				fi
				# Apply for SD Card built system.
				appfolder="data"
				app="run.sh"
				dest="/root/"
				warning "Installing $app for autoboot on SD Boot Systems"
				$DEBUG $SUDO cp $appfolder/$app $tempmount_root/$dest/$app
				if [ $? -ne 0 ]; then
					error "$app installing"
					exit 13
				fi
				# Adding the splash screen/anim to sd-card /root directory
				# First check if custom splash/anim for subvendor is present
				if [ -f $BOOTROMROOT/$CUSTOMIZEFOLDER/splash.png ]; then
					warning "Installing $BOOTROMROOT/$CUSTOMIZEFOLDER/splash.png screen to SDCard /root"
					$DEBUG $SUDO cp $BOOTROMROOT/$CUSTOMIZEFOLDER/splash.png $tempmount_root/root/splash.png
					if [ $? -ne 0 ]; then
						error "$BOOTROMROOT/$CUSTOMIZEFOLDER/splash installing"
						exit 13
					fi
				else
					if [ -f splash/splash-$BOARD.png ]; then
						warning "Installing splash-${BOARD}.png screen to SDCard /root"
						$DEBUG $SUDO cp splash/splash-$BOARD.png $tempmount_root/root/splash.png
						if [ $? -ne 0 ]; then
							error "splash installing"
							exit 13
						fi
					fi
				fi
				if [ -f $BOOTROMROOT/$CUSTOMIZEFOLDER/anim.png ]; then
					warning "Installing $BOOTROMROOT/$CUSTOMIZEFOLDER/anim.png screen to SDCard /root"
					$DEBUG $SUDO cp $BOOTROMROOT/$CUSTOMIZEFOLDER/anim.png $tempmount_root/root/anim.png
					if [ $? -ne 0 ]; then
						error "$BOOTROMROOT/$CUSTOMIZEFOLDER/anim installing"
						exit 13
					fi
				else
					if [ -f splash/anim-$BOARD.png ]; then
						warning "Installing anim-${BOARD}.png screen to SDCard /root"
						$DEBUG $SUDO cp splash/anim-$BOARD.png $tempmount_root/root/anim.png
						if [ $? -ne 0 ]; then
							error "anim installing"
							exit 13
						fi
					fi
				fi
				# Adding the init-board to sd-card /root directory
				# First check if custom init-board for subvendor is present
				if [ -f $BOOTROMROOT/$CUSTOMIZEFOLDER/init-board ]; then
					warning "Installing $BOOTROMROOT/$CUSTOMIZEFOLDER/init-board to SDCard /root"
					# If not nilfs, remove fastboot option
					case "$ROOTFS_FILESYSTEM_TYPE" in 
						ext4)
							warning "Removing fastboot option for EXT4"
							sed 's/bfstrick=\"fastboot\"/#/g' $BOOTROMROOT/$CUSTOMIZEFOLDER/init-board > /tmp/init-board.temp
							$DEBUG $SUDO cp /tmp/init-board.temp $tempmount_root/root/init-board
							;;
						*)
							$DEBUG $SUDO cp $BOOTROMROOT/$CUSTOMIZEFOLDER/init-board $tempmount_root/root/init-board
							;;
					esac
					if [ $? -ne 0 ]; then
						error "$BOOTROMROOT/$CUSTOMIZEFOLDER/init-board installing"
						exit 13
					fi
				else
					if [ -f data/init-board-$BOARD ]; then
						warning "Installing init-board to SDCard /root"
						# If not nilfs, remove fastboot option
						case "$ROOTFS_FILESYSTEM_TYPE" in 
							ext4)
								warning "Removing fastboot option for EXT4"
								sed 's/bfstrick=\"fastboot\"/#/g' data/init-board-$BOARD > /tmp/init-board.temp
								$DEBUG $SUDO cp /tmp/init-board.temp $tempmount_root/root/init-board
								;;
							*)
								$DEBUG $SUDO cp data/init-board-$BOARD $tempmount_root/root/init-board
								;;
						esac
						if [ $? -ne 0 ]; then
							error "data/init-board-$BOARD installing"
							exit 13
						fi
					fi
				fi
				# Adding the lcd-config to sd-card /root directory
				# First check if custom lcd-config for subvendor is present
				if [ -f $BOOTROMROOT/$CUSTOMIZEFOLDER/lcd-config ]; then
					warning "Installing l$BOOTROMROOT/$CUSTOMIZEFOLDER/lcd-config to SDCard /root"
					$DEBUG $SUDO cp $BOOTROMROOT/$CUSTOMIZEFOLDER/lcd-config $tempmount_root/root/lcd-config
					if [ $? -ne 0 ]; then
						error "$BOOTROMROOT/$CUSTOMIZEFOLDER/lcd-config installing"
						exit 13
					fi
				else
					if [ -f data/lcd-config-$BOARD ]; then
						warning "Installing lcd-config to SDCard /root"
						$DEBUG $SUDO cp data/lcd-config-$BOARD $tempmount_root/root/lcd-config
						if [ $? -ne 0 ]; then
							error "lcd-config installing"
							exit 13
						fi
					fi
				fi
			fi
			# Nella SDCARD ho un fstab specifico (per evitare che mount by uuid
			# venga confuso da due uuid identici)
			sdcard_fstab $BOARD $tempmount_root
		else
			# We can now dismount the image filesystem. It is not needed
			# anymore
			$DEBUG $SUDO umount $rootfs_image
		fi
		DO_LINUX=1
	else
		# We can install image to sd or create image to disk
		if [ $create_image -eq 0 ]; then
			alert "Creating Image to sdcard..."
			install_image_rootfs $rootfs_name $p3
			DO_LINUX=1
		else
			get_environment
			rootfs_name="rootfs-$BOARD.img"
			alert "Create Image $rootfs_name and mount to local harddisk"
			create_image_rootfs $rootfs_name $IMAGE_DISK_SIZE_MB
			alert "Installing filesystem to image..."
			install_fs_rootfs $rootfs_dir $tempmount_image $INSTALL_BOOST
			UUID="94578d91-6cd2-401d-b172-a1c4292a3845"
			create_rootfs_fstab $tempmount_image/etc/fstab $UUID
			# Update the permissions of /var/log for logrotate
			alert "Update /var/log permissions..."
			$DEBUG $SUDO chmod 1755 $tempmount_image/var/log
			md5sum $rootfs_name > rootfs-md5sum.log
			ROOT_FILE_SYSTEM_VERSION=`$DEBUG $SUDO cat $ROOTFS_DIR/etc/RootFS_version`
			ROOT_FILE_SYSTEM_VERSION="Edelin-"${ROOT_FILE_SYSTEM_VERSION}
			echo ${ROOT_FILE_SYSTEM_VERSION} > RootFS_version
			warning "RootFileSytem Version: ${ROOT_FILE_SYSTEM_VERSION}"
			# Apply any patch outside the distribution
			alert "Applying patchset for production"
			$DEBUG $SUDO $patchset_exec $tempmount_image
			if [ $? -ne 0 ]; then
				error "Patchset installing"
				exit 13
			fi
			# Do not install linux and dtb on the rootfs image
			DO_LINUX=0
			$DEBUG $SUDO sync
			$DEBUG $SUDO umount $tempmount_image
			warning "DO NOT FORGET TO chown @ user the imagefile $tempmount_image!!"
		fi
	fi
else
	warning "DO NOT INSTALL ROOTFS..."
fi

if [ $DO_LINUX -eq 1 ]; then
	alert "Now Installing kernel & dtb files..."
	is_mounted $p4
	if [[ $bMounted -eq 1 ]]; then
		if [ $verbose -eq 1 ]; then
			warning "$p4 was automounted, continuing..."
		fi
	else
		if [ $verbose -eq 1 ]; then
			warning "$p4 is not mounted, mounting..."
		fi
		$DEBUG mkdir -p $tempmount_boot
		ansi_green
		echo -n "Mounting ${p4} into ${tempmount_boot}..."
		$DEBUG $SUDO mount -t ext4 $p4 $tempmount_boot
		if [ $? -eq 0 ]; then
			ansi_green
			echo "Ok."
			ansi_reset
		else
			ansi_reset
			error "MOUNTING ${p4} into ${tempmount_boot}"
			exit 21
		fi
	fi
	install_boot_stream_system $tempmount_boot
	install_kernel $kernel_name $dtb_name $tempmount_boot
	if [ $DO_REAL_INSTALL -eq 1 ]; then
		if [ $restore_board_config -eq 1 ]; then
			alert "Restoring board-config from backup..."
			$SUDO cp $CONFIG_BAK $tempmount_boot/board-config
		fi
		if [ $restore_splash_png -eq 1 ]; then
			alert "Restoring splash.png from backup..."
			$SUDO cp $SPLASH_BAK $tempmount_boot/splash.png
			if [ $restore_anim_png -eq 1 ]; then
				alert "Restoring anim.png from backup..."
				$SUDO cp $ANIM_BAK $tempmount_boot/anim.png
			fi
		fi
		if [ $restore_init_board -eq 1 ]; then
			alert "Restoring init-board from backup..."
			$SUDO cp $INIT_BAK $tempmount_boot/init-board
		fi
		if [ $restore_lcd_config -eq 1 ]; then
			alert "Restoring lcd-config from backup..."
			$SUDO cp $LCDCONFIG_BAK $tempmount_boot/lcd-config
		fi
	else
		# splash
		if [ -f $BOOTROMROOT/$CUSTOMIZEFOLDER/splash.png ]; then
			warning "Installing $BOOTROMROOT/$CUSTOMIZEFOLDER/splash.png screen to SD Card /boot"
			$DEBUG $SUDO cp $BOOTROMROOT/$CUSTOMIZEFOLDER/splash.png $tempmount_boot/splash.png
		else
			if [ -f splash/splash-$BOARD.png ]; then
				warning "Installing splash-${BOARD}.png screen to SD Card /boot"
				$DEBUG $SUDO cp splash/splash-$BOARD.png $tempmount_boot/splash.png
			fi
		fi
		if [ -f $BOOTROMROOT/$CUSTOMIZEFOLDER/anim.png ]; then
			warning "Installing $BOOTROMROOT/$CUSTOMIZEFOLDER/anim.png animation to SD Card /boot"
			$DEBUG $SUDO cp $BOOTROMROOT/$CUSTOMIZEFOLDER/anim.png $tempmount_boot/anim.png
		else
			if [ -f splash/anim-$BOARD.png ]; then
				warning "Installing anim-${BOARD}.png animation to SD Card /boot"
				$DEBUG $SUDO cp splash/anim-$BOARD.png $tempmount_boot/anim.png
			fi
		fi
		# init-board
		if [ -f $BOOTROMROOT/$CUSTOMIZEFOLDER/init-board ]; then
			warning "Installing $BOOTROMROOT/$CUSTOMIZEFOLDER/init-board to SD Card /boot"
			$DEBUG $SUDO cp $BOOTROMROOT/$CUSTOMIZEFOLDER/init-board $tempmount_boot/init-board
		else
			if [ -f data/init-board-$BOARD ]; then
				warning "Installing init-board to SD Card /boot"
				$DEBUG $SUDO cp data/init-board-$BOARD $tempmount_boot/init-board
			fi
		fi
		# lcd-config
		if [ -f $BOOTROMROOT/$CUSTOMIZEFOLDER/lcd-config ]; then
			warning "Installing $BOOTROMROOT/$CUSTOMIZEFOLDER/lcd-config to SD Card /boot"
			$DEBUG $SUDO cp $BOOTROMROOT/$CUSTOMIZEFOLDER/lcd-config $tempmount_boot/lcd-config
		else
			if [ -f data/lcd-config-$BOARD ]; then
				warning "Installing lcd-config to SD Card /boot"
				$DEBUG $SUDO cp data/lcd-config-$BOARD $tempmount_boot/lcd-config
			fi
		fi
		warning "Synching for SD Card /boot..."
		$DEBUG $SUDO sync
	fi
fi

if [ $create_image -eq 0 ]; then
	warning "Checking for mount $p4"
	is_mounted $p4
	if [[ $bMounted -eq 1 ]]; then
		$DEBUG $SUDO umount $p4
	fi
	warning "Checking for mount $p5"
	is_mounted $p5
	if [[ $bMounted -eq 1 ]]; then
		$DEBUG $SUDO umount $p5
	fi
	if [ $DO_REAL_INSTALL -eq 0 ]; then
		warning "Done! Plug the SD/MMC card into the STM32MP1 board and power-on."
	else
		warning "Done!"
	fi
else
	warning "Done! Your image is ready to be used."
fi

exit 0
#End
