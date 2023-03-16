#!/bin/bash
#
V=20230316.0

set -e -u

PATH="/bin:/usr/bin:/sbin:/usr/sbin"
LC_ALL=C
LANG=C

ORG=""
ALTNAMES=""
SUBJECT=""
CN=""
TARGET=/etc/ssl
OWNER=root:root
DAYS=3650

USAGE() {
  cat <<-_
	Usage: ${0##*/} -o <organisation> [ -L -O <OWNER> -c <commonname> -a <SubjectAlternativeNames> -d <days> -T <TARGET_DIR> ]
	       ${0##*/} -s <subject> [ -L -O <OWNER> -a <SubjectAlternativeNames> -d <days> -T <TARGET_DIR> ]
	Defaults:
	  -o -> NODEFAULT
	  -c -> fqdn
	  -d -> 3650
	  -s -> subject as expected from openssl's -subj arg.
	  -T -> /etc/ssl (Has to exist)
	  -a -> NONE (Comma separated list of SubjectAlternativeNames)
	  -O -> $OWNER
	  -L -> Create symlink: subject_hash.N -> CRT
	
	Version: $V	
	
	_
}

cleanup(){
 test -f "${EXTFILE}" && rm -f "${EXTFILE}"
 test -f "${SSL_CSR}" && rm -f "${SSL_CSR}"
 test -d "${TDIR}" &&  rmdir "${TDIR}"
}


TDIR=""
EXTFILE=""
SSL_CSR=""
EXTENSION=""
SYMLINK=0


while getopts a:c:d:Lo:O:s:T: opt;do
  case $opt in 
    a) ALTNAMES=${OPTARG};;
    c) CN=${OPTARG};;
    d) DAYS=${OPTARG};;
    O) OWNER=${OPTARG};;
    L) SYMLINK=1;;
    o) ORG=${OPTARG};;
    s) SUBJECT=${OPTARG};;
    T) TARGET=${OPTARG};;
    *) USAGE;exit 1 ;;
  esac
done

trap 'cleanup' EXIT 



if [ -n "$SUBJECT" ];then
  if [ -n "$ORG" -o -n "$CN" ];then
    USAGE
    exit 1
  fi
	CN=$(echo ${SUBJECT} | sed 's#^.*/CN=\([^/][^/]*\).*$#\1#')
else
  CN=$({ hostname -f || hostname ; } 2>/dev/null)
  if [ -z "$ORG" -o -z "$CN" ];then
    USAGE
    exit 1
  fi
	SUBJECT="/O=${ORG}/OU=Self Signed Certificate/CN=${CN}"
fi

if [ $DAYS -lt 1 ] ; then
  USAGE
  exit 1
fi

if ! test -d "$TARGET" || test -h "$TARGET"; then
  USAGE
  exit 1
fi

TARGET=$(cd "${TARGET}" && pwd -P) 

if ! TDIR=$(mktemp -d) ; then
  echo "Oops: could not create temporary dir"
  exit 1
fi

if ! SSL_CSR=$(mktemp -p "${TDIR}"); then
  echo "Oops: could not create temporary csr file"
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
    if echo $N | egrep -qi '^((\*\.)?([a-z0-9][a-z0-9-]*[a-z0-9]\.)+[a-z]{0,16}|localhost)$'; then
      DOMAINS="$DOMAINS${DOMAINS:+, }DNS:$N"
    elif echo $N | grep -qi '^[a-z][a-z0-9.+-]*:'; then
      URIS="$URIS${URIS:+, }URI:$N"
    elif echo $N | egrep -qi '^[0-9.]+$'; then
      IPS="$IPS${IPS:+, }IP:$N"
    elif echo $N | fgrep -q ':'; then
      IPS="$IPS${IPS:+, }IP:$N"
    elif echo $N | fgrep -q '@'; then
      EMAILS="$EMAILS${EMAILS:+, }email:$N"
    else
      USAGE
      exit 1
    fi
  done
  IFS=${OIFS}
fi

if echo $CN | egrep -qi '^((\*\.)?([a-z0-9][a-z0-9-]*[a-z0-9]\.)+[a-z]{0,16}|localhost)$'; then
  DOMAINS="$DOMAINS${DOMAINS:+, }DNS:$CN"
elif echo $CN | grep -qi '^[a-z][a-z0-9.+-]*:'; then
  URIS="$URIS${URIS:+, }URI:$CN"
elif echo $CN | egrep -qi '^[0-9.]+$'; then
  IPS="$IPS${IPS:+, }IP:$CN"
elif echo $CN | fgrep -q ':'; then
  IPS="$IPS${IPS:+, }IP:$CN"
elif echo $CN | fgrep -q '@'; then
  EMAILS="$EMAILS${EMAILS:+, }email:$CN"
else
  echo "INVALID CN '${CN}'"
	exit 1
fi
ALTNAMES="${DOMAINS:+, }${DOMAINS}${EMAILS:+, }${EMAILS}${IPS:+, }${IPS}${URIS:+, }${URIS}"
ALTNAMES=${ALTNAMES#, }

if ! EXTFILE=$(mktemp -p "${TDIR}") ; then
  echo "ERROR: Oops: could not create temporary extfile"
  exit 1
fi
set -C
rm "${EXTFILE}"
echo "subjectAltName = ${ALTNAMES}" > "${EXTFILE}"
set +C
if [ -n "${ALTNAMES}" ]; then
  EXTENSION="-extfile ${EXTFILE}"
fi


if ! test -d "${TARGET}/certs"; then
  mkdir "${TARGET}/certs" "${TARGET}/private"
  chmod 755 "${TARGET}/certs"
fi
if ! test -d "${TARGET}/private"; then
  chmod 750 "${TARGET}/private"
fi

## SSL Certs
# Certs and key file
if [ -n "${ORG}" ]; then
  F=$(echo -n ${ORG}-${CN} | sed -e 's/\*/wildcard/g' -e 's|//*|_|g' | tr -sc '[:print:]' '_' | tr -s '[:space:]' '_')
else	
  F=$(echo -n ${CN} | sed -e 's/\*/wildcard/g' -e 's|//*|_|g' | tr -sc '[:print:]' '_' | tr -s '[:space:]' '_')
fi

SSL_CERT=${TARGET}/certs/${F}.crt
SSL_KEY=${TARGET}/private/${F}.key

# Clean ORG and CN
CN=$(echo $CN | sed 's|/|\\/|g')
ORG=$(echo $ORG | sed 's|/|\\/|g')

# Generate new certs if needed
if [ -f "${SSL_CERT}" -o -f "${SSL_KEY}" ]; then
  echo "You already have ssl certs for ORG: ${ORG} CN: ${CN}."
  echo "Please remove ${SSL_CERT} and/or ${SSL_KEY} and run this script again"
  exit 1
else
  echo "Creating generic self-signed certificate: ${SSL_CERT}"
  echo "(replace with hand-crafted or authorized one if needed)."
  cd ${TARGET}/certs
  PATH=${PATH}:/usr/bin/ssl
  if ! (
    umask 077
    openssl req -utf8 -nodes -out "${SSL_CSR}"  -sha256 -newkey rsa:4096 \
			-keyout "${SSL_KEY}" -subj "${SUBJECT}" >/dev/null 2>&1 && \
    openssl rsa -in "${SSL_KEY}" -out "${SSL_KEY}" >/dev/null 2>&1 && \
    openssl x509 -req -days "${DAYS}" -in "${SSL_CSR}" -signkey "${SSL_KEY}" -out "${SSL_CERT}" \
      ${EXTENSION}  >/dev/null 2>&1
    ) ; then
    echo "ERROR : Bad SSL config, can't generate certificate";
    rm -f "${SSL_CERT}" "${SSL_KEY}"
    exit 1
  fi  
  if { chmod 0644 "${SSL_CERT}" && chmod 0640 "${SSL_KEY}" && \
    chown -h "${OWNER}" "${SSL_CERT}" "${SSL_KEY}" ; } > /dev/null 2>&1; then
    :
  else
    echo
    echo "WARNING: Setting correct ownership and/or permissions on cert/key failed"
    echo "WARNING: Please fix"
    echo
  fi
fi

if [ "${SYMLINK}" = "1" ]; then
  h=$(openssl x509 -noout -subject_hash -in "${SSL_CERT}")
  f="${SSL_CERT##*/}" 
  d="${SSL_CERT%/*}" 
  cd "${d}"
  i=0; while [ -e "${h}.${i}" ]; do i=$((i+1)); done
  ln -s "${f}" "${h}.${i}"
fi

cat <<_

Certificate-Information
-----------------------
Cert-file: ${SSL_CERT}
Key-file: ${SSL_KEY}

Certificate Data:
----------------------------
$(openssl x509 -nameopt utf8,-esc_msb -noout -text -in ${SSL_CERT}| egrep '^[[:space:]]*Validity|Not (Before|After)|Subject:|X509v3 Subject Alternative Name|DNS:|IP Address:email:'|sed -e 's/^[ 	]*//' -e '$s/^[ 	]*//')

Cut and Paste snippet to use in apache's configuration
------------------------------------------------------

SSLCertificateFile ${SSL_CERT}
SSLCertificateKeyFile ${SSL_KEY}

_
