#!/bin/bash
#
# Author: github.com/xae7Jeze
# backups local filesystems to external volume
#
V=0.20200620.0

set -u -e
PATH="/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin:/usr/local/sbin"
LC_ALL=C
LANG=C

# Path to default configuration file
CF=/usr/local/etc/backup2zfs.conf

ME=${0##*/}


USAGE() {
  cat <<_

Usage: $ME [ -h? -f <configurationFile>* ]
  *) Default '$CF'

VERSION=$V

_
  
}

# Config items read from config file
# Backup to this Device UUID
UUID='MUST-BE-A-VALID-UUID-OF-A-LUKS-CRYPT-DEVICE'
# Luks key file to open UUID
KEYFILE='/etc/backup.key'
# map opened device to /dev/mapper/$CRYPTMAP
CRYPTMAP='BACKUP'
# ZPOOL to use
ZFSPOOL='ZBACKUP'
# stop and start before backing up
SERVICES=''
# delete backups older than OLDEST days
OLDEST=14
# In case of errors send mails to ERRORMAILTO
ERRORMAILTO=''
#

while getopts f:h? opt;do
  case $opt in 
    f) CF=$OPTARG;;
    h|\?) USAGE; exit 0;;
    *) USAGE; exit 1;;
  esac
done

if [ -f "$CF" -a -r "$CF" ]; then
  for i in UUID KEYFILE CRYPTMAP ZFSPOOL SERVICES OLDEST ERRORMAILTO ; do
    val="$(egrep -i "^[[:space:]]*${i}=['\"]?[a-z0-9_+@/.-]*['\"]?[[:space:]]*\$" "${CF}" || : )" 
    [ -z "$val" ] && continue
    eval $val > /dev/null 2>&1 || \
      { echo "${ME}: Error parsing configuration file '${CF}'. Exiting." ; exit 1 ; }
  done
else
  echo "${ME}: Error: Cannot read configuration file '${CF}'. Exiting"  1>&2
  exit 1
fi

if ! cryptsetup isLuks "UUID=${UUID}" > /dev/null 2>&1 ; then
  echo "${ME}: Error: UUID '${UUID}' isn't a LuksDevice. Exiting"  1>&2
  exit 1
fi

HOST=$(hostname -f | tr 'A-Z' 'a-z')
TARGET="/${ZFSPOOL}/${HOST}"
if ! echo $TARGET | egrep -qi '^/[a-z0-9_]([a-z0-9_.-]*[a-z0-9_])?/[a-z0-9_]([a-z0-9_.-]*[a-z0-9_])?$' ; then
  echo "${ME}: Error: Invalid targetname '${TARGET}'. Exiting"  1>&2
  exit 1
fi


modprobe zfs >/dev/null 2>&1 || :
if ! egrep -q '\bzfs\b' /proc/filesystems; then
  echo "${ME}: Error: No ZFS here. Exiting" 1>&2
  exit 1
fi

if [ ! -e "/dev/mapper/${CRYPTMAP}" ]  ; then
  if ! cryptsetup open --type luks  --key-file "${KEYFILE}" UUID="$UUID"  "${CRYPTMAP}"; then
    echo "${ME}: Error: luksOpen failed. Exiting"  1>&2
    exit 1
  fi
fi

if ! zpool list ZBACKUP >/dev/null 2>&1; then
  if ! zpool import "${ZFSPOOL}" ; then
    echo "${ME}: Error: zfsImport failed. Exiting"  1>&2
    cryptsetup close "${CRYPTMAP}"
    exit 1
  fi
fi

test -d "${TARGET}" || mkdir "${TARGET}"
if ! test -d "${TARGET}" ; then
  echo "${ME}:  Error: Missing target dir '${TARGET}'. Exiting"  1>&2
  cryptsetup close "${CRYPTMAP}"
  zpool export "${ZFSPOOL}"
  exit 1
fi  

cat <<_

${ME}: 
  Successfully mounted backup volume to '${TARGET}'
  Snapshots could be found in '${TARGET}/.zfs/snapshot'

_
exit 0
