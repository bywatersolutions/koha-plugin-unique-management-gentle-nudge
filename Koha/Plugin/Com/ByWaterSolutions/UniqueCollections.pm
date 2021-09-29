## Please see file perltidy.ERR
package Koha::Plugin::Com::ByWaterSolutions::UniqueCollections;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Auth;
use C4::Context;
use Koha::Patrons;

use Carp;
use Text::CSV::Slurp;

## Here we set our plugin version
our $VERSION         = "{VERSION}";
our $MINIMUM_VERSION = "{MINIMUM_VERSION}";

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
            run_on_dow     => $self->retrieve_data('run_on_dow'),
            categorycodes  => $self->retrieve_data('categorycodes'),
            fees_threshold => $self->retrieve_data('fees_threshold'),
            processing_fee => $self->retrieve_data('processing_fee'),
            unique_email   => $self->retrieve_data('unique_email'),
            cc_email       => $self->retrieve_data('cc_email'),
        );

        $self->output_html( $template->output() );
    }
    else {
        $self->store_data(
            {
                run_on_dow     => $cgi->param('run_on_dow'),
                categorycodes  => $cgi->param('categorycodes'),
                fees_threshold => $cgi->param('fees_threshold'),
                processing_fee => $cgi->param('processing_fee'),
                unique_email   => $cgi->param('unique_email'),
                cc_email       => $cgi->param('cc_email'),
            }
        );
        $self->go_home();
    }
}

=head3 cronjob_nightly

=cut

sub cronjob_nightly {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $sth;

    my $fees_threshold = $self->retrieve_data('fees_threshold');
    my $processing_fee = $self->retrieve_data('processing_fee');
    my $unique_email   = $self->retrieve_data('unique_email');
    my $cc_email       = $self->retrieve_data('cc_email');

    my $run_on_dow = $self->retrieve_data('run_on_dow');
    return unless (localtime)[6] == $run_on_dow;

    my @categorycodes = split( /,/, $self->retrieve_data('categorycodes') );

    my $from = C4::Context->preference('KohaAdminEmailAddress');
    my $to   = $cc_email ? "$unique_email,$cc_email" : $unique_email;

    my $today = dt_from_string();
    my $date = $today->ymd();

    ### Process new submissions
    my $ums_submission_query = q{
 SELECT
Concat
('<a href=\"/cgi-bin/koha/members/maninvoice.pl?borrowernumber=',
       borrowers.borrowernumber, '\" target="_blank">', borrowers.cardnumber, '</a>') AS "Link to Fines",
borrowers.borrowernumber,
borrowers.surname,
borrowers.firstname,
borrowers.address,
borrowers.city,
borrowers.zipcode,
borrowers.phone,
borrowers.mobile,
borrowers.phonepro                               AS "Alt Ph 1",
borrowers.b_phone                                AS "Alt Ph 2",
borrowers.branchcode,
categories.category_type                         AS "Adult or Child",
borrowers.dateofbirth,
Max(accountlines.date)                           AS "Most recent charge",
Format(Sum(amountoutstanding), 2)                AS Amt_In_Range,
sub.due                                          AS Total_Due,
sub.dueplus                                      AS Total_Plus_Fee
FROM   accountlines
       LEFT JOIN borrowers USING(borrowernumber)
       LEFT JOIN categories USING(categorycode)
       LEFT JOIN (SELECT Format(Sum(accountlines.amountoutstanding), 2)      AS
                         Due,
                         Format(Sum(accountlines.amountoutstanding) + 10, 2) AS
                         DuePlus
                                                                  ,
       borrowernumber
       FROM   accountlines
       GROUP  BY borrowernumber) AS sub USING(borrowernumber)
WHERE  borrowers.sort1 != 'yes'
       AND accountlines.date > Date_sub(Curdate(), INTERVAL 90 day)
       AND accountlines.date < Date_sub(Curdate(), INTERVAL 45 day)
};

    if (@categorycodes) {
        my $codes = join( ',', map { qq{"$_"} } @categorycodes );
        $ums_submission_query .= qq{ AND borrowers.categorycode IN ( $codes ) };
    }

    $ums_submission_query .= qq{
GROUP  BY borrowers.borrowernumber
HAVING Sum(amountoutstanding) >= $fees_threshold
ORDER  BY borrowers.surname ASC  
    };

    ### Update new submissions patrons, add fee, mark as being in collections
    $sth = $dbh->prepare($ums_submission_query);
    $sth->execute();
    my @ums_new_submissions;
    while ( my $r = $sth->fetchrow_hashref ) {
        my $patron = Koha::Patrons->find( $r->{borrowernumber} );
        next unless $patron;

        $patron->sort1('yes')->update()
          ;    # Could be turned into one query if too slow
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
    my $csv = Text::CSV::Slurp->create( input => \@ums_new_submissions );

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
        $email->send_or_die;
    }
    catch {
        carp "Mail not sent: $_";
    };

    ### Process UMS Update Report
    my $ums_update_query = q{
SELECT borrowers.borrowernumber,
       borrowers.surname,
       borrowers.firstname,
       Format(Sum(accountlines.amountoutstanding), 2) AS Due
FROM   accountlines
       LEFT JOIN borrowers USING(borrowernumber)
       LEFT JOIN categories USING(categorycode)
WHERE  borrowers.sort1 = 'yes'
GROUP  BY borrowers.borrowernumber
ORDER  BY borrowers.surname ASC  
    };

    $sth = $dbh->prepare($ums_update_query);
    $sth->execute();
    my @ums_updates;
    while ( my $r = $sth->fetchrow_hashref ) {
        push( @ums_updates, $r );
    }

    ## Email the results
    $csv = Text::CSV::Slurp->create( input => \@ums_updates );

    $email = Koha::Email->new(
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

    $email->transport( $smtp_server->transport );

    try {
        $email->send_or_die;
    }
    catch {
        carp "Mail not sent: $_";
    };

    ### Clear the "in collections" flag for patrons that are now paid off
    my $ums_cleared_patrons_query = q{
SELECT borrowers.borrowernumber,
       Format(Sum(accountlines.amountoutstanding), 2) AS Due
FROM   accountlines
       LEFT JOIN borrowers USING(borrowernumber)
WHERE  borrowers.sort1 = 'yes'
GROUP  BY borrowers.borrowernumber
HAVING due = 0.00  
    };
    
    $sth = $dbh->prepare($ums_cleared_patrons_query);
    $sth->execute();
    while ( my $r = $sth->fetchrow_hashref ) {
        my $patron = Koha::Patrons->find( $r->{borrowernumber} );
        next unless $patron;

        $patron->sort1('no')->update();
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
            run_on_dow     => "0",
            fees_threshold => "25.00",
            processing_fee => "10.00",
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
