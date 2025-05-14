#!/bin/bash

#
# Bash script for creating backups from hosted Nextcloud instance to a local computer or NAS using SSH. This Script is based on the work of https://codeberg.org/DecaTec/Nextcloud-Backup-Restore and a fork of https://github.com/wagnbeu0/Nextcloud-Backup-Restore
#
# Version 3.5.0
#
# Requirements:
#	- ssh and rsync (for remote pull mode)
#	- tar
#	- xz, bzip2 or pigz compression
#
# Supported database systems:
# 	- MySQL/MariaDB
# 	- PostgreSQL
#
# Usage:
# 	- With backup directory specified in the script:  ./NextcloudBackup.sh
# 	- With backup directory specified by parameter: ./NextcloudBackup.sh <backupDirectory> (e.g. ./NextcloudBackup.sh /media/hdd/nextcloud_backup)
#
# The script is based on an installation of Nextcloud using nginx and MariaDB, see https://decatec.de/home-server/nextcloud-auf-ubuntu-server-24-04-lts-mit-nginx-mariadb-postgresql-php-lets-encrypt-redis-und-fail2ban/
#


# Make sure the script exits when any command fails
set -Eeuo pipefail

# Variables
working_dir=$(dirname "$(readlink -f -- "$0")")
configFile="${working_dir}/NextcloudBackupRestore.conf"   # Holds the configuration for NextcloudBackup.sh and NextcloudRestore.sh
_backupMainDir=${1:-}

# Function for error messages
function errorecho() { echo "$@" 1>&2; }

# Save user in order to set access rules for the backup dir later on
user="$(whoami)"

#
# Check if config file exists
#
if [ ! -f "${configFile}" ]
then
	errorecho "ERROR: Configuration file $configFile cannot be found!"
	errorecho "Please make sure that a configuration file '$configFile' is present in the main directory of the scripts."
	errorecho "This file can be created automatically using the setup.sh script."
	exit 1
fi

source "$configFile" || exit 1  # Read configuration variables
#
# Check for root if not SSH
#

if [ "${sshMode}" = false ] ; then
 if [ "$(id -u)" != "0" ]
 then
 	errorecho "ERROR: This script has to be run as root!"
 	exit 1
 fi
fi
#
# Check if tar exists
#
if ! [ $(command -v tar) ] ; then
  errorecho "ERROR: tar not installed (command tar not found). Install it first and run this script again."
  errorecho "Cancel backup"
  exit 1
fi
#
#Create functions
#
if [ "${sshMode}" = true ] ; then
  function occ_get() {
	ssh "${sshHost}" php ${nextcloudServerDir}/occ config:system:get "$1"
  }
  function DisableMaintenanceMode() {
	echo "$(date +"%H:%M:%S"): Switching off maintenance mode on remote server..."
	ssh "$sshHost" "php ${nextcloudServerDir}/occ maintenance:mode --off"
	echo
  }
  function EnableMaintenanceMode() {
  	echo "$(date +"%H:%M:%S"): Switching on maintenance mode on remote server..."
	ssh "$sshHost" "php ${nextcloudServerDir}/occ maintenance:mode --on"
	echo
  }
##set up SSH pull and data directory
  relDataDir=$(ssh ${sshHost} "realpath -s --relative-to="$nextcloudServerDir" $nextcloudDataDir")
  nextcloudFileDir="${backupMainDir}/pull"
  nextcloudDataDir="${nextcloudFileDir}/${relDataDir}"
  if [ ! -d "${nextcloudFileDir}" ] ; then
    mkdir -p "${nextcloudFileDir}"
    chown -R "${user}" "${nextcloudFileDir}"
    chmod 700 -R "${nextcloudFileDir}"
  fi
else
  function occ_get() {
	sudo -u "${webserverUser}" php ${nextcloudFileDir}/occ config:system:get "$1"
  }
  function DisableMaintenanceMode() {
	echo "$(date +"%H:%M:%S"): Switching off maintenance mode..."
	sudo -u "${webserverUser}" php ${nextcloudFileDir}/occ maintenance:mode --off
	echo "Done"
	echo
  }
  function EnableMaintenanceMode() {
  	echo "$(date +"%H:%M:%S"): Switching on maintenance mode..."
	sudo -u "${webserverUser}" php ${nextcloudFileDir}/occ maintenance:mode --on
	echo "Done"
	echo
  }
  relDataDir=$(realpath -s --relative-to="$nextcloudFileDir" $nextcloudDataDir)
fi

# Make test call to OCC
set +Eeuo pipefail
occ_get datadirectory >/dev/null 2>&1

if [ $? -ne 0 ]; then
  echo ""
  echo "Error calling OCC: Please check if the information provided was correct."
  echo "ABORTING!"
  echo "No file has been altered."
  echo ""
  exit 1
fi

#set -Eeuo pipefail

if [ -n "$_backupMainDir" ]; then
	backupMainDir="${_backupMainDir%/}"
fi

if [ ! -f "${backupMainDir}/${checkFileName}" ]; then
  errorecho "ERROR: Check file ${checkFileName} not found in backup directory ${backupMainDir}!"
  errorecho "Please make sure that an etxernal drive or network share is mounted correctly as backup destination before starting the backup."
  exit 1
fi

currentDate=$(date +"%Y%m%d")

# The actual directory of the current backup - this is a subdirectory of the main directory above with a timestamp
backupDir="${backupMainDir}/${currentDate}"

if [ "${databaseSystem}" = "mysql" ] || [ "${databaseSystem}" = "mariadb" ]; then
  fourByteSupport="$(occ_get mysql.utf8mb4)" || (errorecho "ERROR: OCC config:system:get call failed!" && exit 1)
fi

# Capture CTRL+C
trap CtrlC INT

function CtrlC() {
	read -p "Backup cancelled. Keep maintenance mode? [y/n] " -n 1 -r
	echo

	if ! [[ $REPLY =~ ^[Yy]$ ]]
	then
		DisableMaintenanceMode
	else
    echo "Maintenance mode still enabled."
	fi
    if [ "${sshMode}" = false ] ; then
	echo "Starting web server..."
	systemctl start "${webserverServiceName}"
	echo "Done"
	echo
    fi
	exit 1
}

#
# Print information
#
echo "Backup directory: ${backupMainDir}"
echo

#
# Check if backup dir already exists
#
if [ ! -d "${backupDir}" ] ; then
  mkdir -p "${backupDir}"
  chown -R "${user}" "${backupDir}"
  chmod 700 -R "${backupDir}"
else
  errorecho "ERROR: The backup directory ${backupDir} already exists!"
  exit 1
fi

#
# Set maintenance mode and webserver
#
EnableMaintenanceMode
if [ "${sshMode}" = false ] ; then
 echo "$(date +"%H:%M:%S"): Stopping web server..."
 systemctl stop "${webserverServiceName}"
 echo "Done"
 echo
fi
#
# Backup file directory
#
echo "$(date +"%H:%M:%S"): Creating backup of Nextcloud file directory..."

#Pull from nextcloud server
if [ "${sshMode}" = true ] ; then
  rsync -PAax --del ${sshHost}:${nextcloudServerDir} ${nextcloudFileDir}
fi

if [ "$useCompression" = true ] ; then
	if [ "$includeNextcloudDataDir" = false ]; then
		$($compressionCommand "${backupDir}/${fileNameBackupFileDir}" --exclude="$relDataDir/*" -C "${nextcloudFileDir}" .)
	else
		$($compressionCommand "${backupDir}/${fileNameBackupFileDir}" -C "${nextcloudFileDir}" .)
	fi
else
	if [ "$includeNextcloudDataDir" = false ]; then
		tar -cpf "${backupDir}/${fileNameBackupFileDir}" --exclude="$relDataDir/*" -C "${nextcloudFileDir}" .
	else
		tar -cpf "${backupDir}/${fileNameBackupFileDir}" -C "${nextcloudFileDir}" .
	fi
fi
echo "Backup of files done"

#
# Backup data directory
#
if [ "$includeNextcloudDataDir" = false ]; then
	echo "$(date +"%H:%M:%S"): Ignoring backup of Nextcloud data directory!"
elif [[ "-d "${nextcloudFileDir}/data"" ]] && [ "$includeNextcloudDataDir" = true ]; then
	echo "$(date +"%H:%M:%S"): Skipping backup of Nextcloud data directory (already included in file directory backup)!"
else
	echo "$(date +"%H:%M:%S"): Creating backup of Nextcloud data directory..."

	if [ "$includeUpdaterBackups" = false ] ; then
		echo "Ignoring Nextcloud updater backup directory"

		if [ "$useCompression" = true ] ; then
			`$compressionCommand "${backupDir}/${fileNameBackupDataDir}"  --exclude="updater-*/backups/*" -C "${nextcloudDataDir}" .`
		else
			tar -cpf "${backupDir}/${fileNameBackupDataDir}"  --exclude="updater-*/backups/*" -C "${nextcloudDataDir}" .
		fi
	else
		if [ "$useCompression" = true ] ; then
			$($compressionCommand "${backupDir}/${fileNameBackupDataDir}"  -C "${nextcloudDataDir}" .)
		else
			tar -cpf "${backupDir}/${fileNameBackupDataDir}"  -C "${nextcloudDataDir}" .
		fi
	fi
fi

echo "Done"
echo

#
# Backup local external storage.
#
if [ ! -z "${nextcloudLocalExternalDataDir+x}" ] ; then
	echo "$(date +"%H:%M:%S"): Creating backup of Nextcloud local external storage directory..."

	if [ "$useCompression" = true ] ; then
		$($compressionCommand "${backupDir}/${fileNameBackupExternalDataDir}" -C "${nextcloudLocalExternalDataDir}" .)
	else
		tar -cpf "${backupDir}/${fileNameBackupExternalDataDir}" -C "${nextcloudLocalExternalDataDir}" .
	fi

	echo "Done"
	echo
fi

#
# Backup DB
#
fileNameBackupDbTmp="db_tmp.sql"

if [ "${databaseSystem}" = "mysql" ] || [ "${databaseSystem}" = "mariadb" ]; then
  echo "$(date +"%H:%M:%S"): Backup Nextcloud database (MySQL/MariaDB)..."
  
    if [ "${sshMode}" = true ] ; then
    	if [ "${databaseSystem}" = "mysql" ] && [ "$(ssh "${sshHost}" command -v mariadb-dump)" ] ; then
    	  dumpCommand="mysqldump"
    	elif [ "${databaseSystem}" = "mariadb" ] && [ "$(ssh "${sshHost}" command -v mariadb-dump)" ] ; then
    	  dumpCommand="mariadb-dump"
    	else
    	  errorecho "ERROR: MySQL or MariaDB not installed (command mysqldump/mariadb-dump not found)."
	  errorecho "ERROR: No backup of database possible!"
	fi
	if [ $fourByteSupport = "true" ]; then
	  ssh ${sshHost} $dumpCommand --single-transaction --default-character-set=utf8mb4 -h "${nextcloudDatabaseHost}" -P "${nextcloudDatabasePort}" -u "${dbUser}" -p"${dbPassword}" "${nextcloudDatabase}" > "${backupDir}/${fileNameBackupDbTmp}"
	else
	  ssh ${sshHost} $dumpCommand --single-transaction -h "${nextcloudDatabaseHost}" -P "${nextcloudDatabasePort}" -u "${dbUser}" -p"${dbPassword}" "${nextcloudDatabase}" > "${backupDir}/${fileNameBackupDbTmp}"
	fi
    else
	if [ "${databaseSystem}" = "mysql" ] && ! [ -x "$(command -v mysqldump)" ]; then
		errorecho "ERROR: MySQL not installed (command mysqldump not found)."
		errorecho "ERROR: No backup of database possible!"
  	elif [ "${databaseSystem}" = "mariadb" ] && ! [ -x "$(command -v mariadb-dump)" ]; then
    		errorecho "ERROR: MariaDB not installed (command mariadb-dump not found)."
		errorecho "ERROR: No backup of database possible!"
	else
	  dumpCommand="mariadb-dump"
	if [ "${databaseSystem}" = "mysql" ]; then
	  dumpCommand="mysqldump"
	fi
	if [ $fourByteSupport = "true" ]; then
	  $dumpCommand --single-transaction --default-character-set=utf8mb4 -h "${nextcloudDatabaseHost}" -P "${nextcloudDatabasePort}" -u "${dbUser}" -p"${dbPassword}" "${nextcloudDatabase}" > "${backupDir}/${fileNameBackupDbTmp}"
	else
	  $dumpCommand --single-transaction -h "${nextcloudDatabaseHost}" -P "${nextcloudDatabasePort}" -u "${dbUser}" -p"${dbPassword}" "${nextcloudDatabase}" > "${backupDir}/${fileNameBackupDbTmp}"
	fi
    fi
fi

	echo "Done"
	echo
elif [ "${databaseSystem}" = "postgresql" ] || [ "${databaseSystem}" = "pgsql" ]; then
	echo "$(date +"%H:%M:%S"): Backup Nextcloud database (PostgreSQL)..."

	if ! [ -x "$(command -v pg_dump)" ]; then
		errorecho "ERROR: PostgreSQL not installed (command pg_dump not found)."
		errorecho "ERROR: No backup of database possible!"
	else
		if [ "$nextcloudDatabaseHost" == "localhost" ]; then
			PGPASSWORD="${dbPassword}" pg_dump "${nextcloudDatabase}" -h localhost -U "${dbUser}" -f "${backupDir}/${fileNameBackupDbTmp}"
		else
			PGPASSWORD="${dbPassword}" pg_dump "${nextcloudDatabase}" -h "${nextcloudDatabaseHost}" -p "${nextcloudDatabasePort}" -U "${dbUser}" -f "${backupDir}/${fileNameBackupDbTmp}"
		fi
	fi

	echo "Done"
	echo
fi

# Compress DB dump file
if [ "$useCompression" = true ] ; then
  $($compressionCommand "${backupDir}/${fileNameBackupDb}" -C "${backupDir}" "${fileNameBackupDbTmp}")
  rm "${backupDir}/${fileNameBackupDbTmp}"
else
  mv "${backupDir}/${fileNameBackupDbTmp}" "${backupDir}/${fileNameBackupDb}"
fi

#
# Start web server
#
if [ "${sshMode}" = false ] ; then
echo "$(date +"%H:%M:%S"): Starting web server..."
systemctl start "${webserverServiceName}"
echo "Done"
echo
fi
#
# Disable maintenance mode
#
DisableMaintenanceMode

#
# Delete old backups
#
if [ ${maxNrOfBackups} != 0 ]
then
	nrOfBackups=$(find "${backupMainDir}" -mindepth 1 -maxdepth 1 -type d ! -path './pull' | wc -l)

	if [ ${nrOfBackups} -gt ${maxNrOfBackups} ]
	then
		echo "$(date +"%H:%M:%S"): Removing old backups..."
		ls -t "${backupMainDir}" | tail -$(( nrOfBackups - maxNrOfBackups )) | grep -Ev 'pull' |while read -r dirToRemove; do
			echo "${dirToRemove}"
			rm -r "${backupMainDir}/${dirToRemove:?}"
			echo "Done"
			echo
		done
	fi
fi

echo
echo "DONE!"
echo "$(date +"%H:%M:%S"): Backup created: ${backupDir}"

#set +Eeuo pipefail
