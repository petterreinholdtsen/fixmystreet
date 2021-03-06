package FixMyStreet::Cobrand::LichfieldDC;
use base 'FixMyStreet::Cobrand::Default';

use strict;
use warnings;

use Carp;
use URI::Escape;
use mySociety::VotingArea;

sub site_restriction {
    return ( "and council like '%2434%'", 'lichfield', { council => '2434' } );
}

sub problems_clause {
    return { council => { like => '%2434%' } };
}

sub problems {
    my $self = shift;
    return $self->{c}->model('DB::Problem')->search( $self->problems_clause );
}

sub base_url {
    my $base_url = mySociety::Config::get('BASE_URL');
    if ( $base_url !~ /lichfielddc/ ) {
        $base_url =~ s{http://(?!www\.)}{http://lichfielddc.}g;
        $base_url =~ s{http://www\.}{http://lichfielddc.}g;
    }
    return $base_url;
}

sub site_title {
    my ($self) = @_;
    return 'Lichfield District Council FixMyStreet';
}

sub enter_postcode_text {
    my ($self) = @_;
    return 'Enter a Lichfield district postcode, or street name and area';
}

sub council_check {
    my ( $self, $params, $context ) = @_;

    my $councils = $params->{all_councils};
    my $council_match = defined $councils->{2434};
    if ($council_match) {
        return 1;
    }
    my $url = 'http://www.fixmystreet.com/';
    $url .= 'alert' if $context eq 'alert';
    $url .= '?pc=' . URI::Escape::uri_escape( $self->{c}->req->param('pc') )
      if $self->{c}->req->param('pc');
    my $error_msg = "That location is not covered by Lichfield District Council.
Please visit <a href=\"$url\">the main FixMyStreet site</a>.";
    return ( 0, $error_msg );
}

# All reports page only has the one council.
sub all_councils_report {
    return 0;
}

# FIXME - need to double check this is all correct
sub disambiguate_location {
    return {
        centre => '52.688198,-1.804966',
        span   => '0.1196,0.218675',
        bounds => [ '52.807793,-1.586291', '52.584891,-1.963232' ],
    };
}

sub recent_photos {
    my ( $self, $num, $lat, $lon, $dist ) = @_;
    $num = 2 if $num == 3;
    return $self->problems->recent_photos( $num, $lat, $lon, $dist );
}

1;

