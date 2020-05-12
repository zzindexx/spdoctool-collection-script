# spdoctool-collection-script
Script to collect data from SharePoint farm for https://spdoctool.azurewebsites.net

This script collects data that can be helpful for quick or remote analysis of SharePoint farm components and their interconnections.

Collected data combined with the tool can be helpful during
- Searching for misconfiguration
- Migration planning
- Planning an update
- Farm configuration analysis

## Data collected
Script collects following data:
1) General farm information
   1) Farm servers and IPs
   1) Configuration database name
   1) Farm build number
   1) Central administration URL and pool
   1) Instaled language packs
   1) Farm administrators
1) SQL Servers in the farm
   1) Name
   1) Nodes if Always On is used
   1) Databases
1) Content databases
    1) Server
    1) Size
1) Web applications
    1) Url
    1) Alternate access mappings
    1) Managed paths
    1) User policies
    1) Farm solutions
    1) Resource throttling settings
    1) Outgoing email settings
    1) Identity providers
1) Site collections
    1) Name
    1) Url
    1) Size
1) Managed accounts
    1) Name
    1) Automatic password change
1) Service application pools
    1) Name
    2) Account
1) Web application pools
    1) Name
    1) Account
1) Service applications
    1) Name
    1) Type
    2) Database
1) Service application proxies
    1) Name
    2) Type
