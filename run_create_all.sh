#!/bin/sh
#

bin_path=/usr/local/sbin
log_path=/home/ldap2zimbra
log=${log_path}/create_all_`date +%y%m%d.%H:%M:%S`
mail_to=user@domain

${bin_path}/create_all.pl > ${log} 2>&1
mail -s "create_all output" ${mail_to} < ${log}
