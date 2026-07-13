#!/bin/bash
psql "host=$DB_IP dbname=fiddle user=postgres password=$PGPASSWORD_POSTGRES sslmode=require"
