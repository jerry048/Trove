#!/bin/bash

# Server IP addresses or hostnames
SERVER="105.235.237.2"

# Ports (make sure these are open and listening on the servers)
PORT1=5201
PORT2=5202
PORT3=5203
PORT4=5204
PORT5=5205

# Duration of the test in seconds
DURATION=30

# Run iperf3 with cubic congestion control
iperf3 -c $SERVER -p $PORT1 -C cubic -t $DURATION > /tmp/cubic_results.txt &
PID1=$!

# Run iperf3 with bbr congestion control
iperf3 -c $SERVER -p $PORT2 -C bbr -t $DURATION > /tmp/bbr_results.txt &
PID2=$!

# Run iperf3 with bbr congestion control
iperf3 -c $SERVER -p $PORT3 -C bbrw -t $DURATION > /tmp/bbrw_results.txt &
PID3=$!

# Run iperf3 with bbr congestion control
iperf3 -c $SERVER -p $PORT4 -C bbry -t $DURATION > /tmp/bbry_results.txt &
PID4=$!

# Run iperf3 with bbr congestion control
iperf3 -c $SERVER -p $PORT5 -C bbrx -t $DURATION > /tmp/bbrx_results.txt &
PID5=$!


# Wait for both processes to finish
wait $PID1 $PID2 $PID3 $PID4 $PID5

##DISPLAY RESULTS
#Throughput
cubic=$(cat /tmp/cubic_results.txt | grep "sender" | awk '{print $7}')
bbr=$(cat /tmp/bbr_results.txt | grep "sender" | awk '{print $7}')
bbrw=$(cat /tmp/bbrw_results.txt | grep "sender" | awk '{print $7}')
bbry=$(cat /tmp/bbry_results.txt | grep "sender" | awk '{print $7}')
bbrx=$(cat /tmp/bbrx_results.txt | grep "sender" | awk '{print $7}')
#Unit
cubic_u=$(cat /tmp/cubic_results.txt | grep "sender" | awk '{print $8}')
bbr_u=$(cat /tmp/bbr_results.txt | grep "sender" | awk '{print $8}')
bbrw_u=$(cat /tmp/bbrw_results.txt | grep "sender" | awk '{print $8}')
bbry_u=$(cat /tmp/bbry_results.txt | grep "sender" | awk '{print $8}')
bbrx_u=$(cat /tmp/bbrx_results.txt | grep "sender" | awk '{print $8}')
#Retransmissions
cubic_retrans=$(cat /tmp/cubic_results.txt | grep "sender" | awk '{print $9}')
bbr_retrans=$(cat /tmp/bbr_results.txt | grep "sender" | awk '{print $9}')
bbrw_retrans=$(cat /tmp/bbrw_results.txt | grep "sender" | awk '{print $9}')
bbry_retrans=$(cat /tmp/bbry_results.txt | grep "sender" | awk '{print $9}')
bbrx_retrans=$(cat /tmp/bbrx_results.txt | grep "sender" | awk '{print $9}')

# Display results in a table
echo "Results"
echo "---------------------------------"
echo "Congestion Control | Throughput | Retransmissions"
echo "---------------------------------"
echo "Cubic              | $cubic $cubic_u | $cubic_retrans"
echo "BBR                | $bbr $bbr_u | $bbr_retrans"
echo "BBRw               | $bbrw $bbrw_u | $bbrw_retrans"
echo "BBRy               | $bbry $bbry_u | $bbry_retrans"
echo "BBRx               | $bbrx $bbrx_u | $bbrx_retrans"
echo "---------------------------------"


# Remove temporary files
rm /tmp/cubic_results.txt /tmp/bbr_results.txt /tmp/bbrw_results.txt /tmp/bbry_results.txt /tmp/bbrx_results.txt


