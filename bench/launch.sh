#!/usr/bin/env bash

(stack exec bench-receiver &> /dev/null) & (sleep 1; stack exec bench-sender &> /dev/null)
stack exec bench-log-reader
