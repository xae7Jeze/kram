#!/bin/bash
#
V=20230815.0

set -e -u

PATH="/bin:/usr/bin:/sbin:/usr/sbin"
LC_ALL=C
LANG=C
ME=${0##*/}

USAGE() {
	cat <<-_
	Usage: ${ME} -s <subject> -a <SUBJ_ALT_NAMES>
	Defaults:
	  -s -> subject as expected from openssl's -subj arg. Must include CN. For example -s '/CN=example.com'
	  -a -> NONE (Comma separated list of SubjectAlternativeNames without Type-Tags), 
	        For example: -a 'example.com,user@example.com,192.168.1.1,https://example.com'
          will result in 
	        'DNS:example.com, email:user@example.com, IP Address:192.168.1.1, URI:https://example.com'
	
	Version: $V
	
	_
}

ALTNAMES=""
SUBJECT=""
TD="/"

while getopts s:a:T: opt;do
  case $opt in
    a) ALTNAMES=${OPTARG};;
    s) SUBJECT=${OPTARG};;
    *) USAGE;exit 1 ;;
  esac
done

if [ -z "$SUBJECT" ];then
  USAGE
  exit 1
fi
CN=$(echo ${SUBJECT} | sed 's#^.*/CN=\([^/][^/]*\).*$#\1#')
if [ -z "$CN" ];then
  USAGE
  exit 1
fi

IPS=""
EMAILS=""
DOMAINS=""
URIS=""
if test -n "${ALTNAMES}" ; then
  OIFS=${IFS}
  IFS=","
  for N in ${ALTNAMES};do
    if echo $N | grep -E -qi '^((\*\.)?([a-z0-9][a-z0-9-]*[a-z0-9]\.)+[a-z]{0,16}|localhost)$'; then
      DOMAINS="$DOMAINS${DOMAINS:+, }DNS:$N"
    elif echo $N | grep -qi '^[a-z][a-z0-9.+-]*:'; then
      URIS="$URIS${URIS:+, }URI:$N"
    elif echo $N | grep -E -qi '^[0-9.]+$'; then
      IPS="$IPS${IPS:+, }IP:$N"
    elif echo $N | grep -F -q ':'; then
      IPS="$IPS${IPS:+, }IP:$N"
    elif echo $N | grep -F -q '@'; then
      EMAILS="$EMAILS${EMAILS:+, }email:$N"
    else
      USAGE
      exit 1
    fi
  done
  IFS=${OIFS}
fi
if echo $CN | grep -E -qi '^((\*\.)?([a-z0-9][a-z0-9-]*[a-z0-9]\.)+[a-z]{0,16}|localhost)$'; then
  DOMAINS="$DOMAINS${DOMAINS:+, }DNS:$CN"
elif echo $CN | grep -qi '^[a-z][a-z0-9.+-]*:'; then
  URIS="$URIS${URIS:+, }URI:$CN"
elif echo $CN | grep -E -qi '^[0-9.]+$'; then
  IPS="$IPS${IPS:+, }IP:$CN"
elif echo $CN | grep -F -q ':'; then
  IPS="$IPS${IPS:+, }IP:$CN"
elif echo $CN | grep -F -q '@'; then
  EMAILS="$EMAILS${EMAILS:+, }email:$CN"
else
  echo "${ME}: INVALID CN '${CN}'" 1>&2
  exit 1
fi
ALTNAMES=$(echo -n "${DOMAINS:+, }${DOMAINS}${EMAILS:+, }${EMAILS}${IPS:+, }${IPS}${URIS:+, }${URIS}" | tr "," "\n" | sort | uniq | tr -s "\n" "," | sed -e 's/^[, ]*//' -e 's/[, ]*$//')

BASE_FN=$(echo "${CN}" | tr -d [:cntrl:] | tr "A-Z" "a-z" | tr -cs '[a-z0-9._\-]' '_';)
D=$(date +"%Y%m%d")
if [ -z "$BASE_FN" ];then
  USAGE
  exit 1
fi
(umask 077; mkdir -p "${BASE_FN}/${D}")
chmod 700 "${BASE_FN}" "${BASE_FN}/${D}"
if [ -e "${BASE_FN}/${D}/${BASE_FN}.key" -o -e "${BASE_FN}/${D}/${BASE_FN}.csr" ]; then
  echo "${ME}: Ooops Output files in "${BASE_FN}/${D}" already exist. Exiting" 1>&2
  exit 2
fi
openssl req -new -utf8 -subj "${SUBJECT}" -newkey rsa:4096 -nodes -sha256 \
 -keyout "${BASE_FN}/${D}/${BASE_FN}.key" \
 -out "${BASE_FN}/${D}/${BASE_FN}.csr" \
 -addext "subjectAltName = ${ALTNAMES}" \
 -addext 'basicConstraints = CA:FALSE'

cat <<_

Created CSR "${BASE_FN}.csr" with key file "${BASE_FN}.key" in "${BASE_FN}/${D}"
_

openssl req -utf8 -noout -in "${BASE_FN}/${D}/${BASE_FN}.csr" -text -nameopt utf8

# vim: set noet
