#!/bin/bash

# autobackup mdub v1.0
# author: bergernet.ch
# repo: https://github.com/bergernetch/mdub

source /etc/mdub/mdub.conf

# PRIVATE
_lock()             { flock -$1 $LOCKFD; }
_no_more_locking()  { _lock u; _lock xn && rm -f $LOCKFILE; }
_prepare_locking()  { eval "exec $LOCKFD>\"$LOCKFILE\""; trap _no_more_locking EXIT; }

# ON START
_prepare_locking

# PUBLIC
exlock_now()        { _lock xn; }  # obtain an exclusive lock immediately or fail
exlock()            { _lock x; }   # obtain an exclusive lock
shlock()            { _lock s; }   # obtain a shared lock
unlock()            { _lock u; }   # drop a lock

# Simplest example is avoiding running multiple instances of script.
exlock_now || { echo "failed to obtain lock"; exit 1; }
# Remember! Lock file is removed when one of the scripts exits and it is
#           the only script holding the lock or lock is not acquired at all.

cat $LOG >> $LOG.archive
echo "Archived old log."
echo "" > $LOG

echo "start at $(date +%Y-%m-%d_%H-%M-%S)" 2>&1 | tee -a $LOG

# decide mode
MODE_MOUNT=false
MODE_UNMOUNT=false

MODE_BACKUP=true
MODE_CHECK=false

argc="$@ bergernet"
x=0
# x=0 for unset variable
for arg in $argc
do
   case $x in
	"--init" )
		echo "perform these steps to initialize mdub:"
		echo "1. create disk key"
		echo "   cmd"
		echo "2. get UUID of disk"
		echo "   cmd"
		echo "3. add config for your disk"
		echo "   cmd"
		echo "4. create luks partition"
		echo "   cmd"
		echo "5. format partiton"
		echo "   cmd"
		echo "5. start the backup, first time will take long"
		exit 9
	;;
	"--status" )
	  MODE_CHECK=true
          MODE_BACKUP=false
          MODE_MOUNT=true
          MODE_UNMOUNT=true
	;;
        "--mount" )
	  MODE_MOUNT=true
	  MODE_BACKUP=false
	;;
        "--unmount" )
	  MODE_UNMOUNT=true
          MODE_BACKUP=false
	;;
        "--debug" )
          DEBUG=true
	;;
    esac
    x=$arg
done

echo -n "will perform tasks: " 2>&1 | tee -a $LOG
if $MODE_MOUNT || $MODE_BACKUP ; then echo -n "MOUNT " 2>&1 | tee -a $LOG; fi
if $MODE_BACKUP ; then echo -n "BACKUP " 2>&1 | tee -a $LOG; fi
if $MODE_CHECK ; then echo -n "CHECK " 2>&1 | tee -a $LOG; fi
if $MODE_UNMOUNT || $MODE_BACKUP ; then echo -n "UNMOUNT " 2>&1 | tee -a $LOG; fi

echo 2>&1 | tee -a $LOG
echo 2>&1 | tee -a $LOG
echo "detecing usb backup disk" 2>&1 | tee -a $LOG

# check attached usb drives for known UUIDs
CONNECTED=$($LS -1 /dev/disk/by-uuid/)
TARGETDISK=
for UUID in $($CAT $DISKLIST | $GREP UUID | $CUT -d':' -f2); do
        if echo $CONNECTED | $GREP -w $UUID > /dev/null; then
		TARGETDISK=$UUID
        fi
done

# abort if no targetdisk found
if [ -z "$TARGETDISK" ]; then
	echo "no target disk detected" 2>&1 | tee -a $LOG
	exit 1
else
	echo "$TARGETDISK detected" 2>&1 | tee -a $LOG

	# get infos about disk
	$CAT $DISKLIST | $GREP -A3 $TARGETDISK | $GREP NAME 2>&1 | tee -a $LOG
fi

if $MODE_MOUNT || $MODE_BACKUP ; then
	echo 2>&1 | tee -a $LOG

        KEYFILE="$KEYPATH/$KEYPREFIX-$TARGETDISK"
        IS_MOUNTED=`$MOUNT | $GREP "$MOUNTPOINT" | $WC -l` > /dev/null 2>&1;
	if [ "$IS_MOUNTED" -eq "1" ]; then
        	echo "$MOUNTPOINT is already mounted" 2>&1 | tee -a $LOG
	else
        	echo "$MOUNTPOINT is not mounted, trying to mount" 2>&1 | tee -a $LOG

	        echo "decrypt..." 2>&1 | tee -a $LOG 
        	$CRYPTSETUP open --key-file=$KEYFILE /dev/disk/by-uuid/$TARGETDISK $(basename $CRYPTDEVICE)

	        echo "mount.." 2>&1 | tee -a $LOG
        	$MOUNT $CRYPTDEVICE $MOUNTPOINT
		rc=$?; if [[ $rc != 0 ]]; then
                	echo "mount failed with error: $M_RESULT" 2>&1 | tee -a $LOG
                	exit 2;
        	fi
	fi

        # abort if drive not mounted
        IS_MOUNTED=`$MOUNT | $GREP "$MOUNTPOINT" | $WC -l` > /dev/null 2>&1;
        if [ "$IS_MOUNTED" -eq "1" ]; then
                echo "$MOUNTPOINT is mounted" 2>&1 | tee -a $LOG
        else
                echo "$MOUNTPOINT is not mounted, exit" 2>&1 | tee -a $LOG
                exit 2
        fi
fi

if $MODE_CHECK ; then
	echo 2>&1 | tee -a $LOG
	echo "backup status: " 2>&1 | tee -a $LOG
	$DF -h | $GREP $MOUNTPOINT 2>&1 | tee -a $LOG

	echo  2>&1 | tee -a $LOG
	echo "contents of backup disk: " 2>&1 | tee -a $LOG
	$LS -l $MOUNTPOINT/$HOSTNAME/ 2>&1 | tee -a $LOG

        echo  2>&1 | tee -a $LOG
        echo "configured sources for this disk: " 2>&1 | tee -a $LOG

        # find paths to snapshot
        SOURCE_PATHS=$($CAT $DISKLIST | $GREP -A1 $TARGETDISK | $GREP "SOURCES:" | cut -d':' -f2)

	OLDIFS=$IFS
        IFS=,
        for SOURCE in $SOURCE_PATHS; do
		if [ -d "$SOURCE" ]; then
			echo "source: $SOURCE" 2>&1 | tee -a $LOG
       		else
			echo "source path configured but not existing: $SOURCE" 2>&1 | tee -a $LOG
        	fi
        done
        IFS=$OLDIFS
fi

if $MODE_BACKUP ; then

	# find paths to snapshot
	SOURCE_PATHS=$(cat $DISKLIST | $GREP -A1 $TARGETDISK | $GREP "SOURCES:" | cut -d':' -f2)

	# abort if no sourcepaths
	if  [ -z "$SOURCE_PATHS" ]; then
		echo "no source path!" 2>&1 | tee -a $LOG
		exit 3
	else
		echo "checking sources" 2>&1 | tee -a $LOG
		OLDIFS=$IFS
		IFS=,
		for SOURCE in $SOURCE_PATHS; do
			if [ -d "$SOURCE" ]; then
				echo "source: $SOURCE" 2>&1 | tee -a $LOG
			else
				echo "source path $SOURCE not found!" 2>&1 | tee -a $LOG
				exit 4
			fi
		done
		IFS=$OLDIFS
	fi

	echo 2>&1 | tee -a $LOG
	echo "backup..." 2>&1 | tee -a $LOG
	ls -l $MOUNTPOINT/$HOSTNAME

	# set file separator to comma temporarly
	OLDIFS=$IFS
	IFS=,
	for SOURCE in $SOURCE_PATHS; do
		RUN="$RSYNC $RSYNC_OPTIONS \"$SOURCE\" $MOUNTPOINT/$HOSTNAME/"
		echo $RUN 2>&1 | tee -a $LOG
		eval $RUN
	done
	IFS=$OLDIFS
fi

if $MODE_UNMOUNT || $MODE_BACKUP ; then

	echo 2>&1 | tee -a $LOG
	echo "unmount.." 2>&1 | tee -a $LOG
	$UMOUNT $MOUNTPOINT

	echo "luks close" 2>&1 | tee -a $LOG
	$CRYPTSETUP luksClose $CRYPTDEVICE
fi

echo "done at $(date +%Y-%m-%d_%H-%M-%S)" 2>&1 | tee -a $LOG
exit 0
