# phpipam-to-ad-dns

## Overview
A PowerShell script to create A and PTR records in AD DNS from data in phpipam.

This script is designed to be run on the Windows domain controller/DNS server under a user that has permissions to update DNS records.  The script only acts on addresses that have a custom attribute set.  NOTE: If the custom attribute you create is 'foobar', then use 'custom_foobar' as the attribute name in the script since that's how it will be exposed from the API.

Valid values are 0/No (ignore), 1/Yes (sync A and PTR), and A/OnlyA (update A record only).

The script creates TXT records for the host so that deletions/changes can be detected and sync'd.

## Installation
Copy to domain controller, edit the configuration block, and set up under scheduled tasks for a preferred interval.

Generated with Claude Code free.  I can't believe something like this doesn't already exist, but now it does.
