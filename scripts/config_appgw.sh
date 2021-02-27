###############################################
# Azure Container Instances with Azure CLI
#
# Tested with zsh (if run with bash there are probably A LOT of missing "")
#
# Jose Moreno, January 2021
###############################################

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
          -z=*|--private-dns-zone-name=*)
               dns_zone_name="${i#*=}"
               shift # past argument=value
               ;;
     esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

# Verify there is an AKV in the RG
akv_name=$(az keyvault list -g "$rg" --query '[0].name' -o tsv)
if [[ -n "$akv_name" ]]
then
    echo "INFO: Azure Key Vault $akv_name found in resource group $rg"
else
    echo "ERROR: no Azure Key Vault found in resource group $rg"
    exit 1
fi

# Find app gateway
appgw_name=$(az network application-gateway list -g "$rg" --query '[0].name' -o tsv)
if [[ -n "$appgw_name" ]]
then
    echo "INFO: Azure Application Gateway $appgw_name found in resource group $rg"
else
    echo "ERROR: no Azure Application Gateway could be found in the resource group $rg"
    exit 1
fi

# Import certs from AKV
fqdn="*.${public_domain}"
cert_name=${fqdn//[^a-zA-Z0-9]/}
cert_id=$(az network application-gateway ssl-cert show -n "$cert_name" --gateway-name "$appgw_name" -g "$rg" --query id -o tsv 2>/dev/null)
if [[ -z "$cert_id" ]]
then
    echo "Adding SSL certificate to Application Gateway from Key Vault..."
    # The --keyvault-secret-id parameter doesnt seem to be working in Github's action CLI version (Feb 2021)
    # cert_sid=$(az keyvault certificate show -n "$cert_name" --vault-name "$akv_name" --query sid -o tsv)
    # az network application-gateway ssl-cert create -n "$cert_name" --gateway-name "$appgw_name" -g "$rg" --keyvault-secret-id "$cert_sid"
    pfx_file="/tmp/ssl.pfx"
    az keyvault secret download -n "$cert_name" --vault-name "$akv_name" --encoding base64 --file "$pfx_file"
    cert_passphrase=''
    az network application-gateway ssl-cert create -g "$rg" --gateway-name "$appgw_name" -n "$cert_name" --cert-file "$pfx_file" --cert-password "$cert_passphrase" -o none
else
    echo "Cert $cert_name already exists in application gateway $appgw_name"
fi

# Import X1 root cert for LetsEncrypt
root_cert_id=$(az network application-gateway ssl-cert show -n letsencryptX1 --gateway-name "$appgw_name" -g "$rg" --query id -o tsv 2>/dev/null)
if [[ -z "$root_cert_id" ]]
then
    current_dir=$(dirname "$0")
    base_dir=$(dirname "$current_dir")
    root_cert_file="${base_dir}/letsencrypt/isrgrootx1.crt"
    echo "Adding LetsEncrypt X1 root cert to Application Gateway..."
    az network application-gateway root-cert create -g "$rg" --gateway-name "$appgw_name" --name letsencryptX1 --cert-file "$root_cert_file" -o none
else
    echo "LetsEncrypt X1 root certificate already present in Application Gateway $appgw_name"
fi

# Import X3 root cert for LetsEncrypt
rootx3_cert_id=$(az network application-gateway ssl-cert show -n letsencryptX3 --gateway-name "$appgw_name" -g "$rg" --query id -o tsv 2>/dev/null)
if [[ -z "$rootx3_cert_id" ]]
then
    current_dir=$(dirname "$0")
    base_dir=$(dirname "$current_dir")
    root_cert_file="${base_dir}/letsencrypt/isrgrootx3.cer"
    echo "Adding LetsEncrypt X3 root cert to Application Gateway..."
    az network application-gateway root-cert create -g "$rg" --gateway-name "$appgw_name" --name letsencryptX3 --cert-file "$root_cert_file" -o none
else
    echo "LetsEncrypt X3 root certificate already present in Application Gateway $appgw_name"
fi

# Import staging root cert for LetsEncrypt
root_cert_id=$(az network application-gateway ssl-cert show -n letsencryptstaging --gateway-name "$appgw_name" -g "$rg" --query id -o tsv 2>/dev/null)
if [[ -z "$root_cert_id" ]]
then
    current_dir=$(dirname "$0")
    base_dir=$(dirname "$current_dir")
    root_cert_file="${base_dir}/letsencrypt/fakelerootx1.crt"
    echo "Adding LetsEncrypt staging root cert to Application Gateway..."
    az network application-gateway root-cert create -g "$rg" --gateway-name "$appgw_name" --name letsencryptstaging --cert-file "$root_cert_file" -o none
else
    echo "LetsEncrypt staging root certificate already present in Application Gateway $appgw_name"
fi

# Check if there is already a rule for aciprod
echo "Verifying if rule for production already exists..."
rule_id=$(az network application-gateway rule show -n aciprod --gateway-name "$appgw_name" -g "$rg" --query id -o tsv 2>/dev/null)
if [[ -z "$rule_id" ]]
then
    # HTTP Settings and probe
    echo "Creating probe and HTTP settings..."
    az network application-gateway probe create -g "$rg" --gateway-name "$appgw_name" \
    --name aciprobe --protocol Https --host-name-from-http-settings --match-status-codes 200-399 --port 443 --path /api/healthcheck -o none
    az network application-gateway http-settings create -g "$rg" --gateway-name "$appgw_name" --port 443 \
    --name acisettings --protocol https --host-name-from-backend-pool --probe aciprobe --root-certs letsencryptX1 letsencryptX3 letsencryptstaging -o none

    # Create config for production container
    echo "Creating config for production ACIs..."
    az network application-gateway address-pool create -n aciprod -g "$rg" --gateway-name "$appgw_name" \
    --servers "api-prod-01.${dns_zone_name}" -o none
    frontend_name=$(az network application-gateway frontend-ip list -g "$rg" --gateway-name "$appgw_name" --query '[0].name' -o tsv)
    az network application-gateway frontend-port create -n aciprod -g "$rg" --gateway-name "$appgw_name" --port 443 -o none
    az network application-gateway http-listener create -n aciprod -g "$rg" --gateway-name "$appgw_name" \
    --frontend-port aciprod --frontend-ip "$frontend_name" --ssl-cert "$cert_name" -o none
    az network application-gateway rule create -g "$rg" --gateway-name "$appgw_name" -n aciprod \
    --http-listener aciprod --rule-type Basic --address-pool aciprod --http-settings acisettings -o none
else
    echo "Configurationg for production cluster already found in App GW $appgw_name"
fi

# Check if there is already a rule for the dashboard
echo "Verifying if rule for dashboard already exists..."
rule_id=$(az network application-gateway rule show -n dash --gateway-name "$appgw_name" -g "$rg" --query id -o tsv 2>/dev/null)
if [[ -z "$rule_id" ]]
then
    # Create config for dashboard
    echo "Creating config for dashboard..."
    dash_ip=$(az container show -n dash -g "$rg" --query 'ipAddress.ip' -o tsv) && echo "$dash_ip"
    az network application-gateway probe create -g "$rg" --gateway-name "$appgw_name" \
    --name dash --protocol Http --host-name-from-http-settings --match-status-codes 200-399 --port 8050 --path / -o none
    az network application-gateway http-settings create -g "$rg" --gateway-name "$appgw_name" --port 8050 \
    --name dash --protocol http --host-name-from-backend-pool --probe dash -o none
    az network application-gateway address-pool create -n dash -g "$rg" --gateway-name "$appgw_name" --servers "$dash_ip" -o none
    frontend_name=$(az network application-gateway frontend-ip list -g "$rg" --gateway-name "$appgw_name" --query '[0].name' -o tsv)
    az network application-gateway frontend-port create -n dash -g "$rg" --gateway-name "$appgw_name" --port 8050 -o none
    az network application-gateway http-listener create -n dash -g "$rg" --gateway-name "$appgw_name" \
    --frontend-port dash --frontend-ip "$frontend_name" --ssl-cert "$cert_name" -o none
    az network application-gateway rule create -g "$rg" --gateway-name "$appgw_name" -n dash \
    --http-listener dash --rule-type Basic --address-pool dash --http-settings dash -o none
else
    echo "Configurationg for the dashboard already found in App GW $appgw_name"
fi

# Check if the dummy config is still there
echo "Verifying if dummy config still exists..."
pool_id=$(az network application-gateway address-pool show -n appGatewayBackendPool --gateway-name "$appgw_name" -g "$rg" --query id -o tsv 2>/dev/null)
if [[ -n "$pool_id" ]]
then
    # Cleanup initial dummy config
    echo "Cleaning up intialization config for the Application Gateway $appgw_name..."
    az network application-gateway rule delete -g "$rg" --gateway-name "$appgw_name" -n rule1 -o none
    az network application-gateway address-pool delete -g "$rg" --gateway-name "$appgw_name" -n appGatewayBackendPool -o none
    az network application-gateway http-settings delete -g "$rg" --gateway-name "$appgw_name" -n appGatewayBackendHttpSettings -o none
    az network application-gateway http-listener delete -g "$rg" --gateway-name "$appgw_name" -n appGatewayHttpListener -o none
else
    echo "Initialization configurationg for the App GW $appgw_name had already been deleted"
fi
