#!/bin/bash

# Server IP addresses or hostnames
SERVER="speedtest.lax12.us.leaseweb.net"

# IPv4 or IPv6
IP_VERSION=4

# Ports
PORT1=5201
PORT2=5202
PORT3=5203

# Algorithm
Algo1=cubic
Algo2=reno
Algo3=bbr

# Duration of the test in seconds
DURATION=30

# Function to display a progress bar
progress_bar() {
    local duration=$1
    local elapsed=0
    while [ $elapsed -lt $duration ]; do
        printf "\rProgress: [%-30s] %d%%" $(printf "#%.0s" $(seq 1 $((elapsed * 30 / duration)))) $((elapsed * 100 / duration))
        sleep 1
        elapsed=$((elapsed + 1))
    done
    printf "\rProgress: [%-30s] %d%%\n" $(printf "#%.0s" $(seq 1 30)) 100
}

echo "Testing $Algo1 vs $Algo2 vs $Algo3 on $SERVER"
# Run iperf3 with cubic congestion control
iperf3 -c $SERVER -p $PORT1 -C $Algo1 -t $DURATION -$IP_VERSION > /tmp/${Algo1}_results.txt &
PID1=$!

# Run iperf3 with bbr congestion control
iperf3 -c $SERVER -p $PORT2 -C $Algo2 -t $DURATION -$IP_VERSION > /tmp/${Algo2}_results.txt &
PID2=$!

# Run iperf3 with reno congestion control
iperf3 -c $SERVER -p $PORT3 -C $Algo3 -t $DURATION -$IP_VERSION > /tmp/${Algo3}_results.txt &
PID3=$!

# Show progress bar for the duration of the tests
progress_bar $DURATION &

# Wait for all processes to finish
wait $PID1 $PID2 $PID3

##DISPLAY RESULTS
# Throughput
test1=$(cat /tmp/${Algo1}_results.txt | grep "sender" | awk '{print $7}')
test2=$(cat /tmp/${Algo2}_results.txt | grep "sender" | awk '{print $7}')
test3=$(cat /tmp/${Algo3}_results.txt | grep "sender" | awk '{print $7}')

# Unit
test1_u=$(cat /tmp/${Algo1}_results.txt | grep "sender" | awk '{print $8}')
test2_u=$(cat /tmp/${Algo2}_results.txt | grep "sender" | awk '{print $8}')
test3_u=$(cat /tmp/${Algo3}_results.txt | grep "sender" | awk '{print $8}')

# Retransmissions
test1_retrans=$(cat /tmp/${Algo1}_results.txt | grep "sender" | awk '{print $9}')
test2_retrans=$(cat /tmp/${Algo2}_results.txt | grep "sender" | awk '{print $9}')
test3_retrans=$(cat /tmp/${Algo3}_results.txt | grep "sender" | awk '{print $9}')

# Display results in a table
echo "Results"
echo "---------------------------------"
echo "Congestion Control | Throughput | Retransmissions"
echo "---------------------------------"
echo "$Algo1             | $test1 $test1_u | $test1_retrans"
echo "$Algo2             | $test2 $test2_u | $test2_retrans"
echo "$Algo3             | $test3 $test3_u | $test3_retrans"
echo "---------------------------------"

# Remove temporary files
rm /tmp/${Algo1}_results.txt /tmp/${Algo2}_results.txt /tmp/${Algo3}_results.txt
