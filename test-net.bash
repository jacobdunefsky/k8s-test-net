#!/bin/bash

exec 3>&1
exec &>> /var/log/test-net.log

# first, some functions for dealing with ips
# (these are the same as in setup.bash)

# takes in an ip addr in CIDR notation, outputs the lowest addr in that subnet
function GET_LOWEST_ADDR {
	echo $1 | awk -F'[./]' 'BEGIN {ORS=""} { SUBNET=$5; FIELD=int(SUBNET/8)+1; for (i=1;i<FIELD;i++) { print $i"."; } OFFSET=8-(SUBNET%8); FIRST_IP=1; for(i=0;i<OFFSET;i++){ FIRST_IP=FIRST_IP*2; } print($FIELD-($FIELD % FIRST_IP)); for(i=FIELD+1;i<=4;i++){ print(".0"); }}'
}

# takes in an ip addr, spits out the next ip
function GET_NEXT_ADDR {
	echo $1 | awk -F'[.]' 'BEGIN {ORS=""}{ CUR_FIELD=4; for(;CUR_FIELD>0;CUR_FIELD--){ FIELD_ADDR=$CUR_FIELD; FIELD_ADDR=FIELD_ADDR+1; if(FIELD_ADDR < 256) break; } for(i=1;i<CUR_FIELD;i++){ print $i "."; } print FIELD_ADDR; for(i=CUR_FIELD+1;i<=4;i++){ print ".0" }}'
}

MY_NS_NAME="k8s$CNI_CONTAINERID"

# reserved ips are listed in /run/k8s_reserved_ips
RESERVED_FILE=/run/k8s_reserved_ips

case $CNI_COMMAND in
ADD)

	# first: create netns
	#ip netns a $MY_NS_NAME
	ln -s -f -T $CNI_NETNS /run/netns/$MY_NS_NAME
	echo $CNI_NETNS

	# next, create veth pair
	# set up the host end

	# hash the container id to come up with a unique(-ish) name
	VETHNAME=$(echo -n "$CNI_CONTAINERID" |\
		md5sum |\
		awk '{print $1}' |\
		tail -c 6)
	VETHNAME="veth$VETHNAME"
	ip l a $CNI_IFNAME type veth peer name $VETHNAME
	ip l s $VETHNAME up
	ip l s $VETHNAME master k8sbr

	# get bridge ip
	BRIP=$(ip a | grep k8sbr | awk '/inet /{print $2}' |\
		awk -F '/' '{print $1}')

	# set up the container end
	ip l s $CNI_IFNAME netns $MY_NS_NAME
	ip netns exec $MY_NS_NAME ip l s $CNI_IFNAME up

	# ipam time
	# note that we're not using a lock, even though we should

	# loop through all reserved IPs
	# note that this is SUPER INEFFICIENT
	CUR_IP=$(GET_NEXT_ADDR $(head $RESERVED_FILE -n 1))
	while grep "$CUR_IP" $RESERVED_FILE; do
		CUR_IP=$(GET_NEXT_ADDR $CUR_IP)
	done

	# reserve our new ip
	echo "$CUR_IP" >> $RESERVED_FILE

	# assign our new ip to our new veth
	ip netns exec $MY_NS_NAME ip a a $CUR_IP dev $CNI_IFNAME
	# route everything through this interface
	ip netns exec $MY_NS_NAME ip r a $BRIP dev $CNI_IFNAME
	ip netns exec $MY_NS_NAME ip r a default via $BRIP # dev $CNI_IFNAME

	# get veth mac addr
	MAC=$(ip netns exec $MY_NS_NAME ip l show $CNI_IFNAME |\
		awk '/ether/ {print $2}')

	POD_CIDR=$(kubectl --kubeconfig /etc/kubernetes/kubelet.conf get nodes -o json |\
		jq --raw-output ".items[] | select((.status.addresses[] | select(.type==\"Hostname\")).address==\"$(hostname)\") | .spec.podCIDR")
	POD_SUBNET_SIZE=$(echo $POD_CIDR | awk -F '[/]' '{print $2}')

	>&3 cat <<EOF
{
	"cniVersion": "0.4.0",
	"interfaces": [{
		"name": "$CNI_IFNAME",
		"mac": "$MAC",
		"sandbox": "$CNI_NETNS"

	}],
	"ips": [{
		"version": "4",
		"address": "$CUR_IP/$POD_SUBNET_SIZE",
		"gateway": "$(cat $RESERVED_FILE | head -2 | tail -1)",
		"interface": 0
	}]
}
EOF

cat <<EOF
{
	"cniVersion": "0.4.0",
	"interfaces": [{
		"name": "$CNI_IFNAME",
		"mac": "$mac",
		"sandbox": "$CNI_NETNS"

	}],
	"ips": [{
		"version": "4",
		"address": "$CUR_IP/$POD_SUBNET_SIZE",
		"gateway": "$(cat $RESERVED_FILE | head -2 | tail -1)",
		"interface": 0
	}]
}
EOF
	;;

DEL)
	IP_ADDR_REGEX="([1-2]?[1-9]?[0-9]\.){3}[1-2]?[1-9]?[0-9]"
	IP=$(ip netns exec $MY_NS_NAME ip a s $CNI_IFNAME|\
		tr -d [:blank:]|\
		awk -F '[t/]' '/inet/ {print $2}'|\
		egrep -o "$IP_ADDR_REGEX")
	sed -i "/$IP/d" $RESERVED_FILE
	;;
CHECK)
	exit 1
	;;
VERSION)
	echo '{ "cniVersion": "0.4.0", "supportedVersions": ["0.4.0"]}'>&3
	;;
esac
