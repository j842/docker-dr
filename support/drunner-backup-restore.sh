#!/bin/bash


#------------------------------------------------------------------------------------

# backup BACKUPFILE
# global variables ready: ROOTPATH, DRSERVICESPATH, SUPPORTIMAGE, SERVICENAME, SERVICEPATH, SERVICEVARIABLESPATH, IMAGENAME
function backup {
   if [ -z "$1" ]; then die "No BACKUPFILE was specified." ; fi
   local BACKUPFILE=$(realpath "$1" | tr -d '\r\n')
   if [ -e "$BACKUPFILE" ]; then die "$BACKUPFILE already exists. Aborting." ; fi
   
   # only backup valid services. (otherwise recover then backup!)
   "${ROOTPATH}/support/validator-service" "$SERVICENAME" || die "Use ${CODE_S}drunner recover ${SERVICENAME}${CODE_E} before backing up."
   
   local TEMPROOT="$(mktemp -d)"
   
   ( # SUBSHELL so we can tidy up easily if it goes wrong.
      # bail if any command returns an error!
      set -e
      
      local TEMPPARENT="${TEMPROOT}/backup"
      local TEMPF="${TEMPPARENT}/drbackup"
      mkdir -p "$TEMPF"
      local TEMPC="${TEMPPARENT}/containerbackup"
      mkdir -p "$TEMPC"
      
      # output variables needed for restore to the tempparent folder
      STR_DOCKERVOLS=""
      if [ -v DOCKERVOLS ]; then printf -v STR_DOCKERVOLS "\"%s\" " "${DOCKERVOLS[@]}" ; fi
      cat <<EOF >"${TEMPPARENT}/_oldvariables"
# Auto generated by Docker Runner
OLDDOCKERVOLS=($STR_DOCKERVOLS)
IMAGENAME="${IMAGENAME}"
EOF

      # call through to container to backup anything there in a subfolder.
      # important this is called before backing up any volume containers, as
      # it might put stuff in them.
      getUSERID "$IMAGENAME"
      chown "${USERID}" "${TEMPC}"
      "${ROOTPATH}/services/${SERVICENAME}/drunner/servicerunner" backupstart "$TEMPC"
                  
      # back up our volume containers
      if [ -v DOCKERVOLS ]; then
         for VOLNAME in "${DOCKERVOLS[@]}"; do      
            volexists "$VOLNAME"
            [ $? -eq 0 ] || die "A docker volume required for the backup was missing: $VOLNAME"
            "${ROOTPATH}/support/compress" "$VOLNAME" "${TEMPF}" "${VOLNAME}.tar.7z"
            [ -e "${TEMPF}/${VOLNAME}.tar.7z" ] || die "Unable to back up ${VOLNAME}."
         done      
      fi

      "${ROOTPATH}/services/${SERVICENAME}/drunner/servicerunner" backupend "$TEMPC"
      
      # Compress everything with password
      "${ROOTPATH}/support/compress" "$TEMPPARENT" "$TEMPROOT" backupmain.tar.7z
      mv "${TEMPROOT}/backupmain.tar.7z" "$BACKUPFILE"
   )
   RVAL="$?" 
   rm -r "${TEMPROOT}"
   [ $RVAL -eq 0 ] || die "Backup failed. Temp files have been removed."
   
   echo " ">&2
   echo "Backed up to $BACKUPFILE succesfully.">&2
}

#------------------------------------------------------------------------------------

# restore BACKUPFILE
function restore {
   if [ -z "$1" ]; then die "No BACKUPFILE was specified." ; fi
   local BACKUPFILE=$(realpath "$1" | tr -d '\r\n')
   if [ ! -e "$BACKUPFILE" ]; then die "$BACKUPFILE doesn't exist. Aborting." ; fi
   if [ -e "${ROOTPATH}/services/${SERVICENAME}" ]; then die "$SERVICENAME exists - destroy it before restoring from backup." ; fi
   
   local TEMPROOT="$(mktemp -d)"
   
   ( # SUBSHELL so we can tidy up easily if it goes wrong.
      # bail if any command returns an error!
      set -e

      local TEMPPARENT="${TEMPROOT}/backup"
      mkdir -p "$TEMPPARENT"
      local TEMPF="${TEMPPARENT}/drbackup"
      local TEMPC="${TEMPPARENT}/containerbackup"
      
      # decompress the main backup
      cp "$BACKUPFILE" "${TEMPROOT}/backupmain.tar.7z"
      "${ROOTPATH}/support/decompress" "$TEMPPARENT" "$TEMPROOT" "backupmain.tar.7z"

      # loads the old DOCKERVOLS and IMAGENAME
      source "${TEMPPARENT}/_oldvariables"
         
      # check backup has key files.
      if [ ! -e "$TEMPC" ]; then die "Backup corrupt. Missing ${TEMPC}."; fi
      if [ -v OLDDOCKERVOLS ]; then
         for NEEDEDFILE in "${OLDDOCKERVOLS[@]}"; do
            if [ ! -e "${TEMPF}/${NEEDEDFILE}.tar.7z" ]; then die "Backup corrupt. Missing backup file for docker volume ${NEEDEDFILE}."; fi
         done
      fi
      
      # now can install base service. 
      ( # install in another subshell so it doesn't exit on us.
      installservice
      )
      RVAL="$?"
      if [ $RVAL -ne 0 ]; then echo "Fail on install - aborting.">&2 ; exit $RVAL ; fi
      
      # load DOCKERVOLS etc so we can restore the volumes.
      validateLoadService
         
      # restore volumes.
      # zip file names are based on the _old_ DOCKERVOLS, new volume name based on hte new ones.
      if [ -v OLDDOCKERVOLS ]; then
         if [ "${#OLDDOCKERVOLS[@]}" -gt "${#DOCKERVOLS[@]}" ]; then die "The number of volume containers the image requires has decreased. Not safe to restore." ; fi
         if [ "${#OLDDOCKERVOLS[@]}" -lt "${#DOCKERVOLS[@]}" ]; then echo "The number of volume containers the image specifies has increased. We'll restore what we can, but this container might not work :/" ; fi

         for i in "${!OLDDOCKERVOLS[@]}"; do      
            OLDVOLNAME="${OLDDOCKERVOLS[i]}"
            NEWVOLNAME="${DOCKERVOLS[i]}"
            
            "${ROOTPATH}/support/decompress" "$NEWVOLNAME" "${TEMPF}" "${OLDVOLNAME}.tar.7z"
         done
      fi
      
      # call through to container to restore its backup in TEMPC. Imporant this is the last step,
      # so it can use any docker volumes, the variables.sh file etc.
      "${ROOTPATH}/services/${SERVICENAME}/drunner/servicerunner" restore "$TEMPC"
   )
   RVAL="$?"
   rm -r "${TEMPROOT}"  
   if [ $RVAL -ne 0 ]; then 
      if [ -e "${ROOTPATH}/services/${SERVICENAME}" ]; then 
         obliterateService 
      fi
      die "Restore failed. Temp files have been removed, system back in clean state."
   fi
      
   echo "The backup ${BACKUPFILE##*/} has been restored to ${SERVICENAME}."
   
   # our globals haven't been updated outside the subshell (IMAGENAME not set for example) so exit to be safe.
   exit 0
}
