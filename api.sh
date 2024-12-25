#!/bin/bash
psql --set=password_lambda="$PGPASSWORD_LAMBDA" "host=$DB_IP dbname=fiddle user=postgres password=$PGPASSWORD_POSTGRES sslmode=require" -f sql/api.sql