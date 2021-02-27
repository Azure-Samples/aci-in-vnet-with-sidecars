###############################################
# Azure Container Instances with Azure CLI
#
# Tested with zsh (if run with bash there are probably A LOT of missing "")
#
# Jose Moreno, January 2021
###############################################

# Variables
dns_zone_name=contoso.com
vnet_name=acivnet
vnet_prefix=192.168.0.0/16
appgw_subnet_name=appgw
appgw_subnet_prefix=192.168.1.0/24
aci_subnet_name=aci
aci_subnet_prefix=192.168.2.0/24
sql_subnet_name=sql
sql_subnet_prefix=192.168.3.0/24
sql_db_name=mydb
sql_username=azure
appgw_name=appgw
appgw_pip_name="${appgw_name}-pip"
appgw_pip_dns="${appgw_name}-${unique_id}"
dns_subnet_name=dnsservers
dns_subnet_prefix=192.168.4.0/24

# Argument parsing (can overwrite the previously initialized variables)
for i in "$@"
do
     case $i in
          -g=*|--resource-group=*)
               rg="${i#*=}"
               shift # past argument=value
               ;;
          -l=*|--location=*)
               location="${i#*=}"
               shift # past argument=value
               ;;
          -u=*|--username=*)
               sql_username="${i#*=}"
               shift # past argument=value
               ;;
          -p=*|--password=*)
               sql_password="${i#*=}"
               shift # past argument=value
               ;;
          -z=*|--private-dns-zone-name=*)
               dns_zone_name="${i#*=}"
               shift # past argument=value
               ;;
          -d=*|--public-dns-zone-name=*)
               public_domain="${i#*=}"
               shift # past argument=value
               ;;
     esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

# Function to generate random string
function random_string () {
    if [[ -n "$1" ]]
    then
      length=$1
    else
      length=6
    fi
    echo "$(tr -dc a-z </dev/urandom | head -c $length ; echo '')"
}

# Generate a 6-character, lower-case alphabetic, random string
unique_id=$(random_string 6)

# Create RG
sub_name=$(az account show --query name -o tsv)
rg_id=$(az group show -n "$rg" --query id -o tsv)
if [[ -z "$rg_id" ]]
then
  echo "INFO: Creating new resource group..."
  az group create -n "$rg" -l "$location"
else 
  echo "INFO: Resource group $rg already exists in subscription $sub_name"
fi

# Create ACR
acr_name=$(az acr list -g "$rg" --query '[0].name' -o tsv)
if [[ -z "$acr_name" ]]
then
  echo "INFO: Creating new ACR..."
  acr_name="acilab${unique_id}"
  az acr create -n "$acr_name" -g "$rg" --sku Premium
  az acr update -n "$acr_name" --admin-enabled true
else
  echo "INFO: ACR $acr_name found in resource group $rg"
fi

# Create Vnet
vnet_id=$(az network vnet show -n "$vnet_name" -g "$rg" --query id -o tsv 2>/dev/null)
if [[ -z "$vnet_id" ]]
then
  echo "INFO: Creating new Vnet..."
  az network vnet create -n "$vnet_name" -g "$rg" --address-prefix "$vnet_prefix"
  az network vnet subnet create --vnet-name "$vnet_name" -g "$rg" -n "$appgw_subnet_name" --address-prefix "$appgw_subnet_prefix"
  az network vnet subnet create --vnet-name "$vnet_name" -g "$rg" -n "$aci_subnet_name" --address-prefix "$aci_subnet_prefix"
  az network vnet subnet create --vnet-name "$vnet_name" -g "$rg" -n "$sql_subnet_name" --address-prefix "$sql_subnet_prefix"
  az network vnet subnet create --vnet-name "$vnet_name" -g "$rg" -n "$dns_subnet_name" --address-prefix "$dns_subnet_prefix"
else
  echo "INFO: Vnet $vnet_name already existing in resource group $rg"
fi

# Create Azure private DNS zone for ACIs and link it to Vnet
dns_zone_id=$(az network private-dns zone show -n "$dns_zone_name" -g "$rg" --query id -o tsv 2>/dev/null)
if [[ -z "$dns_zone_id" ]]
then
  echo "INFO: Creating new private DNS zone $dns_zone_name..."
  az network private-dns zone create -n "$dns_zone_name" -g "$rg" 
  az network private-dns link vnet create -g "$rg" -z "$dns_zone_name" -n contoso --virtual-network "$vnet_name" --registration-enabled false
else
  echo "INFO: Private DNS zone $dns_zone_name already existing in resource group $rg"
fi

# Create AKV
akv_name=$(az keyvault list -g "$rg" --query '[0].name' -o tsv)
if [[ -z "$akv_name" ]]
then
  echo "INFO: Creating new AKV..."
  akv_name="acilab${unique_id}"
  az keyvault create -n "$akv_name" -g "$rg" -l "$location"
  sp_appid=$(az account show --query user.name -o tsv)
  sp_oid=$(az ad sp show --id "$sp_appid" --query objectId -o tsv)
  az keyvault set-policy -n "$akv_name" --object-id "$sp_oid" \
          --secret-permissions get list set delete \
          --certificate-permissions create import list get setissuers update \
          --key-permissions create get import sign verify list
else
  echo "INFO: AKV $akv_name found in resource group $rg"
fi

# Create database
sql_server_name=$(az sql server list -g "$rg" --query '[0].name' -o tsv)
if [[ -z "$sql_server_name" ]]
then
  echo "INFO: Creating new Azure SQL Database..."
  sql_server_name=sqlserver-${unique_id}
  echo "DEBUG: SQL Server $sql_server_name, Username $sql_username, Password $sql_password"
  az sql server create -n "$sql_server_name" -g "$rg" -l "$location" --admin-user "$sql_username" --admin-password "$sql_password"
  sql_server_fqdn=$(az sql server show -n "$sql_server_name" -g "$rg" -o tsv --query fullyQualifiedDomainName)
  if [[ -n "$sql_server_fqdn" ]]
  then
    az sql db create -n "$sql_db_name" -s "$sql_server_name" -g "$rg" -e Basic -c 5 --no-wait
    # Create SQL Server private endpoint
    sql_endpoint_name=sqlep
    sql_server_id=$(az sql server show -n "$sql_server_name" -g "$rg" -o tsv --query id)
    az network vnet subnet update -n "$sql_subnet_name" -g "$rg" --vnet-name "$vnet_name" --disable-private-endpoint-network-policies true
    az network private-endpoint create -n "$sql_endpoint_name" -g "$rg" \
      --vnet-name "$vnet_name" --subnet "$sql_subnet_name" \
      --private-connection-resource-id "$sql_server_id" --group-id sqlServer --connection-name sqlConnection
    # Get endpoint's private IP address
    sql_nic_id=$(az network private-endpoint show -n "$sql_endpoint_name" -g "$rg" --query 'networkInterfaces[0].id' -o tsv)
    sql_endpoint_ip=$(az network nic show --ids "$sql_nic_id" --query 'ipConfigurations[0].privateIpAddress' -o tsv) && echo "$sql_endpoint_ip"
    # Create Azure private DNS zone for private link and required A record
    plink_dns_zone_name=privatelink.database.windows.net
    az network private-dns zone create -n "$plink_dns_zone_name" -g "$rg" 
    az network private-dns link vnet create -g "$rg" -z $plink_dns_zone_name -n privatelink --virtual-network "$vnet_name" --registration-enabled false
    az network private-dns record-set a create -n "$sql_server_name" -z $plink_dns_zone_name -g "$rg"
    az network private-dns record-set a add-record --record-set-name "$sql_server_name" -z "$plink_dns_zone_name" -g "$rg" -a "$sql_endpoint_ip"
    # Note: linking the private zone and the private link would be easier and less error-prone
  else
    echo "ERROR: SQL Server $sql_server_name could not be created"
  fi
else
  echo "INFO: Azure SQL Server $sql_server_name already exists in resource group $rg"
fi

# Get network profile ID
# Network profiles are created when a container is created, hence we create and delete a dummy container to the vnet first
vnet_id=$(az network vnet show -n "$vnet_name" -g "$rg" --query id -o tsv 2>/dev/null)
subnet_id=$(az network vnet subnet show -n "$aci_subnet_name" --vnet-name "$vnet_name" -g "$rg" --query id -o tsv) && echo "$subnet_id"
nw_profile_id=$(az network profile list -g "$rg" --query '[0].id' -o tsv) && echo "$nw_profile_id"
while [[ -z "$nw_profile_id" ]]
do
    echo "Trying to create a network profile..."
    az container create -n dummy -g "$rg" --image mcr.microsoft.com/azuredocs/aci-helloworld --ip-address private --ports 80 --vnet "$vnet_id" --subnet "$subnet_id" 2>/dev/null || true
    # If the previous command fails with an error, it is no problem, as long as a network profile is created (see below)
    az container delete -n dummy -g "$rg" -y || true
    nw_profile_id=$(az network profile list -g "$rg" --query '[0].id' -o tsv) && echo "$nw_profile_id"
done

# Create script for init container in an AzFiles share
storage_account_name=$(az storage account list -g "$rg" --query '[0].name' -o tsv)
if [[ -z "$storage_account_name" ]]
then
  echo "INFO: Creating new Azure Storage Account..."
  storage_account_name="acilab${unique_id}"
  az storage account create -n "$storage_account_name" -g "$rg" --sku Premium_LRS --kind FileStorage
  storage_account_key=$(az storage account keys list --account-name "$storage_account_name" -g "$rg" --query '[0].value' -o tsv)
  az storage share create --account-name "$storage_account_name" --account-key "$storage_account_key" --name initscript
  init_script_filename=init.sh
  init_script_path=/tmp/
  cat <<EOF > ${init_script_path}${init_script_filename}
  echo "DEBUG: Environment variables:"
  printenv
  echo "Logging into Azure..."
  az login --service-principal -u \$SP_APPID -p \$SP_PASSWORD --tenant \$SP_TENANT
  echo "Finding out IP address..."
  my_private_ip=\$(az container show -n \$ACI_NAME -g \$RG --query 'ipAddress.ip' -o tsv) && echo \$my_private_ip
  echo "Trying to delete DNS record, if it exists..."
  az network private-dns record-set a delete -n \$HOSTNAME -z \$DNS_ZONE_NAME -g \$RG -y
  echo "Creating DNS record..."
  az network private-dns record-set a create -n \$HOSTNAME -z \$DNS_ZONE_NAME -g \$RG
  az network private-dns record-set a add-record --record-set-name \$HOSTNAME -z \$DNS_ZONE_NAME -g \$RG -a \$my_private_ip
EOF
  az storage file upload --account-name "$storage_account_name" --account-key "$storage_account_key" -s initscript --source "${init_script_path}${init_script_filename}"
  # Create vnet service endpoint for Azure Storage Account for ACI subnet
  az network vnet subnet update -g "$rg" -n "$aci_subnet_name" --vnet-name "$vnet_name" --service-endpoints Microsoft.Storage
  az storage account update -n "$storage_account_name" -g "$rg" --default-action Deny
  az storage account network-rule add -n "$storage_account_name" -g "$rg" --subnet "$aci_subnet_name" --vnet-name "$vnet_name" --action Allow
else
  echo "INFO: Azure Storage Account $storage_account_name already exists in resource group $rg"
fi

# Creates application gateway with dummy rule
appgw_id=$(az network application-gateway show -n "$appgw_name" -g "$rg" --query id -o tsv 2>/dev/null)
if [[ -z "$appgw_id" ]]
then
  echo "INFO: Creating new application gateway..."
  appgw_pip_dns="${appgw_name}-${unique_id}"
  allocation_method=Static
  az network public-ip create -g "$rg" -n "$appgw_pip_name" --sku Standard --allocation-method "$allocation_method" --dns-name "$appgw_pip_dns"
  appgw_fqdn=$(az network public-ip show -g "$rg" -n "$appgw_pip_name" --query dnsSettings.fqdn -o tsv)
  az network application-gateway create -g "$rg" -n $appgw_name --min-capacity 1 --max-capacity 2 --sku Standard_v2 \
      --frontend-port 1234 --routing-rule-type basic \
      --http-settings-port 1234 --http-settings-protocol Http \
      --public-ip-address "$appgw_pip_name" --vnet-name "$vnet_name" --subnet "$appgw_subnet_name" \
      --servers "1.2.3.4"
else
  echo "INFO: Application gateway $appgw_name already exists in resource group $rg"
fi

# Update DNS if required
echo "INFO: Updating now public domain $public_domain..."
public_dns_rg=$(az network dns zone list --query "[?name=='$public_domain'].resourceGroup" -o tsv)
if [[ -z "$public_dns_rg" ]]
then
  echo "ERROR: I could not find the public DNS zone $public_domain in subscription $sub_name"
else
  # First, remove any existing A-record (we are going to use CNAMEs)
  a_record_set=$(az network dns record-set a show -n "$appgw_name" -z "$public_domain" -g "$public_dns_rg" -o tsv --query id 2>/dev/null)
  if [[ -n "$a_record_set" ]]
  then
    echo "Deleting existing A record for ${appgw_name}.${public_domain}..."
    az network dns record-set a delete -n "$appgw_name" -z "$public_domain" -g "$public_dns_rg" -y
  else
    echo "No conflicting A records found in ${public_domain}"
  fi
  # Get FQDN for AppGW PIP
  appgw_fqdn=$(az network public-ip show -g "$rg" -n "$appgw_pip_name" --query dnsSettings.fqdn -o tsv)
  if [[ -n "$appgw_fqdn" ]]
  then
    # Update DNS zone
    # Check if CNAME exists
    existing_record=$(az network dns record-set cname show -g "$public_dns_rg" -z "$public_domain" -n "$appgw_name" --query 'cnameRecord.cname' -o tsv 2>/dev/null)
    if [[ -z "$existing_record" ]]
    then
      echo "Creating new CNAME record to $appgw_fqdn..."
      az network dns record-set cname create -g "$public_dns_rg" -z "$public_domain" -n "$appgw_name"
      az network dns record-set cname set-record -g "$public_dns_rg" -z "$public_domain"  -n "$appgw_name" -c "$appgw_fqdn"
    else
      if [[ "$existing_record" != "$appgw_fqdn" ]]
      then
        echo "Updating existing CNAME record to $appgw_fqdn..."
        az network dns record-set cname remove-record -g "$public_dns_rg" -z "$public_domain" -n "$appgw_name" -c "$existing_record" --keep-empty-record-set
        az network dns record-set cname set-record -g "$public_dns_rg" -z "$public_domain"  -n "$appgw_name" -c "$appgw_fqdn"
      fi
    fi
    echo "Your App Gateway applications should be reachable under the FQDN ${appgw_name}.${public_domain}"
  else
    echo "ERROR: I could not retrieve the FQDN for public IP $appgw_pip_name"
  fi
fi

# Create custom DNS server in VM
dnsvm_name=dns01
cloudinit_file=/tmp/cloudinit.txt
# cat <<EOF > $cloudinit_file
# #cloud-config
# package_upgrade: true
# packages:
#   - dnsmasq
# EOF
cat <<EOF > $cloudinit_file
#cloud-config
runcmd:
  - apt-get update
  - apt-get install -y dnsmasq --fix-missing
EOF
dnsvm_id=$(az vm show -n "$dnsvm_name" -g "$rg" --query id -o tsv 2>/dev/null)
if [[ -z "$dnsvm_id" ]]
then
  echo "INFO: Creating DNS server ${dnsvm_name}..."
  az vm create -n "$dnsvm_name" -g "$rg" -l "$location" --image ubuntuLTS --generate-ssh-keys --custom-data $cloudinit_file \
               --size Standard_B1ms --public-ip-address "${dnsvm_name}-pip" --vnet-name "$vnet_name" --subnet "$dns_subnet_name"
  # dnsvm_ip=$(az network public-ip show -n "${dnsvm_name}-pip" -g $rg --query ipAddress -o tsv)
  # if [[ -n "$dnsvm_ip" ]]
  # then
  #   echo "Installing dnsmasq in $dnsvm_ip..."
  #   ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no "$dnsvm_ip" "sudo apt -y install dnsmasq"
  # else
  #   echo "ERROR: could not find out the public IP for ${dnsvm_name}-pip"
  # fi
else
  echo "INFO: DNS server ${dnsvm_name} already exists."
fi