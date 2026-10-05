#!/usr/bin/perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

use Test::More tests => 4;
use Test::MockModule;
use Test::NoWarnings;

use JSON qw( decode_json );

use Koha::ActionLogs;
use Koha::Database;

use Koha::Plugin::Com::ByWaterSolutions::UniqueCollections;

my $schema = Koha::Database->new->schema;

my $plugin;
{
    # Until the kpz is built $VERSION is the literal '{VERSION}', comparing it to the installed version warns
    my $plugins_base = Test::MockModule->new('Koha::Plugins::Base');
    $plugins_base->mock( '_version_compare', sub { return 0 } );

    # Built outside of any transaction, install() creates a table and that commits implicitly
    $plugin = Koha::Plugin::Com::ByWaterSolutions::UniqueCollections->new( { enable_plugins => 1 } );
}

subtest '_cc_email_addresses() tests' => sub {
    plan tests => 3;
    $schema->storage->txn_begin;

    $plugin->store_data( { cc_email => q{} } );
    is_deeply( [ $plugin->_cc_email_addresses ], [], 'No addresses if cc_email is empty' );

    $plugin->store_data( { cc_email => 'one@example.com' } );
    is_deeply( [ $plugin->_cc_email_addresses ], ['one@example.com'], 'A single address is returned' );

    $plugin->store_data( { cc_email => ' one@example.com, two@example.com;three@example.com  four@example.com, ' } );
    is_deeply(
        [ $plugin->_cc_email_addresses ],
        [ 'one@example.com', 'two@example.com', 'three@example.com', 'four@example.com' ],
        'Addresses are split on commas, semicolons and whitespace'
    );

    $schema->storage->txn_rollback;
};

subtest '_log_configuration_changes() tests' => sub {
    plan tests => 7;
    $schema->storage->txn_begin;

    my $settings = {
        unique_email   => 'ums@example.com',
        cc_email       => q{},
        fees_threshold => '25',
        password       => 'old_password',
    };
    $plugin->store_data($settings);

    my $logs  = Koha::ActionLogs->search( { module => 'GENTLENUDGE', action => 'CONFIGURATION_UPDATED' } );
    my $count = $logs->count;

    my $changes = $plugin->_log_configuration_changes($settings);
    is_deeply( $changes, {}, 'No changes found if no settings changed' );
    is( $logs->count, $count, 'No action log added if no settings changed' );

    $plugin->_log_configuration_changes(
        {
            unique_email   => 'ums@example.com',
            cc_email       => 'one@example.com,two@example.com',
            fees_threshold => '30',
            password       => 'new_password',
        }
    );
    is( $logs->count, $count + 1, 'One action log added if settings changed' );

    my $log = $logs->search( {}, { order_by => { -desc => 'action_id' } } )->next;
    is_deeply(
        decode_json( $log->info ),
        {
            cc_email       => { before => q{},        after => 'one@example.com,two@example.com' },
            fees_threshold => { before => '25',       after => '30' },
            password       => { before => '********', after => '********' },
        },
        'Only changed settings are logged, the password is masked'
    );
    unlike( $log->info, qr/old_password|new_password/, 'The password is not stored in the action log' );
    is( $log->interface, 'intranet', 'Action log interface is intranet' );

    $changes = $plugin->_log_configuration_changes( { password => q{} } );
    is_deeply(
        $changes, { password => { before => '********', after => q{} } },
        'Clearing the password is logged as a change'
    );

    $schema->storage->txn_rollback;
};

subtest '_load_runtime_settings() tests' => sub {
    plan tests => 3;
    $schema->storage->txn_begin;

    $plugin->store_data( { debug => '2', no_email => '1', archive_dir => '/tmp/ums_archive_setting' } );

    {
        delete local $ENV{UMS_COLLECTIONS_DEBUG};
        delete local $ENV{UMS_COLLECTIONS_NO_EMAIL};
        delete local $ENV{UMS_COLLECTIONS_ARCHIVES_DIR};

        $plugin->_load_runtime_settings;
        is_deeply(
            runtime_settings(), [ 2, 1, '/tmp/ums_archive_setting' ],
            'Plugin settings are used if the environment variables are not set'
        );
    }

    {
        local $ENV{UMS_COLLECTIONS_DEBUG}        = '1';
        local $ENV{UMS_COLLECTIONS_NO_EMAIL}     = '0';
        local $ENV{UMS_COLLECTIONS_ARCHIVES_DIR} = '/tmp/ums_archive_env';

        $plugin->_load_runtime_settings;
        is_deeply(
            runtime_settings(), [ 1, 0, '/tmp/ums_archive_env' ],
            'Environment variables are used over the plugin settings'
        );
    }

    {
        delete local $ENV{UMS_COLLECTIONS_DEBUG};
        delete local $ENV{UMS_COLLECTIONS_NO_EMAIL};
        delete local $ENV{UMS_COLLECTIONS_ARCHIVES_DIR};

        $plugin->store_data( { debug => q{}, no_email => q{}, archive_dir => q{} } );
        $plugin->_load_runtime_settings;
        is_deeply( runtime_settings(), [ 0, 0, undef ], 'Defaults are used if nothing is set' );
    }

    $schema->storage->txn_rollback;
};

sub runtime_settings {
    return [
        $Koha::Plugin::Com::ByWaterSolutions::UniqueCollections::debug,
        $Koha::Plugin::Com::ByWaterSolutions::UniqueCollections::no_email,
        $Koha::Plugin::Com::ByWaterSolutions::UniqueCollections::archive_dir,
    ];
}
