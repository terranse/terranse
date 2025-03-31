#!/bin/sh

# This setup was derived from: https://www.cinderblock.tech/p/terraform-proxmox-virtual-machine-deploy/
# Note that there is zero error handling inside!

echo "You are about to create a terraform user. Please specify a password."
stty -echo
printf "Password: "
read PASSWORD
stty echo
printf "\n"

ADD_ROLE='pveum role add TerraformProv -privs "VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Monitor VM.Audit VM.PowerMgmt Datastore.AllocateSpace Datastore.Audit VM.Console SDN.Use"'
ADD_USER="pveum user add terraform-prov@pve --password ${PASSWORD}"
ADD_PERM="pveum aclmod / -user terraform-prov@pve -role TerraformProv"
ADD_TOKEN="pveum user token add terraform-prov@pve terraform-token --privsep=0"

# Approach taken from https://stackoverflow.com/a/7047560
# I think it should not be specific to bash, but not tested
TOKEN_INFO=$(cat <<EOF | ssh proxmox 
    $ADD_ROLE &&
    $ADD_USER &&
    $ADD_PERM &&
    $ADD_TOKEN
EOF
)

# TODO: Fix the output so that something more manageable is either printed or returned after script
echo "$TOKEN_INFO" | sed -nr 's/^| full-tokenid.*(terraform-prov)+$/\1/p' 
# The resulting table with tokenid and token should be inserted into main.tf, manually.
