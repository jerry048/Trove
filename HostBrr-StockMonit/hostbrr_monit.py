from bs4 import BeautifulSoup as bs
import requests
import time
import sys

# Discord webhook URL
webhook_url = sys.argv[1] if len(sys.argv) > 1 else None
if webhook_url is None:
    print("Please provide a Discord webhook URL as an argument.")
    sys.exit(1)
webhook_data = {
    'username': 'HostBRR Product Monitor',
    'content': "HostBRR Product Monitor is now running. 🚀"
}
requests.post(webhook_url, json=webhook_data)

# Initial variables
url = 'https://my.hostbrr.com/order/main/packages/anniversary/?group_id=59'
original_product_info = []
counter = 0

# Main loop
while True:
    product_info = []
    response = requests.get(url)
    soup = bs(response.text, 'html.parser')
    packages = soup.find_all('div', class_='package-boxes')
    for package in packages:
        package_name = package.find('h4').text.strip()  # Product name
        pricing_options = package.find('select', {'name': 'pricing_id'})  # Pricing
        if pricing_options:
            prices = [option['data-display-price'] for option in pricing_options.find_all('option')]
            prices = ', '.join(prices).replace('[', '').replace(']', '')
        else:
            prices = "No pricing available"
        specifications = package.find('p').text.strip()  # Specifications
        if package.find('div', class_='sold-btn') or package.find('button', {'disabled': True}):
            stock_status = "Out of Stock"
        elif package.find('button', class_='btn-success'):
            stock_status = "In Stock"
        else:
            stock_status = "Stock status unknown"

        product_info.append({
            'Package Name': package_name,
            'Pricing': prices,
            'Specifications': specifications,
            'Stock Status': stock_status
        })

    # Check if the product information has changed
    for product in product_info:
        if product not in original_product_info:
            print(f"New product found! {product['Package Name']}")
            webhook_data = {
                'username': 'HostBRR Product Monitor',
                'content': "**New Product Found !!**  🎉",
                'embeds': [
                    {
                        'title': product['Package Name'],
                        'description': f"**Pricing:** {product['Pricing']}\n\n**Specifications:** {product['Specifications']}\n\n**Stock Status:** {product['Stock Status']}",
                        'color': 0x001F,
                        'url': 'https://my.hostbrr.com/order/main/packages/anniversary/?group_id=59'
                    }
                ]
            }
            requests.post(webhook_url, json=webhook_data)
    # Update the original product information
    original_product_info = product_info
    counter += 1
    print(f"Checked at {time.strftime('%H:%M:%S')} - {counter} times")
    time.sleep(10)
