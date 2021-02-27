###############################################
# Azure Container Instances with Azure CLI
#
# Tested with zsh (if run with bash there are probably A LOT of missing "")
#
# Jose Moreno, January 2021
###############################################

# Variables
base_dir='.'
repo_name='acilab'

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
          -d=*|--base-dir=*)
               base_dir="${i#*=}"
               shift # past argument=value
               ;;
          -r=*|--repo-name=*)
               repo_name="${i#*=}"
               shift # past argument=value
               ;;
     esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

# Get ACR name
acr_name=$(az acr list -g "$rg" --query '[0].name' -o tsv)
if [[ -z "$acr_name" ]]
then
  echo "ERROR: No ACR could be found in resource group $rg"
  exit 1
fi

# Build web frontend
dir=$(ls -ald "${base_dir}/web")
if [[ -n "$dir" ]]
then
    az acr build -t "${repo_name}/web:1.0" -r "$acr_name" "${base_dir}/web"
else
    echo "I cannot find the directory with the web app, are you in the right folder?"
fi
# Build API
dir=$(ls -ald "${base_dir}/api")
if [[ -n "$dir" ]]
then
    # Verify the code is showing the correct version
    version=$(grep "'version': '1.0'" "${base_dir}/api/sql_api.py")
    if [[ -n "$version" ]]
    then
        az acr build -t "${repo_name}/api:1.0" -r "$acr_name" "${base_dir}/api"
    else
        echo "Mmmmh, it looks like you have the wrong version in sql_api.py???"
        grep "'version'" "${base_dir}/api/sql_api.py"
    fi
else
    echo "I cannot find the directory with the API code, are you in the right folder?"
fi
# Build dashboard
dir=$(ls -ald "${base_dir}/dash")
if [[ -n "$dir" ]]
then
    az acr build -t "${repo_name}/dash:1.0" -r "$acr_name" "${base_dir}/dash"
else
    echo "I cannot find the directory with the dashboard code, are you in the right folder?"
fi

# Verify created images
az acr repository list -n "$acr_name" -o table
