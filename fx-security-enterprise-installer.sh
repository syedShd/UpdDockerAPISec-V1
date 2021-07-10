#!/bin/bash -x
# apisecuriti enterprise installer script https://apisecuriti.io/
# 20181224

# Installer folder should have the following files
# 1.	.env
# 2.	fx-security-enterprise-data.yaml
# 3.	fx-security-enterprise-control-plane.yaml
# 4.	fx-security-enterprise-dependents.yaml
# 5.	fx-security-enterprise-haproxy.yaml
# 6.	haproxy.cfg
# 7.	fx-security-enterprise-installer.sh

read -p "Enter an email address for admin access: " EMAIL

echo "## INSTALLING DOCKER ##"
#1.	Install docker (latest)
sudo apt update
sudo apt install apt-transport-https ca-certificates curl software-properties-common -y
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
sudo apt update
apt-cache policy docker-ce
sudo apt install docker-ce -y
sudo systemctl start docker
sudo systemctl enable docker
#sudo systemctl status docker

echo "## ACTIVATING DOCKER-SWARM MODE ##"
#2.	Activate docker-swarm mode
sudo docker swarm init
echo "tag hint: better to pull from 'latest' tag"
read -p "Enter image tag: " tag
echo "## PULLING LATEST BUILD APISecuriti IMAGES ##"
#3.	Pull fx-security-enterprise docker images (based on the tag input)
docker pull team2021/web-v1:"$tag"
docker pull team2021/vc-git-bot-v1:"$tag"
docker pull team2021/notification-email-skill-bot-v1:"$tag"
# docker pull apisecuriti/issue-tracker-github-skill-bot-v1:"$tag"
# docker pull apisecuriti/issue-tracker-jira-skill-bot-v1:"$tag"
docker pull team2021/issue-tracker-bot-v1:"$tag"
docker pull team2021/cloud-aws-bot-v1:"$tag"
# docker pull apisecuriti/notification-slack-skill-bot-v1:"$tag"




echo "## CREATING REQUIRED VOLUMES ##"

#4.	Create folder for docker volumes. Optionally, user can mount external drives at these locations.
mkdir -p /apisecuriti/postgres/data
mkdir -p /apisecuriti/elasticsearch/data
mkdir -p /apisecuriti/rabbitmq/data
mkdir -p /apisecuriti/haproxy

echo "## CREATING SELF-SIGNED CERTIFICATE ##"
#5.	Self-signed certificate creation.
# All the cert files (fxcloud.key, fxcloud.crt, fxcloud.pem, and haproxy.cfg) should be moved to /fx-security-enterprise/haproxy folder
SSL_DIR="/apisecuriti/haproxy"
cp haproxy.cfg $SSL_DIR

# Let user customize certification creation with sensible defaults
echo "Please enter info to generate SSL Private Key, CSR and Certificate"
read -p "Enter Passphrase for private key: " Passphrase
read -p "Enter Common Name (The Common Name is the Host + Domain Name. It looks like "www.company.com" or "company.com"): " CommonName
read -p "Enter Country (Use the two-letter code without punctuation for country, for example: US or CA): " Country
read -p "Enter City or Locality (The Locality field is the city or town name, for example: Berkeley): " City
read -p "Enter State or Province (Spell out the state completely; do not abbreviate the state or province name, for example: California): " State
read -p "Enter Organization: " Organization
read -p "Enter Organizational Unit (This field is the name of the department or organization unit making the request): "  OrganizationalUnit

# Set our CSR variables
SUBJ="/"
CN="$CommonName"
C="$Country"
L="$City"
ST="$State"
O="$Organization"
OU="$OrganizationalUnit"

echo "## CREATING SSL DIRECTORY ##"
# Create our SSL directory in case it doesn't exist
sudo mkdir -p "$SSL_DIR"

echo "## GENERATING CERTIFICATE FILES ##"
# Generate our Private Key, CSR and Certificate
sudo openssl genrsa -out "$SSL_DIR/fxcloud.key" 2048
sudo openssl req -new -subj "$(echo -n "$SUBJ")" -key "$SSL_DIR/fxcloud.key" -out "$SSL_DIR/fxcloud.csr" -passin pass:"$Passphrase"
sudo openssl x509 -req -days 365 -in "$SSL_DIR/fxcloud.csr" -signkey "$SSL_DIR/fxcloud.key" -out "$SSL_DIR/fxcloud.crt"

#6.	Run
sysctl -w vm.max_map_count=262144
source .env
export $(cut -d= -f1 .env)

echo "## GENERATING RANDOM PASSWORD FOR POSTGRES AND RABBITMQ ##"
# RabbitMQ
# Generate and set random password for “POSTGRES_PASSWORD” in .env
POSTGRES_PASSWORD="$(openssl rand -base64 12)"
sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASSWORD|g" .env

# Generate and set random password for “RABBITMQ_DEFAULT_PASS” in .env
RABBITMQ_DEFAULT_PASS="$(openssl rand -base64 12)"
sed -i "s|RABBITMQ_DEFAULT_PASS=.*|RABBITMQ_DEFAULT_PASS=$RABBITMQ_DEFAULT_PASS|g" .env

# Generate and set random password for “RABBITMQ_DEFAULT_PASS” in .env
RABBITMQ_AGENT_PASS="$(openssl rand -base64 12)"
sed -i "s|RABBITMQ_AGENT_PASS=.*|RABBITMQ_AGENT_PASS=$RABBITMQ_AGENT_PASS|g" .env

#echo "## ENTER STACK NAME TAG ##"
read -p "Enter stack name tag: " StackName

echo "## DEPLOYING POSTGRES, ELASTICSEARCH & RABBITMQ SERVICES  ##"
# Run Docker stack deploy
docker stack deploy -c fx-security-enterprise-data.yaml "$StackName"

sleep 60

# RabbitMQ Scanbot password (These commands need to executed on RabbitMQ container)
docker exec $(docker ps -q -f name=fx-rabbitmq) rabbitmqctl add_user fx_bot_user apisecuritibotpass
docker exec $(docker ps -q -f name=fx-rabbitmq) rabbitmqctl set_permissions -p fx fx_bot_user "" ".*" ".*"

echo "## DEPLOYING CONTROL-PLANE SERVICE ##"
docker stack deploy -c fx-security-enterprise-control-plane.yaml "$StackName"

sleep 30

echo "## DEPLOYING DEPENDENT SERVICES ##"
docker stack deploy -c fx-security-enterprise-dependents.yaml "$StackName"

echo "## UPDATING SETTINGS ##"
IP_ADDRESS="$(dig +short myip.opendns.com @resolver1.opendns.com)"
echo "update system_setting set value='${IP_ADDRESS}' where key='FX_HOST';">>hostupdate.sql
echo "update system_setting set value='false' where key='FX_SSL';">>hostupdate.sql
echo "update system_setting set value='5672' where key='FX_PORT';">>hostupdate.sql
echo "update system_setting set value='2020-06-20-1836' where key='BOT_TAG';">>hostupdate.sql
echo "update org set billing_email='${EMAIL}' where billing_email='admin@apisecuriti.io';">>hostupdate.sql
echo "update users set email='${EMAIL}' where email='admin@apisecuriti.io';">>hostupdate.sql


docker container cp hostupdate.sql $(docker ps -q -f name=fx-postgres):/

docker container exec -it $(docker ps -q -f name=fx-postgres) psql --dbname=fx --username ${POSTGRES_USER} -f /hostupdate.sql
echo "## GENERATING PEM FILE FOR HAPROXY ##"
sudo cat /apisecuriti/haproxy/fxcloud.crt /apisecuriti/haproxy/fxcloud.key \ | sudo tee /apisecuriti/haproxy/fxcloud.pem
sleep 10

echo "## DEPLOYING HAPROXY SERVICE ##"
docker stack deploy -c fx-security-enterprise-haproxy.yaml "$StackName"

sleep 10
docker service ls
sleep 5
docker ps
sleep 5
echo "$StackName" "SERVICES HAVE BEEN DEPLOYED SUCCESSFULLY!!!"
