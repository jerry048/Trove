
# HostBRR Flash Sales Tracker

## Features
- **Automated dependency checks and installations**: Ensures all necessary software (Python, BeautifulSoup, Requests, and Screen) are installed.
- **Continuous monitoring**: Repeatedly checks the specified webpage for updates in product stock status and details.
- **Discord notifications**: Sends updates directly to a Discord channel via webhooks for immediate notification.

## Prerequisites
- A Discord server and a configured webhook URL to receive notifications.
#### How to create a Discord Webhook
1.  From the channel menu, select  **Edit channel**.
2.  Select  **Integrations**.
3.  If there are no existing webhooks, select  **Create Webhook**. Otherwise, select  **View Webhooks**  then  **New Webhook**.
4.  Copy the URL from the  **WEBHOOK URL**  field.

## Installation and Setup

### 1. Run the Installation Script
```bash
bash <(wget -qO- https://raw.githubusercontent.com/jerry048/Trove/main/HostBrr-StockMonit/HostBrr_flashsales_tracker.sh)
```

### 2. Verify Operation
Once the setup is complete, the system will immediately begin monitoring the designated HostBRR product page and check for changes. You will receive a confirmation message on Discord to confirm that the script is actively monitoring and running properly. 

To monitor the script's real-time operation and output, you can attach to the `screen` session at any time:
```bash
screen -r hostbbr-stock-checker
```
## Usage
The system will automatically monitor the designated HostBRR product page and check for changes every 10 seconds. Whenever a product's availability or details change, it will immediately send a formatted message to the specified Discord webhook.

## Stopping the Tracker
To stop the tracker, you can detach from the `screen` session and terminate it:
```bash
screen -X -S hostbbr-stock-checker quit
```

