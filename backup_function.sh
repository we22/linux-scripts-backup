#!/bin/sh

export LC_ALL=en_US.utf8
DIR_PATTERN='20..-..-..'
CURR_DATE=`date +%F`
#CURR_DATE=`date +%F_%R`
RESERVE_G=5
BACKUP_MAIN_DIR='/backup'
BACKUP_TMP_DIR='/tmp'
BACKUP_DELTA=$BACKUP_TMP_DIR/backup.delta
BACKUP_ERRORS=$BACKUP_TMP_DIR/backup.err
BACKUP_REPORT=$BACKUP_TMP_DIR/backup.report
BACKUP_LOG_FACILITY='user.notice'
BACKUP_EXPIRES_DAYS=0
VERIFY_BACKUP_MOUNTED='no'
PID_FILE='/var/run/backup.pid'
BACKUP_MYSQL_DIR=$BACKUP_TMP_DIR/mysql_dump
MYSQL_DATA_DIR='/var/lib/mysql'

[ -z "`which rsync`" ] && { echo "RSYNC is not installed! backup will not work!"; exit; }
[ -n "`which ionice`" ] && IONICE_CMD='ionice -c2 -n6'
touch /etc/default/backup_exclude
rm $BACKUP_DELTA $BACKUP_ERRORS $BACKUP_REPORT 1>/dev/null 2>/dev/null

verify_backup_mounted() {
    mount -a
    [ -d "$BACKUP_MAIN_DIR" ] || { echo "BACKUP main directory does not exist!"; exit; }
    str=`df "$BACKUP_MAIN_DIR" | tail -1 | grep ' /$'`
    [ "$str" ] && { echo 'BACKUP partition is not mounted!!!!!!!!'; exit; }
    return 0
}
prepare_for_backup() {
    if [ -s "$PID_FILE" ] && [ `cat "$PID_FILE"` -ne $PPID ]
    then
    if [ "`ps ax | awk '{print $1;}' | grep -f \"$PID_FILE\"`" ]
    then
        echo -n "Previous BACKUP script is still running. PID = "; cat "$PID_FILE"; exit
    else
        logger -t BACKUP -p $BACKUP_LOG_FACILITY "Previous BACKUP ended unexpectly"
    fi
    fi
    rm "$PID_FILE" 1>/dev/null 2>/dev/null
    echo $PPID > "$PID_FILE"
    old_dir=`pwd`
    cd "$BACKUP_MAIN_DIR" || { echo "BACKUP main directory does not exist!"; exit; }
    VERIFY_BACKUP_MOUNTED=`echo "$VERIFY_BACKUP_MOUNTED" | tr 'A-Z' 'a-z'`
    [ "$VERIFY_BACKUP_MOUNTED" = "yes" ] && verify_backup_mounted
    reserve_k=$(($RESERVE_G * 1048576))
    mkdir -p $BACKUP_TMP_DIR 1>/dev/null 2>/dev/null
    dirs_list=`ls | grep $DIR_PATTERN | sort`
    if [ -n "$dirs_list" ]
    then
    while { free_k=`df -k .|grep -v Filesystem| sed -e "s/.\+ \([0-9]\+\) .\+/\1/"`
        dirs_list=`ls | grep $DIR_PATTERN | sort`
        free_pre=$free_k
        [ $free_pre -lt $reserve_k ] ; }
    do
        dir_oldest=`echo $dirs_list | tr " " "\n" | head -1`
        [ -d $dir_oldest ] && { logger -t BACKUP -p $BACKUP_LOG_FACILITY "Deleting old backup in $BACKUP_MAIN_DIR/$dir_oldest" ; rm -rf $dir_oldest; }
    done
    fi
    [ "$VERIFY_BACKUP_MOUNTED" = "yes" ] && verify_backup_mounted
    last_date=`ls | grep $DIR_PATTERN | sort | tail -1`
    if [ -n "$last_date" -a \( "$CURR_DATE" != "$last_date" \) ]
    then
    logger -t BACKUP -p $BACKUP_LOG_FACILITY "Preparing. Copying $BACKUP_MAIN_DIR/$last_date -> $BACKUP_MAIN_DIR/$CURR_DATE"
    mkdir $CURR_DATE 1>/dev/null 2>/dev/null
    $IONICE_CMD cp -al "$last_date"/* $CURR_DATE 1>/dev/null 2>/dev/null
    rm -rf $CURR_DATE/_delta 1>/dev/null 2>/dev/null
    fi
    mkdir $CURR_DATE/_delta 1>/dev/null 2>/dev/null
    if [ $BACKUP_EXPIRES_DAYS -gt 0 ]
    then
    for expired_dir in `find "$BACKUP_MAIN_DIR" -maxdepth 1 -mtime +$BACKUP_EXPIRES_DAYS -type d | grep "$DIR_PATTERN"`
    do
        logger -t BACKUP -p $BACKUP_LOG_FACILITY "Deleting expired backup $expired_dir" ; rm -rf $expired_dir;
    done
    fi
    cd $old_dir
    return 0
}
make_backup() {
    while [ -n "$1" ]
    do
    [ "$VERIFY_BACKUP_MOUNTED" = "yes" ] && verify_backup_mounted
    src=$1
    full_src=`echo $PWD/$1 | sed -e 's://:/:g'`
    dst=`echo $BACKUP_MAIN_DIR/$CURR_DATE/$src | sed -e "s/\/\w\+$//"`
    mkdir -p $dst 1>/dev/null 2>/dev/null
    logger -t BACKUP -p $BACKUP_LOG_FACILITY "$full_src started"
    $IONICE_CMD rsync -axW8 --del --exclude-from=/etc/default/backup_exclude $src $dst 2>>$BACKUP_ERRORS
    sync
    shift
    done
    return 0
}
make_backup_with_delta() {
    while [ -n "$1" ]
    do
    [ "$VERIFY_BACKUP_MOUNTED" = "yes" ] && verify_backup_mounted
    src=$1
    full_src=`echo $PWD/$1 | sed -e 's://:/:g'`
    dst=`echo $BACKUP_MAIN_DIR/$CURR_DATE/$src | sed -e "s/\/\w\+$//"`
    mkdir -p $dst 1>/dev/null 2>/dev/null
    rm $BACKUP_DELTA 1>/dev/null 2>/dev/null
    logger -t BACKUP -p $BACKUP_LOG_FACILITY "$full_src (with delta) started"
    $IONICE_CMD rsync -axW8i --del $src $dst --exclude-from=/etc/default/backup_exclude 2>>$BACKUP_ERRORS | grep "^>f" | cut -d ' ' -f 2- 1>$BACKUP_DELTA
    old_dir=`pwd`
    cd $BACKUP_MAIN_DIR/$CURR_DATE
    dst=`echo $src | sed -e "s/\w\+$//"`
    xargs -a $BACKUP_DELTA -r -n5 -d '\n' -I '{}' echo $dst{} | xargs -r -n10 -d '\n' cp -ul --parents -t _delta
    rm $BACKUP_DELTA 1>/dev/null 2>/dev/null
    cd $old_dir
    sync
    shift
    done
    return 0
}
send_email_report() {
    if [ -s $BACKUP_ERRORS ]
    then
    logger -t BACKUP -p $BACKUP_LOG_FACILITY "Sending email report"
    echo 'Content-type: text/plain; charset=utf-8' >> $BACKUP_REPORT
    echo 'Content-Transfer-Encoding: 8bit' >> $BACKUP_REPORT
    echo 'From: root@'`hostname --fqdn` >> $BACKUP_REPORT
    echo 'To: root' >> $BACKUP_REPORT
    echo 'Date:' `date` >> $BACKUP_REPORT
    echo -e 'Subject: Cron <root@'`hostname --fqdn`'> BACKUP\n\n' >> $BACKUP_REPORT
    cat $BACKUP_ERRORS >> $BACKUP_REPORT
    cat $BACKUP_REPORT | sendmail root
    fi
    rm $BACKUP_DELTA $BACKUP_ERRORS $BACKUP_REPORT $PID_FILE 1>/dev/null 2>/dev/null
    logger -t BACKUP -p $BACKUP_LOG_FACILITY "Finished"
    return 0
}
make_mysql_backup() {
    MYSQL_DATA_DIR='/var/lib/mysql'
    mkdir $BACKUP_MAIN_DIR/$CURR_DATE/MySQL 1>/dev/null 2>/dev/null
    rm -rf $BACKUP_MAIN_DIR/$CURR_DATE/MySQL/* 1>/dev/null 2>/dev/null
    rm -rf $BACKUP_MYSQL_DIR 1>/dev/null 2>/dev/null
    mkdir -p $BACKUP_MYSQL_DIR 1>/dev/null 2>/dev/null
    cd $MYSQL_DATA_DIR
    logger -t BACKUP -p $BACKUP_LOG_FACILITY "MySQL started"
    for db_dir in `ls -p | grep '/' | tr -d '/'`
    do
    cd $MYSQL_DATA_DIR/$db_dir
    db_name=`echo $db_dir | sed -e 's/@003d/=/g' -e 's/@002d/-/g'`
    logger -t BACKUP -p $BACKUP_LOG_FACILITY "MySQL database '$db_name' started"
    for table in `ls | grep '.frm' | sed -e 's/\.frm//' -e 's/ /:::/g'`
    do
        table=`echo $table | sed -e 's/:::/ /g' -e 's/@003d/=/g' -e 's/@002d/-/g'`
        mysqldump $db_name "$table" --skip-lock-tables -Q -u $mysql_user -p$mysql_pass > "$BACKUP_MYSQL_DIR/$table.sql"
    done
    cd $BACKUP_MYSQL_DIR
    tar czf $BACKUP_MAIN_DIR/$CURR_DATE/MySQL/$db_name.tar.gz * 1>/dev/null 2>/dev/null
    rm $BACKUP_MYSQL_DIR/* 1>/dev/null 2>/dev/null
    done
    return 0
}