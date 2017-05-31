#!/bin/bash

# Reset the Yubikey OpenPGP applet
# WARNING: This will reset the PIN codes!
function yubikey_reset_pgp_applet() {
    # We provide a wrong user and then admin PIN to the verify mechanism to
    # lock the key, then we send the command to terminate and reset the applet.
    gpg-connect-agent --hex \
        "scd apdu 00 20 00 81 08 40 40 40 40 40 40 40 40" \
        "scd apdu 00 20 00 81 08 40 40 40 40 40 40 40 40" \
        "scd apdu 00 20 00 81 08 40 40 40 40 40 40 40 40" \
        "scd apdu 00 20 00 81 08 40 40 40 40 40 40 40 40" \
        "scd apdu 00 20 00 83 08 40 40 40 40 40 40 40 40" \
        "scd apdu 00 20 00 83 08 40 40 40 40 40 40 40 40" \
        "scd apdu 00 20 00 83 08 40 40 40 40 40 40 40 40" \
        "scd apdu 00 20 00 83 08 40 40 40 40 40 40 40 40" \
        "scd apdu 00 e6 00 00" \
        "scd apdu 00 44 00 00" \
    /bye
}

# Reset the Yubikey PIV applet
# WARNING: This will reset the PIN/PUK codes!
function yubikey_reset_piv_applet() {
    local invalid_puk=999999
    local invalid_pin=9999

    # Enter the PIN incorrectly three times, then enter the PUK incorrectly
    # three times, and finally reset the applet using the yubico-piv-tool.
    yubico-piv-tool -a verify-pin -P ${invalid_pin}
    yubico-piv-tool -a verify-pin -P ${invalid_pin}
    yubico-piv-tool -a verify-pin -P ${invalid_pin}
    yubico-piv-tool -a change-puk -P ${invalid_pin} -N ${invalid_puk}
    yubico-piv-tool -a change-puk -P ${invalid_pin} -N ${invalid_puk}
    yubico-piv-tool -a change-puk -P ${invalid_pin} -N ${invalid_puk}
    yubico-piv-tool -a reset
}

# Reset the slots configuration
# WARNING: You will loose the slot's content!
function yubikey_reset_slots() {
    # Reset the configuration in slots 1 and 2
    ykpersonalize -y -1 -z
    ykpersonalize -y -2 -z
}

# Backup slot configuration into a file.
yubikey_backup_slot() {
    local slot=$1
    local filename=$2

    # Ensure we are given a valid slot number.
    [[ "${slot}" =~ ^(1|2)$ ]] || return -1

    # Backup the configuration of the given slot.
    ykpersonalize -${slot} -s${filename}

    echo "${FUNCNAME[0]}: slot ${slot} saved in ${filename}"
}

# Get the most from the Yubikey NEO.
function yubikey_enable_all_modes() {
    # Timeout (in seconds) for the YubiKey to wait on  button  press  for
    # challenge response (default: 15)
    local challenge_timeout=15
    local autoeject_timeout=

    # Enable OTP/U2F/CCID composite device (0x06),
    # and set MODE_FLAG_EJECT flag (0x80).
    ykpersonalize -y -m86:${challenge_timeout}:${autoeject_timeout}
}

# Reset the OAUTH applet (as configured in one of the two slots.)
function yubikey_reset_oauth_applet() {
    # Reset the OAuth applet using OpenSC and an APDU command.
    opensc-tool -s 00a4040008a000000527210101 -s 0004dead
}

function main() {
    REQUIRED_PROGRAMS="gpg-connect-agent \
                       opensc-tool \
                       ykpersonalize \
                       yubico-piv-tool"

    if [ ! -e /run/pcscd/pcscd.comm ]; then
         echo "pcscd is not running, Bye!"
         exit 1
    fi

    for prog in $REQUIRED_PROGRAMS; do
         if ! command -v $prog >/dev/null 2>&1; then
             echo "$prog is not installed, Bye!"
             exit 1
         fi
    done

    # Restore the Yubikey to it's default state.
    yubikey_reset_piv_applet
    yubikey_reset_pgp_applet
    yubikey_reset_slots
    yubikey_backup_slot 1 slot1_defaults.config
    yubikey_backup_slot 2 slot2_defaults.config

    # Configure the Yubikey as wished.
    yubikey_enable_all_modes

    exit 0
}

main $@
