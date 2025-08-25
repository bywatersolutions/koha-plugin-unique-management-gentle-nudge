use strict;
use warnings;



=head1 TABLE: C<koha_plugin_com_bywatersolutions_uniquegentlenudge_config>

=cut

__PACKAGE__->table("koha_plugin_com_bywatersolutions_uniquegentlenudge_config");

=head1 ACCESSORS

=head2 library_group

  data_type:
  size: 191
  is_nullable: 1

=head2 day_of_week

  data_type: varchar
  size: 191
  is_nullable:

=head2 patron_categories

  data_type: varchar
  size: 91
  is_nullable: 1

=head2 threshold

  data_type:
  default_value: 0
  is_nullable: 0

=head2 processing_fee

  data_type:
  default_value: 0
  is_nullable: 0

=head2 collections_flag

  data_type: varchar
  default_value: 0
  is_nullable: 0

=head2 fees_newer

  data_type: integer
  default_value: 0
  is_nullable: 0

=head2 fees_older

  data_type: integer
  default_value: 0
  is_nullable: 0

=head2 ignore_before

  data_type: 'date'
  default_value: null
  is_nullable: 1

=head2 clear_below

  data_type: 'tinyint'
  default_value: 0
  is_nullable: 0

=head2 restriction

  data_type: 'tinyint'
  default_value: 0
  is_nullable: 0

=head2 remove_minors

  data_type: 'tinyint'
  default_value: 0
  is_nullable: 0

=head2 unique_email

  data_type: 
  default_value: 0
  is_nullable: 0

=head2 additional_email

  data_type: 
  default_value: 0
  is_nullable: 1

=head2 sftp_host

  data_type: 
  default_value: 0
  is_nullable: 1

=head2 sftp_user

  data_type: 
  default_value: 0
  is_nullable: 1

=head2 sftp_pass

  data_type: 
  default_value: 0
  is_nullable: 1
=cut

__PACKAGE__->add_columns(
  "library_group",
  { data_type => "varchar", is_nullable => 0, size => 191 },
  "day_of_week",
  { data_type => "varchar", is_nullable => 0, size => 191 },
  "patron_categories",
  { data_type => "varchar", is_nullable => 0, size => 191 },
  "threshold",
  { data_type => "integer", is_nullable => 0 },
  "processing_fee",
  { data_type => "integer", is_nullable => 0 },
  "collections_flag",
  { data_type => "varchar", is_nullable => 0, size => 191 },
  "fees_newer",
  { data_type => "integer", is_nullable => 1 },
  "fees_older",
  { data_type => "integer", is_nullable => 1 },
  "ignore_before",
  { data_type => "date", is_nullable => 0 },
  "clear_below",
  { data_type => "tinyint", default_value => 0, is_nullable => 0 },
  "restriction",
  { data_type => "tinyint", default_value => 0, is_nullable => 0 },
  "remove_minors",
  { data_type => "tinyint", default_value => 0, is_nullable => 0 },
  "unique_email",
  { data_type => "varchar", is_nullable => 1, size => 191 },
  "additional_email",
  { data_type => "varchar", is_nullable => 1, size => 191 },
  "sftp_host",
  { data_type => "varchar", is_nullable => 1, size => 191 },
  "sftp_user",
  { data_type => "varchar", is_nullable => 1, size => 191 },
  "sftp_password",
  { data_type => "varchar", is_nullable => 1, size => 191 },
);

=head1 PRIMARY KEY

=over

=item * L</library_group>

=back

=cut

__PACKAGE__->set_primary_key("library_group"):