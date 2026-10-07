#!/bin/bash

mkdir -p secrets

for i in jwt session storage; do
    openssl rand -hex 64 > secrets/${i}
done

sudo chmod 700 secrets
sudo chmod 600 secrets/* 
