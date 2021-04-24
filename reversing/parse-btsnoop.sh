#!/bin/bash
tshark -Y btspp -O hci_h4,btspp -r ${1-./b.log} | awk -F'[: ]+' '$1~/Frame/ { printf "%s ", $2};$2~/Direct/ {printf "%s ", $3};$2~/Data/{printf "%s\n", $3}'

# live:
# tshark -l -Y btspp -O hci_h4,btspp -i android-bluetooth-btsnoop-net-$IP:5555 2>&1 | \
#   awk -F'[: ]+' '$1~/Frame/ { printf "%s ", $2};$2~/Direct/ {printf "%s ", $3};$2~/Data/{printf "%s\n", $3; fflush()}' | \
#   ruby annotate-commlog.rb
