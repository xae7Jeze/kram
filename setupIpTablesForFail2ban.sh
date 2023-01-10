#!/bin/bash
#
# Author: github.com/xae7Jeze
# setup iptables rules for running fail2ban unprivileged
#
V=0.20230110.0

set -e
PATH="/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin:/usr/local/sbin"
LC_ALL=C
LANG=C
ME=${0##*/}
ACTION="$1"

set -u

export Fail2BanUser=_fail2ban
export Fail2BanAction=DROP

if ! id ${Fail2BanUser} > /dev/null 2>&1 ; then
  echo "${ME}: Missing fail2ban user '${Fail2BanUser}'. Exiting." 1>&2
  exit 1
fi

export Fail2BanGroup=$(id -gn ${Fail2BanUser})

JAILS=$(fail2ban-server -d | awk -F\' "
  {
  if(/'name'/ && \$4 ~ /^[0-9,a-zA-Z-]+$/)
    {s=\$4};
  if(/'port'/ && \$4 ~ /^[0-9,a-zA-Z-]+$/)
    {p=\$4};
  if(p ~ /.+/ && s ~ /.+/){
    print s,p;
    p=\"\";
    s=\"\"}}
")

JAILS=$(fail2ban-server -d | tr -d '\t ' | tr 'A-Z' 'a-z' | sed -n "\
/\['multi-set','[a-z0-9._-][a-z0-9._-]*','action','iptables-xt_recent-echo',.*'port','[0-9a-z][0-9,a-z]*'/\
{s/^.*\['multi-set','\([a-z0-9._-][a-z0-9._-]*\)','action','iptables-xt_recent-echo',.*\['port','\([0-9a-z][0-9,a-z]*\)'.*$/\1 \2/;p}\
")

case "${ACTION}" in
  start)
    iptables-save | grep -q '^:FAIL2BAN ' || iptables -N FAIL2BAN
    iptables -L INPUT | grep -q '^FAIL2BAN ' || iptables -I INPUT -j FAIL2BAN
    while read service ports; do
      test -f "/proc/net/xt_recent/f2b-${service}" && continue
      iptables -I FAIL2BAN -m multiport -p tcp --dports "${ports}" -m recent --update --seconds 3600 --name "f2b-${service}" -j ${Fail2BanAction}
      chown -h ${Fail2BanUser}:${Fail2BanGroup} "/proc/net/xt_recent/f2b-${service}"
      chmod 640 "/proc/net/xt_recent/f2b-${service}"
    done <<-_
	$JAILS
	_

  ;;
  stop)
    while read service ports; do
      test -f "/proc/net/xt_recent/f2b-${service}" || continue
      iptables -D FAIL2BAN -m multiport -p tcp --dports "${ports}" -m recent --update --seconds 3600 --name "f2b-${service}" -j ${Fail2BanAction}
    done <<-_
	$JAILS
	_
    while iptables -D INPUT -j FAIL2BAN >/dev/null 2>&1 ; do : ; done
    iptables-save | grep -q '^:FAIL2BAN ' && iptables -X FAIL2BAN
  ;;
    *)
    echo "USAGE: ${ME} {start|stop}" 1>&2
    exit 1
  ;;
esac

exit 0
