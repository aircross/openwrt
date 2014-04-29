#!/bin/sh
INCLUDE_ONLY=1

. /lib/functions.sh
. ../netifd-proto.sh
. ./dhcp.sh
init_proto "$@"

proto_qmi_init_config() {
	proto_dhcp_init_config
	proto_config_add_string "device:device"
	proto_config_add_string apn
	proto_config_add_string auth
	proto_config_add_string username
	proto_config_add_string password
	proto_config_add_string pincode
}

proto_qmi_setup() {
	local interface="$1"

	local device apn auth username password pincode cid pdh
	json_get_vars device apn auth username password pincode

	[ -n "$device" ] || {
		proto_notify_error "$interface" NO_DEVICE
		proto_block_restart "$interface"
		return 1
	}
	[ -c "$device" ] || {
		proto_notify_error "$interface" NO_DEVICE
		proto_block_restart "$interface"
		return 1
	}
	
	while uqmi -s -d "$device" --get-pin-status | grep '"UIM uninitialized"' > /dev/null; do
		sleep 1;
	done
	
	[ -n "$pincode" ] && {
		uqmi -s -d "$device" --verify-pin1 "$pincode" || {
			proto_notify_error "$interface" PIN_FAILED
			proto_block_restart "$interface"
			return 1
		}
	}
	
	[ -n "$apn" ] || {
		proto_notify_error "$interface" NO_APN
		proto_block_restart "$interface"
		return 1
	}
	
	while ! uqmi -s -d "$device" --get-serving-system | grep '"registered"' > /dev/null; do
		sleep 1;
	done
	
	cid=`uqmi -s -d "$device" --get-client-id wds`
	pdh=`uqmi -s -d "$device" --set-client-id wds,"$cid" --start-network "$apn" \
	${auth:+--auth-type $auth} \
	${username:+--username $username} \
	${password:+--password $password}`
	
	uci_set_state network $interface cid "$cid"
	uci_set_state network $interface pdh "$pdh"
	
	while ! uqmi -s -d "$device" --get-data-status | grep '"connected"' > /dev/null; do
		sleep 1;
	done
		
	proto_dhcp_setup "$@"
}

proto_qmi_renew() {
	proto_dhcp_renew "$@"
}

proto_qmi_teardown() {
	local interface="$1"

	local device
	json_get_vars device
	local cid=$(uci_get_state network $interface cid)
	local pdh=$(uci_get_state network $interface pdh)
	
	[ -n "$cid" ] && {
		[ -n "$pdh" ] && {
			uqmi -s -d "$device" --set-client-id wds,"$cid" --stop-network "$pdh"
			uci_revert_state network $interface pdh
		}
		uqmi -s -d "$device" --set-client-id wds,"$cid" --release-client-id wds
		uci_revert_state network $interface cid
	}
	proto_kill_command "$interface"
}

add_protocol qmi

