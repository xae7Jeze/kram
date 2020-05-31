#!/bin/bash
#
# trys to renew certs in $PROSODY_HOME if validity is below $DAYS
# exits with 
# 0 if certs were renewed
# 1 if nothing was done
# >=2 on errors
#
# Author: github.com/xae7Jeze
#

set -u -e
PATH="/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin:/usr/local/sbin"
LC_ALL=C
LANG=C

ME=${0##*/}

# Config
PROSODY_HOME=/var/lib/prosody
PROSODY_UG="prosody:prosody"
DAYS=30
#

SECS=$((DAYS * 86400))

E="E_UNKNOWN"

trap 'echo "${ME}: ERROR : ${E} ; exit 2" 1>&2' ERR

UG="$(id -gn):$(id -un)"


E="E_WRONGUSERGROUP"
if [ "${UG}" != "${PROSODY_UG}" ] ; then
  echo "$ME: ERROR: Script must run as ${PROSODY_UG} : exiting" 1>&2
  exit 2
fi

E="E_NO_OPENSSL"
OSSL=$(which openssl || :)

if [ -z "${OSSL}" ]; then
  echo "$ME: ERROR: openssl binary not found : exiting" 1>&2
  exit 2
fi


NOW=$(date +"%s")
if ! echo "${NOW}" | egrep -q -- '-?[0-9]+$' ; then
  echo "$ME: ERROR: date binary doesn't seem to support UnixTimeStampFormat : exiting" 1>&2
  exit 2
fi


renew_cert () {
  cd "${PROSODY_HOME}" || return 1
  [ "$#" -ne 1 ] && return 1
  d="${1}"
  echo "${d}" | egrep -iq '^[0-9a-z][0-9a-z.-]+[0-9a-z]$' || return 1
  bak='bkp~'"$(date --iso-8601=sec)"
  e=0
  for ext in crt key cnf ; do
    [ "${e}" -ne 0 ] && break
    if [ -f "${d}.${ext}" ]; then
      if ! mv "${d}.${ext}" "${d}.${ext}.${bak}" ; then
        e=1
        break
      fi
    fi
  done
    if [ "$e" -eq 0 ]; then
      echo | prosodyctl cert generate "${d}" > /dev/null 2>&1 || e=1
    fi
  [ "$e" -eq 0 ] && return 0
  for ext in crt key cnf ; do
    if [ -f "${d}.${ext}.${bak}" ]; then
      mv "${d}.${ext}.${bak}" "${d}.${ext}"
    fi
  done
  return 1
}


E="E_ACCESSING_PROSODY_HOME"

cd ${PROSODY_HOME}

E="E_RENEWCERT"

renew=0
for c in *.crt; do
  [ -f "$c" ] || continue
  h=${c%.crt}
  E="E_RENEW_CERT_FOR_${h}"
  notAfter="$(openssl x509 -dates -noout -in "$c" 2>/dev/null | fgrep -i notAfter | cut -d= -f2)"
  [ -z "${notAfter}" ] && continue
  VALID_UNTIL=$(date +"%s" -d "${notAfter}")
  [ -z "${VALID_UNTIL}" ] && continue
  VALID_SECS=$((VALID_UNTIL - NOW))
  if [ "${VALID_SECS}" -lt "${SECS}" ] ; then
    renew_cert "${h}" && renew=$((renew + 1))
  fi
done
E="E_UNKNOWN"

if [ "${renew}" -gt 0 ]; then
  exit 0
else
  exit 1
fi
