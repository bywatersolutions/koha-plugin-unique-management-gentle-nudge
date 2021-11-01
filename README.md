# Unique Collections plugin for Koha

This plugin automates the process of sending patrons to the UMS collections service and updating those patrons in Koha.

# Downloading

From the [release page](https://github.com/bywatersolutions/koha-plugin-unique-collections/releases) you can download the latest release in `kpz` format.

# Installation

The plugin requires the Perl library _Text::CSV::Slurp_.
Please install this library before installing the plugin.

## Cronjob
This plugin uses Koha's nightly plugin cronjob system. You can set some environment variables to affect the behavior of this plugin:
* `UMS_COLLECTIONS_DEBUG` - Set to 1 to unable debugging messages
* `UMS_COLLECTIONS_NO_EMAIL` - Set to 1 to test without sending email
* `UMS_COLLECTIONS_ARCHIVES_DIR` - Set to a path to keep copies of the files sent to UMS
