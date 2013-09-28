#!/bin/sh

. /usr/local/sbin/backup_functions.sh
BACKUP_EXPIRES_DAYS=365
# резерв 30√б
RESERVE_G=30
BACKUP_MAIN_DIR='/backup'
VERIFY_BACKUP_MOUNTED='yes'
prepare_for_backup
cd /
make_backup etc boot home root opt srv usr/local
make_backup_with_delta  var/spool var/lib var/www

BACKUP_MAIN_DIR='/backup'
mysql_user='root'
mysql_pass='jndey7hdFdfii7HN6ygdrarUh'
make_mysql_backup

send_email_report