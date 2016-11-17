#!/usr/bin/env bash

echo "Wait for 10 sec while gathering results..."
(stack exec bench-receiver &> /dev/null) & (sleep 1; stack exec bench-sender &> /dev/null)
stack exec bench-log-reader
