#!/bin/bash -x

# a useful IP addr regex
IP_ADDR_REGEX="([1-2]?[1-9]?[0-9]\.){3}[1-2]?[1-9]?[0-9]"

# now, find out subnet allocated for our cluster
CLUSTER_CIDR=$(kubectl get cm -o yaml -n kube-system kubeadm-config |\
	grep podSubnet |\
	awk '{print $2}')
CLUSTER_CIDR=$(echo $CLUSTER_CIDR |\
	egrep -o "$IP_ADDR_REGEX/[1-9]?[1-9]")

# get subnet allocated for this node's pods
POD_CIDR=$(kubectl get nodes -o json |\
	jq --raw-output ".items[] | select((.status.addresses[] | select(.type==\"Hostname\")).address==\"$(hostname)\") | .spec.podCIDR")

# set up iptables forwarding rules

iptables -t filter -A FORWARD -s $CLUSTER_CIDR -j ACCEPT
iptables -t filter -A FORWARD -d $CLUSTER_CIDR -j ACCEPT

# to deal with subnets, we have to define the following functions

# takes in an ip addr in CIDR notation, outputs the lowest addr in that subnet
function GET_LOWEST_ADDR {
	echo $1 | awk -F'[./]' 'BEGIN {ORS=""} { SUBNET=$5; FIELD=int(SUBNET/8)+1; for (i=1;i<FIELD;i++) { print $i"."; } OFFSET=8-(SUBNET%8); FIRST_IP=1; for(i=0;i<OFFSET;i++){ FIRST_IP=FIRST_IP*2; } print($FIELD-($FIELD % FIRST_IP)); for(i=FIELD+1;i<=4;i++){ print(".0"); }}'
}

# takes in an ip addr, spits out the next ip
function GET_NEXT_ADDR {
	echo $1 | awk -F'[.]' 'BEGIN {ORS=""}{ CUR_FIELD=4; for(;CUR_FIELD>0;CUR_FIELD--){ FIELD_ADDR=$CUR_FIELD; FIELD_ADDR=FIELD_ADDR+1; if(FIELD_ADDR < 256) break; } for(i=1;i<CUR_FIELD;i++){ print $i "."; } print FIELD_ADDR; for(i=CUR_FIELD+1;i<=4;i++){ print ".0" }}'
}

MY_LOWEST_ADDR=$(GET_LOWEST_ADDR $POD_CIDR)
BRIDGE_ADDR=$(GET_NEXT_ADDR $MY_LOWEST_ADDR)
# set up bridge
brctl addbr k8sbr
ip l s k8sbr up
ip a a "$BRIDGE_ADDR/$(echo $POD_CIDR | awk -F '/' '{print $2}')" dev k8sbr
ip r a $CLUSTER_CIDR dev k8sbr

# reserve bridge IP (used by IPAM)
echo $MY_LOWEST_ADDR > /run/k8s_reserved_ips
echo $BRIDGE_ADDR >> /run/k8s_reserved_ips

# also, set up NAT
iptables -t nat -A POSTROUTING -s $POD_CIDR ! -o k8sbr -j MASQUERADE

# find the network interface on which the default gateway is reachable
DEFAULT_IF=$(ip r | grep default | egrep -o "dev ([a-z]|[0-9])+? " | awk '{print $2}')

# set up vxlan
ip l a k8svx type vxlan id 473 group 239.0.0.0 dstport 4789 dev $DEFAULT_IF
ip l s k8svx up
ip l s k8svx master k8sbr
