###############################################
# Azure Container Instances with Azure CLI
#
# Tested with zsh (if run with bash there are probably A LOT of missing "")
#
# Jose Moreno, January 2021
###############################################

# Variables
repo_name='acilab'
init_script_filename=init.sh
sql_db_name=mydb
aci_subnet_name=aci

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
          -d=*|--public-dns-zone-name=*)
               public_domain="${i#*=}"
               shift # past argument=value
               ;;
          -r=*|--repo-name=*)
               repo_name="${i#*=}"
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
     esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

# If no location, infer from RG
if [[ -z "$location" ]]
then
    location=$(az group show -n "$rg" --query location -o tsv)
fi

# Get ACR name
acr_name=$(az acr list -g "$rg" --query '[0].name' -o tsv)
if [[ -z "$acr_name" ]]
then
  echo "ERROR: No ACR could be found in resource group $rg"
  exit 1
else
  echo "INFO: ACR $acr_name found in resource group $rg"
fi

# Get Network Profile ID to deploy inside of Vnet
nw_profile_id=$(az network profile list -g "$rg" --query '[0].id' -o tsv)
if [[ -z "$nw_profile_id" ]]
then
  echo "ERROR: No Network Profile ID could be found in resource group $rg"
  exit 1
else
  echo "INFO: Network Profile ID $nw_profile_id found in resource group $rg"
fi

# Get SQL Server FQDN
sql_server_fqdn=$(az sql server list -g "$rg" --query '[0].fullyQualifiedDomainName' -o tsv)
if [[ -z "$sql_server_fqdn" ]]
then
  echo "ERROR: No Azure SQL Server could be found in resource group $rg"
  exit 1
else
  echo "INFO: Azure SQL Server with FQDN $sql_server_fqdn found in resource group $rg"
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

# Verify there is a VNet in the RG, generate the cert for the appgw's name
vnet_name=$(az network vnet list -g "$rg" --query '[].name' -o tsv)
if [[ -n "$akv_name" ]]
then
    echo "INFO: Vnet $vnet_name found in resource group $rg. Finding out Vnet and Subnet IDs now..."
    vnet_id=$(az network vnet show -n "$vnet_name" -g "$rg" --query id -o tsv) && echo "$vnet_id"
    subnet_id=$(az network vnet subnet show -n "$aci_subnet_name" --vnet-name "$vnet_name" -g "$rg" --query id -o tsv) && echo "$subnet_id"
else
    echo "ERROR: no Virtual Network found in resource group $rg"
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

# Get Storage Account name
storage_account_name=$(az storage account list -g "$rg" --query '[0].name' -o tsv)
if [[ -z "$storage_account_name" ]]
then
  echo "ERROR: No Storage Account could be found in resource group $rg"
  exit 1
else
  echo "INFO: Azure Storage Account $storage_account_name found in resource group $rg"
  storage_account_key=$(az storage account keys list --account-name "$storage_account_name" -g "$rg" --query '[0].value' -o tsv)
fi

# Get address for DNS server
dnsvm_name=dns01
dnsvm_nic_id=$(az vm show -n "$dnsvm_name" -g $rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
if [[ -n "$dnsvm_nic_id" ]]
then
  dnsvm_private_ip=$(az network nic show --ids "$dnsvm_nic_id" --query 'ipConfigurations[0].privateIpAddress' -o tsv)
  if [[ -n "$dnsvm_private_ip" ]]
  then
    echo "INFO: found private IP address for DNS forwarder: $dnsvm_private_ip"
  else
    echo "ERROR: could not find private IP address for NIC $dnsvm_nic_id"
  fi
else
  echo "ERROR: could not find NIC ID for VM $dnsvm_name"
fi


# Get Service Principal ID and password from the AZURE_CREDENTIALS env variable if supplied
if [[ -n "$AZURE_CREDENTIALS" ]]
then
    echo "$AZURE_CREDENTIALS"  ########################################## Remove this!
    # jq does not seem to work, it looks like github unformats the JSON into something else
    # sp_appid=$(jq -r '.clientId' <<<"$AZURE_CREDENTIALS")
    # sp_password=$(jq -r '.clientSecret' <<<"$AZURE_CREDENTIALS")
    # sp_tenant=$(jq -r '.tenantId' <<<"$AZURE_CREDENTIALS")
    sp_appid=$(echo "$AZURE_CREDENTIALS" | grep clientId | cut -d ' ' -f 4 | cut -d ',' -f 1)
    sp_password=$(echo "$AZURE_CREDENTIALS" | grep clientSecret | cut -d ' ' -f 4 | cut -d ',' -f 1)
    sp_tenant=$(echo "$AZURE_CREDENTIALS" | grep tenantId | cut -d ' ' -f 4 | cut -d ',' -f 1)
    echo "Extracted application ID and password for service principal $sp_appid in tenant $sp_tenant, password $sp_password"
else
    echo "ERROR: AZURE_CREDENTIALS environment variable not found"
    exit 1
fi

# Get user/password for ACR
# az acr update -n "$acr_name" --admin-enabled true
# echo "Getting username and password for ACR..."
# sp_appid=$(az acr credential show -n "$acr_name" --query username -o tsv)
# sp_password=$(az acr credential show -n "$acr_name" --query passwords[0].value -o tsv)
# WRONG, we need the SP for the init container too!! :(

# Create nginx.conf for SSL
nginx_config_file=/tmp/nginx.conf
cat <<EOF > $nginx_config_file
user nginx;
worker_processes auto;
events {
  worker_connections 1024;
}
pid        /var/run/nginx.pid;
http {
    server {
        listen [::]:443 ssl;
        listen 443 ssl;
        server_name localhost;
        ssl_protocols              TLSv1.2;
        ssl_ciphers                ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:ECDHE-RSA-RC4-SHA:ECDHE-ECDSA-RC4-SHA:AES128:AES256:RC4-SHA:HIGH:!aNULL:!eNULL:!EXPORT:!DES:!3DES:!MD5:!PSK;
        ssl_prefer_server_ciphers  on;
        ssl_session_cache    shared:SSL:10m; # a 1mb cache can hold about 4000 sessions, so we can hold 40000 sessions
        ssl_session_timeout  24h;
        keepalive_timeout 75; # up from 75 secs default
        add_header Strict-Transport-Security 'max-age=31536000; includeSubDomains';
        ssl_certificate      /etc/nginx/ssl.crt;
        ssl_certificate_key  /etc/nginx/ssl.key;
        location / {
            proxy_pass http://127.0.0.1:80 ;
            proxy_set_header Connection "";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            # proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_buffer_size          128k;
            proxy_buffers              4 256k;
            proxy_busy_buffers_size    256k;
        }
        location /api/ {
            proxy_pass http://127.0.0.1:8080 ;
            proxy_set_header Connection "";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            # proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_buffer_size          128k;
            proxy_buffers              4 256k;
            proxy_busy_buffers_size    256k;
        }
    }
}
EOF

# Encode to Base64
nginx_conf=$(base64 "$nginx_config_file")

# Get certificates from AKV
fqdn="*.${public_domain}"
# cert_name=$(echo "$fqdn" | sed 's/[^a-zA-Z0-9]//g')
cert_name=${fqdn//[^a-zA-Z0-9]/}
echo "Getting certificate $cert_name from Azure Key Vault $akv_name"
cert_file="/tmp/ssl.crt"
key_file="/tmp/ssl.key"
pfx_file="/tmp/ssl.pfx"
# az keyvault certificate download -n "$cert_name" --vault-name "$akv_name" --encoding der --file "$cert_file"
az keyvault secret download -n "$cert_name" --vault-name "$akv_name" --encoding base64 --file "$pfx_file"
echo "Extracting key from pfx file..."
key_passphrase=$(tr -dc a-zA-Z0-9 </dev/urandom 2>/dev/null| head -c 12)
openssl pkcs12 -in "$pfx_file" -nocerts -out "$key_file" -passin "pass:" -passout "pass:$key_passphrase"
openssl rsa -in "$key_file" -out "$key_file" -passin "pass:$key_passphrase"
echo "Extracting certs from pfx file..."
openssl pkcs12 -in "$pfx_file" -nokeys -out "$cert_file" -passin "pass:" 
# Encode in base64 variables
ssl_crt=$(base64 "$cert_file")
ssl_key=$(base64 "$key_file")

# Function to deploy the API container to the vnet
# Not including DNS config:
function deploy_api() {
  # ACI name must be provided as argument
  aci_name=$1
  container_image=$2
  # Create YAML
  aci_yaml_file=/tmp/acilab.yaml
  cat <<EOF > $aci_yaml_file
  apiVersion: 2019-12-01
  location: $location
  name: $aci_name
  properties:
    imageRegistryCredentials: # Credentials to pull a private image
    - server: ${acr_name}.azurecr.io
      username: $sp_appid
      password: $sp_password
    networkProfile:
      id: $nw_profile_id
    initContainers:
    - name: azcli
      properties:
        image: microsoft/azure-cli:latest
        command:
        - "/bin/sh"
        - "-c"
        - "/mnt/init/$init_script_filename"
        environmentVariables:
        - name: RG
          value: $rg
        - name: SP_APPID
          value: $sp_appid
        - name: SP_PASSWORD
          secureValue: $sp_password
        - name: SP_TENANT
          value: $sp_tenant
        - name: DNS_ZONE_NAME
          value: $dns_zone_name
        - name: HOSTNAME
          value: $aci_name
        - name: ACI_NAME
          value: $aci_name
        volumeMounts:
        - name: initscript
          mountPath: /mnt/init/
    containers:
    - name: nginx
      properties:
        image: nginx
        ports:
        - port: 443
          protocol: TCP
        resources:
          requests:
            cpu: 1.0
            memoryInGB: 1.5
        volumeMounts:
        - name: nginx-config
          mountPath: /etc/nginx
    - name: web
      properties:
        image: ${acr_name}.azurecr.io/${repo_name}/web:1.0
        environmentVariables:
        - name: API_URL
          value: 127.0.0.1:8080
        ports:
        - port: 80
          protocol: TCP
        resources:
          requests:
            cpu: 0.5
            memoryInGB: 0.5
    - name: sqlapi
      properties:
        image: $container_image
        environmentVariables:
        - name: SQL_SERVER_FQDN
          value: $sql_server_fqdn
        - name: SQL_SERVER_USERNAME
          value: $sql_username
        - name: SQL_SERVER_DB
          value: $sql_db_name
        - name: SQL_SERVER_PASSWORD
          secureValue: $sql_password
        ports:
        - port: 8080
          protocol: TCP
        resources:
          requests:
            cpu: 1.0
            memoryInGB: 1
        volumeMounts:
    volumes:
    - secret:
        ssl.crt: "$ssl_crt"
        ssl.key: "$ssl_key"
        nginx.conf: "$nginx_conf"
      name: nginx-config
    - name: initscript
      azureFile:
        readOnly: true
        shareName: initscript
        storageAccountName: $storage_account_name
        storageAccountKey: $storage_account_key
    dnsConfig:
      nameServers:
      - $dnsvm_private_ip
    ipAddress:
      ports:
      - port: 443
        protocol: TCP
      type: Private
    osType: Linux
  tags: null
  type: Microsoft.ContainerInstance/containerGroups
EOF

  # Deploy ACI
  az container create -g "$rg" --file "$aci_yaml_file" --no-wait
}

function deploy_dash() {
  # ACI name must be provided as argument
  aci_name=$1
  container_image=$2
  # Create YAML
  aci_yaml_file=/tmp/acilab.yaml
  cat <<EOF > $aci_yaml_file
  apiVersion: 2019-12-01
  name: $aci_name
  location: $location
  name: dash
  properties:
    imageRegistryCredentials: # Credentials to pull a private image
    - server: ${acr_name}.azurecr.io
      username: $sp_appid
      password: $sp_password
    networkProfile:
      id: $nw_profile_id
    containers:
    - name: dash
      properties:
        environmentVariables:
        - name: SQL_SERVER_FQDN
          value: $sql_server_fqdn
        - name: SQL_SERVER_USERNAME
          value: $sql_username
        - name: SQL_SERVER_DB
          value: $sql_db_name
        - name: SQL_SERVER_PASSWORD
          secureValue: $sql_password
        image: $container_image
        ports:
        - port: 8050
          protocol: TCP
        resources:
          requests:
            cpu: 1.0
            memoryInGB: 1.5
    dnsConfig:
      nameServers:
      - $dnsvm_private_ip
    ipAddress:
      ports:
      - port: 8050
        protocol: TCP
      type: Private
    osType: Linux
    restartPolicy: Always
  tags: {}
  type: Microsoft.ContainerInstance/containerGroups
EOF

  # Deploy ACI
  az container create -g "$rg" --file "$aci_yaml_file"
}


# Create Dashboard container
echo "Creating dashboard container..."
# az container create -n dash -g "$rg" --image "${acr_name}.azurecr.io/${repo_name}/dash:1.0" --vnet "$vnet_id" --subnet "$subnet_id" --ip-address private --ports 8050  \
#   -e "SQL_SERVER_FQDN=${sql_server_fqdn}" "SQL_SERVER_USERNAME=${sql_username}" "SQL_SERVER_DB=${sql_db_name}" \
#   --secrets "SQL_SERVER_PASSWORD=${sql_password}" \
#   --registry-login-server "${acr_name}.azurecr.io" --registry-username "$sp_appid" --registry-password "$sp_password" --location "$location"
dash_image="${acr_name}.azurecr.io/${repo_name}/dash:1.0"
deploy_dash dash "$dash_image"
echo "Finding out dashboard's IP address..."
dash_ip=$(az container show -n dash -g "$rg" --query 'ipAddress.ip' -o tsv) && echo "$dash_ip"

# Create main API container (the function creates the container in --no-wait)
echo "Creating API container..."
prod_image="${acr_name}.azurecr.io/${repo_name}/api:1.0"
deploy_api api-prod-01 "$prod_image"

# Check
az container list -g "$rg" -o table
