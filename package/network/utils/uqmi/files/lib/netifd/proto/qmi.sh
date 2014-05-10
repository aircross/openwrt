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

	local device apn auth username password pincode delay modes cid pdh
	json_get_vars device apn auth username password pincode delay modes

	[ -n "$device" ] || {
		logger -p daemon.err -t "qmi[$$]" "No control device specified"
		proto_notify_error "$interface" NO_DEVICE
		proto_block_restart "$interface"
		return 1
	}
	[ -c "$device" ] || {
		logger -p daemon.err -t "qmi[$$]" "The specified control device does not exist"
		proto_notify_error "$interface" NO_DEVICE
		proto_block_restart "$interface"
		return 1
	}
	
	[ -n "$delay" ] && sleep "$delay"
	
	while ! uqmi -s -d "$device" --get-pin-status > /dev/null; do
		sleep 1;
	done
	
	[ -n "$pincode" ] && {
		uqmi -s -d "$device" --verify-pin1 "$pincode" || {
			logger -p daemon.err -t "qmi[$$]" "Incorrect PIN"
			proto_notify_error "$interface" PIN_FAILED
			proto_block_restart "$interface"
			return 1
		}
	}
	
	[ -n "$apn" ] || {
		logger -p daemon.err -t "qmi[$$]" "No APN specified"
		proto_notify_error "$interface" NO_APN
		proto_block_restart "$interface"
		return 1
	}
	
	logger -p daemon.info -t "qmi[$$]" "Waiting for network registration"
	while ! uqmi -s -d "$device" --get-serving-system | grep '"registered"' > /dev/null; do
		sleep 1;
	done
	
	[ -n "$modes" ] && uqmi -s -d "$device" --set-network-modes "$modes"
	
	logger -p daemon.info -t "qmi[$$]" "Starting network $apn"
	cid=`uqmi -s -d "$device" --get-client-id wds`
	[ $? -ne 0 ] && {
		logger -p daemon.err -t "qmi[$$]" "Unable to obtain client ID"
		proto_notify_error "$interface" NO_CID
		proto_block_restart "$interface"
		return 1
	}
	pdh=`uqmi -s -d "$device" --set-client-id wds,"$cid" --start-network "$apn" \
	${auth:+--auth-type $auth} \
	${username:+--username $username} \
	${password:+--password $password}`
	[ $? -ne 0 ] && {
		logger -p daemon.err -t "qmi[$$]" "Unable to connect, check APN and authentication"
		proto_notify_error "$interface" NO_PDH
		proto_block_restart "$interface"
		return 1
	}
	
	uci_set_state network $interface cid "$cid"
	uci_set_state network $interface pdh "$pdh"
	
	while ! uqmi -s -d "$device" --get-data-status | grep '"connected"' > /dev/null; do
		sleep 1;
	done
	
	logger -p daemon.info -t "qmi[$$]" "Connected, starting DHCP"
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
	
	logger -p daemon.info -t "qmi[$$]" "Stopping network"
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

