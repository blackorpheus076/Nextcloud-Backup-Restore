#!/bin/bash

#
# Bash script for an easy setup of Nextcloud backup/restore scripts.
#
# Version 3.4.0
#
# Usage:
#   - If you intend to backup your Nextcloud to an external drive or network share, make sure it is mounted.
# 	- Call the setup.sh script
#   - If your using SSH, it's better to setup a pair of key for automated connection (https://linuxopsys.com/ssh-copy-id-command)
#   - Enter the required information
#   - A central configuration file `NextcloudBackupRestore.conf` will be created to match your Nextcloud instance.
#   - This configuration file then is used by the backup/restore scripts.
#
# The script is based on an installation of Nextcloud using nginx and MariaDB, see https://decatec.de/home-server/nextcloud-auf-ubuntu-server-24-04-lts-mit-nginx-mariadb-postgresql-php-lets-encrypt-redis-und-fail2ban/
#

#
# IMPORTANT
# The setup.sh script automates the configuration for the backup/restore scripts (file `NextcloudBackupRestore.conf`).
# However, you should always check this configuration BEFORE executing the scripts!
#

# Make sure the script exits when any command fails
set -Eeuo pipefail

#
# Pre defined variables
#
backupMainDir='/backup'
nextcloudServerDir='remote/nexctloud/dir'
nextcloudFileDir='/var/www/nextcloud'
webserverUser='www-data'
webserverServiceName='nginx'
databaseHost='localhost'
databasePort=''
useCompression=true
includeUpdaterBackups=false
includeNextcloudDataDir=true
checkFileName='.nextcloud-backup-restore'
sshMode=false
sshHost='user@remotehost.com'
compressionCommand='tar -cpjf'
extractCommand='tar -xmpjf'

NextcloudBackupRestoreConf='NextcloudBackupRestore.conf'  # Holds the configuration for NextcloudBackup.sh and NextcloudRestore.sh

# Function for error messages
function errorecho() { echo "$@" 1>&2; }

#
# Gather information
#
clear

echo "Enter the directory to which the backups should be saved."
echo "Important: If you use an external drive or network share, make sure it is currently mounted!"
echo "Default: ${backupMainDir}"
echo ""
read -p "Enter a directory or press ENTER if the backup directory should be ${backupMainDir}: " BACKUPMAINDIR

[ -z "$BACKUPMAINDIR" ] ||  backupMainDir=$BACKUPMAINDIR
clear

# 
# SSH Setup
#
clear
echo ""
read -p "Do you want to use SSH? [N/y]: " SSHMODE
if [ "$SSHMODE" == 'y' ] ; then
  echo "Enter the user and the host to connect. You better setup first a private key from the backup side"
  echo "Using ssh will use rsync to create and update a copy of the Nextcloud instance on the client side"
  echo "this will be more time and ressources consuming at the first time, but then will only send differences"
  echo "Usually: ${sshHost}"
  echo ""
  read -p "Enter ${sshHost}: " SSHHOST

  [ -z "$SSHHOST" ] ||  sshHost=$SSHHOST
  sshMode=true
  echo ""
  echo "enter the path to the nextcloud directory on your server"
  read -p "Usually: ${nextcloudServerDir}: " NEXTCLOUDSERVERDIR
  [ -z "$NEXTCLOUDSERVERDIR" ] || nextcloudServerDir=$NEXTCLOUDSERVERDIR
fi
clear


if [ "$sshMode" = false ] ; then

## Check for root (no need, I guess)
  if [ "$(id -u)" != "0" ] ; then
    errorecho "ERROR: This script has to be run as root!"
    exit 1
  fi

  echo "Enter the path to the Nextcloud file directory."
  echo "Usually: ${nextcloudFileDir}"
  echo ""
  read -p "Enter a directory or press ENTER if the file directory is ${nextcloudFileDir}: " NEXTCLOUDFILEDIRECTORY
  [ -z "$NEXTCLOUDFILEDIRECTORY" ] ||  nextcloudFileDir=$NEXTCLOUDFILEDIRECTORY
  clear

  echo "Enter the webserver user."
  echo "Usually: ${webserverUser}"
  echo ""
  read -p "Enter an new user or press ENTER if the webserver user is ${webserverUser}: " WEBSERVERUSER
  [ -z "$WEBSERVERUSER" ] ||  webserverUser=$WEBSERVERUSER
  clear

  echo "Enter the webserver service name."
  echo "Usually: nginx or apache2"
  echo ""
  read -p "Enter an new webserver service name or press ENTER if the webserver service name is ${webserverServiceName}: " WEBSERVERSERVICENAME
  [ -z "$WEBSERVERSERVICENAME" ] ||  webserverServiceName=$WEBSERVERSERVICENAME
  clear
  read -p "Should the backed up data be compressed (bzip2 should be installed in the machine)? [Y/n]: " USECOMPRESSION

  if [ "$USECOMPRESSION" == 'n' ] ; then
  useCompression=false
  fi
  clear
fi

echo "Enter host/IP of the database server."
echo "Usually: localhost"
echo ""
read -p "Enter an new database host/IP or press ENTER if the database host is ${databaseHost}: " DATABASEHOST

[ -z "$DATABASEHOST" ] ||  databaseHost=$DATABASEHOST
clear

# Force entry 'localhost' if the user entered '127.0.0.1' as database host
if [ "$databaseHost" == "127.0.0.1" ]; then
  databaseHost='localhost'
fi

if [ "$databaseHost" != "localhost" ]; then
  echo "Enter port of the database server."
  echo "Usually: 3306 (MariaDB/MySQL) or 5432 (PostgreSQL)"
  echo ""
  read -p "Enter an new database port if it is an unusual port: " DATABASEPORT

  [ -z "$DATABASEPORT" ] ||  databasePort=$DATABASEPORT
  clear
fi

echo ""
read -p "Should the backups created by the Nextcloud updater be included in the backups (usually not necessary)? [y/N]: " INCLUDEUPDATERBACKUPS

if [ "$INCLUDEUPDATERBACKUPS" == 'y' ] ; then
  includeUpdaterBackups=true
fi

clear

echo ""
read -p "Should the data directory be saved separately? Usefull if the data directory is in the same root folder [y/N]: " INCLUDENEXTCLOUDDATADIR

if [ "$INCLUDENEXTCLOUDDATADIR" == 'y' ] ; then
  includeNextcloudDataDir=false
fi

clear

echo "How many backups should be kept?"
echo "If this is set to '0', no backups will be deleted."
echo ""
read -p "How many backups should be kept (default: '0'): " MAXNUMBEROFBACKUPS

maxNrOfBackups=0

if ! [ -z "$MAXNUMBEROFBACKUPS" ]  && ! [[ "$MAXNUMBEROFBACKUPS" =~ ^[0-9]+$ ]] ; then
  echo "ERROR: Number of backups must be a positive integer!"
  echo ""
  echo "ABORTING!"
  echo "No file has been altered."
  exit 1
fi

[ -z "$MAXNUMBEROFBACKUPS" ] ||  maxNrOfBackups=$MAXNUMBEROFBACKUPS
clear

echo "Backup directory: ${backupMainDir}"


if [ "$sshMode" = true ] ; then
 echo "SSH address: ${sshHost}"
 echo "Distant Nextcloud file directory: ${nextcloudServerDir}"
else
 echo "Nextcloud file directory: ${nextcloudFileDir}"
 echo "Webserver user: ${webserverUser}"
 echo "Webserver service name: ${webserverServiceName}"
fi

echo "Database host: ${databaseHost}"

if [ "$databaseHost" != "localhost" ]; then
  echo "Database port: ${databasePort}"
fi

if [ "$useCompression" = true ] ; then
	echo "Compression: yes"
else
  echo "Compression: no"
fi

if [ "$includeUpdaterBackups" = true ] ; then
	echo "Include backups from the Nextcloud updater: yes"
else
  echo "Include backups from the Nextcloud updater: no"
fi

echo "Number of backups to keep (0: keep all backups): ${maxNrOfBackups}"
echo ""

read -p "Is the information correct? [Y/n] " CORRECTINFO

if [ "$CORRECTINFO" = 'n' ] ; then
  echo ""
  echo "ABORTING!"
  echo "No file has been altered."
  exit 1
fi

#Connect Test function

if [ "$sshMode" = true ] ; then
  function occ_get() {
	ssh "${sshHost}" php ${nextcloudServerDir}/occ config:system:get "$1"
  }
else
  function occ_get() {
	sudo -u "${webserverUser}" php ${nextcloudFileDir}/occ config:system:get "$1"
  }
fi
# Make test call to OCC
echo "OCC Test"
occ_get datadirectory > /dev/null 2>&1
echo "test ok"
if [ $? -ne 0 ]; then
  echo ""
  echo "Error calling OCC: Please check if the information provided was correct."
  echo "ABORTING!"
  echo "No file has been altered."
  exit 1
fi

#
# Read data from OCC and write to config file.
#

if [ -e "$NextcloudBackupRestoreConf" ] ; then
  echo -e "\n\nSaving existing $NextcloudBackupRestoreConf to ${NextcloudBackupRestoreConf}_bak"
  cp --force "$NextcloudBackupRestoreConf" "${NextcloudBackupRestoreConf}_bak"
fi

echo ""
echo ""
echo "Creating $NextcloudBackupRestoreConf to match your Nextcloud instance..."
echo ""

# Nextcloud data dir
nextcloudDataDir=$(occ_get datadirectory)

# Database system
databaseSystem=$(occ_get dbtype)

# Nextcloud only recognizes MariaDB as MySQL, so have a closer look
if [ "$sshMode" = true ] ; then
 if [ "${databaseSystem}" = "mysql" ] && ssh ${sshHost} 'command -v mariadb > /dev/null'; then
    databaseSystem="mariadb"

    if [ -z "$databasePort" ]; then
      databasePort='3306'
    fi
 fi
else
 if [ "${databaseSystem,,}" = "mysql" ] && command -v mariadb > /dev/null; then
    databaseSystem="mariadb"

    if [ -z "$databasePort" ]; then
      databasePort='3306'
    fi
 fi
fi

# PostgreSQL is identified as pgsql
if [ "${databaseSystem}" = "pgsql" ]; then
  databaseSystem='postgresql';
  
  if [ -z "$databasePort" ]; then
      databasePort='5432'
    fi
fi

# Database
nextcloudDatabase=$(occ_get dbname)

# Database user
dbUser=$(occ_get dbuser)

# Database password
dbPassword=$(occ_get dbpassword)

# File names for backup files
fileNameBackupFileDir='nextcloud-filedir.tar'
fileNameBackupDataDir='nextcloud-datadir.tar'
fileNameBackupDb='nextcloud-db.sql'

if [ "$useCompression" = true ] ; then
	fileNameBackupFileDir='nextcloud-filedir.tar.bz2'
	fileNameBackupDataDir='nextcloud-datadir.tar.bz2'
	fileNameBackupDb='nextcloud-db.sql.tar.bz2'
fi

fileNameBackupExternalDataDir=''

if [ ! -z "${nextcloudLocalExternalDataDir+x}" ] ; then
	fileNameBackupExternalDataDir='nextcloud-external-datadir.tar'

	if [ "$useCompression" = true ] ; then
		fileNameBackupExternalDataDir='nextcloud-external-datadir.tar.bz2'
	fi
fi

mkdir -p "$backupMainDir"
touch "${backupMainDir}/${checkFileName}"

{ echo "# Configuration for Nextcloud-Backup-Restore scripts"
  echo ""
  echo "# The main backup directory"
  echo "backupMainDir='$backupMainDir'"
  echo ""
  echo "# The file to check on the backup destination."
  echo "# If the file does not exist, the backup/restore is cancelled."
  echo "checkFileName='$checkFileName'"
  echo ""
  echo "# SSH: backup from a distant server via SSH"
  echo "# It is advised to first setup a key pair with the user of the script to be more straitforward"
  echo "sshMode=$sshMode"
  echo "sshHost=$sshHost"
  echo "nextcloudServerDir=$nextcloudServerDir"
  echo ""
  echo "# Use compression for file/data dir"
  echo "# When this is the only script for backups, it is recommend to enable compression."
  echo "# If the output of this script is used in another (compressing) backup (e.g. borg backup),"
  echo "# you should probably disable compression here and only enable compression of your main backup script."
  echo "useCompression=$useCompression"
  echo ""
  echo "# TODO: The bare tar command for using compression while backup. Using bzip2"
  echo "# Use 'tar -cpzf' if you want to use gzip compression."
  echo "compressionCommand='$compressionCommand'"
  echo ""
  echo "# TODO: The bare tar command for using compression while restoring."
  echo "# Use 'tar -xmpzf' if you want to use gzip compression."
  echo "extractCommand='$extractCommand'"
  echo ""
  echo "# TODO: File names for backup files"
  echo "fileNameBackupFileDir='$fileNameBackupFileDir'"
  echo "fileNameBackupDataDir='$fileNameBackupDataDir'"
  echo "fileNameBackupExternalDataDir='$fileNameBackupExternalDataDir'"
  echo "fileNameBackupDb='$fileNameBackupDb'"
  echo ""
  echo "# TODO: The directory of your Nextcloud installation (this is a directory under your web root)"
  echo "nextcloudFileDir='$nextcloudFileDir'"
  echo ""
  echo "# The directory of your Nextcloud data directory (outside the Nextcloud file directory)"
  echo "# If your data directory is located under Nextcloud's file directory (somewhere in the web root),"
  echo "# the data directory will not be a separate part of the backup but included in the file directory backup."
  echo "nextcloudDataDir='$nextcloudDataDir'"
  echo ""
  echo "# TODO: The directory of your Nextcloud's local external storage."
  echo "# Uncomment if you use local external storage."
  echo "#nextcloudLocalExternalDataDir='/var/nextcloud_external_data'"
  echo ""
  echo "# TODO: The service name of the web server. Used to start/stop web server (e.g. 'systemctl start <webserverServiceName>')"
  echo "webserverServiceName='$webserverServiceName'"
  echo ""
  echo "# TODO: Your web server user"
  echo "webserverUser='$webserverUser'"
  echo ""
  echo "# The name of the database system (one of: mysql, mariadb, postgresql)"
  echo "# 'mysql' and 'mariadb' are equivalent, so when using 'mariadb', you could also set this variable to 'mysql' and vice versa."
  echo "databaseSystem='$databaseSystem'"
  echo ""
  echo "# Your Nextcloud database name"
  echo "nextcloudDatabase='$nextcloudDatabase'"
  echo ""
  echo "# Your Nextcloud database host/IP"
  echo "nextcloudDatabaseHost='$databaseHost'"
  echo ""
  echo "# Your Nextcloud database port"
  echo "nextcloudDatabasePort='$databasePort'"
  echo ""
  echo "# Your Nextcloud database user"
  echo "dbUser='$dbUser'"
  echo ""
  echo "# The password of the Nextcloud database user"
  echo "dbPassword='$dbPassword'"
  echo ""
  echo "# The maximum number of backups to keep (when set to 0, all backups are kept)"
  echo "maxNrOfBackups=$maxNrOfBackups"
  echo ""
  echo "# TODO: Setting to include/exclude the backup directory of the Nextcloud updater"
  echo "# Set to true in order to include the backups of the Nextcloud updater"
  echo "includeUpdaterBackups=$includeUpdaterBackups"
  echo ""
  echo "# OPTIONAL: Setting to include/exclude the Nextcloud data directory"
  echo "# Set to false to exclude the Nextcloud data directory from backup"
  echo "# WARNING: Excluding the data directory is NOT RECOMMENDED as it leaves the backup in an inconsistent state and may result in data loss!"
  echo "includeNextcloudDataDir=$includeNextcloudDataDir"

} > ./"${NextcloudBackupRestoreConf}"

echo ""
echo "Done!"
echo ""
echo ""
echo "IMPORTANT: Please check $NextcloudBackupRestoreConf if all variables were set correctly BEFORE running the backup/restore scripts!"

if [ "$useCompression" = true ] ; then
  echo ""
	echo "As compression should be used for backups, please make sure that 'bzip2' is installed"
fi

echo ""
echo ""

set +Eeuo pipefail
