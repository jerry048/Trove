#!/bin/bash

# Check if we have all the necessary dependencies
if ! command -v python3 &> /dev/null
then
	if [[ $EUID -ne 0 ]]
	then
		echo "Python3 could not be found. Please install python3."
		exit 1
	else
		apt-get update
		apt-get install python3 -y
	fi
fi

# Check if python3-bs4 is installed
if ! python3 -c "import bs4" &> /dev/null
then
	if [[ $EUID -ne 0 ]]
	then
		echo "Python3-bs4 could not be found. Please install python3-bs4."
		exit 1
	else
		apt-get update
		apt-get install python3-bs4 -y
	fi
fi

# Check if python3-requests is installed
if ! python3 -c "import requests" &> /dev/null
then
	if [[ $EUID -ne 0 ]]
	then
		echo "Python3-requests could not be found. Please install python3-requests."
		exit 1
	else
		apt-get update
		apt-get install python3-requests -y
	fi
fi

# Check if screen is installed
if ! command -v screen &> /dev/null
then
	if [[ $EUID -ne 0 ]]
	then
		echo "Screen could not be found. Please install screen."
		exit 1
	else
		apt-get update
		apt-get install screen -y
	fi
fi

# Ask user for Discord webhook URL
echo "Please enter your Discord webhook URL:"
read webhook

# Sanity check for Discord webhook URL
while true
do
	if [[ ! $webhook =~ ^https://discord.com/api/webhooks/[0-9]+/[a-zA-Z0-9_-]+$ ]]
	then
		echo "Invalid Discord webhook URL. Please enter a valid Discord webhook URL."
		read webhook
	else
		break
	fi
done

# Download the python script
wget -O /tmp/hostbrr_monit.py https://raw.githubusercontent.com/jerry048/Trove/main/HostBrr-StockMonit/hostbrr_monit.py

# Create a screen session
screen -dmS hostbbr-stock-checker python3 /tmp/stock.py $webhook
