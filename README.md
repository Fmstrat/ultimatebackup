# Ultimate Linux Backup Script
A backup script for Linux that can back up an entire system, including KVMs, and then break it up into pieces to be backed up onto multiple external hard drives.

The Ultimate Linux Backup Script is a backup script for Linux that can back up an entire system, including KVMs, and then break it up into pieces to be backed up onto multiple external hard drives. This allows you to have an easy backup mechanism with a collection of external or SATA drives of any size that can be carried off site.

For example, if you have 5TB of data on a RAID array in your server, you could then have 3TB, 1.5TB, and 1TB drives as externals, and the script will automatically split the data between those drives.
FEATURES

- Interactive shell based menu system
- Full system backups using tar/bzip2
- Incremental backups based on changes since last backup
- Integrated backups of KVM guests
- External backup capabilities including:
    - Splitting backups onto multiple drives
    - Encrypted drives
    - Progress monitors using data transferred to show remaining time
    - Delta sync (only backs up changed files)
    - Multidrive: Backup to multiple drives at the same time
    - Run in background even if session is lost

##USAGE/INSTALLATION

Installation is simple and straightforward.  Simply extract the script anywhere on a system. Open up the script in vi or your favorite text editor to edit the configuration, and then fire up the script. After running, hit H for help and to show the command line parameters if you wish to automate your backups. From the help output:
```
[F]ull System Backup ( --full-backup )

Using tar and bzip2, create a full system backup excluding folders specified in the config. All incremental backups will be removed when a full system backup is run.

[I]ncremental System Backup ( –incremental-backup )
Using tar and bzip2, create a backup of any files that have changed since the last backup.

[K]VM Backup ( –kvm-backup )
One at a time, stop specified KVMs, create a full image backup, and restart KVMs

[M]ount External Drives ( –mount )
Mount any connected and unmounted external backup drives

[G]et Sizes for Configuration ( –get-sizes )
Get the block sizes to put in the configuration. First, connect the drive and get the serial number. Then enter the serial number into configuration with a bogus size. Then, run this command to get the size, and replace the bogus size in the configuration.

[U]pdate List For External Backup ( –update-list )
Scan the system to determine which files get backed up to which drives. MUST be ran before Backup.

[B]ackup to External Drives ( –backup-external )
Backup files to whatever backup drives are attached

[E]xternal => Mount+Update+Backup ( –external )
Conduct an Update then Backup

[C]leanup => Remove completed logs ( –cleanup )
Remove any log files that are showing progress

[P]ause External Backup ( –pause )
Stops any rsync processes and cleans up logs/progress. Essentially a resume is to start over, however since only changes are synchronized, it is also a resume.

[D]ismount External Drives ( –dismount )
Unmount any connected and mounted external drives, then disconnect from kernel and spin down

[A]ll => Mount+Full+KVM+Update+Backup ( –all )
Mount external drives, Full system backup, then backup specified KVMs, Update the list, and Backup.

( –progress )
Show progress on external backups from command line. Results shown as:
<DriveSerialNumber>: F:<FilesCopied>/<TotalFiles> P:[<Percent>%] E:[<Elapsed>] R:[<Remaining>]
```
KVM support requires virt-backup.pl: https://github.com/vazhnov/virt-backup.pl

To setup an encrypted drive for external use:

    ~# cryptsetup -y -v luksFormat /dev/sd?1 # Create LUKS partition
    ~# cryptsetup luksOpen /dev/sd?1 backup # Open LUKS volume
    ~# dd if=/dev/zero of=/dev/mapper/backup # Optional, clears disk for security reasons
    ~# mkfs.ext4 /dev/mapper/backup # Create EST4 filesystem
    ~# tune2fs -m 0 /dev/mapper/backup # Free up reserved blocks
    ~# hdparm -I /dev/sd? |grep “Serial Number” |awk ‘{print $3}’ # Prints the drive’s serial number
    Edit the config to add: DRIVES[X]=”<SERIAL NUMBER>”; SIZES[X]=0 # Use the above SN.
    ~# cryptsetup luksClose backup # Close the LUKS volume
    ~# backup –get-sizes # This script will print out the actual available size.
    Edit the config to include: DRIVES[X]=”<SERIAL NUMBER>”; SIZES[X]=<ACTUAL SIZE> # Use the above size.
    ~# echo 1 > /sys/block/sd?/device/delete # Option, disconnects SATA drive from kernel for disconnect.

##CONFIGURATION

The following setup variables should be edited before running your backups for the first time.

**Host Configuration**

The folder where your tar archives of full and incremental host backups will go.
```
SERVERBACKUPFOLDER=”/storage/backup/server”
```

The number of historical full backups to keep when running a new backup
```
NUMTOKEEP=2
```

Folders to exclude from host backups
```
EXCLUDE=”lost+found media mnt proc sys storage virtual”
```

**KVM Configuration**

Path to virt-backup.pl from https://github.com/vazhnov/virt-backup.pl
```
VIRTBACKUP=”/bin/custom/virt-backup.pl”
```

Path to backup KVMs to
```
KVMBACKUPFOLDER=”/storage/backup/kvm”
```

The number of historical kvm backups to keep when running a new backup
```
KNUMTOKEEP=2
```

KVMs to backup, use a space to seperate. Leave blank for none.
```
KVMS=”centos-vm ws2012-vm”
```

**External Drive Configuration**

Paths to breakup and backup to external drives. Do not include trailing slash, spaces separate folders, ie “/storage /files”, no spaces in paths allowed!
```
FOLDERS=”/storage”
```

Temporary folder to store file lists for external backup in (small text files)
```
TMPFOLDER=”/tmp/multibak/” # include trailing slash
```

Renice value if you would like your backup to consume less resources.
```
RENICE=19
```

Backup Drives (Serial Number, then size in 1K blocks)
Serial Numbers found here: hdparm -I /dev/sd? |grep “Serial Number” |awk ‘{print $3}’
1K Blocks found here: df -P |grep MOUNTPOINT |awk ‘{print $2}’
```
DRIVES[1]=”WD-WCAWZ0355378″ SIZES[1]=2884281560 # 3TB
DRIVES[2]=”WD-WCAZA0907534″; SIZES[2]=1922857776 # 2TB
DRIVES[3]=”9VS23WCH”; SIZES[3]=1442144316 # 1.5TB
DRIVES[4]=”WD-NO3I1″; SIZES[4]=1442144316 # 1.5TB
```

Encryption password for external drives. Leave blank to be asked every time
```
PASSWORD=”"
```

##CHANGE LOG

**v0.01**

- Release
