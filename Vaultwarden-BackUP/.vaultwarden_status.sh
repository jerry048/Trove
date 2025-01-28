#!/bin/bash

# Variables
DOMAIN="example.com"
CF_API_KEY="YOUR_API_KEY"
CF_EMAIL="YOUR_EMAIL"
CADDYFILE="/etc/caddy/Caddyfile"
VW_PORT=8080

CF_ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
    -H "Authorization: Bearer $ CF_API_KEY" \
    -H "Content-Type: application/json" | jq -r '.result[0].id')
CF_RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=A&name=$DOMAIN" \
    -H "Authorization: Bearer $ CF_API_KEY" \
    -H "Content-Type: application/json" | jq -r '.result[0].id')

# Get the backup IP address
BACKUP_IP=$(curl -s https://api.ipify.org)
if [[ $BACKUP_IP == *":"* ]]; then
    BACKUP_IP_TYPE="AAAA"
else
    BACKUP_IP_TYPE="A"
fi

# Check if the main Vaultwarden URL is down
if ! curl --silent --head "https://$DOMAIN" | grep "200" > /dev/null; then
    # Update the DNS record to point to the backup IP address
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID" \
        -H "Authorization: Bearer $
        CF_API_KEY" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$BACKUP_IP_TYPE\",\"name\":\"$DOMAIN\",\"content\":\"$BACKUP_IP\",\"ttl\":1,\"proxied\":true}"
    # Start Cadddy
    systemctl start caddy
fi

# Check if the main Vaultwarden URL is up
if curl --silent --head "https://$DOMAIN" | grep "200" > /dev/null; then
    # Update the DNS record to point to the main IP address
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID" \
        -H "Authorization: Bearer $
        CF_API_KEY" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$BACKUP_IP_TYPE\",\"name\":\"$DOMAIN\",\"content\":\"$MAIN_IP\",\"ttl\":1,\"proxied\":true}"
    # Stop Caddy
    systemctl stop caddy
fi

