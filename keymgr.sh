#!/bin/bash
# Type `./keymgr.sh --help` for more info.

set -eou pipefail

# Default arguments
SALTPATH="/home/.e4crypt/salt/$USER"
WRAPPATH="/home/.e4crypt/wrap"
USE_WRAP_KEY=""
SYNC_INNER_KEYS=0
CREATE_INNER_KEY=0
LOAD_INNER_KEYS=0

# This is actually 1024 but we can't make it that big due to a bug in the e4crypt utility
EXT4_MAX_PASSPHRASE_SIZE=512
EXT4_MAX_SALT_SIZE=256
i=0


function print_help() {
    cat <<EOF
Usage:
 ./keymgr.sh [--use-wrap-key [key]] 
             [--create-inner-key] [--sync-inner-keys] [--load-inner-keys]
             [--wrap-path PATH] [--salt-path PATH]

    --use-wrap-key [key] The wrap key to be used.
                        If this option is not specified, the utility asks
                        for a password and derives the wrap key from the password.
    --create-inner-key  If specified, the utility generates a new random inner key and salt
    --sync-inner-keys   If specified, the utility adds all currently accessible inner
                        keys to the specified wrap key.
    --load-inner-keys   If specified, all inner keys of this wrap key are loaded into the keychain
    --wrap-path PATH    Path where the wrapped keys are stored
    --salt-path PATH    Path where the salts are stored
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    flag="$1"
    shift # shift arguments

    case "$flag" in
        -w|--use-wrap-key)
            if [ $# == 0 ] || [ -z "$1" ]; then
                echo "Expected argument after $flag"
                exit 1
            fi
            USE_WRAP_KEY="$1"
            shift
        ;;
        --wrap-path)
            if [ $# == 0 ] || [ -z "$1" ]; then
                echo "Expected argument after $flag"
                exit 1
            fi
            WRAPPATH="$1"
            shift
        ;;
        --salt-path)
            if [ $# == 0 ] || [ -z "$1" ]; then
                echo "Expected argument after $flag"
                exit 1
            fi
            SALTPATH="$1"
            shift
        ;;
        -s|--sync-inner-keys)
            SYNC_INNER_KEYS=1
        ;;
        -n|--create-inner-key)
            CREATE_INNER_KEY=1
        ;;
        -l|--load-inner-keys)
            LOAD_INNER_KEYS=1
        ;;
        -h|--help)
            print_help
            exit 0
        ;;
        *)
            echo "Unknown argument $flag"
            exit 1
        ;;
    esac
done


if ! [ "$USE_WRAP_KEY" == "" ]; then
    WRAP_KEY="$USE_WRAP_KEY"
else
    # Create salt for wrap keys if it doesn't exist
    if ! sudo [ -f "$SALTPATH" ]; then
        sudo mkdir -p "$(dirname "$SALTPATH")"
        sudo touch "$SALTPATH"
        sudo chmod 700 "$SALTPATH"
        sudo chown $USER:$USER "$SALTPATH"

        echo -n "Generated new outer salt: "
        head -c $EXT4_MAX_SALT_SIZE /dev/urandom | sudo tee "$SALTPATH" | xxd -c 9999 -p
    fi

    # Create new password-derived wrap key using the wrap salt
    echo -n "Enter passphrase (echo disabled): "
    e4crypt_out="$(e4crypt add_key -S 0x$(sudo xxd -c 9999 -p "$SALTPATH"))"
    echo ""
    echo "created new wrap key $e4crypt_out" | tail +2
    WRAP_KEY=$(echo "$e4crypt_out" | grep -oP '(?<=\[)[0-9a-f]+(?=\])')
fi


if ! [ "$WRAP_KEY" == "" ]; then
    # make sure a directory exists for the wrap key
    sudo mkdir -p -m=700 "$WRAPPATH/$WRAP_KEY"
    sudo chown $USER:$USER "$WRAPPATH/$WRAP_KEY"
    sudo e4crypt set_policy $WRAP_KEY "$WRAPPATH/$WRAP_KEY"
fi


if [ $SYNC_INNER_KEYS == 1 ]; then
    # Search for any auth* files. The ones we can find are unencrypted
    # so we copy those (and the associated salt file)
    INNER_KEYS="$(sudo find "$WRAPPATH" -name auth* 2>/dev/null)"
    while read -r f; do
        [ -z "$f" ] && continue # ignore empty lines
        prefix="$(sed 's/^\(.*\)auth\(.*\)$/\1/' <<< "$f")"
        suffix="$(sed 's/^\(.*\)auth\(.*\)$/\2/' <<< "$f")"

        # prevent copying to the same directory
        if [ "$prefix" -ef "$WRAPPATH/$WRAP_KEY" ]; then
            continue
        fi
        
        # find an unused key number
        while [[ -e "$WRAPPATH/$WRAP_KEY/auth$i" ]] ; do
            let ++i
        done

        # TODO: check if the same key already exists
        sudo cp "$prefix/auth$suffix" "$WRAPPATH/$WRAP_KEY/auth$i"
        sudo cp "$prefix/salt$suffix" "$WRAPPATH/$WRAP_KEY/salt$i"
        sudo [ -f "$prefix/description$suffix" ] && \
            sudo cp "$prefix/description$suffix" "$WRAPPATH/$WRAP_KEY/description$i"
    done <<< "$INNER_KEYS"
fi


if [ $CREATE_INNER_KEY == 1 ]; then
    # find an unused key number
    while [[ -e "$WRAPPATH/$WRAP_KEY/auth$i" ]] ; do
        let ++i
    done
    
    head -c $EXT4_MAX_SALT_SIZE /dev/urandom | sudo tee "$WRAPPATH/$WRAP_KEY/salt$i" > /dev/null
    echo -n `head -c $((EXT4_MAX_PASSPHRASE_SIZE / 2)) /dev/urandom | xxd -c 99999 -p` | sudo tee "$WRAPPATH/$WRAP_KEY/auth$i" > /dev/null
    echo "Created encryption key in $WRAPPATH/$WRAP_KEY/auth$i"
fi


if [ $LOAD_INNER_KEYS == 1 ]; then
    # Load all auth* files that belong to the current wrap-key
    INNER_KEYS="$(sudo find "$WRAPPATH/$WRAP_KEY" -name auth* 2>/dev/null)"
    while read -r f; do
        [ -z "$f" ] && continue # ignore empty lines
        prefix="$(sed 's/^\(.*\)auth\(.*\)$/\1/' <<< "$f")"
        suffix="$(sed 's/^\(.*\)auth\(.*\)$/\2/' <<< "$f")"
        sudo cat "$prefix/auth$suffix" | e4crypt add_key -S 0x$(sudo xxd -c 9999 -p "$prefix/salt$suffix") | tail +2
    done <<< "$INNER_KEYS"
fi
