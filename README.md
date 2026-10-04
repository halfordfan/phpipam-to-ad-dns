# phpipam-to-ad-dns

## Overview
A PowerShell script to create A and PTR records in AD DNS from data in phpipam.

This script is designed to be run on the Windows domain controller/DNS server under a user that has permissions to update DNS records.  The script only acts on addresses that have a custom attribute set.  

Valid values are 0/No (ignore), 1/Yes (sync A and PTR), and A/OnlyA (update A record only).

The script creates TXT records for the host so that deletions/changes can be detected and sync'd.

## Installation
### On your phpipam instance
1. Enable API access to your phpipam instance.
2. Create an API application ID with a read-only token.
3. Create a custom attribute that controls sync.  I used an `enum` type to reflect the values above with a default of `0`.

### On your domain controller.
1. Copy the script to domain controller.
2. Edit the configuration block to match values set in phpipam.
3. Set up under scheduled tasks for a preferred interval.

Generated with Claude Code free.  I can't believe something like this doesn't already exist, but now it does.
