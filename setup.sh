#!/usr/bin/env bash

#########################################################################
# Copyright 2016, Проект "РАССВЕТ", ООО "СКАН-ПЛЮС"                     #
#                                                                       #
# This program is free software; you can redistribute it and/or modify  #
# it under the terms of the GNU General Public License as published by  #
# the Free Software Foundation; either version 2 of the License, or     #
# (at your option) any later version.                                   #
#                                                                       #
# This program is distributed in the hope that it will be useful,       #
# but WITHOUT ANY WARRANTY; without even the implied warranty of        #
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         #
# GNU General Public License for more details.                          #
#                                                                       #
# You should have received a copy of the GNU General Public License     #
# along with this program; if not, write to the Free Software           #
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA         #
# 02110-1301  USA                                                       #
#########################################################################

# установка ansible
yum install epel-release -y;
yum install ansible -y;

# создаем переменные для конфигурирования cobbler
CURDIR=$(pwd)
LOCALHOST_CONF=$CURDIR/host_vars/localhost
ALL_CONF=$CURDIR/group_vars/all
SETTINGS=$CURDIR/nebula.conf
ANSIBLE_HOSTS=$CURDIR/hosts
HOSTS_TEMPLATE=$CURDIR/roles/sysprep/templates/hosts.j2
VIRT_NAME=nvm
VIRT_UUID=$(uuidgen)
VIRT_MAC=$(echo $FQDN|md5sum|sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/')
NEW_NAME="node"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

# заполняем конфиг для установки cobbler
cat << _EOF_ >> $LOCALHOST_CONF
pxe_net: "$NET"
pxe_mask: "$NETMASK"
pxe_gw: "$GATEWAY"
pxe_dns: "$DNS_SERVER"
pxe_range_start: "$PXE_START"
pxe_range_end: "$PXE_END"
pxe_named_address: "$IP_ADDRESS"
pxe_root_passwd: "$ROOT_PASSWD"
pxe_server: "$IP_ADDRES"
_EOF_

# устанавливаем cobbler на localhost
ansible-playbook install_cobbler.yml

# пауза для установки хостов по сети
read -p "Загрузите хосты по сети и нажмите Enter ->"

# переименовываем хосты
inc=1
for host in $(cobbler system list); do
    if [[ "$host" == "default" ]]; then
        :
    else
        cobbler system rename --name=$host --newname=$NEW_NAME$inc
        hosts+=($NEW_NAME$inc)
        inc=$(($inc + 1))
    fi
done

# настраиваем сетевые параметры на хостах и заполняем файл hosts
for node in ${hosts[@]}; do
    cobbler system edit --name=$node --hostname=$node --name-servers=$DNS_SERVER --ipv6-autoconfiguration=True --netboot-enabled=True
    echo "[$node]" >> $ANSIBLE_HOSTS
    for i in $(cobbler system report --name=$node | grep "Interface =*" | awk '{print $4}'); do
        ip=$(cobbler system report --name=$node | grep -A 10 "Interface =* *: $i" | sed '$!d' | awk '{print $4}')
        if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            cobbler system edit --name=$node --interface=$i --interface-type=bridge_slave --interface-master=br0
            cobbler system edit --name=$node --interface=br0 --interface-type=bridge --ip-address=$ip --static=True --if-gateway=$GATEWAY --netmask=$NETMASK
            echo $ip >> $ANSIBLE_HOSTS
            echo >> $ANSIBLE_HOSTS
            echo $ip $node >> $HOSTS_TEMPLATE
            echo $ip $node >> /etc/hosts
        fi
    done
done

# создаем систему в cobbler для контроллера
cobbler system add --name=$VIRT_NAME --profile=CentOS7-x86_64 --hostname=$VIRT_NAME --interface=eth0 --ip-address=$CONTROLLER_IP \
--netmask=$NETMASK --static=True --name-servers=$DNS_SERVER --mac=$VIRT_MAC --gateway=$GATEWAY
cobbler sync > /dev/null 2>&1

# дополняем файл hosts информацией о контроллере
echo $CONTROLLER_IP $VIRT_NAME >> $HOSTS_TEMPLATE
echo $CONTROLLER_IP $VIRT_NAME >> /etc/hosts
echo "[$VIRT_NAME]" >> $ANSIBLE_HOSTS
echo $CONTROLLER_IP >> $ANSIBLE_HOSTS
echo >> $ANSIBLE_HOSTS
echo  "[nodes:children]" >> $ANSIBLE_HOSTS
for n in ${hosts[@]}; do
    echo $n >> $ANSIBLE_HOSTS
done

hosts+=($VIRT_NAME)

cat << _EOF_ >> $ALL_CONF
ntpserver3: "$IP_ADDRESS"
virtuid: "$VIRT_UUID"
virtname: "$VIRT_NAME"
virtip: "$CONTROLLER_IP"
virtmac: "$VIRT_MAC"
hosts: "${hosts[*]}"
_EOF_


# установка OpenNebula на узлы
ansible-playbook main.yml

echo "Установка завершена, веб интерфейс доступен по адресу: http://$CONTROLLER_IP:9869"