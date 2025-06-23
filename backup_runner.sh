#! /usr/bin/env bash

export FULL_BACKUP

if [ -z "$FULL_BACKUPS" ]; then
    FULL_BACKUP=(
        "07:00"
        "16:00"
        "23:00"
    )
else
    # convert string to list
    mapfile -t FULL_BACKUP <<< "$FULL_BACKUPS"
    echo "[$(date +%H:%M)] FULL_BACKUPS is set, using ${FULL_BACKUP[*]}, and env ADDITIONAL_FULL_BACKUPS"
fi

export DB_BACKUP

# if DB_BACKUPS is set, use it instead of the default list
if [ -z "$DB_BACKUPS" ]; then

    # for every hour in the day, check if it is in the FULL_BACKUP list
    # if it is, do not add to DB_BACKUP list, else add it
    DB_BACKUP=()
    BUSINESS_HOUR_START=7
    BUSINESS_HOUR_END=21
    hour=$BUSINESS_HOUR_START
    while [ $hour -lt $BUSINESS_HOUR_END ]; do
        hour_str=$(printf "%02d:00" $hour)
        if [[ ! " ${FULL_BACKUP[*]} " =~ " ${hour_str} " ]]; then
            DB_BACKUP+=( "${hour_str}" )
        fi
        hour=$((hour + 1))
    done
else
    # convert string to list
    mapfile -t DB_BACKUP <<< "$DB_BACKUPS"
    echo "DB_BACKUPS is set, using ${DB_BACKUP[*]}"
fi

echo "[$(date +%H:%M)] FULL_BACKUP will run at ${FULL_BACKUP[*]}"
echo "[$(date +%H:%M)] DB_BACKUP will run at ${DB_BACKUP[*]}"

while true; do
    # Get the current time in HH:MM format
    current_time=$(date +%H:%M)

    if [[ " ${FULL_BACKUP[*]} " =~ " ${current_time} " ]]; then
        echo "[${current_time}] Running full backup with extended options ${BACKUP_OPTS}"
        /home/ubuntu/pnut-code/db_dump_import/backup.sh ${BACKUP_OPTS} >&2
    elif [[ " ${DB_BACKUP[*]} " =~ " ${current_time} " ]]; then
        echo "[${current_time}] Running db-only backup with extended options ${BACKUP_OPTS}"
        /home/ubuntu/pnut-code/db_dump_import/backup.sh --skip-storage ${BACKUP_OPTS} >&2
    elif [ $(( 10#$(date +%M) % 10 )) = 0 ]; then
        echo "[${current_time}] Running upload-only with extended options ${BACKUP_OPTS}"
        /home/ubuntu/pnut-code/db_dump_import/backup.sh --skip-db --skip-storage ${BACKUP_OPTS} >&2
    fi

    # Sleep for 1 minute before checking again
    sleep 60
done