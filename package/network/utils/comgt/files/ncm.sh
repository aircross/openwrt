#!/bin/sh

. /lib/functions.sh
. ../netifd-proto.sh
init_proto "$@"

proto_ncm_init_config() {
	proto_config_add_string "device:device"
	proto_config_add_string apn
	proto_config_add_string auth
	proto_config_add_string username
	proto_config_add_string password
	proto_config_add_string pincode
	proto_config_add_string delay
	proto_config_add_string modes
}

proto_ncm_setup() {
	local interface="$1"

	local cardinfo authtype mode initialize setmode connect

	local device apn auth username password pincode delay modes
	json_get_vars device apn auth username password pincode delay modes

	[ -n "$device" ] || {
		logger -p daemon.err -t "ncm[$$]" "No control device specified"
		proto_notify_error "$interface" NO_DEVICE
		proto_block_restart "$interface"
		return 1
	}
	[ -c "$device" ] || {
		logger -p daemon.err -t "ncm[$$]" "The specified control device does not exist"
		proto_notify_error "$interface" NO_DEVICE
		proto_block_restart "$interface"
		return 1
	}
	[ -n "$apn" ] || {
		logger -p daemon.err -t "ncm[$$]" "No APN specified"
		proto_notify_error "$interface" NO_APN
		proto_block_restart "$interface"
		return 1
	}

	[ -n "$delay" ] && sleep "$delay"

	cardinfo=`gcom -d "$device" -s /etc/gcom/getcardinfo.gcom`

	[ -n "$pincode" ] && {
		PINCODE="$pincode" gcom -d "$device" -s /etc/gcom/setpin.gcom || {
			logger -p daemon.err -t "ncm[$$]" "Unable to verify PIN"
			proto_notify_error "$interface" PIN_FAILED
			proto_block_restart "$interface"
			return 1
		}
	}

	if echo "$cardinfo" | grep -qi huawei; then
		case "$auth" in
			pap) authtype=1;;
			chap) authtype=2;;
		esac
		case "$modes" in
			lte) mode="\"03\"";;
			umts) mode="\"02\"";;
			gsm) mode="\"01\"";;
			*) mode="\"00\"";;
		esac

		setmode="AT^SYSCFGEX=${mode},3fffffff,2,4,7fffffffffffffff,,"
		connect="AT^NDISDUP=1,1,\"${apn}\"${username:+,\"$username\"}${password:+,\"$password\"}${authtype:+,$authtype}"
	else
		logger -p daemon.info -t "ncm[$$]" "Device is not supported."
		proto_notify_error "$interface" UNSUPPORTED_DEVICE
		proto_block_restart "$interface"
		return 1
	fi

	[ -n "$initialize" ] && {
		COMMAND="$initialize" gcom -d "$device" -s /etc/gcom/runcommand.gcom
		[ $? -ne 0 ] && {
			logger -p daemon.err -t "ncm[$$]" "Failed to initialize modem"
			proto_notify_error "$interface" INITIALIZE_FAILED
			proto_block_restart "$interface"
			return 1
		}
	}
	[ -n "$setmode" ] && {
		COMMAND="$setmode" gcom -d "$device" -s /etc/gcom/runcommand.gcom
		[ $? -ne 0 ] && {
			logger -p daemon.err -t "ncm[$$]" "Failed to set operating mode"
			proto_notify_error "$interface" SETMODE_FAILED
			proto_block_restart "$interface"
			return 1
		}
	}

	COMMAND="$connect" gcom -d "$device" -s /etc/gcom/runcommand.gcom
	[ $? -ne 0 ] && {
		logger -p daemon.err -t "ncm[$$]" "Failed to connect"
		proto_notify_error "$interface" CONNECT_FAILED
		proto_block_restart "$interface"
		return 1
	}

	logger -p daemon.info -t "ncm[$$]" "Connected, starting DHCP"
	proto_init_update "*" 1
	proto_send_update "$interface"

	json_init
	json_add_string name "${interface}_dhcp"
	json_add_string ifname "@$interface"
	json_add_string proto "dhcp"
	json_close_object
	ubus call network add_dynamic "$(json_dump)"

	json_init
	json_add_string name "${interface}_dhcpv6"
	json_add_string ifname "@$interface"
	json_add_string proto "dhcpv6"
	json_close_object
	ubus call network add_dynamic "$(json_dump)"
}

proto_ncm_teardown() {
	local interface="$1"

	local cardinfo disconnect

	local device 
	json_get_vars device

	logger -p daemon.info -t "ncm[$$]" "Stopping network"

	cardinfo=`gcom -d "$device" -s /etc/gcom/getcardinfo.gcom`

	if echo "$cardinfo" | grep -qi huawei; then
		disconnect="AT^NDISDUP=1,0"
	else
		logger -p daemon.info -t "ncm[$$]" "Device is not supported."
		proto_notify_error "$interface" UNSUPPORTED_DEVICE
		proto_block_restart "$interface"
		return 1
	fi

	COMMAND="$disconnect" gcom -d "$device" -s /etc/gcom/runcommand.gcom
	[ $? -ne 0 ] && {
		logger -p daemon.err -t "ncm[$$]" "Failed to disconnect"
		proto_notify_error "$interface" DISCONNECT_FAILED
		proto_block_restart "$interface"
		return 1
	}

	proto_init_update "*" 0
	proto_send_update "$interface"
}

add_protocol ncm
