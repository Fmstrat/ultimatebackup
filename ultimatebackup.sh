#!/bin/bash

#
# Ultimate Linux Backup Script v0.01
#
# WHAT IS IT?
# -----------
# This is a backup script for Linux that can back up an entire system, including KVMs,
# and them break up into pieces to be backed up onto multiple external hard drives.
#
# FEATURES
# --------
#
#  - Interactive shell based menu system
#  - Full system backups using tar/bzip2
#  - Incremental backups based on changes since last backup
#  - Integrated backups of KVM guests
#  - External backup capabilities including:
#      - Splitting backups onto multiple drives
#      - Encrypted drives
#      - Progress monitors using data transferred to show remaining time
#      - Delta sync (only backs up changed files)
#      - Multidrive: Backup to multiple drives at the same time
#      - Run in background even if session is lost
#

######################################################################################
### BEGIN CONFIGURATION ###
######################################################################################


### HOST CONFIG ###
#
#
# The folder where your tar archives of full and incremental host backups will go.
#
SERVERBACKUPFOLDER="/storage/backup/server"
#
#
# The number of historical full backups to keep when running a new backup
#
NUMTOKEEP=2
#
#
# Folders to exclude from host backups
#
EXCLUDE="lost+found media mnt proc sys storage virtual"
#



### KVM CONFIG ###
#
#
# Path to virt-backup.pl from https://github.com/vazhnov/virt-backup.pl
#
VIRTBACKUP="/bin/custom/virt-backup.pl"
#
#
# Path to backup KVMs to
#
KVMBACKUPFOLDER="/storage/backup/kvm"
#
#
# The number of historical kvm backups to keep when running a new backup
#
KNUMTOKEEP=2
#
#
# KVMs to backup, use a space to separate. Leave blank for none.
#
KVMS="centos-vm ws2012-vm"
#



### EXTERNAL BACKUP CONFIG ###
#
#
# Paths to breakup and backup to external drives. Do not include trailing slash,
# spaces seperate folders, ie "/storage /files", no spaces in paths allowed!
#
FOLDERS="/storage"
#
#
# Temporary folder to store file lists for external backup in (small text files)
#
TMPFOLDER="/tmp/multibak/" # include trailing slash
#
#
# Renice value if you would like your backup to consume less resources
#
RENICE=19
#
#
# Backup Drives (Serial Number, then size in 1K blocks)
# Serial Numbers found here: hdparm -I /dev/sd? |grep "Serial Number" |awk '{print $3}'
# 1K Blocks found by running this command after fs is created: backup --get-sizes
#
# To setup an encrypted drive:
#  1) ~# cryptsetup -y -v luksFormat /dev/sd?1 # Create LUKS partition
#  2) ~# cryptsetup luksOpen /dev/sd?1 backup # Open LUKS volume
#  3) ~# dd if=/dev/zero of=/dev/mapper/backup # Optional, clears disk for security reasons
#  4) ~# mkfs.ext4 /dev/mapper/backup # Create EST4 filesystem
#  5) ~# tune2fs -m 0 /dev/mapper/backup # Free up reserved blocks
#  6) ~# cryptsetup luksClose backup # Close the LUKS volume
#  7) ~# hdparm -I /dev/sd? |grep "Serial Number" |awk '{print $3}' # Prints the drive's serial number
#  8) Edit the below to add: DRIVES[X]="<SERIAL NUMBER>"; SIZES[X]=0 # Use the above SN.
#  9) ~# backup --get-sizes # This script will print out the actual available size.
#  10) Edit the below to include: DRIVES[X]="<SERIAL NUMBER>"; SIZES[X]=<ACTUAL SIZE> # Use the above size.
#  11) ~# echo 1 > /sys/block/sd?/device/delete # Option, disconnects SATA drive from kernel for disconnect.
#
DRIVES[1]="WD-WCAWZ0355378" SIZES[1]=2884475904 # 3TB
DRIVES[2]="WD-WCAZA0907534"; SIZES[2]=1922985984 # 2TB
DRIVES[3]="9VS23WCH"; SIZES[3]=1442240512 # 1.5TB
DRIVES[4]="9VS1827T"; SIZES[4]=1442240512 # 1.5TB
#
#
# Encryption password for external drives
# Leave blank to be asked every time
#
PASSWORD="mypassword"
#


######################################################################################
### END CONFIGURATION ###
######################################################################################


# Setup drives
length=`expr ${#DRIVES[@]} + 1`
DRIVES[$length]="NOTREAL"
SIZES[$length]=900000000000000
for (( c=1; c<=${length}; c++ )); do
	USED[$c]=0
	SIZES[$c]=`expr ${SIZES[$c]} - 1000000` # Pad some space to make sure the drive doesn't fill up (~ 1GB or higher for pesky WD 3TB drives)
done
CURRENT=1


EXTDRIVE=""

containsElement () {
	local e
	for e in "${@:2}"; do [[ "$e" == "$1" ]] && return 0; done
	return 1
}


function getSerial {
	# Send /dev/sd?
	/sbin/udevadm info --query=property --name ${1} |grep ^ID_SERIAL_SHORT |awk -F'=' '{print $2}'
}

function umExt {
	cd "${TMPFOLDER}"
	for d in /dev/sd?; do
		#SN=`hdparm -I ${d} |grep "Serial Number" |awk '{print $3}'`
		SN=$(getSerial ${d})
		containsElement "${SN}" "${DRIVES[@]}"
		if [ $? == 0 ]; then
			CONNECTED=`df -P |grep "${SN}"`
			if [ -n "${CONNECTED}" ]; then
				# See if the backup is still running
				isrunning=0
				if [ -f files-${SN}.pid ]; then
					if isRunning files-${SN}.pid; then
						isrunning=1
						echo "Found backup drive ${d} (${SN}), but backup is still running."
					fi
				fi
				if [ $isrunning -eq 0 ]; then
					echo "Found backup drive ${d} (${SN}), unmounting..."
					umount /mnt/${SN}
					sleep 2
					CONNECTED=`df -P |grep "${SN}"`
					if [ -z "${CONNECTED}" ]; then
						rmdir /mnt/${SN}
						cryptsetup -v luksClose /dev/mapper/${SN}
						sleep 2
						if [ ! -f /dev/mapper/${SN} ]; then
							device=`echo ${d} | sed 's/^\/dev\///g'`
							echo 1 > /sys/block/${device}/device/delete
						else
							echo "Failed to close LUKS."
						fi
					else
						echo "Failed to unmount."
					fi
				fi
			fi;
		fi
	done;
}

function mExt {
	for d in /dev/sd?; do
		#SN=`hdparm -I ${d} |grep "Serial Number" |awk '{print $3}'`
		SN=$(getSerial ${d})
		containsElement "${SN}" "${DRIVES[@]}"
		if [ $? == 0 ]; then
			CONNECTED=`df -P |grep "${SN}"`
			while [ -z "${CONNECTED}" ]; do
				echo "Found backup drive ${d} (${SN}), mounting..."
				mkdir -p /mnt/${SN}
				if [ -z "${PASSWORD}" ]; then
					cryptsetup -v luksOpen ${d}1 ${SN}
				else
					cryptsetup luksOpen ${d}1 ${SN} << EOF
${PASSWORD}
EOF
				fi
				mount /dev/mapper/${SN} /mnt/${SN}
				CONNECTED=`df -P |grep "${SN}"`
			done
			echo "${SN} connected."
			
		fi
	done;
}

function bExt {
	for d in "${DRIVES[@]}"; do
		CONNECTED=`df -P |grep "${d}"`
		if [ -n "${CONNECTED}" ]; then
			cd ${TMPFOLDER}
			echo "Backup to ${d}..."
			if [ ! -f files-${d}.pid ]; then
				externalBackupSync ${d}
			else
				echo "Backup for ${d} already running."
			fi
		fi
	done
}

function rmOld {
	# Call as rmOld DIR KEEP, IE rmOld /backups/dir 4
	cd $1
	KEEP=$2;
	DCOUNT=`ls -td * |wc -l`
	DCOUNT=`echo $DCOUNT-$KEEP | bc`;
	if [[ $DCOUNT =~ ^[0-9]+$ ]]; then
		if [[ $DCOUNT > 0 ]]; then 
			DLIST=`ls -td * |grep -v lastran`;
			DCOUNT2=1;
			for D in $DLIST; do
				DCOUNT3=`echo $DCOUNT2-$KEEP | bc`;
				if [[ $DCOUNT3 > 0 ]]; then 
					echo "Removing $D.";
					rm -rf $D;
				fi;
				DCOUNT2=`echo $DCOUNT2+1 | bc`;
			done;
		fi;
	fi;
}

function fullBackup {
	# Backs up full system
	START=`date`
	echo "Start: $START";
	mkdir -p ${SERVERBACKUPFOLDER}/incremental
	cd ${SERVERBACKUPFOLDER}/incremental
	touch lastran.txt
	mkdir -p ${SERVERBACKUPFOLDER}/full
	cd ${SERVERBACKUPFOLDER}/full
	touch lastran.txt
	FOLDERS=`ls /`
	BDIR=`date +"%Y%m%d"`;
	mkdir $BDIR
	echo "Make Folders: ${EXCLUDE}, then untar." > "$SERVERBACKUPFOLDER/full/$BDIR/restore.txt"
	cd /
	#echo "Backing up MBR...";
	#dd if=/dev/hda of=${SERVERBACKUPFOLDER}/$BDIR/MBR.iso bs=512 count=1
	for F in $FOLDERS; do
		CONT=1
		for E in $EXCLUDE; do
			if test "$F" = "$E"; then
				CONT=0
			fi;
		done;
		if test "$CONT" = "1"; then
			echo "Tarring $F...";
			tar cfj ${SERVERBACKUPFOLDER}/full/$BDIR/$F.tgb $F
		fi;
	done;
	cd ${SERVERBACKUPFOLDER}/full
	DSIZE=`du -sm $BDIR |awk '{print $1}'`;
	DSIZE=`echo $DSIZE-1000 | bc`;
	if [[ $DSIZE > 0 ]]; then
		rmOld ${SERVERBACKUPFOLDER}/full ${NUMTOKEEP}
		echo "Clearing Incremental backups.";
		rm -rf ${SERVERBACKUPFOLDER}/incremental/*
	else
		echo "Backup less than 1 gig!!!!!";
	fi;
}

function incrementalBackup {
	# Backs up system incrementally.
	cd ${SERVERBACKUPFOLDER}/incremental
	touch runningnow.txt
	if [ ! -f ${SERVERBACKUPFOLDER}/incremental/lastran.txt ]; then
		cp -a ${SERVERBACKUPFOLDER}/full/lastran.txt ${SERVERBACKUPFOLDER}/incremental/lastran.txt;
	fi;
	BDIR=`date +"%Y%m%d"`;
	mkdir $BDIR
	cd /
	START=`date`
	echo "Start: $START";
	FOLDERS=`ls /`
	for F in $FOLDERS; do
		CONT=1
		for E in $EXCLUDE; do
			if test "$F" = "$E"; then
				CONT=0
			fi;
		done;
		if test "$CONT" = "1"; then
			echo "Tarring $F...";
			find $F -newer ${SERVERBACKUPFOLDER}/incremental/lastran.txt -not -type d -print0 | xargs -0 tar cfj ${SERVERBACKUPFOLDER}/incremental/$BDIR/$F.tgb
		fi;
	done;
	cd ${SERVERBACKUPFOLDER}/incremental
	mv runningnow.txt lastran.txt
	END=`date`
	echo "End: $END";
}

function kvmBackup {
	cd ${KVMBACKUPFOLDER}
	BDIR=`date +"%Y%m%d"`;
	KBDIR="${KVMBACKUPFOLDER}/${1}/${BDIR}"
	mkdir -p "${KBDIR}"
	RUNNING=`virsh list --all |grep ${1} |awk '{print $3}'`
	if [ "${RUNNING}" == "running" ]; then
		echo "Shutting down ${1}..."
		virsh shutdown ${1}	
		CURSTATE="running"
		while [ "${CURSTATE}" == "running" ]; do
			CURSTATE=`virsh list --all |grep ${1} |awk '{print $3}'`
			sleep 5
		done;
		echo "Shutdown complete."
	fi;
	${VIRTBACKUP} --vm=${1} --compress=pbzip2 --backupdir=${KBDIR} --debug
	sleep 3
	rm -rf ${KBDIR}/${1}.meta
	sleep 1
	rmOld ${KVMBACKUPFOLDER}/${1} ${KNUMTOKEEP}
	if [ "${RUNNING}" == "running" ]; then
		echo "Starting ${1}..."
		virsh start ${1}	
		echo "Startup complete."
	fi;
}

function externalBackupUpdate {
	mkdir -p "${TMPFOLDER}"
	rm -f "${TMPFOLDER}"*
	cd "${TMPFOLDER}"

	## Whatever this find command finds will be backed up.  Edit accordingly.
	echo " "
	echo "Updating file list..."
	find ${FOLDERS} -xdev -printf '%p\0%k\n' | sort | gawk -F'\0' -v DRIVES="${DRIVES[*]}" -v SIZES="${SIZES[*]}" -v USED="${USED[*]}" ' 
		BEGIN { 
			split(DRIVES,drives," ")
			split(SIZES,sizes," ")
			split(USED,used," ")
			current=1;
		}  
		{ 
			if ( used[current] + $2 > sizes[current] ) {   
				current+=1 ;
			}

			used[current]+=$2
			print $1 > "files-"drives[current];
			#print $2 > "sizes-"drives[current];
     
		}
		END {
			print "Done updating backup files."
		} 

	' 
	echo " "
	echo " NUMBER OF FILES PER DRIVE"
	echo " ----------------------------------------------------------------------"
	for d in "${DRIVES[@]}"; do
		c=0
		if [ -f files-${d} ]; then
			c=`wc -l files-${d} |awk '{print $1}'`
		fi
		if [ "${d}" != "NOTREAL" ]; then
			echo " ${d}: ${c} files"
		fi
	done
}


function externalBackupSync {
	cd "${TMPFOLDER}"
	drives="/mnt/${1}"
	backupfile="files-${1}"

	find $drives -xdev | sed "s/^\/mnt\/${1}//g" > $backupfile.currentFilesTemp
	awk '$0!~/^$/ {print $0}' $backupfile.currentFilesTemp > $backupfile.currentFiles ## Get rid of blank lines
	rm $backupfile.currentFilesTemp

	if [ -f $backupfile ]; then
		cat $backupfile.currentFiles $backupfile $backupfile | sort | uniq -u > $backupfile.toDelete
	else
		echo "update first!!!! no backup found for attached drive(s)" $backupfile
		exit 1
	fi

	##Sort list of files to be deleted by lenght so longest lines (files) are deleted first and shorter lines (directories) are deleted last.  It makes sense believe me.
	echo "Deleting files that no longer exist..."
	cat "$backupfile.toDelete" | awk '{ print length, $0 }' | sort -n -r | awk ' { $1="" ; print $0 } ' | while read -r line
	do
		if [ "$drives" = "" ]; then
			echo "This is so impossible to have happened but we check for it anyways."
			exit 1
		fi
		if [ -f "$drives$line" ]; then
			rm "$drives$line"
		elif [ -d "$drives$line" ]; then
			#echo "Deleting $drives$line"
			#Printing the above could make users think it's deleting a valid directory.
			rmdir --ignore-fail-on-non-empty "$drives$line"
		fi
	done    

	echo "Consolidating list of changed files for this drive..."
	rsync -an --files-from=$backupfile --out-format="%l /%f" / $drives/ > $backupfile.changedFilesTemp

	echo "Calculating amount of data to be transfered..."
	DATA=0
	echo -n "" > $backupfile.changedFiles
	while read size file; do
		DATA=$(( DATA + size ))
		echo "$file" >> $backupfile.changedFiles
	done < $backupfile.changedFilesTemp
	echo $DATA > $backupfile.transferSize
	rm $backupfile.changedFilesTemp

	if [ $DATA -eq 0 ]; then
		echo "Drive is already up to date."
	else
		echo "About to back up $DATA bytes..."
		echo "Forking backup process..."
		#rsync -a --files-from="${backupfile}.changedFiles" --out-format="/%f" / $drives/ > $backupfile.progress  2> $backupfile.errors &
		rsync -a --files-from="${backupfile}.changedFiles" --out-format="%l" / $drives/ > $backupfile.progress  2> $backupfile.errors &
		echo $! > $backupfile.pid
		renice ${RENICE} `cat $backupfile.pid`
	fi
	echo " "
}

function isRunning {
	cd "${TMPFOLDER}"
	ps -p `cat $1` > /dev/null 2>&1 && running=1 || running=0
	if [ $running == 1 ]; then
		return 0
	else
		return 1
	fi
}

function showProgress {
	cd "${TMPFOLDER}"
	if ls *.pid &> /dev/null; then
		if [ ${1} == 1 ]; then
			echo " PROGRESS"
			echo " ----------------------------------------------------------------------"
		fi
		for p in *.pid; do
			backupfile=`echo $p | sed 's/\.pid$//g'`
			drivename=`echo $backupfile | sed 's/^files-//g'`
			numfiles=`wc -l $backupfile.changedFiles | awk '{print $1}'`
			numcopied=`wc -l $backupfile.progress | awk '{print $1}'`
			datatotal=`cat $backupfile.transferSize`
			datacopied=0
			while read num; do 
				datacopied=$(( datacopied + num ));
			done < $backupfile.progress
			if [[ $datacopied -eq 0 ]]; then
				datacopied=1
			fi
			if [[ $numcopied -eq 0 ]]; then
				numcopied=1
			fi
			#percent=`echo "scale=2;$numcopied/$numfiles*100" | bc | sed 's/\.00$//g'`
			percent=`echo "scale=2;$datacopied/$datatotal*100" | bc | sed 's/\.00$//g'`
			if isRunning $p; then
				ct=`date +%s`
				ot=`stat -c %Z $p`
				secs=`expr $ct - $ot`
				h=$(( secs / 3600 ))
				m=$(( ( secs / 60 ) % 60 ))
				s=$(( secs % 60 ))
				e=`printf "%02d:%02d:%02d\n" $h $m $s`
				#secsremaining=`echo "scale=4;(${secs}/${numcopied})*(${numfiles}-${numcopied})" | bc | sed 's/.\{5\}$//'`
				secsremaining=`echo "scale=4;(${datatotal}-${datacopied})/(${datacopied}/${secs})" | bc | sed 's/.\{5\}$//'`
				h=$(( secsremaining / 3600 ))
				m=$(( ( secsremaining / 60 ) % 60 ))
				s=$(( secsremaining % 60 ))
				r=`printf "%02d:%02d:%02d\n" $h $m $s`
			else
				if [[ $percent -lt 98 ]]; then
					e="ERROR"
					r="ERROR"
				else
					e="FINISHED"
					r="FINISHED"
				fi
			fi
			if [ ${1} == 1 ]; then
				echo -n " "
			fi
			echo "${drivename}: F:$numcopied/$numfiles P:[${percent}%] E:[${e}] R:[${r}]"
		done;
		if [ ${1} == 1 ]; then
			echo " "
		fi
	fi
}

function pause {
	echo " "
	echo -n "Press ENTER to continue..."
	read -n 1 NEXT
	echo " "
}

function cleanup {
	cd "${TMPFOLDER}"
	echo " "
	if ls *.pid &> /dev/null; then
		for p in *.pid; do
			if ! isRunning $p; then
				backupfile=`echo $p | sed 's/\.pid$//g'`
				SN=`echo $backupfile | sed 's/^files-//g'`
				echo "Removing logs for $SN."
				rm $backupfile.*
			fi
		done
	else
		echo "No logs to clear."
	fi
}

function getSizes {
	echo "Make sure your external drive serial numbers are listed in the configuration and connected to the computer now. We will mount and then poll the partitions for the sizes to add to the configuration."
	pause
	mExt
	for d in "${DRIVES[@]}"; do
		CONNECTED=`df -P |grep "${d}"`
		if [ -n "${CONNECTED}" ]; then
			echo " "
			echo "Checking size on backup drive ${d}"
			inodec=`tune2fs -l /dev/mapper/${d} | grep -i "^inode count:" |awk '{print $3}'`
			inodes=`tune2fs -l /dev/mapper/${d} | grep -i "^inode size:" |awk '{print $3}'`
			blockc=`tune2fs -l /dev/mapper/${d} | grep -i "^block count:" |awk '{print $3}'`
			blocks=`tune2fs -l /dev/mapper/${d} | grep -i "^block size:" |awk '{print $3}'`
			inodeb=$(( inodec * inodes / blocks ))
			blockr=$(( blockc - inodeb ))
			blockr1k=$(( blocks / 1024 * blockr ))
			echo "Inode count/size: ${inodec}/${inodes}"
			echo "Block count/size: ${blockc}/${blocks}"
			echo "Inode blocks: ${inodeb}"
			echo "Remaining blocks: ${blockr}"
			echo "Remaining 1K blocks: ${blockr1k}"
			echo "For config (change X):"
			echo "  DRIVES[X]=\"${d}\"; SIZES[X]=${blockr1k}"
			echo " "
			
		fi;
	done
}

function pauseBackup {
	cd "${TMPFOLDER}"
	echo " "
	if ls *.pid &> /dev/null; then
		for p in *.pid; do
			if isRunning $p; then
				pid=`cat ${p}`
				echo "Stopping process ${pid}..."
				kill $pid
			fi
		done
	fi
	sleep 5
	cleanup
}

function help {
	echo "
[F]ull System Backup ( --full-backup )
Using tar and bzip2, create a full system backup excluding folders specified in the config. All incremental backups will be removed when a full system backup is run.

[I]ncremental System Backup ( --incremental-backup )
Using tar and bzip2, create a backup of any files that have changed since the last backup.

[K]VM Backup ( --kvm-backup )
One at a time, stop specified KVMs, create a full image backup, and restart KVMs

[M]ount External Drives ( --mount )
Mount any connected and unmounted external backup drives

[G]et Sizes for Configuration ( --get-sizes )
Get the block sizes to put in the configuration. First, connect the drive and get the serial number. Then enter the serial number into configuration with a bogus size. Then, run this command to get the size, and replace the bogus size in the configuration.

[U]pdate List For External Backup ( --update-list )
Scan the system to determine which files get backed up to which drives. MUST be ran before Backup.

[B]ackup to External Drives ( --backup-external )
Backup files to whatever backup drives are attached

[E]xternal => Mount+Update+Backup ( --external )
Conduct an Update then Backup

[C]leanup => Remove completed logs ( --cleanup )
Remove any log files that are showing progress

[P]ause External Backup ( --pause )
Stops any rsync processes and cleans up logs/progress. Essentially a resume is to start over, however since only changes are synchronized, it is also a resume.

[D]ismount External Drives ( --dismount )
Unmount any connected and mounted external drives, then disconnect from kernel and spin down

[A]ll => Mount+Full+KVM+Update+Backup ( --all )
Mount external drives, Full system backup, then backup specified KVMs, Update the list, and Backup.

( --progress )
Show progress on external backups from command line. Results shown as:
<DriveSerialNumber>: F:<FilesCopied>/<TotalFiles> P:[<Percent>%] E:[<Elapsed>] R:[<Remaining>]

"
	if [ -z "${1}" ]; then
		echo "Press Q to exit help..."
	fi
}

if [ -n "${2}" ]; then
	echo "Invalid command line options."
	exit
fi

if [ "${1}" == "--pause" ]; then
	pauseBackup
elif [ "${1}" == "--help" ]; then
	help noquit
elif [ "${1}" == "--mount" ]; then
	mExt
elif [ "${1}" == "--dismount" ]; then
	umExt
elif [ "${1}" == "--get-sizes" ]; then
	getSizes
elif [ "${1}" == "--cleanup" ]; then
	cleanup
elif [ "${1}" == "--all" ]; then
	mExt
	fullBackup
	for K in ${KVMS}; do
		kvmBackup ${K}
		sleep 3
	done
	externalBackupUpdate
	sleep 3
	bExt
elif [ "${1}" == "--external" ]; then
	mExt
	externalBackupUpdate
	sleep 3
	bExt
elif [ "${1}" == "--full-backup" ]; then
	fullBackup
elif [ "${1}" == "--incremental-backup" ]; then
	incrementalBackup
elif [ "${1}" == "--kvm-backup" ]; then
	for K in ${KVMS}; do
		kvmBackup ${K}
		sleep 3
	done
elif [ "${1}" == "--update-list" ]; then
	externalBackupUpdate
elif [ "${1}" == "--backup-external" ]; then
	bExt
elif [ "${1}" == "--progress" ]; then
	showProgress 0
elif [ -z "${1}" ]; then
	OPTION=""
	while [ "${OPTION}" != "q" ] && [ "${OPTION}" != "Q" ]; do
		clear
		showProgress 1
		echo " "
		echo " BACKUP MENU"
		echo " ----------------------------------------------------------------------"
		echo -e " [\e[00;32mF\e[00m]ull System Backup"
		echo -e " [\e[00;32mI\e[00m]ncremental System Backup"
		echo " "
		echo -e " [\e[00;35mK\e[00m]VM Backup"
		echo " "
		echo -e " [\e[00;36mM\e[00m]ount External Drives"
		echo -e " [\e[00;36mG\e[00m]et Sizes for Configuration"
		echo -e " [\e[00;36mU\e[00m]pdate List For External Backup"
		echo -e " [\e[00;36mB\e[00m]ackup to External Drives"
		echo -e " [\e[00;36mE\e[00m]xternal => Mount+Update+Backup"
		echo -e " [\e[00;36mC\e[00m]leanup => Remove completed logs"
		echo -e " [\e[00;36mP\e[00m]ause External Backup"
		echo -e " [\e[00;36mD\e[00m]ismount External Drives"
		echo " "
		echo -e " [\e[00;31mA\e[00m]ll => Mount+Full+KVM+Update+Backup"
		echo " "
		echo -e " [\e[00;33mH\e[00m]elp/Command Line Options"
		echo -e " [\e[00;33mQ\e[00m]uit"
		echo " ----------------------------------------------------------------------"
		echo " "
		echo -n " Select: "
		read -n 1 -t 25 OPTION
		echo " "
		echo " "
		if [ "${OPTION}" == "g" ] || [ "${OPTION}" == "G" ]; then
			getSizes
			pause
		fi
		if [ "${OPTION}" == "p" ] || [ "${OPTION}" == "P" ]; then
			pauseBackup
			pause
		fi
		if [ "${OPTION}" == "h" ] || [ "${OPTION}" == "H" ]; then
			clear
			help |less
		fi
		if [ "${OPTION}" == "m" ] || [ "${OPTION}" == "M" ]; then
			mExt
			pause
		fi
		if [ "${OPTION}" == "d" ] || [ "${OPTION}" == "D" ]; then
			umExt
			pause
		fi
		if [ "${OPTION}" == "c" ] || [ "${OPTION}" == "C" ]; then
			cleanup
			pause
		fi
		if [ "${OPTION}" == "a" ] || [ "${OPTION}" == "A" ]; then
			mExt
			fullBackup
			for K in ${KVMS}; do
				kvmBackup ${K}
				sleep 3
			done
			externalBackupUpdate
			sleep 3
			bExt
			pause
		fi;
		if [ "${OPTION}" == "e" ] || [ "${OPTION}" == "E" ]; then
			mExt
			externalBackupUpdate
			sleep 3
			bExt
			pause
		fi
		if [ "${OPTION}" == "f" ] || [ "${OPTION}" == "F" ]; then
			fullBackup
			pause
		fi;
		if [ "${OPTION}" == "i" ] || [ "${OPTION}" == "I" ]; then
			incrementalBackup
			pause
		fi;
		if [ "${OPTION}" == "k" ] || [ "${OPTION}" == "K" ]; then
			for K in ${KVMS}; do
				kvmBackup ${K}
				sleep 3
			done
			pause
		fi;
		if [ "${OPTION}" == "u" ] || [ "${OPTION}" == "U" ]; then
			externalBackupUpdate
			pause
		fi;
		if [ "${OPTION}" == "b" ] || [ "${OPTION}" == "B" ]; then
			bExt
			pause
		fi;
		echo " "
	done
else
	echo "Invalid command line options."
fi
