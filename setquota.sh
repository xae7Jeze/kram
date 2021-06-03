#!/bin/bash
#
# Wrapper for setting quota
#
# V: 20191205.0

set -e -u

PATH="/bin:/usr/bin:/sbin:/usr/sbin"
LC_ALL=C
LANG=C

USAGE() {
  cat <<-_
	Usage: ${0##*/} -u <USER> -g <GROUP> -s <QUOTASIZE> -d <MOUNTPOINT> 
	Hints:
	  -g -> Set group quota for <GROUP>*
	  -u -> Set user quota for <USER>*
	  -s -> Set quota to size <SIZE> (Can be <number>kKmMgG)
	  -d -> Set quota on filesystem mounted on <MOUNTPOINT>
	
	*) Either user, group or both must be specified.
	   UID,GID must be >=1000
	
	_
}

QSIZE=""
QGROUP=""
QUSER=""
MP=""

while getopts d:g:s:u: opt;do
  case $opt in 
    d) MP=${OPTARG%/};;
    g) QGROUP=${OPTARG};;
    s) QSIZE=$(echo ${OPTARG} | tr 'A-Z' 'a-z') ;;
    u) QUSER=${OPTARG};;
    *) USAGE;exit 1 ;;
  esac
done

trap USAGE err

if [ -z "$MP" -o -z "$QSIZE" ];then
  USAGE
  exit 1
fi

if [ -z "$QUSER" -a -z "$QGROUP" ];then
  USAGE
  exit 1
fi

fgrep " $MP " /proc/mounts | fgrep -q quota
fgrep " $MP " /proc/mounts | fgrep -q quota

echo "$QSIZE" | egrep -q '[0-9]+[kmg]?$'

case "$QSIZE" in 
  *k|[*0-9]) fac=1;;
  *m) fac=1024;;
  *g) fac=$((1024 * 1024));;
  *) USAGE; exit 1;;
esac

SSIZE=$((${QSIZE%[gkm]} * fac))
SINODE=$((SSIZE / 4))
HSIZE=$((${SSIZE} + ${SSIZE} / 5))
HINODE=$((${SINODE} + ${SINODE} / 5))

if [ -n "$QUSER" ]; then
  QUID=$(id -u "$QUSER" 2>/dev/null)
  test "$QUID" -ge 1000 2>/dev/null
  setquota -u "$QUSER" "$SSIZE" "$HSIZE" "$SINODE" "$HINODE" "$MP"
fi
if [ -n "$QGROUP" ]; then
  QGID=$(getent group "$QGROUP" 2>/dev/null)
  QGID=$(echo "$QGID" | cut -d: -f3)
  test "$QGID" -ge 1000 2>/dev/null
  setquota -g "$QGROUP" "$SSIZE" "$HSIZE" "$SINODE" "$HINODE" "$MP"
fi
