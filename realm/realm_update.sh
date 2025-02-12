#!/bin/bash

systemctl stop realm
cd /etc/realm
wget  https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz
tar -xvf realm-x86_64-unknown-linux-gnu.tar.gz
rm realm-x86_64-unknown-linux-gnu.tar.gz

systemctl start realm