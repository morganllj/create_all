#!/bin/sh
#

# bin_path=create_all
#bin_path=/export/jobroot/zimbra/create_all
base_path=`echo $0 | awk -F/ '{for (i=1;i<NF;i++){printf $i "/"}}' | sed 's/\/$//'`
log_path=${base_path}/log
log=${log_path}/create_all_`date +%y%m%d.%H:%M:%S`

echo "logging to ${log}"
#${base_path}/create_all.pl -c ${base_path}/create_all_sdp.cf $* 2>&1 | tee ${log}
${base_path}/create_all.pl -c ${base_path}/create_all.cf $* 2>&1 | tee ${log}
