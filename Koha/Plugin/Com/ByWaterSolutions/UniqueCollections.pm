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
use Koha::Patrons;

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
    name            => 'Unique Management Services - Collections',
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

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            run_on_dow        => $self->retrieve_data('run_on_dow'),
            categorycodes     => $self->retrieve_data('categorycodes'),
            fees_threshold    => $self->retrieve_data('fees_threshold'),
            processing_fee    => $self->retrieve_data('processing_fee'),
            unique_email      => $self->retrieve_data('unique_email'),
            cc_email          => $self->retrieve_data('cc_email'),
            collections_flag  => $self->retrieve_data('collections_flag'),
            fees_starting_age => $self->retrieve_data('fees_starting_age'),
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
            }
        );
        $self->go_home();
    }
}

=head3 cronjob_nightly

=cut

sub cronjob_nightly {
    my ($self) = @_;

    my $run_on_dow = $self->retrieve_data('run_on_dow');
    unless ( (localtime)[6] == $run_on_dow ) {
        say "Run on Day of Week $run_on_dow does not match current day of week "
          . (localtime)[6]
          if $debug >= 1;
        return;
    }

    my $dbh = C4::Context->dbh;
    my $sth;

    my $fees_threshold    = $self->retrieve_data('fees_threshold');
    my $processing_fee    = $self->retrieve_data('processing_fee');
    my $unique_email      = $self->retrieve_data('unique_email');
    my $cc_email          = $self->retrieve_data('cc_email');
    my $collections_flag  = $self->retrieve_data('collections_flag');
    my $fees_starting_age = $self->retrieve_data('fees_starting_age');

    my $flag_type =
      $collections_flag eq 'sort1' ? 'borrower_field' : 'attribute_field';

    my @categorycodes = split( /,/, $self->retrieve_data('categorycodes') );

    my $from = C4::Context->preference('KohaAdminEmailAddress');
    my $to   = $cc_email ? "$unique_email,$cc_email" : $unique_email;

    my $today = dt_from_string();
    my $date  = $today->ymd();

    ### Process new submissions
    my $ums_submission_query = q{
SELECT
    };

    $ums_submission_query .= q{
MAX(attribute),
    } if $flag_type eq 'attribute_field';

    $ums_submission_query .= q{
CONCAT ('<a href=\"/cgi-bin/koha/members/maninvoice.pl?borrowernumber=', borrowers.borrowernumber, '\" target="_blank">', MAX(borrowers.cardnumber), '</a>') AS "Link to Fines",
MAX(borrowers.borrowernumber)     AS "borrowernumber",
MAX(borrowers.surname)            AS "surname",
MAX(borrowers.firstname)          AS "firstname",
MAX(borrowers.address)            AS "address",
MAX(borrowers.city)               AS "city",
MAX(borrowers.zipcode)            AS "zipcode",
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
MAX(sub.dueplus)                  AS Total_Plus_Fee
FROM   accountlines
    };

    $ums_submission_query .= qq{
       LEFT JOIN borrower_attributes ON accountlines.borrowernumber = borrower_attributes.borrowernumber
                                    AND code = '$collections_flag'
    } if $flag_type eq 'attribute_field';

    $ums_submission_query .= qq{
       LEFT JOIN borrowers ON ( accountlines.borrowernumber = borrowers.borrowernumber )
       LEFT JOIN categories ON ( categories.categorycode = borrowers.categorycode )
       LEFT JOIN (SELECT FORMAT(Sum(accountlines.amountoutstanding), 2) AS Due,
                         FORMAT(Sum(accountlines.amountoutstanding) + $processing_fee, 2) AS DuePlus,
                         borrowernumber
                  FROM   accountlines
                  GROUP  BY borrowernumber) AS sub ON ( borrowers.borrowernumber = sub.borrowernumber)
WHERE  1=1
       AND DATE(accountlines.date) >= DATE_SUB(CURDATE(), INTERVAL 90 DAY)
       AND DATE(accountlines.date) <= DATE_SUB(CURDATE(), INTERVAL $fees_starting_age DAY)
    };

    $ums_submission_query .= q{
       AND borrowers.sort1 != 'yes'
    } if $flag_type eq 'borrower_field';

    $ums_submission_query .= q{
       AND ( attribute = '0' OR attribute IS NULL )
    } if $flag_type eq 'attribute_field';

    if (@categorycodes) {
        my $codes = join( ',', map { qq{"$_"} } @categorycodes );
        $ums_submission_query .= qq{
       AND borrowers.categorycode IN ( $codes )
        };
    }

    $ums_submission_query .= qq{
GROUP  BY borrowers.borrowernumber
HAVING Sum(amountoutstanding) >= $fees_threshold
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

        if ( $flag_type eq 'borrower_field' ) {
            $patron->sort1('yes')->update();
        }
        if ( $flag_type eq 'attribute_field' ) {
            my $a = Koha::Patron::Attributes->find(
                {
                    borrowernumber => $patron->id,
                    code           => $collections_flag,
                }
            );

            if ($a) {
                $a->attribute(1)->store();
            }
            else {
                Koha::Patron::Attribute->new(
                    {
                        borrowernumber => $patron->id,
                        code           => $collections_flag,
                        attribute      => 1,
                    }
                )->store();
            }
        }

        $patron->account->add_debit(
            {
                amount      => $processing_fee,
                description => "UMS Processing Fee",
                interface   => 'cron',
                type        => 'PROCESSING',
            }
        );

        push( @ums_new_submissions, $r );
    }

    ## Email the results
    if (@ums_new_submissions) {
        my $csv = Text::CSV::Slurp->create( input => \@ums_new_submissions );
        say "CSV:\n" . $csv if $debug >= 2;

        write_file("$archive_dir/ums-new-submissions-$date.csv") if $archive_dir;

        my $email = Koha::Email->new(
            {
                to      => $to,
                from    => $from,
                subject => "UMS New Submissions for "
                  . C4::Context->preference('LibraryName'),
            }
        );

        $email->attach(
            Encode::encode_utf8($csv),
            content_type => "text/csv",
            name         => "ums-new-submissions-$date.csv",
            disposition  => 'attachment',
        );

        my $smtp_server = Koha::SMTP::Servers->get_default;
        $email->transport( $smtp_server->transport );

        try {
            $email->send_or_die unless $no_email;;
        }
        catch {
            warn "Mail not sent: $_";
        };
    }
    else {
        say "NO NEW SUBMISSIONS TO SUBMIT\n\n" if $debug >= 1;
    }

    ### Process UMS Update Report
    my $ums_update_query = q{
SELECT borrowers.borrowernumber,
       MAX(borrowers.surname)                         AS "surname",
       MAX(borrowers.firstname)                       AS "firstname",
       FORMAT(Sum(accountlines.amountoutstanding), 2) AS "Due"
FROM   accountlines
       LEFT JOIN borrowers USING(borrowernumber)
       LEFT JOIN categories USING(categorycode)
    };

    $ums_update_query .= qq{
       LEFT JOIN borrower_attributes ON accountlines.borrowernumber = borrower_attributes.borrowernumber
                                    AND code = '$collections_flag'
    } if $flag_type eq 'attribute_field';

    $ums_update_query .= q{
WHERE  1=1 
    };

    $ums_update_query .= qq{
       AND attribute = '1'
    } if $flag_type eq 'attribute_field';

    $ums_update_query .= q{
       AND borrowers.sort1 = 'yes'
    } if $flag_type eq 'borrower_field';

    $ums_update_query .= q{
GROUP  BY borrowers.borrowernumber
ORDER  BY borrowers.surname ASC  
    };

    say "UMS UPDATE QUERY:\n$ums_update_query" if $debug >= 0;

    $sth = $dbh->prepare($ums_update_query);
    $sth->execute();
    my @ums_updates;
    while ( my $r = $sth->fetchrow_hashref ) {
        say "QUERY RESULT: " . Data::Dumper::Dumper($r) if $debug >= 1;
        push( @ums_updates, $r );
    }

    if (@ums_updates) {
        ## Email the results
        my $csv = Text::CSV::Slurp->create( input => \@ums_updates );
        say "CSV:\n" . $csv if $debug >= 2;

        write_file("$archive_dir/ums-updates-$date.csv") if $archive_dir;

        my $email = Koha::Email->new(
            {
                to      => $to,
                from    => $from,
                subject => "UMS Update Report for "
                  . C4::Context->preference('LibraryName'),
            }
        );

        $email->attach(
            Encode::encode_utf8($csv),
            content_type => "text/csv",
            name         => "ums-updates-$date.csv",
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
    else {
        say "NO UPDATES TO SUBMIT\n\n" if $debug >= 1;
    }


    ### Clear the "in collections" flag for patrons that are now paid off
    my $ums_cleared_patrons_query = q{
SELECT borrowers.borrowernumber,
       FORMAT(Sum(accountlines.amountoutstanding), 2) AS Due
FROM   accountlines
       LEFT JOIN borrowers USING(borrowernumber)
    };

    $ums_update_query .= qq{
       LEFT JOIN borrower_attributes ON accountlines.borrowernumber = borrower_attributes.borrowernumber
                                    AND code = '$collections_flag'
    } if $flag_type eq 'attribute_field';

    $ums_cleared_patrons_query = q{
WHERE  1=1
    };

    $ums_update_query .= q{
       AND borrowers.sort1 = 'yes'
    } if $flag_type eq 'borrower_field';

    $ums_update_query .= qq{
       AND attribute = '1'
    } if $flag_type eq 'attribute_field';

    $ums_update_query .= q{
GROUP  BY borrowers.borrowernumber
HAVING due = 0.00  
    };

    say "UMS CLEARED PATRONS QUERY:\n$ums_update_query" if $debug >= 0;

    $sth = $dbh->prepare($ums_cleared_patrons_query);
    $sth->execute();
    while ( my $r = $sth->fetchrow_hashref ) {
        say "QUERY RESULT: " . Data::Dumper::Dumper($r) if $debug >= 1;

        my $patron = Koha::Patrons->find( $r->{borrowernumber} );
        next unless $patron;

        if ( $flag_type eq 'borrower_field' ) {
            $patron->sort1('no')->update();
        }
        if ( $flag_type eq 'attribute_field' ) {
            my $a = Koha::Patron::Attributes->find(
                {
                    borrowernumber => $patron->id,
                    code           => $collections_flag,
                }
            );

            $a->attribute(0)->store() if $a;
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
            fees_starting_age => "45",
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
