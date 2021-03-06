package Koha::Plugin::Com::ByWaterSolutions::UniqueCollections;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Auth;
use C4::Context;
use Koha::DateUtils qw(dt_from_string);
use Koha::Patron::Attribute::Types;
use Koha::Patron::Debarments;
use Koha::Patrons;

use File::Path qw( make_path );
use File::Slurp;
use Text::CSV::Slurp;
use Try::Tiny;

## Here we set our plugin version
our $VERSION         = "{VERSION}";
our $MINIMUM_VERSION = "{MINIMUM_VERSION}";
our $debug           = $ENV{UMS_COLLECTIONS_DEBUG} // 0;
our $no_email        = $ENV{UMS_COLLECTIONS_NO_EMAIL} // 0;
our $archive_dir     = $ENV{UMS_COLLECTIONS_ARCHIVES_DIR} // undef;

our $metadata = {
    name            => 'Unique Management Services - Gentle Nudge',
    author          => 'Kyle M Hall',
    date_authored   => '2021-09-27',
    date_updated    => "1900-01-01",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description =>
'Plugin to forward messages to Unique Collections for processing and sending',
};

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
            run_on_dow        => $self->retrieve_data('run_on_dow'),
            categorycodes     => $self->retrieve_data('categorycodes'),
            fees_threshold    => $self->retrieve_data('fees_threshold'),
            processing_fee    => $self->retrieve_data('processing_fee'),
            unique_email      => $self->retrieve_data('unique_email'),
            cc_email          => $self->retrieve_data('cc_email'),
            collections_flag  => $self->retrieve_data('collections_flag'),
            fees_starting_age => $self->retrieve_data('fees_starting_age') || 60,
            fees_ending_age   => $self->retrieve_data('fees_ending_age') || 90,
            auto_clear_paid   => $self->retrieve_data('auto_clear_paid'),
            add_restriction   => $self->retrieve_data('add_restriction'),
            attributes => scalar Koha::Patron::Attribute::Types->search(),
        );

        $self->output_html( $template->output() );
    }
    else {
        $self->store_data(
            {
                run_on_dow        => $cgi->param('run_on_dow'),
                categorycodes     => $cgi->param('categorycodes'),
                fees_threshold    => $cgi->param('fees_threshold'),
                processing_fee    => $cgi->param('processing_fee'),
                unique_email      => $cgi->param('unique_email'),
                cc_email          => $cgi->param('cc_email'),
                collections_flag  => $cgi->param('collections_flag'),
                fees_starting_age => $cgi->param('fees_starting_age'),
                fees_ending_age   => $cgi->param('fees_ending_age'),
                auto_clear_paid   => $cgi->param('auto_clear_paid'),
                add_restriction   => $cgi->param('add_restriction'),
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
                  : $f =~ /^ums-sync/          ? $thresholds->{sync}
                  : $f =~ /^ums-updates/       ? $thresholds->{updates}
                  :                              undef;

                next unless $threshold_filename;

                if ( $f lt $threshold_filename ) {
                    unlink( $archive_dir . "/" . $f );
                }
            }
        }
        else {
            make_path $archive_dir or die "Failed to create path: $archive_dir";
        }
    }


    my $run_weeklys;
    my $run_on_dow = $self->retrieve_data('run_on_dow');
    unless ( (localtime)[6] == $run_on_dow ) {
        say "Run on Day of Week $run_on_dow does not match current day of week "
          . (localtime)[6]
          if $debug >= 1;
    }
    else {
        $run_weeklys = 1;
    }

    my $params = { send_sync_report => $p->{send_sync_report} };

    my $unique_email = $self->retrieve_data('unique_email');
    my $cc_email     = $self->retrieve_data('cc_email');

    $params->{fees_threshold}    = $self->retrieve_data('fees_threshold');
    $params->{processing_fee}    = $self->retrieve_data('processing_fee');
    $params->{collections_flag}  = $self->retrieve_data('collections_flag');
    $params->{fees_starting_age} = $self->retrieve_data('fees_starting_age');
    $params->{fees_ending_age}   = $self->retrieve_data('fees_ending_age');
    $params->{auto_clear_paid}   = $self->retrieve_data('auto_clear_paid');
    $params->{add_restriction}   = $self->retrieve_data('add_restriction');

    # Starting age should be the large of the two numbers
    ( $params->{fees_starting_age}, $params->{fees_ending_age} ) =
      ( $params->{fees_ending_age}, $params->{fees_starting_age} )
      if $params->{fees_starting_age} < $params->{fees_ending_age};

    $params->{flag_type} =
         $params->{collections_flag} eq 'sort1'
      || $params->{collections_flag} eq 'sort2'
      ? 'borrower_field'
      : 'attribute_field';

    my @categorycodes = split( /,/, $self->retrieve_data('categorycodes') );
    $params->{categorycodes} = \@categorycodes;

    $params->{from} = C4::Context->preference('KohaAdminEmailAddress');
    $params->{to}   = $unique_email;
    $params->{cc}   = $cc_email if $cc_email;

    my $today = dt_from_string();
    $params->{date} = $today->ymd();

    ### Process new submissions
    if ( $run_weeklys && !$params->{send_sync_report} ) {
        $self->run_submissions_report($params);
    }
    elsif ( !$params->{send_sync_report} ) {
        say "NOT THE DOW TO RUN SUBMISSIONS\n\n" if $debug >= 1;
    }

    ### Process UMS Update Report
    $self->run_update_report_and_clear_paid($params);
}

sub run_submissions_report {
    my ( $self, $params ) = @_;

    my $dbh = C4::Context->dbh;
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
MAX(borrowers.city)               AS "city",
MAX(borrowers.zipcode)            AS "zipcode",
MAX(borrowers.state)              AS "state",
MAX(borrowers.phone)              AS "phone",
MAX(borrowers.mobile)             AS "mobile",
MAX(borrowers.phonepro)           AS "Alt Ph 1",
MAX(borrowers.b_phone)            AS "Alt Ph 2",
MAX(borrowers.branchcode),
MAX(categories.category_type)     AS "Adult or Child",
MAX(borrowers.dateofbirth),
MAX(accountlines.date)            AS "Most recent charge",
FORMAT(Sum(amountoutstanding), 2) AS Amt_In_Range,
MAX(sub.due)                      AS Total_Due,
MAX(sub.dueplus)                  AS Total_Plus_Fee,
MAX(borrowers.email)
FROM   accountlines
    };

    $ums_submission_query .= qq{
       LEFT JOIN borrower_attributes ON accountlines.borrowernumber = borrower_attributes.borrowernumber
           AND code = '$params->{collections_flag}'
        } if $params->{flag_type} eq 'attribute_field';

    $ums_submission_query .= qq{
            LEFT JOIN borrowers ON ( accountlines.borrowernumber = borrowers.borrowernumber )
                LEFT JOIN categories ON ( categories.categorycode = borrowers.categorycode )
                LEFT JOIN (SELECT FORMAT(Sum(accountlines.amountoutstanding), 2) AS Due,
                        FORMAT(Sum(accountlines.amountoutstanding) + $params->{processing_fee}, 2) AS DuePlus,
                        borrowernumber
                        FROM   accountlines
                        GROUP  BY borrowernumber) AS sub ON ( borrowers.borrowernumber = sub.borrowernumber)
                WHERE  1=1
                AND DATE(accountlines.date) >= DATE_SUB(CURDATE(), INTERVAL $params->{fees_starting_age} DAY)
                AND DATE(accountlines.date) <= DATE_SUB(CURDATE(), INTERVAL $params->{fees_ending_age} DAY)
        };

    $ums_submission_query .= qq{
            AND ( borrowers.$params->{collections_flag} = 'no' OR borrowers.$params->{collections_flag} IS NULL )
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

    $ums_submission_query .= qq{
            GROUP  BY borrowers.borrowernumber
                HAVING Sum(amountoutstanding) >= $params->{fees_threshold}
                ORDER  BY borrowers.surname ASC  
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
                    comment => "Patron sent to collections on $params->{date}",
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
            }
            else {
                Koha::Patron::Attribute->new(
                    {
                        borrowernumber => $patron->id,
                        code           => $params->{collections_flag},
                        attribute      => 1,
                    }
                )->store();
            }
        }

        $patron->account->add_debit(
            {
                amount      => $params->{processing_fee},
                description => "UMS Processing Fee",
                interface   => 'cron',
                type        => 'MANUAL',
            }
        );

        push( @ums_new_submissions, $r );
    }

    ## Email the results
    my $csv =
      @ums_new_submissions
      ? Text::CSV::Slurp->create( input => \@ums_new_submissions )
      : 'No qualifying records';
    say "CSV:\n" . $csv if $debug >= 2;

    write_file( "$archive_dir/ums-new-submissions-$params->{date}.csv", $csv )
      if $archive_dir;
    say
      "ARCHIVE WRITTEN TO $archive_dir/ums-new-submissions-$params->{date}.csv"
      if $archive_dir && $debug;

    my $email = Koha::Email->new(
        {
            to      => $params->{to},
            from    => $params->{from},
            subject => "UMS New Submissions for "
              . C4::Context->preference('LibraryName'),
        }
    );

    $email->attach(
        Encode::encode_utf8($csv),
        content_type => "text/csv",
        name         => "ums-new-submissions-$params->{date}.csv",
        disposition  => 'attachment',
    );

    my $smtp_server = Koha::SMTP::Servers->get_default;
    $email->transport( $smtp_server->transport );

    try {
        $email->send_or_die unless $no_email;
    }
    catch {
        warn "Mail not sent: $_";
    };
}

sub run_update_report_and_clear_paid {
    my ( $self, $params ) = @_;

    my $dbh = C4::Context->dbh;
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
        GROUP  BY borrowers.borrowernumber
            ORDER  BY borrowers.surname ASC  
    };

    say "UMS UPDATE QUERY:\n$ums_update_query"
      if ( !$params->{send_sync_report} ) && $debug >= 0;

    $sth = $dbh->prepare($ums_update_query);
    $sth->execute();
    my @ums_updates;
    while ( my $r = $sth->fetchrow_hashref ) {
        say "QUERY RESULT: " . Data::Dumper::Dumper($r) if $debug >= 1;
        push( @ums_updates, $r );

        $self->clear_patron_from_collections( $params, $r->{borrowernumber} )
          if $params->{auto_clear_paid} eq 'yes' && $r->{Due} eq "0.00";
    }

    ## Email the results
    my $type = $params->{send_sync_report} ? 'sync' : 'updates';

    my $csv =
      @ums_updates
      ? Text::CSV::Slurp->create( input => \@ums_updates )
      : 'No qualifying records';
    say "CSV:\n" . $csv if $debug >= 2;

    write_file( "$archive_dir/ums-$type-$params->{date}.csv", $csv )
      if $archive_dir;
    say "ARCHIVE WRITTEN TO $archive_dir/ums-$type-$params->{date}.csv"
      if $archive_dir && $debug;

    my $email = Koha::Email->new(
        {
            to      => $params->{to},
            from    => $params->{from},
            subject => sprintf( "UMS %s for %s",
                ucfirst($type), C4::Context->preference('LibraryName') ),
        }
    );

    $email->attach(
        Encode::encode_utf8($csv),
        content_type => "text/csv",
        name         => "ums-$type-$params->{date}.csv",
        disposition  => 'attachment',
    );

    my $smtp_server = Koha::SMTP::Servers->get_default;
    $email->transport( $smtp_server->transport );

    try {
        $email->send_or_die unless $no_email;
    }
    catch {
        warn "Mail not sent: $_";
    };
}

sub clear_patron_from_collections {
    my ( $self, $params, $borrowernumber ) = @_;

    say "CLEARING PATRON $borrowernumber FROM COLLECTIONS" if $debug >= 2;

    my $patron = Koha::Patrons->find($borrowernumber);
    next unless $patron;

    if ( $params->{flag_type} eq 'borrower_field' ) {
        $patron->update( { $params->{collections_flag} => 'no' } );
    }
    if ( $params->{flag_type} eq 'attribute_field' ) {
        my $a = Koha::Patron::Attributes->find(
            {
                borrowernumber => $patron->id,
                code           => $params->{collections_flag},
            }
        );

        $a->attribute(0)->store() if $a;
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
