#!/bin/bash
psql -v ON_ERROR_STOP=1 --set=password_lambda="$PGPASSWORD_LAMBDA" "host=$DB_IP dbname=fiddle user=postgres password=$PGPASSWORD_POSTGRES sslmode=require" -f sql/api.sql