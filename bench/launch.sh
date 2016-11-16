#!/usr/bin/env bash

(sleep 1; stack exec bench-sender) & stack exec bench-receiver
