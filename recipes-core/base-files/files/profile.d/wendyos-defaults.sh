#!/bin/sh
# WendyOS System Defaults - Updated via OTA
# This file is part of the rootfs and will be updated with each OTA update
# User customizations should go in ~/.bashrc or ~/.profile

# Set prompt
export PS1='\u@\h:\w\$ '

# Extend PATH with common directories
export PATH=$PATH:/usr/local/bin:/usr/sbin:/sbin

# WendyOS build information
if [ -f /etc/wendyos-build-id ]; then
    export WENDYOS_BUILD=$(cat /etc/wendyos-build-id)
fi

# WendyOS device UUID
if [ -f /etc/wendyos/device-uuid ]; then
    export WENDYOS_UUID=$(cat /etc/wendyos/device-uuid)
fi

# Useful aliases
alias ll='ls -la'
alias l='ls -CF'
alias la='ls -A'

# WendyOS specific commands
alias wendyos-version='cat /etc/wendyos-build-id 2>/dev/null || echo "Build ID not available"'
alias wendyos-uuid='cat /etc/wendyos/device-uuid 2>/dev/null || echo "UUID not available"'
