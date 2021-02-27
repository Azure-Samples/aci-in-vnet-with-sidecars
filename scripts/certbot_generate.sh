#!/bin/bash

# Argument parsing (can overwrite the previously initialized variables)
for i in "$@"
do
     case $i in
          -g=*|--resource-group=*)
               rg="${i#*=}"
               shift # past argument=value
               ;;
          -d=*|--public-dns-zone-name=*)
               public_domain="${i#*=}"
               shift # past argument=value
               ;;
          -e=*|--email=*)
               email_address="${i#*=}"
               shift # past argument=value
               ;;
          -s=*|--staging=*)
               staging="${i#*=}"
               shift # past argument=value
               ;;
          -p=*|--use_key_passphrase=*)
               use_key_passphrase="${i#*=}"
               shift # past argument=value
               ;;
          -f=*|--force=*)
               force="${i#*=}"
               shift # past argument=value
               ;;
          --debug=*)
               DEBUG="${i#*=}"
               shift # past argument=value
               ;;
     esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

# Verify certbot is installed
certbot_exec=$(which certbot)
if [[ -n "$certbot_exec" ]]
then
    echo "INFO: certbot executable found in $certbot_exec"
else
    echo "ERROR: no certbot executable could be found"
    exit 1
fi

# Verify there is an AKV in the RG
akv_name=$(az keyvault list -g "$rg" --query '[0].name' -o tsv)
if [[ -n "$akv_name" ]]
then
    echo "INFO: Azure Key Vault $akv_name found in resource group $rg"
else
    echo "ERROR: no Azure Key Vault found in resource group $rg"
    exit 1
fi

# Verify there is a DNS zone for the domain in the subscription
public_dns_rg=$(az network dns zone list --query "[?name=='$public_domain'].resourceGroup" -o tsv)
if [[ -n "$public_dns_rg" ]]
then
    echo "INFO: Azure DNS zone $public_domain found in resource group $public_dns_rg"
else
    echo "ERROR: public DNS zone $public_domain could not be found in current subscription"
    exit 1
fi

# Verify there is an Application Gateway in the RG, generate the cert for the appgw's name
appgw_name=$(az network application-gateway list -g "$rg" --query '[0].name' -o tsv)
if [[ -n "$appgw_name" ]]
then
    echo "INFO: Azure Application Gateway $appgw_name found in resource group $rg"
else
    echo "ERROR: no Azure Application Gateway could be found in the resource group $rg"
    exit 1
fi

# Verify if cert already exists in the Azure Key Vault
fqdn="*.${public_domain}"
# cert_name=$(echo "$fqdn" | sed 's/[^a-zA-Z0-9]//g')
cert_name=${fqdn//[^a-zA-Z0-9]/}
cert_id=$(az keyvault certificate show -n "$cert_name" --vault-name "$akv_name" --query id -o tsv 2>/dev/null)
if [[ -n "$cert_id" ]]
then
    echo "INFO: Certificate $cert_name already exists in Key Vault $akv_name, no need to create another one"
    cert_expiration_date=$(az keyvault certificate show -n "$cert_name" --vault-name "$akv_name" --query 'policy.attributes.expires' -o tsv 2>/dev/null)
    cert_creation_date=$(az keyvault certificate show -n "$cert_name" --vault-name "$akv_name" --query 'policy.attributes.created' -o tsv 2>/dev/null)
    cert_validity_months=$(az keyvault certificate show -n appgwcloudtroopernet --vault-name "$akv_name" --query policy.x509CertificateProperties.validityInMonths)
    echo "INFO: Creation date:     $cert_creation_date"
    echo "INFO: Expiration date:   $cert_expiration_date"
    echo "INFO: Validity (months): $cert_validity_months"
    # Exit unless running in force mode
    if [[ "$force" != "yes" ]]
    then
        exit 0
    fi
else
    echo "INFO: Certificate $cert_name does not exist in Key Vault $akv_name"
fi

# Create certificate (optionally using the staging server)
current_dir=$(dirname "$0")
if [[ "$staging" == "yes" ]]
then
    echo "Generating certificate in staging server for $fqdn..."
    certbot certonly -n -d "$fqdn" --manual -m "$email_address" --preferred-challenges=dns \
        --staging --manual-public-ip-logging-ok --agree-tos \
        --manual-auth-hook "${current_dir}/certbot_auth.sh" --manual-cleanup-hook "${current_dir}/certbot_cleanup.sh"
else
    echo "Generating certificate in production server for $fqdn..."
    certbot certonly -n -d "$fqdn" --manual -m "$email_address" --preferred-challenges=dns \
        --manual-public-ip-logging-ok --agree-tos \
        --manual-auth-hook "${current_dir}/certbot_auth.sh" --manual-cleanup-hook "${current_dir}/certbot_cleanup.sh"
fi
# If debugging, show created certificates
if [[ "$DEBUG" == "yes" ]]
then
    ls -al "/etc/letsencrypt/live/${fqdn}/"
    cat "/etc/letsencrypt/live/${fqdn}/fullchain.pem"
    cat "/etc/letsencrypt/live/${fqdn}/privkey.pem"
    cat "/var/log/letsencrypt/letsencrypt.log"
fi
# Variables to create AKV cert
pem_file="/etc/letsencrypt/live/${fqdn}/fullchain.pem"
pem_file="${pem_file//\*./}"
key_file="/etc/letsencrypt/live/${fqdn}/privkey.pem"
key_file="${key_file//\*./}"
if [[ "$use_key_passphrase" == "yes" ]]
then
    key_passphrase=$(tr -dc a-zA-Z0-9 </dev/urandom 2>/dev/null| head -c 12)
else
    key_passphrase=''
fi
# Combine PEM and key in one pfx file (pkcs#12)
echo "Generating pfx file with cert chain and private key..."
pfx_file="${pem_file}.pfx"
openssl pkcs12 -export -in "$pem_file" -inkey "$key_file" -out "$pfx_file" -passin "pass:$key_passphrase" -passout "pass:$key_passphrase"
echo "Verifying generated pfx file..."
openssl pkcs12 -info -in "$pfx_file" -passin "pass:$key_passphrase"
# Add certificate to AKV
echo "Adding certificate $cert_name to Azure Key Vault..."
if [[ "$use_key_passphrase" == "yes" ]]
then
    az keyvault certificate import --vault-name "$akv_name" -n "$cert_name" -f "$pfx_file" --password "$key_passphrase"
else
    az keyvault certificate import --vault-name "$akv_name" -n "$cert_name" -f "$pfx_file"
fi
# Add key phrase to AKV
akv_secret_name="${cert_name}passphrase"
# akv_secret_name=$(echo "$akv_secret_name" | sed 's/[^a-zA-Z0-9]//g')
akv_secret_name=${akv_secret_name//[^a-zA-Z0-9]/}
if [[ "$use_key_passphrase" == "yes" ]]
then
    echo "Adding certificate key passphrase to Azure Key Vault $akv_name as secret $akv_secret_name"
    az keyvault secret set -n "$akv_secret_name" --value "$key_passphrase" --vault-name "$akv_name"
else
    echo "Making sure there is no key passphrase secret in Azure Key Vault $akv_name as secret $akv_secret_name"
    secret_id=$(az keyvault secret show -n "$akv_secret_name" --vault-name "$akv_name" --query id -o tsv 2>/dev/null)
    if [[ -n "$secret_id" ]]
    then
        az keyvault secret delete -n "$akv_secret_name" --vault-name "$akv_name" || true
    fi
fi
