#!/bin/bash

IP=/sbin/ip
DHCLIENT=/sbin/dhclient
TOUCH=/bin/touch
GREP=/bin/grep
UMOUNT=/bin/umount
ECHO=/bin/echo
JOURNALCTL=/bin/journalctl
CHOWN=/bin/chown
CHMOD=/bin/chmod
MOUNT=/bin/mount
SLEEP=/bin/sleep
MKDIR=/bin/mkdir
LXC_ATTACH=/bin/lxc-attach
LXC_COPY=/bin/lxc-copy
LXC_START=/bin/lxc-start
LXC_STOP=/bin/lxc-stop
LXC_DESTROY=/bin/lxc-destroy
UDISKSCTL=/bin/udisksctl
FRESHCLAM=/bin/freshclam
CLAMSCAN=/bin/clamscan
RM=/bin/rm
INFORM_USER=/bin/pleiade-usb-userinfo.sh

SUBUID=$($GREP "root" /etc/subuid | /bin/cut -d':' -f2)

#Fichier de log des analyses de ClamAV 
$TOUCH /var/log/usb_log.txt
# Clean mounting folder
$RM -rf /media/*
#Le s�parateur de la boucle for doit �tre modifi� pour garder les lignes enti�res (par d�faut : ' ')
IFS=$'\n'


#Launch usb container
$LXC_START -n pleiade-usb
$LXC_ATTACH -n pleiade-usb -- $IP link add dev lxcbr0 type bridge
$LXC_ATTACH -n pleiade-usb -- $IP link set dev eth0 master lxcbr0


#Destruction du container de montage et restauration de la sauvegarde "saine"
$ECHO "Destruction du container de montage"
$LXC_ATTACH -n pleiade-usb -- $LXC_DESTROY -n montage -f
$ECHO "D�marrage du container save"
$LXC_ATTACH -n pleiade-usb -- $LXC_START -n save
$ECHO "Mise � jour de la base virale"
$LXC_ATTACH -n pleiade-usb -- $LXC_ATTACH -n save -- $FRESHCLAM &> /dev/null
$ECHO "Arr�t du container save"
$LXC_ATTACH -n pleiade-usb -- $LXC_STOP -n save
$SLEEP 1
$ECHO "Copie du container save"
$LXC_ATTACH -n pleiade-usb -- $LXC_COPY -n save -N montage
$SLEEP 0.5
$ECHO "D�marrage du container de montage"
$LXC_ATTACH -n pleiade-usb -- $LXC_START -n montage
$ECHO "Container pr�t pour une nouvelle analyse"



#Liste des �l�ments connect�s � la machine ("connected", "disconnected")
declare -A dev_list
#R�sultats d'analyse des p�riph�riques ("no", "progressing", "clean", "virus" ou "erreur")
declare -A dev_clam
#Emplacement dans /dev
declare -A dev_name
#Emplacement du montage ("", "container" ou "nfs")
declare -A dev_mount

while true
do
	#Inventaire des p�riph�riques connect�s
	for device in $($JOURNALCTL -b -kq --no-hostname | $GREP -oP "new high-speed USB device number \K\d+")
	do
		if [ "$($JOURNALCTL -b -kq --no-hostname | $GREP -oP "USB disconnect, device number $device")" == "" ]
		then
			if [ "${dev_clam[$device]}" == "" ]
			then
				dev_list[$device]="connected"
				$SLEEP 2
				dev_name[$device]=$($JOURNALCTL -b -kq --no-hostname | $GREP -A14 -P "new high-speed USB device number $device" | $GREP -oP "sd[^a]: \Ksd[^a]\d+")
				dev_clam[$device]="no"
				dev_mount[$device]=""
			fi
		else
			dev_list[$device]="disconnected"
			dev_name[$device]=""
			dev_clam[$device]=""
			dev_mount[$device]=""
			#G�re le cas o� la cl� a �t� retir�e durant l'analyse
			if [ "${dev_clam[$device]}" == "progressing" ]
			then
				$UMOUNT /var/lib/lxc/pleiade-usb/rootfs/var/lib/lxc/montage/rootfs/media/$device
			fi
		fi
	done

	#Analyse des devices
	for device in "${!dev_list[@]}"
	do
		if [ "${dev_list[$device]}" == "connected" ] && [ ! "${dev_mount[$device]}" == "nfs" ] && [ ! "${dev_clam[$device]}" == "clean" ]
		then
			$INFORM_USER "started" $device
			#Montage dans le container "Montage"
			$ECHO "Montage du p�riph�rique no$device"
			$MKDIR /var/lib/lxc/pleiade-usb/rootfs/var/lib/lxc/montage/rootfs/media/$device
			$CHOWN $SUBUID:$SUBUID /var/lib/lxc/pleiade-usb/rootfs/var/lib/lxc/montage/rootfs/media/$device
			$CHMOD 400 /var/lib/lxc/pleiade-usb/rootfs/var/lib/lxc/montage/rootfs/media/$device
			$MOUNT /dev/${dev_name[$device]} /var/lib/lxc/pleiade-usb/rootfs/var/lib/lxc/montage/rootfs/media/$device
			$SLEEP 1
			#Analyse
			$ECHO "Analyse du p�riph�rique no$device"
			dev_mount[$device]="container"
			dev_clam[$device]="progressing"
			$ECHO -e "\n++++++++++NEW++++++++++\n" >> /var/log/usb_log.txt
			$ECHO -e "$device : Analyse du $(/bin/date +%d-%m-%y) � $(/bin/date +%H:%M:%S)" >> /usr/share/usb_log.txt
			$LXC_ATTACH -n pleiade-usb -- $LXC_ATTACH -n montage -- $FRESHCLAM > /dev/null
			$LXC_ATTACH -n pleiade-usb -- $LXC_ATTACH -n montage -- $CLAMSCAN -ir /media/$device >> /usr/share/usb_log.txt 2> /dev/null
			if [ $? == 0 ]
			then
				#Montage dans le container "NFS"
				$UMOUNT /var/lib/lxc/pleiade-usb/rootfs/var/lib/lxc/montage/rootfs/media/$device
				$RM -rf /var/lib/lxc/pleiade-usb/rootfs/var/lib/lxc/montage/rootfs/media/$device
				dev_clam[$device]="clean"
				$ECHO "Montage du p�riph�rique no$device sur nfs"
				$MKDIR /var/lib/lxc/pleiade-usb/rootfs/media/$device
				#Sans changer les droits, le dossier cr�� appartient au root de la machine h�te
				$CHOWN $SUBUID:$SUBUID /var/lib/lxc/pleiade-usb/rootfs/media/$device
				$CHMOD 400 /var/lib/lxc/pleiade-usb/rootfs/media/$device
				$MOUNT /dev/${dev_name[$device]} /var/lib/lxc/pleiade-usb/rootfs/media/$device
				dev_mount[$device]="nfs"
				$INFORM_USER "clean" $device
			elif [ $? == 1 ]
			then
				#Virus d�tect�
				dev_clam[$device]="virus"
				$ECHO "Virus trouv�(s) sur le p�riph�rique no$device"
				$UMOUNT /var/lib/lxc/pleiade-usb/rootfs/var/lib/lxc/montage/rootfs/media/$device
				$UDISKSCTL poweroff -b /dev/${dev_name[$device]::-1}
				$RM -rf /var/lib/lxc/pleiade-usb/rootfs/var/lib/lxc/montage/rootfs/media/$device
				$INFORM_USER "virus" $device
			else
				#Erreur inconnue (permission manquante, ...)
				dev_clam[$device]="erreur"
				$ECHO "Une erreur est survenue sur le p�riph�rique no$device"
				$UMOUNT /var/lib/lxc/pleiade-usb/rootfs/var/lib/lxc/montage/rootfs/media/$device
				$UDISKSCTL poweroff -b /dev/${dev_name[$device]::-1}
				$RM -rf /var/lib/lxc/pleiade-usb/rootfs/var/lib/lxc/montage/rootfs/media/$device
				$INFORM_USER "error" $device
			fi
			#Destruction du container de montage et restauration de la sauvegarde "saine"
			$ECHO "Destruction du container de montage"
			$LXC_ATTACH -n pleiade-usb -- $LXC_DESTROY -n montage -f
			$ECHO "D�marrage du container save"
			$LXC_ATTACH -n pleiade-usb -- $LXC_START -n save
			$ECHO "Mise � jour de la base virale"
			$LXC_ATTACH -n pleiade-usb -- $LXC_ATTACH -n save -- $FRESHCLAM &> /dev/null
			$ECHO "Arr�t du container save"
			$LXC_ATTACH -n pleiade-usb -- $LXC_STOP -n save
			$SLEEP 1
			$ECHO "Copie du container save"
			$LXC_ATTACH -n pleiade-usb -- $LXC_COPY -n save -N montage
			$SLEEP 0.5
			$ECHO "D�marrage du container de montage"
			$LXC_ATTACH -n pleiade-usb -- $LXC_START -n montage
			$ECHO "Container pr�t pour une nouvelle analyse"
		fi
	done
done
