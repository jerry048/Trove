#!/bin/bash
mkdir -p /etc/realm && cd /etc/realm
wget https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz
tar -xvf realm-x86_64-unknown-linux-gnu.tar.gz
rm realm-x86_64-unknown-linux-gnu.tar.gz

# Create a systemd service
cat <<EOF > /etc/systemd/system/realm.service
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service
 
[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
DynamicUser=true
WorkingDirectory=/etc/realm
ExecStart=/etc/realm/realm -c /etc/realm/config.toml
 
[Install]
WantedBy=multi-user.target
EOF

# Create a configuration file
cat <<EOF > /etc/realm/config.toml
[[endpoints]]
listen = "0.0.0.0:5000"
remote = "1.2.3.4:8080"
EOF

systemctl enable realm

