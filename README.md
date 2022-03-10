# Unique Collections plugin for Koha

This plugin automates the process of sending patrons to the UMS collections service and updating those patrons in Koha.

## What is ByWater Solutions’ UMS Gentle Nudge plugin?

Gentle Nudge is a product offered by Unique Management Services to assist libraries with the recovery of overdue material and unpaid fines.  ByWater’s Gentle Nudge plugin will generate and send reports of patrons to UMS.  UMS then contacts those patrons and ‘nudges’ them to return to the library to pay their fines and/or return materials.  UMS does not ‘collect’ on behalf of the library.

### Reports sent to UMS:

1. New submission report: A weekly report of ‘new’ patrons that qualify for collections based on the specified criteria of minimum balance, patron types, account age, etc.
2. Update report: A report sent daily that monitors previously referred/active accounts for changes in account balance. This report keeps UMS current on patron balances for active collection accounts.
3. Synchronization report: This is the same as the Update report above and can be generated manually at any time by clicking the ‘Sync’ button on the plugin configuration page. This report sends the patron ID, patron name and total amount owed. Unique uses this report to query against our database to look for balance discrepancies and is useful for troubleshooting or catching up missed update or submission files.

The plugin will automatically flag patrons who meet specific requirements as being in collections and optionally add a processing fee and restrict their account. Once a patron clears their account by paying their fines to 0, the plugin can optionally automatically clear the collections flag.  At this time, the patron’s account restriction must be manually removed by library staff.

## How to set up the plugin:

The library will need to download and install the following plugin from the ByWater Github repository: koha-plugin-unique-management-gentle-nudge

### Downloading

From the [release page](https://github.com/bywatersolutions/koha-plugin-unique-collections/releases) you can download the latest release in `kpz` format.

### Installation

The plugin requires the Perl library _Text::CSV::Slurp_.
Please install this library before installing the plugin.

#### Cronjob
This plugin uses Koha's nightly plugin cronjob system. You can set some environment variables to affect the behavior of this plugin:
* `UMS_COLLECTIONS_DEBUG` - Set to 1 to unable debugging messages
* `UMS_COLLECTIONS_NO_EMAIL` - Set to 1 to test without sending email
* `UMS_COLLECTIONS_ARCHIVES_DIR` - Set to a path to keep copies of the files sent to UMS

### Configurations:

#### On what day of the week would you like new submissions sent to Unique?

Choose a single day of the week to report new patrons in collections to Unique.  Any day of the week can be selected.

#### What patron categories are eligible for collections?

Enter the Koha category codes for the patrons that can be sent to collections.  You can enter as many category codes as you need.  Remember to enter the cateogry code and not the Patron category name. You can find the category codes by going to Administration->Patron categories in Koha.  If this field is left blank, all patron categories will be included.

#### Threshold: at what amount owed should patrons be sent to collections?

This is the minimum amount owed by a single patron that will move them to collections.

#### Processing fee: what fee, if any, should be applied to patrons’ accounts when they are sent to collections?

If you charge the patron an additional fee when they are moved to collections, enter it here.  It will be added to the patron’s account as a line item.

#### Unique email: to what email address with UMS would you like the report sent?

This email will be provided to you by Unique Management Systems.  It is the email address at which they will receive the weekly, daily, and sync reports from Koha.

#### Collections flag: How are you identifying patrons in collections?

This is the field that Koha will use to mark patrons as being in collections. Sort1, Sort2, or a Patron Attribute are often used. Your Data Librarian and Educator will discuss the options with you.

#### Count fees newer/older than

These parameters establish the age of fees that Koha will review in determining collection status for new submissions and updates, i.e. the total fees between X and Y days old to check if a patron should be sent to collections. The default values are older than 60, newer than 90.

#### Clear collections flag

If you would like the collections flag automatically cleared for patrons who have paid their balance to 0, select Yes from the dropdown.

#### Add Restriction

If your library restricts patrons while they are in collections, select Yes from the dropdown. Remember that while the collections flag can be set to clear automatically, restrictions must be manually cleared.

