package FixMyStreet::App::Controller::Report::New;

use Moose;
use namespace::autoclean;
BEGIN { extends 'Catalyst::Controller'; }

use FixMyStreet::Geocode;
use Encode;
use Sort::Key qw(keysort);
use List::MoreUtils qw(uniq);
use HTML::Entities;
use mySociety::MaPit;
use Path::Class;
use Utils;
use mySociety::EmailUtil;

=head1 NAME

FixMyStreet::App::Controller::Report::New

=head1 DESCRIPTION

Create a new report, or complete a partial one .

=head1 PARAMETERS

=head2 flow control

submit_map: true if we reached this page by clicking on the map

submit_problem: true if a problem has been submitted

=head2 location (required)

We require a location - either lat/lng or a tile click.

longitude, latitude: location of the report - either determined from the
address/postcode or from a map click.

x, y, tile_xxx.yyy.x, tile_xxx.yyy.y: x and y are the tile locations. The
'tile_xxx.yyy' pair are the click locations on the tile. These can be converted
back into lat/lng by the map code.

=head2 image related

Parameters are 'photo' or 'upload_fileid'. The 'photo' is used when a user has selected a file. Once it has been uploaded it is cached on disk so that if there are errors on the form it need not be uploaded again. The cache location is stored in 'upload_fileid'. 

=head2 optional

pc: location user searched for

skipped: true if the map was skipped - may mean that the location is not as
accurate as we'd like. Default is false.

upload_fileid: set if there is an uploaded file (might not be needed if we use the Catalyst upload handlers)

may_show_name: bool - false if the user wants this report to be anonymous.

title

detail

name

email

phone

partial

=head2 can be ignored

all_pins: related to map display - not relevant to creation of a new report

=cut

sub report_new : Path : Args(0) {
    my ( $self, $c ) = @_;

    # set up the page
    $c->forward('setup_page');

    # create the report - loading a partial if available
    $c->forward('initialize_report');

    # work out the location for this report and do some checks
    return
      unless $c->forward('determine_location')
          && $c->forward('load_councils');

    # create a problem from the submitted details
    $c->stash->{template} = "report/new/fill_in_details.html";
    $c->forward('setup_categories_and_councils');
    $c->forward('generate_map');

    # deal with the user and report and check both are happy
    return
      unless $c->forward('process_user')
          && $c->forward('process_report')
          && $c->forward('process_photo')
          && $c->forward('check_form_submitted')
          && $c->forward('check_for_errors')
          && $c->forward('save_user_and_report')
          && $c->forward('redirect_or_confirm_creation');
}

=head2 report_import

Action to accept report creations from iPhones and other mobile apps. URL is
'/import' to be compatible with existing apps.

=cut

sub report_import : Path('/import') {
    my ( $self, $c ) = @_;

    # If this is not a POST then just print out instructions for using page
    return unless $c->req->method eq 'POST';

    # anything else we return is plain text
    $c->res->content_type('text/plain; charset=utf-8');

    # use strict;
    # use Standard;
    # use mySociety::AuthToken;
    # use mySociety::Config;
    # use mySociety::EvEl;
    # use mySociety::Locale;

    my %input =
      map { $_ => $c->req->param($_) || '' } (
        'service', 'subject',  'detail', 'name', 'email', 'phone',
        'easting', 'northing', 'lat',    'lon',  'id',    'phone_id',
      );

    my @errors;

    # Get our location
    my $latitude  = $input{lat} ||= 0;
    my $longitude = $input{lon} ||= 0;
    if (
        !( $latitude || $longitude )    # have not been given lat or lon
        && ( $input{easting} && $input{northing} )    # but do have e and n
      )
    {
        ( $latitude, $longitude ) =
          Utils::convert_en_to_latlon( $input{easting}, $input{northing} );
    }

    # handle the photo upload
    $c->forward( 'process_photo_upload', [ { rotate_photo => 1 } ] );
    my $photo = $c->stash->{upload_fileid};
    if ( my $error = $c->stash->{photo_error} ) {
        push @errors, $error;
    }

    push @errors, 'You must supply a service' unless $input{service};
    push @errors, 'Please enter a subject'    unless $input{subject} =~ /\S/;
    push @errors, 'Please enter your name'    unless $input{name} =~ /\S/;

    if ( $input{email} !~ /\S/ ) {
        push @errors, 'Please enter your email';
    }
    elsif ( !mySociety::EmailUtil::is_valid_email( $input{email} ) ) {
        push @errors, 'Please enter a valid email';
    }

    if ( $latitude && $c->config->{COUNTRY} eq 'GB' ) {
        eval { Utils::convert_latlon_to_en( $latitude, $longitude ); };
        push @errors,
          "We had a problem with the supplied co-ordinates - outside the UK?"
          if $@;
    }

    unless ( $photo || ( $latitude || $longitude ) ) {
        push @errors, 'Either a location or a photo must be provided.';
    }

    # if we have errors then we should bail out
    if (@errors) {
        my $body = join '', map { "ERROR:$_\n" } @errors;
        $c->res->body($body);
        return;
    }

### leaving commented out for now as the values stored here never appear to
### get used and the new user accounts might make them redundant anyway.
    #
    # # Store for possible future use
    # if ( $input{id} || $input{phone_id} ) {
    #     my $id = $input{id} || $input{phone_id};
    #     my $already =
    #       dbh()
    #       ->selectrow_array(
    #         'select id from partial_user where service=? and nsid=?',
    #         {}, $input{service}, $id );
    #     unless ($already) {
    #         dbh()->do(
    #             'insert into partial_user (service, nsid, name, email, phone)'
    #               . ' values (?, ?, ?, ?, ?)',
    #             {},
    #             $input{service},
    #             $id,
    #             $input{name},
    #             $input{email},
    #             $input{phone}
    #         );
    #     }
    # }

    # find or create the user
    my $report_user = $c->model('DB::User')->find_or_create(
        {
            email => $input{email},
            name  => $input{name},
            phone => $input{phone}
        }
    );

    # create a new report (don't save it yet)
    my $report = $c->model('DB::Problem')->new(
        {
            user      => $report_user,
            postcode  => '',
            latitude  => $latitude,
            longitude => $longitude,
            title     => $input{subject},
            detail    => $input{detail},
            name      => $input{name},
            service   => $input{service},
            state     => 'partial',
            used_map  => 1,
            anonymous => 0,
            category  => '',
            areas     => '',

        }
    );

    # If there was a photo add that too
    if ( my $fileid = $c->stash->{upload_fileid} ) {
        my $file = file( $c->config->{UPLOAD_CACHE}, "$fileid.jpg" );
        my $blob = $file->slurp;
        $file->remove;
        $report->photo($blob);
    }

    # save the report;
    $report->insert();

    my $token =
      $c->model("DB::Token")
      ->create( { scope => 'partial', data => $report->id } );

    $c->stash->{report} = $report;
    $c->stash->{token_url} = $c->uri_for( '/L', $token->token );

    my $sender = mySociety::Config::get('CONTACT_EMAIL');
    $sender =~ s/team/fms-DO-NOT-REPLY/;

    # TODO - used to be sent using EvEl
    $c->send_email(
        'partial.txt',
        {
            to   => $report->user->email,
            from => $sender
        }
    );

    $c->res->body('SUCCESS');
    return 1;
}

=head2 setup_page

Setup the page - notably add the map js to the stash

=cut

sub setup_page : Private {
    my ( $self, $c ) = @_;

    $c->stash->{extra_js_verbatim} = FixMyStreet::Map::header_js();

    return 1;
}

=head2 initialize_report

Create the report and set up some basics in it. If there is a partial report
requested then use that .

Partial reports are created when people submit to us via mobile apps or by
specially tagging photos on Flickr. They are in the database but are not
completed yet. Users reach us by following a link we email them that contains a
token link. This action looks for the token and if found retrieves the report in it.

=cut

sub initialize_report : Private {
    my ( $self, $c ) = @_;

    # check to see if there is a partial report that we should use, otherwise
    # create a new one. Stick it on the stash.
    my $report = undef;

    if ( my $partial = scalar $c->req->param('partial') ) {

        for (1) {    # use as pseudo flow control

            # did we find a token
            last unless $partial;

            # is it in the database
            my $token =
              $c->model("DB::Token")
              ->find( { scope => 'partial', token => $partial } )    #
              || last;

            # can we get an id from it?
            my $id = $token->data                                    #
              || last;

            # load the related problem
            $report = $c->model("DB::Problem")                       #
              ->search( { id => $id, state => 'partial' } )          #
              ->first;

            if ($report) {

                # log the problem creation user in to the site
                $c->authenticate( { email => $report->user->email },
                    'no_password' );

                # save the token to delete at the end
                $c->stash->{partial_token} = $token if $report;

            }
            else {

                # no point keeping it if it is done.
                $token->delete;
            }
        }
    }
    else {

        # If we didn't find a partial then create a new one
        $report = $c->model('DB::Problem')->new( {} );

        # If we have a user logged in let's prefill some values for them.
        if ( $c->user ) {
            my $user = $c->user->obj;
            $report->user($user);
            $report->name( $user->name );
        }

    }

    $c->stash->{report} = $report;

    return 1;
}

=head2 determine_location

Work out what the location of the report should be - either by using lat,lng or
a tile click or a user search query C<pc>. Returns false if no location could be
found.

=cut 

sub determine_location : Private {
    my ( $self, $c ) = @_;

    return
      unless $c->forward('determine_location_from_tile_click')
          || $c->forward('determine_location_from_coords')
          || $c->forward('determine_location_from_pc')
          || $c->forward('determine_location_from_report');

    # These should be set now
    my $lat = $c->stash->{latitude};
    my $lon = $c->stash->{longitude};

    # Check this location is okay to be displayed for the cobrand
    my ( $success, $error_msg ) = $c->cobrand->council_check(    #
        { lat => $lat, lon => $lon },
        'submit_problem'
    );

    # If in UK and we have a lat,lon coocdinate check it is in UK
    if ( !$error_msg && $lat && $c->config->{COUNTRY} eq 'GB' ) {
        eval { Utils::convert_latlon_to_en( $lat, $lon ); };
        $error_msg =
          _( "We had a problem with the supplied co-ordinates - outside the UK?"
          ) if $@;
    }

    # all good
    return 1 if !$error_msg;

    # show error
    $c->stash->{pc_error} = $error_msg;
    return;
}

=head2 determine_location_from_tile_click

Detect that the map tiles have been clicked on by looking for the tile
parameters.

=cut 

sub determine_location_from_tile_click : Private {
    my ( $self, $c ) = @_;

    # example: 'tile_1673.1451.x'
    my $param_key_regex = '^tile_(\d+)\.(\d+)\.[xy]$';

    my @matching_param_keys =
      grep { m/$param_key_regex/ } keys %{ $c->req->params };

    # did we find any matches
    return unless scalar(@matching_param_keys) == 2;

    # get the x and y keys
    my ( $x_key, $y_key ) = sort @matching_param_keys;

    # Extract the data needed
    my ( $pin_tile_x, $pin_tile_y ) = $x_key =~ m{$param_key_regex};
    my $pin_x = $c->req->param($x_key);
    my $pin_y = $c->req->param($y_key);

    # return if they are both 0 - this happens when you submit the form by
    # hitting enter and not using the button. It also happens if you click
    # exactly there on the map but that is less likely than hitting return to
    # submit. Lesser of two evils...
    return unless $pin_x && $pin_y;

    # convert the click to lat and lng
    my ( $latitude, $longitude ) = FixMyStreet::Map::click_to_wgs84(    #
        $c->req,                                                        #
        $pin_tile_x, $pin_x, $pin_tile_y, $pin_y
    );

    # store it on the stash
    $c->stash->{latitude}  = $latitude;
    $c->stash->{longitude} = $longitude;

    # set a flag so that the form is not considered submitted. This will prevent
    # errors showing on the fields.
    $c->stash->{force_form_not_submitted} = 1;

    # return true as we found a location
    return 1;
}

=head2 determine_location_from_coords

Use latitude and longitude if provided in parameters.

=cut 

sub determine_location_from_coords : Private {
    my ( $self, $c ) = @_;

    my $latitude  = $c->req->param('latitude');
    my $longitude = $c->req->param('longitude');

    if ( defined $latitude && defined $longitude ) {
        $c->stash->{latitude}  = $latitude;
        $c->stash->{longitude} = $longitude;

        # Also save the pc if there is one
        if ( my $pc = $c->req->param('pc') ) {
            $c->stash->{pc} = $pc;
        }

        return 1;
    }

    return;
}

=head2 determine_location_from_pc

User has searched for a location - try to find it for them.

If one match is found returns true and lat/lng is set.

If several possible matches are found puts an array onto stash so that user can be prompted to pick one and returns false.

If no matches are found returns false.

=cut 

sub determine_location_from_pc : Private {
    my ( $self, $c ) = @_;

    # check for something to search
    my $pc = $c->req->param('pc') || return;
    $c->stash->{pc} = $pc;    # for template

    my ( $latitude, $longitude, $error ) =
      eval { FixMyStreet::Geocode::lookup( $pc, $c->req ) };

    # Check that nothing blew up
    if ($@) {
        warn "Error: $@";
        return;
    }

    # If we got a lat/lng set to stash and return true
    if ( defined $latitude && defined $longitude ) {
        $c->stash->{latitude}  = $latitude;
        $c->stash->{longitude} = $longitude;
        return 1;
    }

    # $error doubles up to return multiple choices by being an array
    if ( ref($error) eq 'ARRAY' ) {
        @$error = map { decode_utf8($_) } @$error;
        $c->stash->{possible_location_matches} = $error;
        return;
    }

    # pass errors back to the template
    $c->stash->{pc_error} = $error;
    return;
}

=head2 determine_location_from_report

Use latitude and longitude stored in the report - this is probably result of a
partial report being loaded.

=cut 

sub determine_location_from_report : Private {
    my ( $self, $c ) = @_;

    my $report = $c->stash->{report};

    if ( defined $report->latitude && defined $report->longitude ) {
        $c->stash->{latitude}  = $report->latitude;
        $c->stash->{longitude} = $report->longitude;
        return 1;
    }

    return;
}

=head2 load_councils

Try to load councils for this location and check that we have at least one. If
there are no councils then return false.

=cut

sub load_councils : Private {
    my ( $self, $c ) = @_;
    my $latitude  = $c->stash->{latitude};
    my $longitude = $c->stash->{longitude};

    # Look up councils and do checks for the point we've got
    my @area_types = $c->cobrand->area_types();

    # TODO: I think we want in_gb_locale around the next line, needs testing
    my $all_councils =
      mySociety::MaPit::call( 'point', "4326/$longitude,$latitude",
        type => \@area_types );

    # Let cobrand do a check
    my ( $success, $error_msg ) =
      $c->cobrand->council_check( { all_councils => $all_councils },
        'submit_problem' );
    if ( !$success ) {
        $c->stash->{location_error} = $error_msg;
        return;
    }

    # If we don't have any councils we can't accept the report
    if ( !scalar keys %$all_councils ) {
        $c->stash->{location_error} =
          _(    'That spot does not appear to be covered by a council. If you'
              . ' have tried to report an issue past the shoreline, for'
              . ' example, please specify the closest point on land.' );
        return;
    }

    # edit hash in-place
    _remove_redundant_councils($all_councils);

    # all good if we have some councils left
    $c->stash->{all_councils} = $all_councils;
    $c->stash->{all_council_names} =
      [ map { $_->{name} } values %$all_councils ];
    return 1;
}

# TODO - should not be here.
# These are country specific tweaks that should be in the cobrands
sub _remove_redundant_councils {
    my $all_councils = shift;

    # UK specific tweaks
    if ( FixMyStreet->config('COUNTRY') eq 'GB' ) {

        # Ipswich & St Edmundsbury are responsible for everything in their
        # areas, not Suffolk
        delete $all_councils->{2241}
          if $all_councils->{2446}    #
              || $all_councils->{2443};

        # Norwich is responsible for everything in its areas, not Norfolk
        delete $all_councils->{2233}    #
          if $all_councils->{2391};
    }

    # Norway specific tweaks
    if ( FixMyStreet->config('COUNTRY') eq 'NO' ) {

        # Oslo is both a kommune and a fylke, we only want to show it once
        delete $all_councils->{301}     #
          if $all_councils->{3};
    }

}

=head2 setup_categories_and_councils

Look up categories for this council or councils

=cut

sub setup_categories_and_councils : Private {
    my ( $self, $c ) = @_;

    my @all_council_ids = keys %{ $c->stash->{all_councils} };

    my @contacts                #
      = $c                      #
      ->model('DB::Contact')    #
      ->not_deleted             #
      ->search( { area_id => \@all_council_ids } )    #
      ->all;

    # variables to populate
    my @area_ids_to_list = ();       # Areas with categories assigned
    my @category_options = ();       # categories to show
    my $category_label   = undef;    # what to call them

    # FIXME - implement in cobrand
    if ( $c->cobrand->moniker eq 'emptyhomes' ) {

        # add all areas found to the list
        foreach (@contacts) {
            push @area_ids_to_list, $_->area_id;
        }

        # set our own categories
        @category_options = (
            _('-- Pick a property type --'),
            _('Empty house or bungalow'),
            _('Empty flat or maisonette'),
            _('Whole block of empty flats'),
            _('Empty office or other commercial'),
            _('Empty pub or bar'),
            _('Empty public building - school, hospital, etc.')
        );
        $category_label = _('Property type:');
    }
    else {

        @contacts = keysort { $_->category } @contacts;
        foreach my $contact (@contacts) {
            push @area_ids_to_list, $contact->area_id;
            push @category_options, $contact->category
              unless $contact->category eq _('Other');
        }

        if (@category_options) {
            @category_options =
              ( _('-- Pick a category --'), @category_options, _('Other') );
            $category_label = _('Category:');
        }
    }

    # put results onto stash for display
    $c->stash->{area_ids_to_list} = \@area_ids_to_list;
    $c->stash->{category_label}   = $category_label;
    $c->stash->{category_options} = \@category_options;

    # add some conveniant things to the stash
    my $all_councils = $c->stash->{all_councils};
    my %area_ids_to_list_hash = map { $_ => 1 } @area_ids_to_list;

    my @missing_details_councils =
      grep { !$area_ids_to_list_hash{$_} }    #
      keys %$all_councils;

    my @missing_details_council_names =
      map { $all_councils->{$_}->{name} }     #
      @missing_details_councils;

    $c->stash->{missing_details_councils}      = @missing_details_councils;
    $c->stash->{missing_details_council_names} = @missing_details_council_names;
}

=head2 check_form_submitted

    $bool = $c->forward('check_form_submitted');

Returns true if the form has been submitted, false if not. Determines this based
on the presence of the C<submit_problem> parameter.

=cut

sub check_form_submitted : Private {
    my ( $self, $c ) = @_;
    return if $c->stash->{force_form_not_submitted};
    return $c->req->param('submit_problem') || '';
}

=head2 process_user

Load user from the database or prepare a new one.

=cut

sub process_user : Private {
    my ( $self, $c ) = @_;

    # FIXME - If user already logged in use them regardless

    # Extract all the params to a hash to make them easier to work with
    my %params =    #
      map { $_ => scalar $c->req->param($_) }    #
      ( 'email', 'name', 'phone', );

    # cleanup the email address
    my $email = lc $params{email};
    $email =~ s{\s+}{}g;

    my $report = $c->stash->{report};
    my $report_user                              #
      = ( $report ? $report->user : undef )
      || $c->model('DB::User')->find_or_new( { email => $email } );

    # set the user's name and phone (if given)
    $report_user->name( _trim_text( $params{name} ) );
    $report_user->phone( _trim_text( $params{phone} ) ) if $params{phone};

    $c->stash->{report_user} = $report_user;

    return 1;
}

=head2 process_report

Looking at the parameters passed in create a new item and return it. Does not
save anything to the database. If no item can be created (ie no information
provided) returns undef.

=cut

# args: allow_multiline => bool - strips out "\n\n" linebreaks
sub _cleanup_text {
    my $input = shift || '';
    my $args  = shift || {};

    # lowercase everything if looks like it might be SHOUTING
    $input = lc $input if $input !~ /[a-z]/;

    # clean up language and tradmarks
    for ($input) {

        # shit -> poo
        s{\bdog\s*shit\b}{dog poo}ig;

        # 'portakabin' to '[portable cabin]' (and variations)
        s{\b(porta)\s*([ck]abin|loo)\b}{[$1ble $2]}ig;
        s{kabin\]}{cabin\]}ig;
    }

    # Remove unneeded whitespace
    my @lines = grep { m/\S/ } split m/\n\n/, $input;
    for (@lines) {
        $_ = _trim_text($_);
        $_ = ucfirst $_;       # start with capital
    }

    my $join_char = $args->{allow_multiline} ? "\n\n" : " ";
    $input = join $join_char, @lines;

    return $input;
}

sub _trim_text {
    my $input = shift;
    for ($input) {
        last unless $_;
        s{\s+}{ }g;    # all whitespace to single space
        s{^ }{};       # trim leading
        s{ $}{};       # trim trailing
    }
    return $input;
}

sub process_report : Private {
    my ( $self, $c ) = @_;

    # Extract all the params to a hash to make them easier to work with
    my %params =       #
      map { $_ => scalar $c->req->param($_) }    #
      (
        'title', 'detail', 'pc',                 #
        'name', 'may_show_name',                 #
        'category',                              #
        'partial', 'skipped', 'submit_problem'   #
      );

    # load the report
    my $report = $c->stash->{report};

    # Enter the location and other bits which are not from the form
    $report->postcode( $params{pc} );
    $report->latitude( $c->stash->{latitude} );
    $report->longitude( $c->stash->{longitude} );

    # Short circuit unless the form has been submitted
    return 1 unless $params{submit_problem};

    # set some simple bool values (note they get inverted)
    $report->anonymous( $params{may_show_name} ? 0 : 1 );
    $report->used_map( $params{skipped}        ? 0 : 1 );

    # clean up text before setting
    $report->title( _cleanup_text( $params{title} ) );
    $report->detail(
        _cleanup_text( $params{detail}, { allow_multiline => 1 } ) );

    # set these straight from the params
    $report->name( _trim_text( $params{name} ) );
    $report->category( _ $params{category} );

    my $mapit_query =
      sprintf( "4326/%s,%s", $report->longitude, $report->latitude );
    my $areas = mySociety::MaPit::call( 'point', $mapit_query );
    $report->areas( ',' . join( ',', sort keys %$areas ) . ',' );

    # determine the area_types that this cobrand is interested in
    my @area_types = $c->cobrand->area_types();
    my %area_types_lookup = map { $_ => 1 } @area_types;

    # get all the councils that are of these types and cover this area
    my %councils =
      map { $_ => 1 }    #
      grep { $area_types_lookup{ $areas->{$_}->{type} } }    #
      keys %$areas;

    # partition the councils onto these two arrays
    my @councils_with_category    = ();
    my @councils_without_category = ();

    # all councils have all categories for emptyhomes
    if ( $c->cobrand->moniker eq 'emptyhomes' ) {
        @councils_with_category = keys %councils;
    }
    else {

        my @contacts = $c->       #
          model('DB::Contact')    #
          ->not_deleted           #
          ->search(
            {
                area_id  => [ keys %councils ],    #
                category => $report->category
            }
          )->all;

        # clear category if it is not in db for possible councils
        $report->category(undef) unless @contacts;

        my %councils_with_contact_for_category =
          map { $_->area_id => 1 } @contacts;

        foreach my $council_key ( keys %councils ) {
            $councils_with_contact_for_category{$council_key}
              ? push( @councils_with_category,    $council_key )
              : push( @councils_without_category, $council_key );
        }

    }

    # construct the council string:
    #  'x,x'     - x are councils_ids that have this category
    #  'x,x|y,y' - x are councils_ids that have this category, y don't
    my $council_string = join '|', grep { $_ }    #
      (
        join( ',', @councils_with_category ),
        join( ',', @councils_without_category )
      );
    $report->council($council_string);

    # set defaults that make sense
    $report->state('unconfirmed');

    # save the cobrand and language related information
    $report->cobrand( $c->cobrand->moniker );
    $report->cobrand_data( $c->cobrand->extra_problem_data );
    $report->lang( $c->stash->{lang_code} );

    return 1;
}

=head2 process_photo

Handle the photo - either checking and storing it after an upload or retrieving
it from the cache.

Store any error message onto 'photo_error' in stash.
=cut

sub process_photo : Private {
    my ( $self, $c ) = @_;

    return
         $c->forward('process_photo_upload')
      || $c->forward('process_photo_cache')
      || 1;    # always return true
}

sub process_photo_upload : Private {
    my ( $self, $c, $args ) = @_;

    # setup args and set defaults
    $args ||= {};
    $args->{rotate_photo} ||= 0;

    # check for upload or return
    my $upload = $c->req->upload('photo')
      || return;

    # check that the photo is a jpeg
    my $ct = $upload->type;
    unless ( $ct eq 'image/jpeg' || $ct eq 'image/pjpeg' ) {
        $c->stash->{photo_error} = _('Please upload a JPEG image only');
        return;
    }

    # convert the photo into a blob (also resize etc)
    my $photo_blob =
      eval { Page::process_photo( $upload->fh, $args->{rotate_photo} ) };
    if ( my $error = $@ ) {
        my $format = _(
"That image doesn't appear to have uploaded correctly (%s), please try again."
        );
        $c->stash->{photo_error} = sprintf( $format, $error );
        return;
    }

    # we have an image we can use - save it to the cache in case there is an
    # error
    my $cache_dir = dir( $c->config->{UPLOAD_CACHE} );
    $cache_dir->mkpath;
    unless ( -d $cache_dir && -w $cache_dir ) {
        warn "Can't find/write to photo cache directory '$cache_dir'";
        return;
    }

    # create a random name and store the file there
    my $fileid = int rand 1_000_000_000;
    my $file   = $cache_dir->file("$fileid.jpg");
    $file->openw->print($photo_blob);

    # stick the random number on the stash
    $c->stash->{upload_fileid} = $fileid;

    return 1;
}

=head2 process_photo_cache

Look for the upload_fileid parameter and check it matches a file on disk. If it
does return true and put fileid on stash, otherwise false.

=cut

sub process_photo_cache : Private {
    my ( $self, $c ) = @_;

    # get the fileid and make sure it is just a number
    my $fileid = $c->req->param('upload_fileid') || '';
    $fileid =~ s{\D+}{}g;
    return unless $fileid;

    my $file = file( $c->config->{UPLOAD_CACHE}, "$fileid.jpg" );
    return unless -e $file;

    $c->stash->{upload_fileid} = $fileid;
    return 1;
}

=head2 check_for_errors

Examine the user and the report for errors. If found put them on stash and
return false.

=cut

sub check_for_errors : Private {
    my ( $self, $c ) = @_;

    # let the model check for errors
    my %field_errors = (
        %{ $c->stash->{report_user}->check_for_errors },
        %{ $c->stash->{report}->check_for_errors },
    );

    # add the photo error if there is one.
    if ( my $photo_error = delete $c->stash->{photo_error} ) {
        $field_errors{photo} = $photo_error;
    }

    # all good if no errors
    return 1 unless scalar keys %field_errors;

    $c->stash->{field_errors} = \%field_errors;

    return;
}

=head2 save_user_and_report

Save the user and the report.

Be smart about the user - only set the name and phone if user did not exist
before or they are currently logged in. Otherwise discard any changes.

=cut

sub save_user_and_report : Private {
    my ( $self, $c ) = @_;
    my $report_user = $c->stash->{report_user};
    my $report      = $c->stash->{report};

    # Save or update the user if appropriate
    if ( !$report_user->in_storage ) {
        $report_user->insert();
    }
    elsif ( $c->user && $report_user->id == $c->user->id ) {
        $report_user->update();
        $report->confirm;
    }
    else {

        # user exists and we are not logged in as them. Throw away changes to
        # the name and phone. TODO - propagate changes using tokens.
        $report_user->discard_changes();
    }

    # add the user to the report
    $report->user($report_user);

    # If there was a photo add that too
    if ( my $fileid = $c->stash->{upload_fileid} ) {
        my $file = file( $c->config->{UPLOAD_CACHE}, "$fileid.jpg" );
        my $blob = $file->slurp;
        $file->remove;
        $report->photo($blob);
    }

    # Set a default if possible
    $report->category( _('Other') ) unless $report->category;

    # save the report;
    $report->in_storage ? $report->update : $report->insert();

    # tidy up
    if ( my $token = $c->stash->{partial_token} ) {
        $token->delete;
    }

    return 1;
}

=head2 generate_map

Add the html needed to for the map to the stash.

=cut

# FIXME - much of this should not happen here or in maps code but in the
# templates. Perhaps also create a map 'None' to use when map is skipped.

sub generate_map : Private {
    my ( $self, $c ) = @_;
    my $latitude  = $c->stash->{latitude};
    my $longitude = $c->stash->{longitude};

    # Forms that allow photos need a different enctype
    my $allow_photo_upload = $c->cobrand->allow_photo_upload;

    # Don't do anything if the user skipped the map
    if ( $c->req->param('skipped') ) {

        my $enctype =
          $allow_photo_upload
          ? ' enctype="multipart/form-data"'
          : '';

        my $cobrand_form_elements =
          $c->cobrand->form_elements('mapSkippedForm');

        my $form_action = $c->uri_for('');
        my $pc          = encode_entities( $c->stash->{pc} );

        $c->stash->{map_html} = <<"END_MAP_HTML";
<form action="$form_action" method="post" name="mapSkippedForm"$enctype>
<input type="hidden" name="latitude"  value="$latitude">
<input type="hidden" name="longitude" value="$longitude">
<input type="hidden" name="pc" value="$pc">
<input type="hidden" name="skipped" value="1">
$cobrand_form_elements
<div id="skipped-map">
END_MAP_HTML

    }
    else {
        my $map_type = $allow_photo_upload ? 2 : 1;

        $c->stash->{map_html} = FixMyStreet::Map::display_map(
            $c->req,
            latitude  => $latitude,
            longitude => $longitude,
            type      => $map_type,
            pins      => [ [ $latitude, $longitude, 'purple' ] ],
        );
    }

    # get the closing for the map
    $c->stash->{map_end} = FixMyStreet::Map::display_map_end(1);

    return 1;
}

=head2 redirect_or_confirm_creation

Now that the report has been created either redirect the user to its page if it
has been confirmed or email them a token if it has not been.

=cut

sub redirect_or_confirm_creation : Private {
    my ( $self, $c ) = @_;
    my $report = $c->stash->{report};

    # If confirmed send the user straigh there.
    if ( $report->confirmed ) {
        my $report_uri = $c->uri_for( '/report', $report->id );
        $c->res->redirect($report_uri);
        $c->detach;
    }

    # otherwise create a confirm token and email it to them.
    my $token =
      $c->model("DB::Token")
      ->create( { scope => 'problem', data => $report->id } );
    $c->stash->{token_url} = $c->uri_for( '/P', $token->token );
    $c->send_email( 'problem-confirm.txt', { to => $report->user->email } );

    # tell user that they've been sent an email
    $c->stash->{template}   = 'email_sent.html';
    $c->stash->{email_type} = 'problem';
}

__PACKAGE__->meta->make_immutable;

1;