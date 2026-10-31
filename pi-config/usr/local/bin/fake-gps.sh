#!/bin/bash
# TEMPORARY fake GPS fix (Antibes) so charts render without a real GPS.
# Remove/disable once real GPS data reaches Signal K.
while true; do
  printf "\$GPGLL,4334.824,N,00707.500,E,153000.0,A,A*55\r\n" > /dev/udp/127.0.0.1/34667
  sleep 1
done
