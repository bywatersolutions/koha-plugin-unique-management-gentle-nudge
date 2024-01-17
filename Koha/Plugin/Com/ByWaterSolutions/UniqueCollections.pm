package Koha::Plugin::Com::ByWaterSolutions::UniqueCollections;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Auth;
use C4::Context;
use C4::Log qw(logaction);
use Koha::DateUtils qw(dt_from_string);
use Koha::Patron::Attribute::Types;
use Koha::Patron::Debarments qw(AddDebarment);
use Koha::Patrons;

use File::Path qw( make_path );
use File::Slurp;
use JSON;
use Net::SFTP::Foreign;
use Text::CSV::Slurp;
use Try::Tiny;

## Here we set our plugin version
our $VERSION         = "{VERSION}";
our $MINIMUM_VERSION = "{MINIMUM_VERSION}";
our $debug           = $ENV{UMS_COLLECTIONS_DEBUG}        // 0;
our $no_email        = $ENV{UMS_COLLECTIONS_NO_EMAIL}     // 0;
our $archive_dir     = $ENV{UMS_COLLECTIONS_ARCHIVES_DIR} // undef;

our $metadata = {
    name            => 'Unique Management Services - Gentle Nudge',
    author          => 'Kyle M Hall',
    date_authored   => '2021-09-27',
    date_updated    => "1900-01-01",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Plugin to forward messages to Unique Collections for processing and sending',
};

our $json = JSON->new;
$json->pretty(1);
$json->convert_blessed(1);

=head3 new

=cut

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

=head3 configure

=cut

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        if ( $cgi->param('sync') ) {
            $self->cronjob_nightly( { send_sync_report => 1 } );
            $template->param( sync_report_ran => 1, );
        }

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            run_on_dow                      => $self->retrieve_data('run_on_dow'),
            require_lost_fee                => $self->retrieve_data('require_lost_fee'),
            categorycodes                   => $self->retrieve_data('categorycodes'),
            fees_threshold                  => $self->retrieve_data('fees_threshold'),
            processing_fee                  => $self->retrieve_data('processing_fee') || 0,
            unique_email                    => $self->retrieve_data('unique_email'),
            cc_email                        => $self->retrieve_data('cc_email'),
            collections_flag                => $self->retrieve_data('collections_flag'),
            fees_starting_age               => $self->retrieve_data('fees_starting_age') || 60,
            fees_ending_age                 => $self->retrieve_data('fees_ending_age')   || 90,
            auto_clear_paid                 => $self->retrieve_data('auto_clear_paid'),
            add_restriction                 => $self->retrieve_data('add_restriction'),
            remove_restriction              => $self->retrieve_data('remove_restriction'),
            age_limitation                  => $self->retrieve_data('age_limitation'),
            host                            => $self->retrieve_data('host'),
            username                        => $self->retrieve_data('username'),
            password                        => $self->retrieve_data('password'),
            attributes                      => scalar Koha::Patron::Attribute::Types->search(),
            auto_clear_paid_threshold       => $self->retrieve_data('auto_clear_paid_threshold'),
            fees_created_before_date_filter => $self->retrieve_data('fees_created_before_date_filter'),
        );

        $self->output_html( $template->output() );
    } else {
        $self->store_data(
            {
                run_on_dow                      => $cgi->param('run_on_dow'),
                require_lost_fee                => $cgi->param('require_lost_fee'),
                categorycodes                   => $cgi->param('categorycodes'),
                fees_threshold                  => $cgi->param('fees_threshold'),
                processing_fee                  => $cgi->param('processing_fee') || 0,
                unique_email                    => $cgi->param('unique_email'),
                cc_email                        => $cgi->param('cc_email'),
                collections_flag                => $cgi->param('collections_flag'),
                fees_starting_age               => $cgi->param('fees_starting_age'),
                fees_ending_age                 => $cgi->param('fees_ending_age'),
                auto_clear_paid                 => $cgi->param('auto_clear_paid'),
                add_restriction                 => $cgi->param('add_restriction'),
                remove_restriction              => $cgi->param('remove_restriction'),
                age_limitation                  => $cgi->param('age_limitation'),
                host                            => $cgi->param('host'),
                username                        => $cgi->param('username'),
                password                        => $cgi->param('password'),
                auto_clear_paid_threshold       => $cgi->param('auto_clear_paid_threshold'),
                fees_created_before_date_filter => $cgi->param('fees_created_before_date_filter'),
            }
        );
        $self->go_home();
    }
}

=head3 cronjob_nightly

=cut

sub cronjob_nightly {
    my ( $self, $p ) = @_;

    # Clear up archives older than 30 days
    if ($archive_dir) {
        if ( -d $archive_dir ) {
            my $dt = dt_from_string();
            $dt->subtract( days => 30 );
            my $age_threshold = $dt->ymd;
            opendir my $dir, $archive_dir or die "Cannot open directory: $!";
            my @files = readdir $dir;
            closedir $dir;

            my $thresholds = {
                new_submissions => "ums-new-submissions-$age_threshold.csv",
                sync            => "ums-sync-$age_threshold.csv",
                updates         => "ums-updates-$age_threshold.csv",
            };

            foreach my $f (@files) {
                next unless $f =~ /csv$/;

                my $threshold_filename =
                      $f =~ /^ums-new-submissions/ ? $thresholds->{new_submissions}
                    : $f =~ /^ums-sync/            ? $thresholds->{sync}
                    : $f =~ /^ums-updates/         ? $thresholds->{updates}
                    :                                undef;

                next unless $threshold_filename;

                if ( $f lt $threshold_filename ) {
                    unlink( $archive_dir . "/" . $f );
                }
            }
        } else {
            make_path $archive_dir or die "Failed to create path: $archive_dir";
        }
    }

    my $run_weeklys;
    my $run_on_dow = $self->retrieve_data('run_on_dow');
    unless ( (localtime)[6] == $run_on_dow ) {
        say "Run on Day of Week $run_on_dow does not match current day of week " . (localtime)[6]
            if $debug >= 1;
    } else {
        $run_weeklys = 1;
    }

    my $params = { send_sync_report => $p->{send_sync_report} };

    $params->{require_lost_fee}                = $self->retrieve_data('require_lost_fee');
    $params->{fees_threshold}                  = $self->retrieve_data('fees_threshold');
    $params->{processing_fee}                  = $self->retrieve_data('processing_fee');
    $params->{collections_flag}                = $self->retrieve_data('collections_flag');
    $params->{fees_starting_age}               = $self->retrieve_data('fees_starting_age');
    $params->{fees_ending_age}                 = $self->retrieve_data('fees_ending_age');
    $params->{auto_clear_paid}                 = $self->retrieve_data('auto_clear_paid');
    $params->{add_restriction}                 = $self->retrieve_data('add_restriction');
    $params->{remove_restriction}              = $self->retrieve_data('remove_restriction');
    $params->{age_limitation}                  = $self->retrieve_data('age_limitation');
    $params->{auto_clear_paid_threshold}       = $self->retrieve_data('auto_clear_paid_threshold');
    $params->{fees_created_before_date_filter} = $self->retrieve_data('fees_created_before_date_filter');

    # Starting age should be the large of the two numbers
    ( $params->{fees_starting_age}, $params->{fees_ending_age} ) =
        ( $params->{fees_ending_age}, $params->{fees_starting_age} )
        if $params->{fees_starting_age} < $params->{fees_ending_age};

    $params->{flag_type} =
        $params->{collections_flag} eq 'sort1' || $params->{collections_flag} eq 'sort2'
        ? 'borrower_field'
        : 'attribute_field';

    my @categorycodes = split( /,/, $self->retrieve_data('categorycodes') );
    $params->{categorycodes} = \@categorycodes;

    my $today = dt_from_string();
    $params->{date} = $today->ymd();

    ### Process new submissions
    if ( $run_weeklys && !$params->{send_sync_report} ) {
        $self->run_submissions_report($params);
    } elsif ( !$params->{send_sync_report} ) {
        say "NOT THE DOW TO RUN SUBMISSIONS\n\n" if $debug >= 1;
    }

    ### Process UMS Update Report
    $self->run_update_report_and_clear_paid($params);
}

sub run_submissions_report {
    my ( $self, $params ) = @_;
    my $age_limitation = $params->{age_limitation};

    my $dbh = C4::Context->dbh;
    $dbh->{RaiseError} = 1;    # die if a query has problems

    my $info = {};
    try {
        my $sth;

        my $ums_submission_query = q{
    SELECT
        };

        $ums_submission_query .= q{
    MAX(attribute),
        } if $params->{flag_type} eq 'attribute_field';

        $ums_submission_query .= q{
    MAX(borrowers.cardnumber)         AS "cardnumber",
    MAX(borrowers.borrowernumber)     AS "borrowernumber",
    MAX(borrowers.surname)            AS "surname",
    MAX(borrowers.firstname)          AS "firstname",
    MAX(borrowers.address)            AS "address",
    MAX(borrowers.address2)           AS "address2",
    MAX(borrowers.city)               AS "city",
    MAX(borrowers.zipcode)            AS "zipcode",
    MAX(borrowers.state)              AS "state",
    MAX(borrowers.phone)              AS "phone",
    MAX(borrowers.mobile)             AS "mobile",
    MAX(borrowers.phonepro)           AS "Alt Ph 1",
    MAX(borrowers.b_phone)            AS "Alt Ph 2",
    MAX(borrowers.branchcode)         AS "branchcode",
    MAX(categories.category_type)     AS "Adult or Child",
    MAX(borrowers.dateofbirth)        AS "dateofbirth",
    MAX(accountlines.date)            AS "Most recent charge",
    FORMAT(Sum(amountoutstanding), 2) AS "Amt_In_Range",
    MAX(sub.due)                      AS "Total_Due",
    MAX(sub.dueplus)                  AS "Total_Plus_Fee",
    MAX(borrowers.email)              AS "email"
    FROM accountlines
        };

        $ums_submission_query .= qq{
           LEFT JOIN borrower_attributes ON accountlines.borrowernumber = borrower_attributes.borrowernumber
               AND code = '$params->{collections_flag}'
            } if $params->{flag_type} eq 'attribute_field';

        $ums_submission_query .= qq{
            LEFT JOIN borrowers ON ( accountlines.borrowernumber = borrowers.borrowernumber )

            LEFT JOIN (
              SELECT borrowernumber, COUNT(*) AS lost_fees_count
              FROM accountlines
              WHERE debit_type_code = 'LOST'
                AND amountoutstanding > 0
              GROUP BY borrowernumber
            ) AS lost_fees_count ON ( lost_fees_count.borrowernumber = borrowers.borrowernumber)

            LEFT JOIN categories ON ( categories.categorycode = borrowers.categorycode )

            LEFT JOIN ( SELECT
              REPLACE( FORMAT( SUM( accountlines.amountoutstanding ), 2), ',', '' ) AS Due,
              REPLACE( FORMAT( SUM(accountlines.amountoutstanding) + $params->{processing_fee}, 2), ',', '' ) AS DuePlus,
                  borrowernumber
              FROM accountlines
              GROUP BY borrowernumber) AS sub ON ( borrowers.borrowernumber = sub.borrowernumber)

            WHERE  1=1
              AND DATE(accountlines.date) >= DATE_SUB(CURDATE(), INTERVAL $params->{fees_starting_age} DAY)
              AND DATE(accountlines.date) <= DATE_SUB(CURDATE(), INTERVAL $params->{fees_ending_age} DAY)
            };

        $ums_submission_query .= qq{
              AND lost_fees_count.lost_fees_count > 0
            } if $params->{require_lost_fee} && $params->{require_lost_fee} eq 'yes';

        $ums_submission_query .= qq{
                AND ( borrowers.$params->{collections_flag} = 'no' OR borrowers.$params->{collections_flag} IS NULL OR borrowers.$params->{collections_flag} = "" )
            } if $params->{flag_type} eq 'borrower_field';

        $ums_submission_query .= q{
                AND ( attribute = '0' OR attribute IS NULL )
            } if $params->{flag_type} eq 'attribute_field';

        if ( @{ $params->{categorycodes} } ) {
            my $codes = join( ',', map { qq{"$_"} } @{ $params->{categorycodes} } );
            $ums_submission_query .= qq{
                    AND borrowers.categorycode IN ( $codes )
                };
        }

        if ( $age_limitation eq 'yes' ) {
            $ums_submission_query .= qq{ AND TIMESTAMPDIFF( YEAR, borrowers.dateofbirth, CURDATE() ) >= 18 };
        }

        if ( $params->{fees_created_before_date_filter} ) {
            $ums_submission_query .= qq{ AND accountlines.date > "$params->{fees_created_before_date_filter}" };
        }

        $ums_submission_query .= qq{
                GROUP BY borrowers.borrowernumber
                    HAVING Sum(amountoutstanding) >= $params->{fees_threshold}
                    ORDER BY borrowers.surname ASC
            };

        say "UMS SUBMISSION QUERY:\n$ums_submission_query" if $debug >= 0;

### Update new submissions patrons, add fee, mark as being in collections
        $sth = $dbh->prepare($ums_submission_query);
        $sth->execute();
        my @ums_new_submissions;
        while ( my $r = $sth->fetchrow_hashref ) {
            say "QUERY RESULT: " . Data::Dumper::Dumper($r) if $debug >= 1;

            my $patron = Koha::Patrons->find( $r->{borrowernumber} );
            next unless $patron;

            if ( $params->{add_restriction} eq 'yes' ) {
                AddDebarment(
                    {
                        borrowernumber => $patron->borrowernumber,
                        expiration     => undef,
                        type           => 'MANUAL',
                        comment        => "Patron sent to collections on $params->{date}",
                    }
                );
            }

            if ( $params->{flag_type} eq 'borrower_field' ) {
                $patron->update( { $params->{collections_flag} => 'yes' } );
            }
            if ( $params->{flag_type} eq 'attribute_field' ) {
                my $a = Koha::Patron::Attributes->find(
                    {
                        borrowernumber => $patron->id,
                        code           => $params->{collections_flag},
                    }
                );

                if ($a) {
                    $a->attribute(1)->store();
                } else {
                    Koha::Patron::Attribute->new(
                        {
                            borrowernumber => $patron->id,
                            code           => $params->{collections_flag},
                            attribute      => 1,
                        }
                    )->store();
                }
            }

            my $processing_fee = $params->{processing_fee};
            $patron->account->add_debit(
                {
                    amount      => $params->{processing_fee},
                    description => "UMS Processing Fee",
                    interface   => 'cron',
                    type        => 'MANUAL',
                }
            ) if $processing_fee && $processing_fee > 0;

            push( @ums_new_submissions, $r );
        }

        my $columns = [
            "borrowernumber", "surname",
            "firstname",      "cardnumber",
            "address",        "address2",
            "city",           "zipcode", 
            "state",          "phone",
            "mobile",         "Alt Ph 1",
            "Alt Ph 2",       "branchcode", 
            "Adult or Child", "dateofbirth",   
            "Most recent charge","Amt_In_Range",   
            "Total_Due",      "Total_Plus_Fee", 
            "email"
        ];

        ## Email the results
        my $csv =
            @ums_new_submissions
            ? Text::CSV::Slurp->create( input => \@ums_new_submissions, field_order => $columns )
            : 'No qualifying records';
        say "CSV:\n" . $csv if $debug >= 2;

        $archive_dir ||= "/tmp";

        my $filename  = "ums-new-submissions-$params->{date}.csv";
        my $file_path = "$archive_dir/$filename";

        write_file( $file_path, $csv );
        say "ARCHIVE WRITTEN TO $file_path" if $debug;

        my $sftp_host     = $self->retrieve_data('host');
        my $sftp_username = $self->retrieve_data('username');
        my $sftp_password = $self->retrieve_data('password');

        my $email_to   = $self->retrieve_data('unique_email');
        my $email_from = C4::Context->preference('KohaAdminEmailAddress');
        my $email_cc   = $self->retrieve_data('cc_email');

        $info = {
            count     => scalar @ums_new_submissions,
            filename  => $filename,
            file_path => $file_path,
        };

        if ($sftp_host) {
            $info->{sftp_host}     = $sftp_host;
            $info->{sftp_username} = $sftp_username;

            my $directory = $ENV{GENTLENUDGE_SFTP_DIR} || 'incoming';

            my $sftp = Net::SFTP::Foreign->new(
                host     => $sftp_host,
                user     => $sftp_username,
                port     => 22,
                password => $sftp_password
            );

            try {
                $sftp->die_on_error("Unable to establish SFTP connection");
                $sftp->setcwd($directory)
                    or die "unable to change cwd: " . $sftp->error;
                $sftp->put( $file_path, $filename )
                    or die "put failed: " . $sftp->error;
            } catch {
                $info->{sftp_failed} = 'true';
                $info->{sftp_error}  = $_;
            }
        }

        foreach my $email_address ( $email_to, $email_cc ) {
            next unless $email_address;
            say "ATTEMPTING TO SEND NEW SUBMISSIONS REPORT TO $email_address" if $debug >= 0;

            $info->{email_to}   = $email_address;
            $info->{email_from} = $email_from;

            my $p = {
                to      => $email_address,
                from    => $email_from,
                subject => "UMS New Submissions for " . C4::Context->preference('LibraryName'),
            };
            my $email = Koha::Email->new($p);

            $email->attach(
                Encode::encode_utf8($csv),
                content_type => "text/csv",
                filename     => "ums-new-submissions-$params->{date}.csv",
                name         => "ums-new-submissions-$params->{date}.csv",
                disposition  => 'attachment',
            );

            my $smtp_server = Koha::SMTP::Servers->get_default;
            $email->transport( $smtp_server->transport );

            try {
                $email->send_or_die unless $no_email;
            } catch {
                $info->{email_failed}  = 'true';
                $info->{email_address} = $email_address;
                $info->{email_error}   = $_;

                logaction(
                    'GENTLENUDGE',        'NEW_SUBMISSIONS_ERROR', undef,
                    $json->encode($info), 'cron'
                );

                die "Mail not sent: $_";
            };
        }

        logaction(
            'GENTLENUDGE',        'NEW_SUBMISSIONS', undef,
            $json->encode($info), 'cron'
        );
    } catch {
        if ( $_->isa('Koha::Exception') ) {
            $info->{error} = $_->error . "\n" . $_->trace->as_string;
        } else {
            $info->{error} = $_;
        }

        logaction(
            'GENTLENUDGE',        'NEW_SUBMISSIONS_ERROR', undef,
            $json->encode($info), 'cron'
        );
        die "error in run_update_report_and_clear_paid: " . $info->{error};
    };
}

sub run_update_report_and_clear_paid {
    my ( $self, $params ) = @_;

    my $dbh = C4::Context->dbh;
    $dbh->{RaiseError} = 1;    # die if a query has problems

    my $type = $params->{send_sync_report} ? 'sync' : 'updates';
    my $info = {};
    try {
        my $sth;

        my $ums_update_query = q{
            SELECT borrowers.cardnumber,
                   borrowers.borrowernumber,
                   MAX(borrowers.surname)                         AS "surname",
                   MAX(borrowers.firstname)                       AS "firstname",
                   FORMAT(Sum(accountlines.amountoutstanding), 2) AS "Due"
                       FROM   accountlines
                       LEFT JOIN borrowers USING(borrowernumber)
                       LEFT JOIN categories USING(categorycode)
        };

        $ums_update_query .= qq{
            LEFT JOIN borrower_attributes ON accountlines.borrowernumber = borrower_attributes.borrowernumber
                AND code = '$params->{collections_flag}'
        } if $params->{flag_type} eq 'attribute_field';

        $ums_update_query .= q{
            WHERE  1=1
        };

        $ums_update_query .= qq{
            AND attribute = '1'
        } if $params->{flag_type} eq 'attribute_field';

        $ums_update_query .= qq{
            AND borrowers.$params->{collections_flag} = 'yes'
        } if $params->{flag_type} eq 'borrower_field';

        $ums_update_query .= q{
            GROUP BY borrowers.borrowernumber
                ORDER BY borrowers.surname ASC
        };

        say "UMS UPDATE QUERY:\n$ums_update_query"
            if ( !$params->{send_sync_report} ) && $debug >= 0;

        $sth = $dbh->prepare($ums_update_query);
        $sth->execute();
        my @ums_updates;
        while ( my $r = $sth->fetchrow_hashref ) {
            say "QUERY RESULT: " . Data::Dumper::Dumper($r) if $debug >= 1;
            push( @ums_updates, $r );

            my $due = $r->{Due} || 0;
            $due =~ s/,//;
            if ( $params->{auto_clear_paid} eq 'yes' && $due <= $params->{auto_clear_paid_threshold} ) {
                $self->clear_patron_from_collections( $params, $r->{borrowernumber} );
                if ( $params->{remove_restriction} ) {
                    Koha::Patron::Restrictions->search(
                        {
                            borrowernumber => $r->{borrowernumber},
                            comment        => { 'like' => "Patron sent to collections on %" }
                        }
                    )->delete();
                    Koha::Patron::Debarments::UpdateBorrowerDebarmentFlags( $r->{borrowernumber} );
                }
            }
        }

        ## Email the results

        $archive_dir ||= "/tmp";
        my $filename  = "ums-$type-$params->{date}.csv";
        my $file_path = "$archive_dir/$filename";

        $info = {
            count     => scalar @ums_updates,
            type      => $type,
            filename  => $filename,
            file_path => $file_path,
        };

        my $columns = [ "borrowernumber", "surname", "firstname", "cardnumber", "Due" ];

        my $csv =
            @ums_updates
            ? Text::CSV::Slurp->create( input => \@ums_updates, field_order => $columns )
            : 'No qualifying records';
        say "CSV:\n" . $csv if $debug >= 2;

        write_file( $file_path, $csv )
            if $archive_dir;
        say "ARCHIVE WRITTEN TO $archive_dir/ums-$type-$params->{date}.csv"
            if $archive_dir && $debug;

        my $sftp_host     = $self->retrieve_data('host');
        my $sftp_username = $self->retrieve_data('username');
        my $sftp_password = $self->retrieve_data('password');

        my $email_from = C4::Context->preference('KohaAdminEmailAddress');
        my $email_to   = $self->retrieve_data('unique_email');
        my $email_cc   = $self->retrieve_data('cc_email');

        if ($sftp_host) {
            $info->{sftp_host}     = $sftp_host;
            $info->{sftp_username} = $sftp_username;

            my $directory = $ENV{GENTLENUDGE_SFTP_DIR} || 'cust2unique';

            my $sftp = Net::SFTP::Foreign->new(
                host     => $sftp_host,
                user     => $sftp_username,
                port     => 22,
                password => $sftp_password
            );

            try {
                $sftp->die_on_error("Unable to establish SFTP connection");
                $sftp->setcwd($directory)
                    or die "unable to change cwd: " . $sftp->error;
                $sftp->put( $file_path, $filename )
                    or die "put failed: " . $sftp->error;
            } catch {
                $info->{sftp_failed} = 'true';
                $info->{sftp_error}  = $_;
            }
        }

        foreach my $email_address ( $email_to, $email_cc ) {
            next unless $email_address;
            say "ATTEMPTING TO SEND ${\(uc($type))} REPORT TO $email_address" if $debug >= 0;

            my $p = {
                to      => $email_address,
                from    => $email_from,
                subject => sprintf(
                    "UMS %s for %s",
                    ucfirst($type), C4::Context->preference('LibraryName')
                ),
            };
            my $email = Koha::Email->new($p);

            $email->attach(
                Encode::encode_utf8($csv),
                content_type => "text/csv",
                filename     => $filename,
                name         => $filename,
                disposition  => 'attachment',
            );

            my $smtp_server = Koha::SMTP::Servers->get_default;
            $email->transport( $smtp_server->transport );

            try {
                $email->send_or_die unless $no_email;
            } catch {
                $info->{email_failed}  = 'true';
                $info->{email_address} = $email_address;
                $info->{email_error}   = $_;

                logaction(
                    'GENTLENUDGE',        uc($type) . "_ERROR", undef,
                    $json->encode($info), 'cron'
                );

                die "Mail not sent: $_";
            };
        }

        logaction(
            'GENTLENUDGE',        uc($type), undef,
            $json->encode($info), 'cron'
        );

    } catch {
        if ( $_->isa('Koha::Exception') ) {
            $info->{error} = $_->error . "\n" . $_->trace->as_string;
        } else {
            $info->{error} = $_;
        }

        logaction(
            'GENTLENUDGE',        uc($type) . "_ERROR", undef,
            $json->encode($info), 'cron'
        );
        die "error in run_update_report_and_clear_paid: $_";
    };
}

sub clear_patron_from_collections {
    my ( $self, $params, $borrowernumber ) = @_;

    say "CLEARING PATRON $borrowernumber FROM COLLECTIONS" if $debug >= 2;

    my $patron = Koha::Patrons->find($borrowernumber);
    next unless $patron;

    if ( $params->{flag_type} eq 'borrower_field' ) {
        $patron->_result->update( { $params->{collections_flag} => 'no' } );
    }
    if ( $params->{flag_type} eq 'attribute_field' ) {
        my $a = Koha::Patron::Attributes->find(
            {
                borrowernumber => $patron->id,
                code           => $params->{collections_flag},
            }
        );

        # At the time of this writing it is not possible to update a repeatable
        # attribute. Instead, it must be deleted and recreated.
        if ($a) {
            $a->delete();
            $a->attribute(0);
            Koha::Patron::Attribute->new( $a->unblessed )->store();
        }
    }
}

=head3 install

This is the 'install' method. Any database tables or other setup that should
be done when the plugin if first installed should be executed in this method.
The installation method should always return true if the installation succeeded
or false if it failed.

=cut

sub install() {
    my ( $self, $args ) = @_;

    $self->store_data(
        {
            run_on_dow        => "0",
            fees_threshold    => "25.00",
            processing_fee    => "10.00",
            fees_starting_age => "60",
            fees_ending_age   => "90",
        }
    );

    return 1;
}

=head3 upgrade

This is the 'upgrade' method. It will be triggered when a newer version of a
plugin is installed over an existing older version of a plugin

=cut

sub upgrade {
    my ( $self, $args ) = @_;

    return 1;
}

=head3 uninstall

This method will be run just before the plugin files are deleted
when a plugin is uninstalled. It is good practice to clean up
after ourselves!

=cut

sub uninstall() {
    my ( $self, $args ) = @_;

    return 1;
}

1;
